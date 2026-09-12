/// llm_benchmark_runner.dart
///
/// Repeatable generation load for the *currently loaded* reasoning model,
/// with the same honesty rules as [BenchmarkRunner]: percentiles over a
/// mean, and utilisation averaged over the run rather than sampled at two
/// points in time.
///
/// WHY THIS NEVER SWITCHES BACKENDS ITSELF
///
/// [BenchmarkRunner]'s embedding sweep builds a throwaway TFLite interpreter
/// per backend because a wrong TFLite delegate throws — the failure is
/// catchable, and a failed candidate cannot take the live interpreter with
/// it. [LlmRuntime.load] carries the opposite risk, documented at length
/// there: CPU-quantised weights handed to the GPU backend do not throw, they
/// SIGSEGV inside `libllm_inference_engine_jni.so` and kill the whole
/// process with no exception, no fallback and no second attempt.
///
/// So this runner does exactly one thing: it times generation on whichever
/// backend [LlmRuntime] already has loaded, and refuses outright if nothing
/// is loaded. A CPU-vs-GPU comparison for the reasoning model is still
/// possible — load a `-cpu-` file, run this, note the numbers; unload, load
/// a `-gpu-` file, run this again — but that is two deliberate, user-
/// initiated loads through the crash-safe path in `model_page.dart`, never
/// an automated sweep that could hand the wrong weights to the wrong
/// backend on its own.
///
/// NPU: MediaPipe's LLM Inference API exposes exactly two backends, CPU and
/// GPU — there is no NNAPI/NPU delegate to select here the way there is for
/// the embedding encoder. [computeUsage] still reports the device's NPU
/// lane during generation, because "no execution path uses it" and "so the
/// counter should read near-idle" is itself the finding worth recording
/// next to the CPU/GPU numbers.

library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/llm/llm_runtime.dart';
import 'benchmark_runner.dart' show LatencyStats;
import 'compute_telemetry.dart';

/// Long enough to force a real prefill + decode pass rather than exiting on
/// the first token, short enough that a handful of iterations does not turn
/// this into the multi-minute wait the embedding backend sweep already is.
/// Prose, not a one-line question, so token count is representative of an
/// actual capsule write-up.
const _benchmarkPrompt = '''
Summarise, in three sentences, what a zero-trust retrieval vault is and why
retrieved passages should never leave the device that indexed them. Then
list two risks of running the reasoning step on a laptop instead of on the
device that holds the corpus.
''';

class LlmBenchmarkReport {
  final DateTime startedAt;
  final int warmup;
  final String backend;
  final String modelLabel;
  final int loadMs;

  /// Wall-clock generation latency. MediaPipe's `generateResponse` has no
  /// native-clock equivalent to `lastNativeInferenceDurationMicroSeconds`,
  /// so this is the same [Stopwatch] figure [LlmRuntime.generate] already
  /// reports as [LlmGeneration.elapsedMs].
  final LatencyStats latency;

  /// One entry per generation that reported a token count. Shorter than
  /// [latency] whenever MediaPipe omits `sizeInTokens` for a run — never
  /// padded or estimated, per [LlmGeneration.tokens].
  final List<double> tokensPerSecond;

  /// Device-wide CPU/GPU/NPU utilisation averaged over the timed
  /// iterations, discarding [warmup].
  final ComputeUsageSummary computeUsage;

  /// Set when the run stopped early on a generation failure. The report is
  /// still returned with whatever iterations completed beforehand — a
  /// partial reasoning benchmark is more useful than none, the same call
  /// [BenchmarkRunner] makes for a user-requested cancel.
  final String? error;

  const LlmBenchmarkReport({
    required this.startedAt,
    required this.warmup,
    required this.backend,
    required this.modelLabel,
    required this.loadMs,
    required this.latency,
    required this.tokensPerSecond,
    required this.computeUsage,
    this.error,
  });

  double? get meanTokensPerSecond => tokensPerSecond.isEmpty
      ? null
      : tokensPerSecond.reduce((a, b) => a + b) / tokensPerSecond.length;

