/// Encrypted store + in-RAM matrix.
///
/// The VectorMatrix group is pure Dart. The VectorStore group opens a real
/// in-memory SQLite database and skips itself where the host has no sqlite3
/// library — it does not fake SQL.

library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:vault_rag_test/core/chunking.dart';
import 'package:vault_rag_test/core/security/host_test_keystore.dart';
import 'package:vault_rag_test/core/security/keystore_service.dart';
import 'package:vault_rag_test/core/security/security_constants.dart';
import 'package:vault_rag_test/core/vector/rank_benchmark.dart';
import 'package:vault_rag_test/core/vector/vector_matrix.dart';
import 'package:vault_rag_test/core/vector_store.dart';

Float32List randomUnit(Random rng, [int dim = kEmbeddingDim]) {
  final v = Float32List(dim);
  var n = 0.0;
  for (var i = 0; i < dim; i++) {
    v[i] = rng.nextDouble() * 2 - 1;
    n += v[i] * v[i];
  }
  final inv = 1 / sqrt(n);
  for (var i = 0; i < dim; i++) {
    v[i] *= inv;
  }
  return v;
}

/// Counts calls and can be told to fail, around the host AES-GCM double.
class CountingCipher implements ChunkCipher {
  final inner = HostTestKeystoreBackend();
  int encrypts = 0;
  int decrypts = 0;
  bool failEncrypt = false;

  @override
  Future<Uint8List> encrypt(Uint8List plaintext) {
    encrypts++;
    if (failEncrypt) {
      return Future.error(const KeystoreUnavailableException('refused'));
    }
    return inner.encrypt(plaintext);
  }

  @override
  Future<List<Uint8List>> decryptBatch(List<Uint8List> payloads) {
    decrypts += payloads.length;
    return inner.decryptBatch(payloads);
  }
}

TextChunk chunk(String id, String content, [String file = 'doc.md']) =>
    TextChunk(id: id, fileName: file, content: content, startWord: 0, endWord: 1);

