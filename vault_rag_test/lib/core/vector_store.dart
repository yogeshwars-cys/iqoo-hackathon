/// vector_store.dart
///
/// Encrypted chunk storage plus an in-RAM vector index.
///
/// SCHEMA (user_version 2)
///
///   chunks(id TEXT PK, file_name TEXT, content_cipher BLOB, embedding BLOB)
///
/// `content_cipher` is AES-256-GCM under the AndroidKeyStore master key, in
/// the `IV(12) || ciphertext || tag(16)` layout KeystoreChannel.kt produces.
/// `embedding` stays a plaintext little-endian float32 BLOB: ranking needs
/// it, and the threat model this build targets is document text at rest.
/// Embeddings do leak *something* about content (see "Remaining
/// limitations" in SECURITY.md) — they are not a substitute for encryption,
/// and they are not the document.
///
/// QUERY PATH
///
///   1. [VectorMatrix.topK] ranks every chunk in RAM. No SQL, no decryption.
///   2. Only the k winners are read back: `SELECT id, content_cipher … WHERE
///      id IN (…)`.
///   3. Their ciphertexts are decrypted in ONE keystore batch call.
///
/// The matrix is loaded once in [open] from `SELECT id, file_name, embedding`
/// — `content_cipher` is never read during initialisation.
///
/// CONSISTENCY: SQLite is the source of truth and is always written first.
/// The matrix is only updated after the write succeeds, so a failed insert
/// (encryption refused, disk full, constraint) can never leave RAM pointing
/// at a row that does not exist.
///
/// WHY NOT sqlite-vec: a native extension inside Android's bundled SQLite is
/// its own integration project, and a contiguous float32 scan over a few
/// thousand rows runs in low single-digit milliseconds anyway. Revisit past
/// ~50k chunks, where an IVF or HNSW index starts to pay for itself.

library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'chunking.dart';
import 'security/keystore_service.dart';
import 'security/security_constants.dart';
import 'vector/vector_matrix.dart';

class RetrievedChunk {
  final String id;
  final String fileName;
  final String content;
  final double score;

  RetrievedChunk({
    required this.id,
    required this.fileName,
    required this.content,
    required this.score,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'file_name': fileName,
        'score': double.parse(score.toStringAsFixed(4)),
        'content': content,
      };
}

/// Chunk-level encrypt/decrypt, injectable so tests can count calls.
abstract interface class ChunkCipher {
  Future<Uint8List> encrypt(Uint8List plaintext);
  Future<List<Uint8List>> decryptBatch(List<Uint8List> payloads);
}

/// Production cipher: AndroidKeyStore via [KeystoreService].
class KeystoreChunkCipher implements ChunkCipher {
  const KeystoreChunkCipher();

  @override
  Future<Uint8List> encrypt(Uint8List plaintext) =>
      KeystoreService.encrypt(plaintext);

  @override
  Future<List<Uint8List>> decryptBatch(List<Uint8List> payloads) =>
      KeystoreService.decryptBatch(payloads);
}

/// Legacy plaintext rows could not be encrypted, so nothing was changed.
class VaultMigrationException implements Exception {
  final String message;
  const VaultMigrationException(this.message);
  @override
  String toString() => 'VaultMigrationException: $message';
}

/// A stored chunk failed authentication (tampered DB, or a lost key).
class ChunkIntegrityException implements Exception {
  final String chunkId;
  const ChunkIntegrityException(this.chunkId);
  @override
  String toString() =>
      'ChunkIntegrityException: stored chunk $chunkId failed authentication '
      '— the vault database was modified or its key is no longer available.';
}

class VectorStore {
  static const schemaVersion = 2;

  final Database _db;
  final ChunkCipher _cipher;
  final VectorMatrix _matrix;

  /// Rows skipped while loading the matrix: wrong BLOB length (another
  /// encoder's dimensionality, a truncated write) or non-finite values.
  final int skippedRows;

  int _lastRankMicros = 0;
  int _lastFetchMicros = 0;
  int _lastDecryptMicros = 0;

  VectorStore._(this._db, this._cipher, this._matrix, this.skippedRows);

  int get dimension => _matrix.dim;

  /// Chunk count, from RAM — this is read on every UI rebuild.
  int get count => _matrix.length;

  /// Microseconds for the pure in-RAM ranking of the most recent [topK].
  int get lastRankMicros => _lastRankMicros;
  int get lastFetchMicros => _lastFetchMicros;
  int get lastDecryptMicros => _lastDecryptMicros;

  /// Always 0 now that malformed rows are filtered at load time; kept for
  /// callers of the previous API.
  int get lastDimensionMismatches => 0;

