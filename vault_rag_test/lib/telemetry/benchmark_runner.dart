/// benchmark_runner.dart
///
/// Repeatable load for the stats screen: a fixed workload, run enough times
/// to say something about the distribution, with the telemetry chart
/// recording underneath it.
///
/// WHAT THIS REPORTS AND WHY IT IS NOT A MEAN.
///
/// The previous build's headline number was "233 ms per embedding", derived
/// from one run. That is fine as a sanity check and useless as a benchmark,
/// because a phone is a thermally-throttled, frequency-scaled, shared
/// machine: the first inference after idle is slow (the governor has not
/// ramped), the tenth is fast, and the two-hundredth is slow again for a
/// completely different reason (the SoC is hot). A mean folds those three
/// regimes into one number that describes none of them.
///
/// So this reports min / median / p90 / max, and it reports them from
/// `lastNativeInferenceDurationMicroSeconds` — the native interpreter's own
/// clock — rather than a Dart Stopwatch around the call. The gap between
/// those two is marshalling overhead, which is real but is not the model,
/// and the previous build lost hours to conflating them.
///
/// Warm-up iterations are discarded rather than included. That is not
/// cheating as long as it is disclosed, which [BenchmarkReport.warmup]
/// does: the first call allocates tensor arenas and the governor is still
/// at idle clocks, so including it measures Android's scheduler, not the
/// delegate.

library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../core/embedding_service.dart';
import '../core/vault_engine.dart';

/// Fixed benchmark input. Deliberately prose-like and long enough to fill a
/// good fraction of the 256-token window: a short string exits the encoder
/// early on padding and flatters the result.
const _benchmarkText = '''
The air-gapped settlement vault stores its master signing keys inside the
secure enclave and never transmits them over any network interface. Risk
limits, kill-switch thresholds and the disaster recovery rotation are held
alongside them, so that an operator on a severed network can still evaluate
whether a pending order is within policy before the uplink is restored.
''';

class LatencyStats {
  final List<double> samplesMs;

  LatencyStats(List<double> samples)
      : samplesMs = List<double>.unmodifiable(samples..sort());

  bool get isEmpty => samplesMs.isEmpty;
  int get count => samplesMs.length;

  double get min => isEmpty ? 0 : samplesMs.first;
  double get max => isEmpty ? 0 : samplesMs.last;
  double get median => _percentile(50);
  double get p90 => _percentile(90);

  double get mean =>
      isEmpty ? 0 : samplesMs.reduce((a, b) => a + b) / samplesMs.length;

  /// Population standard deviation. Reported next to the median as a
  /// throttling tell: a tight distribution means the clocks held, a wide
  /// one means they did not.
  double get stdDev {
    if (samplesMs.length < 2) return 0;
    final m = mean;
    final variance = samplesMs
            .map((x) => (x - m) * (x - m))
            .reduce((a, b) => a + b) /
        samplesMs.length;
    return math.sqrt(variance);
  }

  double get throughputPerSecond => median <= 0 ? 0 : 1000 / median;

  double _percentile(int p) {
    if (isEmpty) return 0;
    // Nearest-rank, which is the honest choice for small n — interpolating
    // between two samples invents a measurement that was never taken.
    final rank = ((p / 100) * samplesMs.length).ceil().clamp(1, samplesMs.length);
    return samplesMs[rank - 1];
  }

  Map<String, dynamic> toJson() => {
        'count': count,
        'min_ms': double.parse(min.toStringAsFixed(2)),
        'median_ms': double.parse(median.toStringAsFixed(2)),
        'p90_ms': double.parse(p90.toStringAsFixed(2)),
        'max_ms': double.parse(max.toStringAsFixed(2)),
        'mean_ms': double.parse(mean.toStringAsFixed(2)),
        'stddev_ms': double.parse(stdDev.toStringAsFixed(2)),
        'per_second': double.parse(throughputPerSecond.toStringAsFixed(2)),
      };
}

class BackendResult {
  final String backend;
  final LatencyStats? stats;

  /// Populated instead of [stats] when the backend could not be built —
  /// which is itself a result worth showing, not an error to hide.
  final String? unavailableReason;

