/// vector_store.dart
///
/// Stores chunk embeddings as plain BLOBs in a local SQLite database and
/// ranks them with brute-force cosine similarity in Dart.
///
/// WHY NOT sqlite-vec: it's a native SQLite extension, and loading a
/// native extension into Android's bundled SQLite from Flutter is a real
/// integration project on its own — not worth the risk for a corpus of a
/// few hundred to a few thousand chunks, where brute-force cosine over
/// Float32 vectors in Dart runs in low single-digit milliseconds anyway.
/// If your vault ever grows past ~20k chunks, revisit this — not before.

library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'package:sqlite3/sqlite3.dart';
import 'chunking.dart';

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

class VectorStore {
  final Database _db;

  VectorStore._(this._db);

  static VectorStore open(String path) {
    final db = sqlite3.open(path);
    db.execute('''
      CREATE TABLE IF NOT EXISTS chunks (
        id TEXT PRIMARY KEY,
        file_name TEXT NOT NULL,
        content TEXT NOT NULL,
        embedding BLOB NOT NULL
      );
    ''');
    return VectorStore._(db);
  }

  void insert(TextChunk chunk, Float32List embedding) {
    _db.execute(
      'INSERT OR REPLACE INTO chunks (id, file_name, content, embedding) '
      'VALUES (?, ?, ?, ?)',
      [chunk.id, chunk.fileName, chunk.content, _encode(embedding)],
    );
  }

  void clear() => _db.execute('DELETE FROM chunks');

  int get count {
    final result = _db.select('SELECT COUNT(*) as c FROM chunks');
    return result.first['c'] as int;
  }

  /// Brute-force cosine similarity search across every stored chunk. Fine
  /// up to a few thousand rows on phone-class hardware — see file header.
  List<RetrievedChunk> topK(Float32List queryEmbedding, {int k = 5}) {
    final rows = _db.select(
      'SELECT id, file_name, content, embedding FROM chunks',
    );
    final scored = <RetrievedChunk>[];

    for (final row in rows) {
      final candidate = _decode(row['embedding'] as Uint8List);
      final score = _cosine(queryEmbedding, candidate);
      scored.add(RetrievedChunk(
        id: row['id'] as String,
        fileName: row['file_name'] as String,
        content: row['content'] as String,
        score: score,
      ));
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(k).toList();
  }

  double _cosine(Float32List a, Float32List b) {
    var dot = 0.0, normA = 0.0, normB = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA == 0 || normB == 0) return 0.0;
    return dot / (math.sqrt(normA) * math.sqrt(normB));
  }

  // Explicit little-endian byte packing rather than a raw buffer view —
  // safer across host byte orders and doesn't assume the BLOB's backing
  // buffer happens to be 4-byte aligned.
  Uint8List _encode(Float32List floats) {
    final bytes = ByteData(floats.length * 4);
    for (var i = 0; i < floats.length; i++) {
      bytes.setFloat32(i * 4, floats[i], Endian.little);
    }
    return bytes.buffer.asUint8List();
  }

  Float32List _decode(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    final floats = Float32List(bytes.length ~/ 4);
    for (var i = 0; i < floats.length; i++) {
      floats[i] = data.getFloat32(i * 4, Endian.little);
    }
    return floats;
  }

  void close() => _db.dispose();
}