bool sqliteAvailable() {
  try {
    sqlite3.openInMemory().dispose();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  group('VectorMatrix', () {
    test('lays rows out contiguously and ranks by exact cosine', () {
      final rng = Random(7);
      final m = VectorMatrix(dim: kEmbeddingDim, initialCapacity: 2);
      final vectors = <String, Float32List>{};
      for (var i = 0; i < 300; i++) {
        final v = randomUnit(rng);
        vectors['c$i'] = v;
        m.upsert('c$i', 'f', v);
      }
      expect(m.length, 300);
      expect(m.liveBuffer.length, 300 * kEmbeddingDim);
      expect(m.liveBuffer.sublist(0, kEmbeddingDim), vectors['c0']);

      final q = randomUnit(rng);
      final expected = vectors.entries
          .map((e) => MapEntry(e.key, cosineSimilarity(q, e.value)))
          .toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final hits = m.topK(q, 5);
      expect(hits.map((h) => h.id), expected.take(5).map((e) => e.key));
      for (var i = 0; i < 5; i++) {
        expect(hits[i].score, closeTo(expected[i].value, 1e-5));
      }
    });

    test('cosine is correct for vectors that are not unit length', () {
      final m = VectorMatrix(dim: 3);
      m.upsert('long', 'f', Float32List.fromList([10, 0, 0.1]));
      m.upsert('aligned', 'f', Float32List.fromList([0, 1, 0]));
      final hits = m.topK(Float32List.fromList([0, 2, 0]), 2);
      expect(hits.first.id, 'aligned');
      expect(hits.first.score, closeTo(1.0, 1e-6));
    });

    test('rejects wrong dimensions and non-finite values', () {
      final m = VectorMatrix(dim: kEmbeddingDim);
      expect(() => m.upsert('x', 'f', Float32List(383)), throwsArgumentError);
      expect(() => m.upsert('x', 'f', Float32List(kEmbeddingDim)..[5] = double.nan),
          throwsArgumentError);
      expect(m.upsertFromLittleEndianBytes('x', 'f', Uint8List(383 * 4)), isFalse);
      expect(m.length, 0);
      expect(() => m.topK(Float32List(10), 3), throwsArgumentError);
    });

    test('reads little-endian float32 BLOBs exactly', () {
      final v = randomUnit(Random(1));
      final m = VectorMatrix(dim: kEmbeddingDim)
        ..upsertFromLittleEndianBytes('a', 'f', encodeEmbedding(v));
      expect(m.liveBuffer, v);
    });

    test('equal scores order deterministically by id', () {
      final m = VectorMatrix(dim: 2);
      for (final id in ['c', 'a', 'b']) {
        m.upsert(id, 'f', Float32List.fromList([1, 0]));
      }
      expect(m.topK(Float32List.fromList([1, 0]), 3).map((h) => h.id),
          ['a', 'b', 'c']);
    });

    test('remove keeps the live region contiguous and the index right', () {
      final rng = Random(3);
      final m = VectorMatrix(dim: kEmbeddingDim);
      final vs = [for (var i = 0; i < 4; i++) randomUnit(rng)];
      for (var i = 0; i < 4; i++) {
        m.upsert('c$i', 'f$i', vs[i]);
      }
      expect(m.remove('c1'), isTrue);
      expect(m.remove('c1'), isFalse);
      expect(m.length, 3);
      expect(m.liveBuffer.length, 3 * kEmbeddingDim);
      // c3 moved into c1's slot; querying by its own vector still finds it.
      final hit = m.topK(vs[3], 1).single;
      expect(hit.id, 'c3');
      expect(hit.fileName, 'f3');
      expect(hit.score, closeTo(1, 1e-6));
    });

    test('upsert replaces in place; clear empties everything', () {
      final m = VectorMatrix(dim: 2)
        ..upsert('a', 'f', Float32List.fromList([1, 0]))
        ..upsert('a', 'g', Float32List.fromList([0, 1]));
      expect(m.length, 1);
      expect(m.topK(Float32List.fromList([0, 1]), 1).single.fileName, 'g');
      m.clear();
      expect(m.length, 0);
      expect(m.topK(Float32List.fromList([0, 1]), 1), isEmpty);
    });

    test('BENCHMARK: rank 1,000 x 384 vectors (ranking only)', () {
      final r = runRankBenchmark(vectors: 1000, runs: 200);
      // Host numbers (flutter test = JIT on a desktop CPU), NOT a device
      // result. The device figure comes from lib/bench_rank_main.dart.
      // ignore: avoid_print
      print('HOST $r');
      // Loose sanity bound only, so a slow CI box cannot fail the suite.
      expect(r.medianMs, lessThan(50));
    });
  });

  group('VectorStore (SQLite)', skip: sqliteAvailable() ? false : 'no sqlite3 on host', () {
    late Database db;
    late CountingCipher cipher;

    setUp(() {
      db = sqlite3.openInMemory();
      cipher = CountingCipher();
    });

    Future<VectorStore> open() =>
        VectorStore.openDatabase(db, cipher: cipher, dimension: kEmbeddingDim);

    test('fresh schema matches the specification', () async {
      final store = await open();
      final cols = {
        for (final r in db.select('PRAGMA table_info(chunks)'))
          r['name'] as String: r['type'] as String
      };
      expect(cols, {
        'id': 'TEXT',
        'file_name': 'TEXT',
        'content_cipher': 'BLOB',
        'embedding': 'BLOB',
      });
      expect(db.select('PRAGMA user_version').first.values.first, 2);
      store.close();
    });

    test('content is encrypted at rest; plaintext is not in the database', () async {
      final store = await open();
      const secret = 'Employee 413 salary is 184,000 USD — confidential';
      await store.insert(chunk('c0', secret), randomUnit(Random(1)));

      final row = db.select('SELECT content_cipher FROM chunks').single;
      final blob = row['content_cipher'] as Uint8List;
      expect(blob.length, utf8.encode(secret).length + kGcmMinPayloadLength);
      // Byte-level search for the plaintext and for a distinctive token.
      String latin1(Uint8List b) => String.fromCharCodes(b);
      expect(latin1(blob).contains('184,000'), isFalse);
      final hex = blob.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final needle = utf8
          .encode('salary')
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(hex.contains(needle), isFalse);
      // Nothing anywhere in the table reads back as the plaintext.
      final dump = db.select('SELECT * FROM chunks').toString();
      expect(dump.contains('salary'), isFalse);
    });

    test('raw database file never contains the plaintext, even after migration',
        () async {
      final dir = Directory.systemTemp.createTempSync('vault_raw_');
      final path = '${dir.path}/vault.db';
      db.dispose();
      db = sqlite3.open(path);
      // Start from a legacy plaintext vault so freed pages would hold it.
      db.execute('CREATE TABLE chunks (id TEXT PRIMARY KEY, file_name TEXT NOT NULL, '
          'content TEXT NOT NULL, embedding BLOB NOT NULL)');
      const marker = 'ZEBRA-PASSPORT-K7781234-PLAINTEXT-MARKER';
      db.execute('INSERT INTO chunks VALUES (?,?,?,?)',
          ['old', 'hr.md', 'legacy $marker', encodeEmbedding(randomUnit(Random(1)))]);
      final store = await open();
      await store.insert(chunk('new', 'fresh $marker'), randomUnit(Random(2)));
      store.close();

      final raw = File(path).readAsBytesSync();
      final needle = utf8.encode(marker);
      bool containsBytes(List<int> hay, List<int> n) {
        outer:
        for (var i = 0; i <= hay.length - n.length; i++) {
          for (var j = 0; j < n.length; j++) {
            if (hay[i + j] != n[j]) continue outer;
          }
          return true;
        }
        return false;
      }

      expect(raw.length, greaterThan(0));
      expect(containsBytes(raw, needle), isFalse,
          reason: 'plaintext marker found in the raw database file');
      for (final f in dir.listSync().whereType<File>()) {
        expect(containsBytes(f.readAsBytesSync(), needle), isFalse,
            reason: 'plaintext marker found in ${f.path}');
      }
      dir.deleteSync(recursive: true);
    });

    test('ranking decrypts nothing; topK decrypts only the winners', () async {
      final rng = Random(9);
      final store = await open();
      final vs = <Float32List>[];
      for (var i = 0; i < 40; i++) {
        vs.add(randomUnit(rng));
        await store.insert(chunk('c${i.toString().padLeft(2, '0')}', 'text $i'), vs[i]);
      }
      cipher.decrypts = 0;

      final hits = store.rank(vs[17], k: 3);
      expect(hits.first.id, 'c17');
      expect(cipher.decrypts, 0);

      final results = await store.topK(vs[17], k: 3);
      expect(cipher.decrypts, 3);
      expect(results.first.content, 'text 17');
      expect(results.map((r) => r.id), hits.map((h) => h.id));
      expect(store.lastRankMicros, greaterThanOrEqualTo(0));
      store.close();
    });

    test('reopening rebuilds the matrix without reading content_cipher', () async {
      final rng = Random(5);
      final path = db; // same in-memory handle; reopen over it
      var store = await VectorStore.openDatabase(path, cipher: cipher);
      final v = randomUnit(rng);
      await store.insert(chunk('keep', 'kept text'), v);
      // New store object over the same connection (close would free it).
      cipher.decrypts = 0;
      store = await VectorStore.openDatabase(path, cipher: cipher);
      expect(store.count, 1);
      expect(cipher.decrypts, 0);
      expect((await store.topK(v, k: 1)).single.content, 'kept text');
    });

    test('failed encryption leaves neither a row nor a cache entry', () async {
      final store = await open();
      cipher.failEncrypt = true;
      await expectLater(
        store.insert(chunk('x', 'text'), randomUnit(Random(2))),
        throwsA(isA<KeystoreUnavailableException>()),
      );
      expect(store.count, 0);
      expect(db.select('SELECT COUNT(*) c FROM chunks').first['c'], 0);
    });

    test('duplicate ids replace, delete and clear keep DB and cache in step',
        () async {
      final rng = Random(4);
      final store = await open();
      final v1 = randomUnit(rng), v2 = randomUnit(rng);
      await store.insert(chunk('a', 'first'), v1);
      await store.insert(chunk('a', 'second'), v2);
      await store.insert(chunk('b', 'other'), v1);
      expect(store.count, 2);
      expect((await store.topK(v2, k: 1)).single.content, 'second');

      expect(store.delete('a'), isTrue);
      expect(store.count, 1);
      expect(db.select('SELECT id FROM chunks').map((r) => r['id']), ['b']);
      expect(store.rank(v2, k: 5).map((h) => h.id), ['b']);

      store.clear();
      expect(store.count, 0);
      expect(db.select('SELECT COUNT(*) c FROM chunks').first['c'], 0);
      expect(await store.topK(v1), isEmpty);
    });

    test('a tampered ciphertext fails closed with no plaintext', () async {
      final store = await open();
      final v = randomUnit(Random(6));
      await store.insert(chunk('t', 'do not leak'), v);
      final blob = Uint8List.fromList(
          db.select('SELECT content_cipher FROM chunks').single['content_cipher']
              as Uint8List)
        ..[kGcmIvLength] ^= 0xff;
      db.execute('UPDATE chunks SET content_cipher = ?', [blob]);
      await expectLater(store.topK(v, k: 1),
          throwsA(isA<ChunkIntegrityException>()));
    });

    test('malformed embeddings are skipped at load, not fatal', () async {
      db.execute('CREATE TABLE chunks (id TEXT PRIMARY KEY, file_name TEXT NOT NULL, '
          'content_cipher BLOB NOT NULL, embedding BLOB NOT NULL)');
      final good = encodeEmbedding(randomUnit(Random(8)));
      final sealed = await cipher.encrypt(Uint8List.fromList(utf8.encode('ok')));
      db.execute('INSERT INTO chunks VALUES (?,?,?,?)', ['good', 'f', sealed, good]);
      db.execute('INSERT INTO chunks VALUES (?,?,?,?)',
          ['short', 'f', sealed, Uint8List(100)]);
      final store = await open();
      expect(store.count, 1);
      expect(store.skippedRows, 1);
    });

    group('migration from the plaintext v1 schema', () {
      void createLegacy() {
        db.execute('CREATE TABLE chunks (id TEXT PRIMARY KEY, file_name TEXT NOT NULL, '
            'content TEXT NOT NULL, embedding BLOB NOT NULL)');
        final rng = Random(11);
        for (var i = 0; i < 5; i++) {
          db.execute('INSERT INTO chunks VALUES (?,?,?,?)', [
            'legacy$i',
            'old.md',
            'legacy secret number $i',
            encodeEmbedding(randomUnit(rng)),
          ]);
        }
      }

      test('encrypts every row, preserves ids and embeddings, drops plaintext',
          () async {
        createLegacy();
        final before = {
          for (final r in db.select('SELECT id, embedding FROM chunks'))
            r['id']: r['embedding'] as Uint8List
        };
        final store = await open();
        expect(store.count, 5);
        final cols = db.select('PRAGMA table_info(chunks)').map((r) => r['name']);
        expect(cols, isNot(contains('content')));
        for (final r in db.select('SELECT id, embedding, content_cipher FROM chunks')) {
          expect(r['embedding'], before[r['id']]);
          expect(String.fromCharCodes(r['content_cipher'] as Uint8List)
              .contains('legacy secret'), isFalse);
        }
        final hit =
            (await store.topK(_decode(before['legacy3']!), k: 1)).single;
        expect(hit.id, 'legacy3');
        expect(hit.content, 'legacy secret number 3');
      });

      test('is idempotent', () async {
        createLegacy();
        await open();
        final encryptsAfterFirst = cipher.encrypts;
        await open();
        expect(cipher.encrypts, encryptsAfterFirst);
        expect(db.select('SELECT COUNT(*) c FROM chunks').first['c'], 5);
      });

      test('keystore failure leaves the legacy database untouched', () async {
        final dir = Directory.systemTemp.createTempSync('vault_migrate_');
        final path = '${dir.path}/vault.db';
        db.dispose();
        db = sqlite3.open(path);
        createLegacy();
        cipher.failEncrypt = true;
        await expectLater(open(), throwsA(isA<VaultMigrationException>()));

        // open() closed the handle; inspect the file with a fresh one.
        final check = sqlite3.open(path);
        final tables = check
            .select("SELECT name FROM sqlite_master WHERE type='table'")
            .map((r) => r['name'])
            .toList();
        expect(tables, ['chunks']);
        expect(check.select('SELECT COUNT(*) c FROM chunks').first['c'], 5);
        expect(check.select('PRAGMA table_info(chunks)').map((r) => r['name']),
            contains('content'));
        check.dispose();
        dir.deleteSync(recursive: true);
      });
    });
  });
}

Float32List _decode(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  return Float32List.fromList(
      [for (var i = 0; i < bytes.length ~/ 4; i++) data.getFloat32(i * 4, Endian.little)]);
}