  const BackendResult({
    required this.backend,
    this.stats,
    this.unavailableReason,
  });

  bool get isAvailable => stats != null;

  Map<String, dynamic> toJson() => {
        'backend': backend,
        if (stats != null) ...stats!.toJson(),
        if (unavailableReason != null) 'unavailable': unavailableReason,
      };
}

class BenchmarkReport {
  final DateTime startedAt;
  final int warmup;
  final int iterations;
  final int sequenceLength;
  final int embeddingDim;

  /// Embedding latency on the backend the app is actually running.
  final LatencyStats live;
  final String liveBackend;

  /// End-to-end retrieval latency, including the vector scan.
  final LatencyStats? retrieval;
  final int corpusChunks;

  /// Populated only when a backend sweep was requested.
  final List<BackendResult> comparison;

  /// Telemetry averages across the run.
  final Map<String, dynamic> computeDuringRun;

  const BenchmarkReport({
    required this.startedAt,
    required this.warmup,
    required this.iterations,
    required this.sequenceLength,
    required this.embeddingDim,
    required this.live,
    required this.liveBackend,
    required this.retrieval,
    required this.corpusChunks,
    required this.comparison,
    required this.computeDuringRun,
  });

  Map<String, dynamic> toJson() => {
        'started_at': startedAt.toIso8601String(),
        'warmup_iterations_discarded': warmup,
        'iterations': iterations,
        'sequence_length': sequenceLength,
        'embedding_dim': embeddingDim,
        'timing_source': 'lastNativeInferenceDurationMicroSeconds',
        'live_backend': liveBackend,
        'embedding': live.toJson(),
        if (retrieval != null) 'retrieval': retrieval!.toJson(),
        'corpus_chunks': corpusChunks,
        if (comparison.isNotEmpty)
          'backend_comparison': comparison.map((c) => c.toJson()).toList(),
        'compute_during_run': computeDuringRun,
      };
}

/// Phases, surfaced so the chart can label what the spike it is drawing
/// actually was.
enum BenchmarkPhase { idle, warmup, embedding, retrieval, comparison, done }

class BenchmarkRunner extends ChangeNotifier {
  final VaultEngine engine;

  /// Returns a snapshot of live compute telemetry, averaged into the report.
  final Map<String, dynamic> Function() telemetrySnapshot;

  BenchmarkRunner({required this.engine, required this.telemetrySnapshot});

  BenchmarkPhase _phase = BenchmarkPhase.idle;
  double _progress = 0;
  String _detail = '';
  BenchmarkReport? _report;
  bool _cancelRequested = false;

  BenchmarkPhase get phase => _phase;
  double get progress => _progress;
  String get detail => _detail;
  BenchmarkReport? get report => _report;
  bool get isRunning =>
      _phase != BenchmarkPhase.idle && _phase != BenchmarkPhase.done;

  void cancel() {
    if (isRunning) _cancelRequested = true;
  }

  void _update(BenchmarkPhase phase, double progress, String detail) {
    _phase = phase;
    _progress = progress;
    _detail = detail;
    notifyListeners();
  }