  /// Opens (creating or migrating) the store at [path].
  static Future<VectorStore> open(
    String path, {
    ChunkCipher cipher = const KeystoreChunkCipher(),
    int dimension = kEmbeddingDim,
  }) =>
      openDatabase(sqlite3.open(path), cipher: cipher, dimension: dimension);

  /// Same as [open] over an already-open handle (tests use in-memory DBs).
  static Future<VectorStore> openDatabase(
    Database db, {
    ChunkCipher cipher = const KeystoreChunkCipher(),
    int dimension = kEmbeddingDim,
  }) async {
    try {
      // Deleted pages are zeroed rather than left in the file's free list —
      // matters most for the plaintext a legacy migration removes.
      db.execute('PRAGMA secure_delete = ON;');
      await _migrate(db, cipher);

      final matrix = VectorMatrix(
        dim: dimension,
        initialCapacity: math.max(256, _rowCount(db)),
      );
      var skipped = 0;
      // Index columns only. content_cipher is not read here.
      final rows = db.select('SELECT id, file_name, embedding FROM chunks');
      for (final row in rows) {
        final ok = matrix.upsertFromLittleEndianBytes(
          row['id'] as String,
          row['file_name'] as String,
          row['embedding'] as Uint8List,
        );
        if (!ok) skipped++;
      }
      return VectorStore._(db, cipher, matrix, skipped);
    } catch (_) {
      db.dispose();
      rethrow;
    }
  }

  static int _rowCount(Database db) =>
      db.select('SELECT COUNT(*) AS c FROM chunks').first['c'] as int;

  // -------------------------------------------------------------- migration