  Map<String, dynamic> toJson() => {
        'started_at': startedAt.toIso8601String(),
        'warmup_iterations_discarded': warmup,
        'timing_source': 'dart_stopwatch_around_method_channel',
        'backend': backend,
        'model': modelLabel,
        'load_ms': loadMs,
        'generation': latency.toJson(),
        if (tokensPerSecond.isNotEmpty)
          'tokens_per_second_mean':
              double.parse(meanTokensPerSecond!.toStringAsFixed(2)),
        'compute_usage': computeUsage.toJson(),
        if (error != null) 'stopped_early': error,
      };
}

enum LlmBenchmarkPhase { idle, warmup, generating, done }

class LlmBenchmarkRunner extends ChangeNotifier {
  final LlmRuntime llm;
  final ComputeTelemetry telemetry;

  LlmBenchmarkRunner({required this.llm, required this.telemetry});

  LlmBenchmarkPhase _phase = LlmBenchmarkPhase.idle;
  double _progress = 0;
  String _detail = '';
  LlmBenchmarkReport? _report;
  bool _cancelRequested = false;

  LlmBenchmarkPhase get phase => _phase;
  double get progress => _progress;
  String get detail => _detail;
  LlmBenchmarkReport? get report => _report;
  bool get isRunning =>
      _phase != LlmBenchmarkPhase.idle && _phase != LlmBenchmarkPhase.done;

  void cancel() {
    if (isRunning) _cancelRequested = true;
  }

  void _update(LlmBenchmarkPhase phase, double progress, String detail) {
    _phase = phase;
    _progress = progress;
    _detail = detail;
    notifyListeners();
  }

  /// Times generation on whichever backend [llm] already has loaded.
  ///
  /// Returns null, with nothing recorded, if no model is loaded — the
  /// caller (the stats screen) is expected to disable the run button in
  /// that state, but a defensive check costs nothing and a null result is a
  /// clearer contract than an exception for "there was nothing to measure".
  ///
  /// [warmup] defaults to 1, not [BenchmarkRunner]'s 3: each generation
  /// costs seconds, not milliseconds, so three discarded runs is half a
  /// minute spent on nothing before the first measured number.
  Future<LlmBenchmarkReport?> run({int warmup = 1, int iterations = 5}) async {
    _cancelRequested = false;
    _report = null;

    if (!llm.isReady) {
      _update(LlmBenchmarkPhase.done, 0, 'No reasoning model loaded.');
      return null;
    }

    final startedAt = DateTime.now();
    final backend = llm.backendLabel;
    final modelLabel = llm.modelLabel;
    final loadMs = llm.loadMs;
    String? runError;

    _update(LlmBenchmarkPhase.warmup, 0, 'Warming up ($warmup discarded)…');
    try {
      for (var i = 0; i < warmup && !_cancelRequested; i++) {
        await llm.generate(_benchmarkPrompt);
      }
    } catch (e) {
      runError = 'Warm-up failed: $e';
    }

    final windowStart = DateTime.now();
    final latencyMs = <double>[];
    final tokensPerSecond = <double>[];
    if (runError == null) {
      for (var i = 0; i < iterations && !_cancelRequested; i++) {
        _update(
          LlmBenchmarkPhase.generating,
          i / iterations,
          'Generating ${i + 1}/$iterations on ${backend.toUpperCase()}…',
        );
        try {
          final result = await llm.generate(_benchmarkPrompt);
          latencyMs.add(result.elapsedMs.toDouble());
          final tps = result.tokensPerSecond;
          if (tps != null) tokensPerSecond.add(tps);
        } catch (e) {
          runError = '$e';
          break;
        }
      }
    }

    final report = LlmBenchmarkReport(
      startedAt: startedAt,
      warmup: warmup,
      backend: backend,
      modelLabel: modelLabel,
      loadMs: loadMs,
      latency: LatencyStats(latencyMs),
      tokensPerSecond: tokensPerSecond,
      computeUsage: summarizeUsage(
        telemetry.samplesSince(windowStart),
        thermal: telemetry.thermal,
      ),
      error: runError,
    );

    _report = report;
    _update(
      LlmBenchmarkPhase.done,
      1,
      runError != null
          ? 'Stopped early — $runError'
          : _cancelRequested
              ? 'Cancelled — partial results'
              : 'Complete',
    );
    return report;
  }
}
