/// vector_matrix.dart
///
/// The in-RAM retrieval index: every embedding in one contiguous
/// [Float32List], ranked without touching SQLite, the keystore, or the heap
/// per row.
///
/// LAYOUT
///
///   _matrix   [v0_0 … v0_383][v1_0 … v1_383] …   capacity × dim float32s
///   _invNorms [1/|v0|][1/|v1|] …                 one float32 per row
///   _ids, _fileNames                             parallel, row-indexed
///   _rowOf    id -> row                          for replace / delete
///
/// Row i occupies `_matrix[i * dim .. (i + 1) * dim)`. Capacity doubles on
/// growth, so N inserts cost O(N) amortised copies, and deletion swaps the
/// last row into the hole so the live region stays contiguous with no gaps
/// to skip at query time.
///
/// WHY COSINE WITH CACHED NORMS RATHER THAN A BARE DOT PRODUCT
///
/// MiniLMEmbeddingService L2-normalises its output, so for vectors it
/// produced cosine == dot. But the store cannot prove every row came from
/// that path (a legacy row, a future encoder), and ranking with a bare dot
/// product silently favours long vectors if one ever is not unit length.
/// Caching 1/|v| at insert time keeps cosine exact for any input while the
/// per-query cost stays one multiply per row on top of the dot product.
///
/// TOP-K SELECTION
///
/// A bounded min-heap of size k over two primitive arrays (score, row):
/// O(N log k), no sort of the whole corpus, no per-row allocation. Equal
/// scores are broken by chunk id, so the ordering is deterministic whatever
/// physical row a chunk happens to occupy after swap-deletes.

library;

import 'dart:math' as math;
import 'dart:typed_data';

class MatrixHit {
  final String id;
  final String fileName;
  final double score;

  const MatrixHit(this.id, this.fileName, this.score);
}

class VectorMatrix {
  final int dim;

  Float32List _matrix;
  Float32List _invNorms;
  final List<String> _ids = [];
  final List<String> _fileNames = [];
  final Map<String, int> _rowOf = {};

  VectorMatrix({required this.dim, int initialCapacity = 256})
      : assert(dim > 0),
        _matrix = Float32List(math.max(1, initialCapacity) * dim),
        _invNorms = Float32List(math.max(1, initialCapacity));

  int get length => _ids.length;
  int get capacity => _invNorms.length;
  bool contains(String id) => _rowOf.containsKey(id);
  List<String> get ids => List.unmodifiable(_ids);

  /// Exposed for the benchmark and tests: the live region of the buffer.
  Float32List get liveBuffer => Float32List.sublistView(_matrix, 0, length * dim);

  /// Inserts or replaces [id]. Throws [ArgumentError] for a wrong dimension
  /// or non-finite component — a NaN row would poison every ranking.
  void upsert(String id, String fileName, Float32List vector) {
    _checkVector(vector);
    final existing = _rowOf[id];
    final row = existing ?? _appendRow(id, fileName);
    if (existing != null) _fileNames[row] = fileName;
    _writeRow(row, vector, 0);
  }

  /// Fills a row straight from a little-endian float32 BLOB, without an
  /// intermediate Float32List. Returns false (and inserts nothing) when the
  /// BLOB is the wrong length or contains non-finite values.
  bool upsertFromLittleEndianBytes(String id, String fileName, Uint8List blob) {
    if (blob.length != dim * 4) return false;
    final data = ByteData.sublistView(blob);
    for (var j = 0; j < dim; j++) {
      if (!data.getFloat32(j * 4, Endian.little).isFinite) return false;
    }
    final existing = _rowOf[id];
    final row = existing ?? _appendRow(id, fileName);
    if (existing != null) _fileNames[row] = fileName;

    final base = row * dim;
    var normSq = 0.0;
    for (var j = 0; j < dim; j++) {
      final v = data.getFloat32(j * 4, Endian.little);
      _matrix[base + j] = v;
      normSq += v * v;
    }
    _invNorms[row] = normSq > 0 ? 1.0 / math.sqrt(normSq) : 0.0;
    return true;
  }

  /// Removes [id], moving the last row into its slot. Returns whether it
  /// was present.
  bool remove(String id) {
    final row = _rowOf.remove(id);
    if (row == null) return false;
    final last = length - 1;
    if (row != last) {
      final src = last * dim;
      _matrix.setRange(row * dim, row * dim + dim, _matrix, src);
      _invNorms[row] = _invNorms[last];
      _ids[row] = _ids[last];
      _fileNames[row] = _fileNames[last];
      _rowOf[_ids[row]] = row;
    }
    _ids.removeLast();
    _fileNames.removeLast();
    return true;
  }

  void clear() {
    _ids.clear();
    _fileNames.clear();
    _rowOf.clear();
    // Zero the numbers too: embeddings are derived from document content.
    _matrix.fillRange(0, _matrix.length, 0);
    _invNorms.fillRange(0, _invNorms.length, 0);
  }