  static Future<void> _migrate(Database db, ChunkCipher cipher) async {
    final columns = {
      for (final r in db.select('PRAGMA table_info(chunks)')) r['name'] as String
    };

    if (columns.isEmpty) {
      db.execute('''
        CREATE TABLE chunks (
          id TEXT PRIMARY KEY,
          file_name TEXT NOT NULL,
          content_cipher BLOB NOT NULL,
          embedding BLOB NOT NULL
        );
      ''');
      db.execute('PRAGMA user_version = $schemaVersion;');
      return;
    }

    if (columns.contains('content_cipher') && !columns.contains('content')) {
      db.execute('PRAGMA user_version = $schemaVersion;');
      return; // already v2; idempotent
    }

    if (!columns.contains('content')) {
      throw VaultMigrationException(
          'Unrecognised chunks schema: ${columns.join(', ')}.');
    }

    // Legacy v1: plaintext `content`. Encrypt everything BEFORE touching the
    // file, so a keystore failure leaves the old database exactly as it was.
    final legacy = db.select('SELECT id, file_name, content, embedding FROM chunks');
    final encrypted = <Uint8List>[];
    try {
      for (final row in legacy) {
        encrypted.add(
            await cipher.encrypt(utf8.encode(row['content'] as String)));
      }
    } catch (e) {
      throw VaultMigrationException(
          'Could not encrypt ${legacy.length} legacy chunks '
          '(${e.runtimeType}); the database was left unchanged.');
    }

    db.execute('BEGIN IMMEDIATE;');
    try {
      db.execute('''
        CREATE TABLE chunks_v2 (
          id TEXT PRIMARY KEY,
          file_name TEXT NOT NULL,
          content_cipher BLOB NOT NULL,
          embedding BLOB NOT NULL
        );
      ''');
      final insert = db.prepare(
          'INSERT INTO chunks_v2 (id, file_name, content_cipher, embedding) '
          'VALUES (?, ?, ?, ?)');
      try {
        for (var i = 0; i < legacy.length; i++) {
          final row = legacy[i];
          insert.execute(
              [row['id'], row['file_name'], encrypted[i], row['embedding']]);
        }
      } finally {
        insert.dispose();
      }
      final migrated =
          db.select('SELECT COUNT(*) AS c FROM chunks_v2').first['c'] as int;
      if (migrated != legacy.length) {
        throw VaultMigrationException(
            'Migrated $migrated of ${legacy.length} chunks.');
      }
      db.execute('DROP TABLE chunks;');
      db.execute('ALTER TABLE chunks_v2 RENAME TO chunks;');
      db.execute('PRAGMA user_version = $schemaVersion;');
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
    // Rebuild the file so no page of the old plaintext table survives.
    db.execute('VACUUM;');
  }

  // ------------------------------------------------------------------ write

  /// Encrypts and persists [chunk], then indexes [embedding].
  Future<void> insert(TextChunk chunk, Float32List embedding) async {
    if (embedding.length != dimension) {
      throw ArgumentError.value(
          embedding.length, 'embedding.length', 'expected $dimension');
    }
    for (final v in embedding) {
      if (!v.isFinite) {
        throw ArgumentError('Embedding contains a non-finite component.');
      }
    }

    final plaintext = utf8.encode(chunk.content);
    final cipherText = await _cipher.encrypt(plaintext);
    plaintext.fillRange(0, plaintext.length, 0);

    // SQLite first. If this throws, the matrix was never touched.
    _db.execute(
      'INSERT OR REPLACE INTO chunks (id, file_name, content_cipher, embedding) '
      'VALUES (?, ?, ?, ?)',
      [chunk.id, chunk.fileName, cipherText, encodeEmbedding(embedding)],
    );
    _matrix.upsert(chunk.id, chunk.fileName, embedding);
  }

  /// Deletes one chunk. Returns whether a row existed.
  bool delete(String id) {
    _db.execute('DELETE FROM chunks WHERE id = ?', [id]);
    final deleted = _db.updatedRows > 0;
    _matrix.remove(id);
    return deleted;
  }

  void clear() {
    _db.execute('DELETE FROM chunks');
    _matrix.clear();
  }

  // ------------------------------------------------------------------- read

  /// Ranks in RAM only. Exposed for the benchmark and for tests that must
  /// prove ranking performs no decryption.
  List<MatrixHit> rank(Float32List queryEmbedding, {int k = 5}) {
    final sw = Stopwatch()..start();
    final hits = _matrix.topK(queryEmbedding, k);
    _lastRankMicros = sw.elapsedMicroseconds;
    return hits;
  }

  /// Top-[k] chunks, decrypting only the winners.
  ///
  /// Throws [ChunkIntegrityException] if a winning chunk fails GCM
  /// authentication: tampering is surfaced, never papered over with a
  /// partial result.
  Future<List<RetrievedChunk>> topK(Float32List queryEmbedding, {int k = 5}) async {
    if (queryEmbedding.length != dimension) return const [];
    final hits = rank(queryEmbedding, k: k);
    if (hits.isEmpty) return const [];

    final fetch = Stopwatch()..start();
    final placeholders = List.filled(hits.length, '?').join(',');
    final rows = _db.select(
      'SELECT id, content_cipher FROM chunks WHERE id IN ($placeholders)',
      [for (final h in hits) h.id],
    );
    final cipherById = {
      for (final r in rows) r['id'] as String: r['content_cipher'] as Uint8List
    };
    _lastFetchMicros = fetch.elapsedMicroseconds;

    // Keep rank order; drop any id the DB no longer has (cannot happen
    // through this class, but a file edited underneath it can do it).
    final present = [for (final h in hits) if (cipherById.containsKey(h.id)) h];

    final decrypt = Stopwatch()..start();
    final List<Uint8List> plaintexts;
    try {
      plaintexts = await _cipher
          .decryptBatch([for (final h in present) cipherById[h.id]!]);
    } on CiphertextIntegrityException {
      // Find which one, for the error message, without returning any.
      throw ChunkIntegrityException(await _firstBadChunk(present, cipherById));
    }
    _lastDecryptMicros = decrypt.elapsedMicroseconds;

    return [
      for (var i = 0; i < present.length; i++)
        RetrievedChunk(
          id: present[i].id,
          fileName: present[i].fileName,
          content: utf8.decode(plaintexts[i]),
          score: present[i].score,
        ),
    ];
  }

  Future<String> _firstBadChunk(
      List<MatrixHit> hits, Map<String, Uint8List> cipherById) async {
    for (final h in hits) {
      try {
        await _cipher.decryptBatch([cipherById[h.id]!]);
      } on CiphertextIntegrityException {
        return h.id;
      }
    }
    return hits.isEmpty ? '?' : hits.first.id;
  }

  void close() => _db.dispose();
}

/// Little-endian float32 packing — the on-disk embedding format. Explicit
/// rather than a raw buffer view so it is independent of host byte order
/// and of whether the BLOB's backing buffer is 4-byte aligned.
Uint8List encodeEmbedding(Float32List floats) {
  final bytes = ByteData(floats.length * 4);
  for (var i = 0; i < floats.length; i++) {
    bytes.setFloat32(i * 4, floats[i], Endian.little);
  }
  return bytes.buffer.asUint8List();
}

/// Cosine similarity of two equal-length vectors.
///
/// Returns 0 for a length mismatch instead of throwing — a scoring function
/// that can throw is one that can fail a whole query on one bad row. The
/// store itself ranks through [VectorMatrix], which shares these semantics.
double cosineSimilarity(Float32List a, Float32List b) {
  if (a.length != b.length || a.isEmpty) return 0.0;

  var dot = 0.0, normA = 0.0, normB = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  if (normA == 0 || normB == 0) return 0.0;

  final score = dot / (math.sqrt(normA) * math.sqrt(normB));
  // Float error can push a unit-vector dot product a hair outside [-1, 1].
  return score.isFinite ? score.clamp(-1.0, 1.0) : 0.0;
}
