/// rank_benchmark.dart
///
/// Times [VectorMatrix.topK] alone — no SQLite, no decryption, no encoder,
/// no UI — so the number means exactly "vector ranking". Used by the host
/// test and by `lib/bench_rank_main.dart` on the device:
///
///   flutter run --release --flavor airgap -t lib/bench_rank_main.dart
///
/// Run it in release (AOT); debug/JIT numbers are not representative.

library;

import 'dart:math';
import 'dart:typed_data';

import '../security/security_constants.dart';
import 'vector_matrix.dart';

class RankBenchmarkResult {
  final int vectors;
  final int dim;
  final int runs;
  final int k;
  final List<int> samplesMicros; // sorted ascending

  const RankBenchmarkResult(this.vectors, this.dim, this.runs, this.k, this.samplesMicros);

  double _ms(double q) =>
      samplesMicros[min(samplesMicros.length - 1, (samplesMicros.length * q).floor())] /
      1000;

  double get medianMs => _ms(0.5);
  double get p95Ms => _ms(0.95);
  double get minMs => samplesMicros.first / 1000;

  @override
  String toString() =>
      'rank $vectors x $dim top-$k over $runs runs: median ${medianMs.toStringAsFixed(3)} ms, '
      'p95 ${p95Ms.toStringAsFixed(3)} ms, min ${minMs.toStringAsFixed(3)} ms';
}

RankBenchmarkResult runRankBenchmark({
  int vectors = 1000,
  int dim = kEmbeddingDim,
  int runs = 200,
  int warmup = 50,
  int k = 5,
  int seed = 42,
}) {
  final rng = Random(seed);
  Float32List unit() {
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

  final matrix = VectorMatrix(dim: dim, initialCapacity: vectors);
  for (var i = 0; i < vectors; i++) {
    matrix.upsert('c$i', 'bench', unit());
  }
  final queries = [for (var i = 0; i < 32; i++) unit()];
  for (var i = 0; i < warmup; i++) {
    matrix.topK(queries[i % queries.length], k);
  }
  final samples = <int>[];
  final sw = Stopwatch();
  for (var i = 0; i < runs; i++) {
    sw
      ..reset()
      ..start();
    matrix.topK(queries[i % queries.length], k);
    sw.stop();
    samples.add(sw.elapsedMicroseconds);
  }
  samples.sort();
  return RankBenchmarkResult(vectors, dim, runs, k, samples);
}