  /// Runs the suite.
  ///
  /// [compareBackends] additionally builds a *separate* interpreter per
  /// listed backend and times it. That is slow — the plain-CPU path is
  /// roughly 2.8 s per embedding on a Snapdragon 695, so ten iterations is
  /// half a minute on its own — which is why it is opt-in and uses a
  /// smaller iteration count.
  Future<BenchmarkReport> run({
    int warmup = 3,
    int iterations = 20,
    int retrievalIterations = 10,
    List<EmbeddingBackend> compareBackends = const [],
    int comparisonIterations = 5,
    String? vocabText,
  }) async {
    _cancelRequested = false;
    _report = null;
    final startedAt = DateTime.now();
    final computeStart = telemetrySnapshot();

    // --- warm-up ----------------------------------------------------------
    _update(BenchmarkPhase.warmup, 0, 'Warming up ($warmup discarded)…');
    for (var i = 0; i < warmup && !_cancelRequested; i++) {
      await engine.embedOnce(_benchmarkText);
      await _breathe();
    }

    // --- embedding latency ------------------------------------------------
    final embedSamples = <double>[];
    for (var i = 0; i < iterations && !_cancelRequested; i++) {
      await engine.embedOnce(_benchmarkText);
      embedSamples.add(engine.embeddings.lastInferenceMicros / 1000);
      _update(
        BenchmarkPhase.embedding,
        (i + 1) / iterations,
        'Embedding ${i + 1}/$iterations',
      );
      await _breathe();
    }

    // --- retrieval latency ------------------------------------------------
    LatencyStats? retrievalStats;
    if (engine.chunkCount > 0 && !_cancelRequested) {
      final retrievalSamples = <double>[];
      for (var i = 0; i < retrievalIterations && !_cancelRequested; i++) {
        final r = await engine.search(
          'maximum notional order limit risk engine',
          topK: 5,
        );
        retrievalSamples.add(r.latencyMs.toDouble());
        _update(
          BenchmarkPhase.retrieval,
          (i + 1) / retrievalIterations,
          'Retrieval ${i + 1}/$retrievalIterations '
          'over ${engine.chunkCount} chunks',
        );
        await _breathe();
      }
      retrievalStats = LatencyStats(retrievalSamples);
    }

    // --- optional backend sweep ------------------------------------------
    final comparison = <BackendResult>[];
    if (compareBackends.isNotEmpty && vocabText != null && !_cancelRequested) {
      for (final backend in compareBackends) {
        if (_cancelRequested) break;
        comparison.add(await _timeBackend(
          backend,
          vocabText,
          comparisonIterations,
        ));
      }
    }

    final computeEnd = telemetrySnapshot();
    final report = BenchmarkReport(
      startedAt: startedAt,
      warmup: warmup,
      iterations: embedSamples.length,
      sequenceLength: engine.sequenceLength,
      embeddingDim: engine.embeddingDim,
      live: LatencyStats(embedSamples),
      liveBackend: engine.backend,
      retrieval: retrievalStats,
      corpusChunks: engine.chunkCount,
      comparison: comparison,
      computeDuringRun: {'at_start': computeStart, 'at_end': computeEnd},
    );

    _report = report;
    _update(
      BenchmarkPhase.done,
      1,
      _cancelRequested ? 'Cancelled — partial results' : 'Complete',
    );
    return report;
  }

  /// Builds a throwaway interpreter on [backend] and times it.
  ///
  /// A fresh [MiniLMEmbeddingService] rather than reconfiguring the live one:
  /// swapping a delegate under the running engine would break any bridge
  /// query in flight, and a failed delegate build must not take the app's
  /// working interpreter with it.
  Future<BackendResult> _timeBackend(
    EmbeddingBackend backend,
    String vocabText,
    int iterations,
  ) async {
    final name = backend.name.toUpperCase();
    _update(BenchmarkPhase.comparison, 0, 'Building $name interpreter…');

    final probe = MiniLMEmbeddingService(backendsToTry: [backend]);
    try {
      await probe.load(vocabText: vocabText);
    } catch (e) {
      probe.close();
      return BackendResult(
        backend: name,
        unavailableReason: e.toString().split('\n').first,
      );
    }

    try {
      final samples = <double>[];
      // One discarded call: a brand-new interpreter's first inference
      // includes arena allocation.
      await probe.embed(_benchmarkText);
      for (var i = 0; i < iterations && !_cancelRequested; i++) {
        await probe.embed(_benchmarkText);
        samples.add(probe.lastInferenceMicros / 1000);
        _update(
          BenchmarkPhase.comparison,
          (i + 1) / iterations,
          '$name ${i + 1}/$iterations',
        );
        await _breathe();
      }
      return BackendResult(backend: name, stats: LatencyStats(samples));
    } catch (e) {
      return BackendResult(
        backend: name,
        unavailableReason: e.toString().split('\n').first,
      );
    } finally {
      probe.close();
    }
  }

  /// Yields long enough for the 1 Hz telemetry sampler and the raster thread
  /// to run. Without this the benchmark monopolises the isolate and the
  /// chart it exists to feed records nothing but one flat line.
  Future<void> _breathe() =>
      Future<void>.delayed(const Duration(milliseconds: 16));
}