  /// Top-[k] rows by cosine similarity to [query]. Pure RAM: no I/O, no
  /// decryption, and the only allocations are the k-sized heap arrays and
  /// the k result objects.
  List<MatrixHit> topK(Float32List query, int k) {
    if (query.length != dim) {
      throw ArgumentError.value(
          query.length, 'query.length', 'expected $dim dimensions');
    }
    final n = length;
    if (n == 0 || k <= 0) return const [];
    final kk = math.min(k, n);

    var qNormSq = 0.0;
    for (var j = 0; j < dim; j++) {
      qNormSq += query[j] * query[j];
    }
    if (!(qNormSq > 0) || !qNormSq.isFinite) return const [];
    final qInv = 1.0 / math.sqrt(qNormSq);

    final heapScores = Float64List(kk);
    final heapRows = Int32List(kk);
    var heapSize = 0;

    final m = _matrix;
    final d = dim;
    final tail = d - (d % 4);

    for (var row = 0; row < n; row++) {
      final base = row * d;
      // Unrolled by four: fewer bounds checks and loop-condition branches
      // per component, which is most of the scan's cost in Dart AOT.
      var dot = 0.0;
      var j = 0;
      for (; j < tail; j += 4) {
        dot += m[base + j] * query[j] +
            m[base + j + 1] * query[j + 1] +
            m[base + j + 2] * query[j + 2] +
            m[base + j + 3] * query[j + 3];
      }
      for (; j < d; j++) {
        dot += m[base + j] * query[j];
      }
      var score = dot * _invNorms[row] * qInv;
      if (score > 1.0) score = 1.0;
      if (score < -1.0) score = -1.0;

      if (heapSize < kk) {
        heapScores[heapSize] = score;
        heapRows[heapSize] = row;
        heapSize++;
        _siftUp(heapScores, heapRows, heapSize - 1);
      } else if (_better(score, row, heapScores[0], heapRows[0])) {
        heapScores[0] = score;
        heapRows[0] = row;
        _siftDown(heapScores, heapRows, heapSize);
      }
    }

    // Pop the min-heap into descending order.
    final out = List<MatrixHit?>.filled(heapSize, null);
    for (var i = heapSize - 1; i >= 0; i--) {
      final row = heapRows[0];
      out[i] = MatrixHit(_ids[row], _fileNames[row], heapScores[0]);
      heapSize--;
      if (heapSize > 0) {
        heapScores[0] = heapScores[heapSize];
        heapRows[0] = heapRows[heapSize];
        _siftDown(heapScores, heapRows, heapSize);
      }
    }
    return out.cast<MatrixHit>();
  }

  /// "a ranks above b": higher score, or equal score and smaller id.
  bool _better(double sa, int ra, double sb, int rb) =>
      sa > sb || (sa == sb && _ids[ra].compareTo(_ids[rb]) < 0);

  void _siftUp(Float64List s, Int32List r, int i) {
    while (i > 0) {
      final parent = (i - 1) >> 1;
      // Min-heap on "rank": the root is the worst of the kept candidates.
      if (_better(s[parent], r[parent], s[i], r[i])) {
        _swap(s, r, i, parent);
        i = parent;
      } else {
        return;
      }
    }
  }

  void _siftDown(Float64List s, Int32List r, int size) {
    var i = 0;
    while (true) {
      final left = 2 * i + 1;
      final right = left + 1;
      var worst = i;
      if (left < size && _better(s[worst], r[worst], s[left], r[left])) {
        worst = left;
      }
      if (right < size && _better(s[worst], r[worst], s[right], r[right])) {
        worst = right;
      }
      if (worst == i) return;
      _swap(s, r, i, worst);
      i = worst;
    }
  }

  static void _swap(Float64List s, Int32List r, int a, int b) {
    final ts = s[a];
    s[a] = s[b];
    s[b] = ts;
    final tr = r[a];
    r[a] = r[b];
    r[b] = tr;
  }

  int _appendRow(String id, String fileName) {
    final row = length;
    if (row == capacity) _grow();
    _ids.add(id);
    _fileNames.add(fileName);
    _rowOf[id] = row;
    return row;
  }

  void _grow() {
    final newCapacity = capacity * 2;
    _matrix = Float32List(newCapacity * dim)..setRange(0, length * dim, _matrix);
    _invNorms = Float32List(newCapacity)..setRange(0, length, _invNorms);
  }

  void _writeRow(int row, Float32List v, int offset) {
    final base = row * dim;
    var normSq = 0.0;
    for (var j = 0; j < dim; j++) {
      final x = v[offset + j];
      _matrix[base + j] = x;
      normSq += x * x;
    }
    _invNorms[row] = normSq > 0 ? 1.0 / math.sqrt(normSq) : 0.0;
  }

  void _checkVector(Float32List v) {
    if (v.length != dim) {
      throw ArgumentError.value(v.length, 'vector.length', 'expected $dim');
    }
    for (var j = 0; j < dim; j++) {
      if (!v[j].isFinite) {
        throw ArgumentError('Embedding contains a non-finite component.');
      }
    }
  }
}
