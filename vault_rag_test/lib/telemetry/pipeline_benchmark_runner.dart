/// pipeline_benchmark_runner.dart
///
/// Benchmarks the actual two-model pipeline, one stage at a time, and then
/// with the stages genuinely overlapping.
///
/// STAGES, NEVER BLENDED
///
///   1. MiniLM embedding      on whatever the encoder's verdict says (QNN HTP
///                            verified -> NPU; otherwise XNNPACK/CPU)
///   2. Vector search         CPU ranking only, on the live store and on a
///                            fixed synthetic 1,000 x 384 matrix
///   3. Retrieval-only        ask(generate: false): embed + rank + top-K
///      (generation off)      decrypt + extractive answer + sign. NO LLM. Kept
///                            in its own section because a millisecond-scale
///                            extractive answer is not comparable to a
///                            GPU-generated one, and averaging them together
///                            would flatter the pipeline.
///   4. Generation            the selected reasoner: prefill, decode, total,
///                            tok/s
///   5. Overlap               sustained indexing (embed + encrypt, not
///                            persisted) running WHILE a capsule generates.
///                            Overlap is proven from the per-hardware leases
///                            (compute_ledger.dart): wall time during which
///                            the NPU and the GPU both had work in flight.
///
/// Captured alongside: P50/P95, tok/s, RSS memory, thermal state before and
/// after, the QNN delegate verdict and llama.cpp's own backend status.

library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../core/compute_ledger.dart';
import '../core/llm/llama_runtime.dart';
import '../core/llm/reasoner_coordinator.dart';
import '../core/vault_engine.dart';
import '../core/vector/rank_benchmark.dart';
import 'benchmark_runner.dart' show LatencyStats;
import 'compute_telemetry.dart';
import 'device_info.dart';
import 'telemetry_sources.dart' show readRssMb;

double _r(double v, [int d = 2]) => double.parse(v.toStringAsFixed(d));

class GenerationStats {
  final String reasoner;
  final String model;
  final String backend;
  final String hardware;
  final LatencyStats total;
  final LatencyStats prefill;
  final LatencyStats decode;
  final List<double> tokensPerSecond;

  const GenerationStats({
    required this.reasoner,
    required this.model,
    required this.backend,
    required this.hardware,
    required this.total,
    required this.prefill,
    required this.decode,
    required this.tokensPerSecond,
  });

  double get medianTokensPerSecond {
    if (tokensPerSecond.isEmpty) return 0;
    final s = [...tokensPerSecond]..sort();
    return s[s.length ~/ 2];
  }

  Map<String, dynamic> toJson() => {
        'reasoner': reasoner,
        'model': model,
        'backend': backend,
        'confirmed_hardware': hardware,
        'total': total.toJson(),
        if (!prefill.isEmpty) 'prefill': prefill.toJson(),
        if (!decode.isEmpty) 'decode': decode.toJson(),
        'tokens_per_second_median': _r(medianTokensPerSecond, 1),
        'tokens_per_second': [for (final t in tokensPerSecond) _r(t, 1)],
      };
}

class OverlapStats {
  final int indexedChunks;
  final LatencyStats embeddingUnderLoad;
  final GenerationStats? generationUnderLoad;
  final Duration window;
  final Map<ComputeHardware, Duration> busy;
  final Duration npuGpuOverlap;
  final Duration embeddingGenerationOverlap;

  const OverlapStats({
    required this.indexedChunks,
    required this.embeddingUnderLoad,
    required this.generationUnderLoad,
    required this.window,
    required this.busy,
    required this.npuGpuOverlap,
    required this.embeddingGenerationOverlap,
  });

  /// True only when leases show both accelerators working at once.
  bool get genuineNpuGpuOverlap => npuGpuOverlap > Duration.zero;

  Map<String, dynamic> toJson() => {
        'indexed_chunks': indexedChunks,
        'indexing_note': 'embed + AES-GCM encrypt per chunk; not persisted',
        'embedding_under_load': embeddingUnderLoad.toJson(),
        if (generationUnderLoad != null)
          'generation_under_load': generationUnderLoad!.toJson(),
        'window_ms': window.inMilliseconds,
        'busy_ms': {for (final e in busy.entries) e.key.name: e.value.inMilliseconds},
        'npu_gpu_overlap_ms': npuGpuOverlap.inMilliseconds,
        'embedding_generation_overlap_ms': embeddingGenerationOverlap.inMilliseconds,
        'genuine_npu_gpu_overlap': genuineNpuGpuOverlap,
      };
}

class PipelineBenchmarkReport {
  final DateTime startedAt;
  final DateTime finishedAt;
  final Map<String, dynamic> embeddingStatus;
  final LatencyStats embedding;
  final String embeddingHardware;
  final LatencyStats? liveVectorSearch;
  final int liveChunks;
  final RankBenchmarkResult syntheticVectorSearch;
  final LatencyStats retrievalOnlyEarlyExit;
  final GenerationStats? generation;
  final OverlapStats? overlap;
  final String? skippedGenerationReason;
  final Map<String, double?> rssMb;
  final ThermalState thermalBefore;
  final ThermalState thermalAfter;
  final Map<String, dynamic>? llamaBackendStatus;
  final DeviceFacts device;

  const PipelineBenchmarkReport({
    required this.startedAt,
    required this.finishedAt,
    required this.embeddingStatus,
    required this.embedding,
    required this.embeddingHardware,
    required this.liveVectorSearch,
    required this.liveChunks,
    required this.syntheticVectorSearch,
    required this.retrievalOnlyEarlyExit,
    required this.generation,
    required this.overlap,
    required this.skippedGenerationReason,
    required this.rssMb,
    required this.thermalBefore,
    required this.thermalAfter,
    required this.llamaBackendStatus,
    required this.device,
  });

  Map<String, dynamic> toJson() => {
        'benchmark': 'two-model pipeline',
        'started_at': startedAt.toIso8601String(),
        'duration_ms': finishedAt.difference(startedAt).inMilliseconds,
        'device': device.toJson(),
        'thermal_before': thermalBefore.isKnown ? thermalBefore.toJson() : null,
        'thermal_after': thermalAfter.isKnown ? thermalAfter.toJson() : null,
        'rss_mb': rssMb,
        'stage_1_minilm_embedding': {
          'hardware': embeddingHardware,
          'accelerator_status': embeddingStatus,
          ...embedding.toJson(),
        },
        'stage_2_cpu_vector_search': {
          if (liveVectorSearch != null)
            'live_store': {'chunks': liveChunks, ...liveVectorSearch!.toJson()},
          'synthetic_1000x384': {
            'median_ms': _r(syntheticVectorSearch.medianMs, 3),
            'p95_ms': _r(syntheticVectorSearch.p95Ms, 3),
          },
        },
        'stage_3_retrieval_only_generation_off': {
          'note': 'no language model; not comparable to a generated answer',
          ...retrievalOnlyEarlyExit.toJson(),
        },
        if (generation != null) 'stage_4_generation': generation!.toJson(),
        if (overlap != null) 'stage_5_overlap': overlap!.toJson(),
        if (skippedGenerationReason != null)
          'generation_skipped': skippedGenerationReason,
        'llama_backend_status': llamaBackendStatus,
      };
}

enum PipelinePhase { idle, embedding, vectorSearch, earlyExit, generation, overlap, done }

class PipelineBenchmarkRunner extends ChangeNotifier {
  final VaultEngine engine;
  final ComputeTelemetry telemetry;
  final InferenceMeter meter;
  final ReasonerCoordinator reasoner;
  final LlamaRuntime llama;

  PipelineBenchmarkRunner({
    required this.engine,
    required this.telemetry,
    required this.meter,
    required this.reasoner,
    required this.llama,
  });

  PipelinePhase _phase = PipelinePhase.idle;
  String _detail = '';
  bool _cancel = false;
  bool _disposed = false;
  PipelineBenchmarkReport? _report;

  PipelinePhase get phase => _phase;
  String get detail => _detail;
  bool get isRunning => _phase != PipelinePhase.idle && _phase != PipelinePhase.done;
  PipelineBenchmarkReport? get report => _report;

  void cancel() => _cancel = true;

  static const _query = 'what is the maximum notional order limit';
  static const _chunkText =
      'The risk engine rejects any order whose notional exceeds 250,000 USD '
      'and routes orders above 100,000 USD to manual review before execution.';

  Future<PipelineBenchmarkReport> run({
    int embedRuns = 30,
    int searchRuns = 50,
    int earlyExitRuns = 20,
    int generationRuns = 3,
  }) async {
    _cancel = false;
    _report = null;
    final started = DateTime.now();
    final thermalBefore = await ThermalState.read();
    final rss = <String, double?>{'before': readRssMb().value};
    var rssPeak = rss['before'] ?? 0;
    void sampleRss() => rssPeak = math.max(rssPeak, readRssMb().value ?? 0);

    // 1. MiniLM embedding -------------------------------------------------
    final embedMs = <double>[];
    for (var i = 0; i < 3; i++) {
      await engine.embedOnce(_chunkText); // warm-up, discarded
    }
    for (var i = 0; i < embedRuns && !_cancel; i++) {
      _set(PipelinePhase.embedding, 'MiniLM embedding ${i + 1}/$embedRuns');
      await engine.embedOnce(_chunkText);
      embedMs.add(engine.embeddings.lastInferenceMicros / 1000);
      await _yield();
    }
    sampleRss();

    // 2. CPU vector search ------------------------------------------------
    _set(PipelinePhase.vectorSearch, 'Vector search (ranking only)');
    LatencyStats? liveSearch;
    if (engine.chunkCount > 0) {
      final q = await engine.embedOnce(_query);
      final ms = <double>[];
      for (var i = 0; i < searchRuns && !_cancel; i++) {
        ms.add(await engine.benchmarkRankMicros(Float32List.fromList(q)) / 1000);
      }
      liveSearch = LatencyStats(ms);
    }
    final synthetic = runRankBenchmark(vectors: 1000, runs: searchRuns);
    await _yield();

    // 3. Retrieval-only (generation off) ---------------------------------
    final earlyMs = <double>[];
    for (var i = 0; i < earlyExitRuns && !_cancel && engine.chunkCount > 0; i++) {
      _set(PipelinePhase.earlyExit, 'Retrieval-only (no LLM) ${i + 1}/$earlyExitRuns');
      final sw = Stopwatch()..start();
      await engine.ask(_query, generate: false);
      earlyMs.add(sw.elapsedMicroseconds / 1000);
      await _yield();
    }
    sampleRss();

    // 4 & 5 need the selected reasoner --------------------------------------
    GenerationStats? generation;
    OverlapStats? overlap;
    String? skipped;
    final synth = reasoner.activeSynthesizer;
    final slot = reasoner.activeSlot;
    if (synth == null || slot == null) {
      skipped = 'no reasoner loaded (select and load one on the Model tab)';
    } else if (engine.chunkCount == 0) {
      skipped = 'vault is empty: generation needs retrieved context';
    } else if (!_cancel) {
      final context = await engine.search(_query);
      generation = await _generate(synth, slot, context, generationRuns, sampleRss);
      if (!_cancel) {
        overlap = await _overlap(synth, slot, context, sampleRss);
      }
    }

    rss['after'] = readRssMb().value;
    rss['peak'] = rssPeak;
    final report = PipelineBenchmarkReport(
      startedAt: started,
      finishedAt: DateTime.now(),
      embeddingStatus: engine.embeddings.acceleratorStatus.toJson(),
      embedding: LatencyStats(embedMs),
      embeddingHardware: engine.embeddings.acceleratorStatus.hardware.name,
      liveVectorSearch: liveSearch,
      liveChunks: engine.chunkCount,
      syntheticVectorSearch: synthetic,
      retrievalOnlyEarlyExit: LatencyStats(earlyMs),
      generation: generation,
      overlap: overlap,
      skippedGenerationReason: skipped,
      rssMb: rss,
      thermalBefore: thermalBefore,
      thermalAfter: await ThermalState.read(),
      llamaBackendStatus:
          slot?.kind == ReasonerKind.llama ? llama.backendStatusSnapshot : null,
      device: telemetry.deviceFacts,
    );
    _report = report;
    _set(PipelinePhase.done, _cancel ? 'Cancelled — partial results' : 'Complete');
    return report;
  }

  Future<GenerationStats> _generate(
    CapsuleSynthesizer synth,
    ReasonerSlot slot,
    SearchResult context,
    int runs,
    void Function() sampleRss,
  ) async {
    final total = <double>[], prefill = <double>[], decode = <double>[], tps = <double>[];
    for (var i = 0; i < runs && !_cancel; i++) {
      _set(PipelinePhase.generation, 'Generation ${i + 1}/$runs on ${slot.backendLabel}');
      final out = await synth.synthesize(context);
      _collect(out, total, prefill, decode, tps);
      sampleRss();
    }
    return _stats(slot, total, prefill, decode, tps);
  }

  Future<OverlapStats> _overlap(
    CapsuleSynthesizer synth,
    ReasonerSlot slot,
    SearchResult context,
    void Function() sampleRss,
  ) async {
    _set(PipelinePhase.overlap, 'Indexing while a capsule generates…');
    final windowStart = DateTime.now();
    var generating = true;
    final total = <double>[], prefill = <double>[], decode = <double>[], tps = <double>[];

    final generationDone = synth.synthesize(context).then((out) {
      _collect(out, total, prefill, decode, tps);
    }).whenComplete(() => generating = false);

    final embedUnderLoad = <double>[];
    var indexed = 0;
    // Keep indexing until generation finishes (bounded, in case it hangs).
    final hardStop = windowStart.add(const Duration(minutes: 3));
    while (generating && !_cancel && DateTime.now().isBefore(hardStop)) {
      final micros = await engine.indexingWorkload(_chunkText);
      embedUnderLoad.add(micros / 1000);
      indexed++;
      if (indexed % 5 == 0) {
        sampleRss();
        _set(PipelinePhase.overlap, 'Indexed $indexed chunks while generating…');
      }
      await _yield();
    }
    await generationDone.catchError((_) {});
    final windowEnd = DateTime.now();

    return OverlapStats(
      indexedChunks: indexed,
      embeddingUnderLoad: LatencyStats(embedUnderLoad),
      generationUnderLoad:
          total.isEmpty ? null : _stats(slot, total, prefill, decode, tps),
      window: windowEnd.difference(windowStart),
      busy: {
        for (final h in ComputeHardware.values)
          h: meter.busyTime(h, windowStart, windowEnd),
      },
      npuGpuOverlap: meter.overlapTime(
          ComputeHardware.npu, ComputeHardware.gpu, windowStart, windowEnd),
      embeddingGenerationOverlap: meter.overlapTime(
        engine.embeddings.acceleratorStatus.hardware,
        _generationHardware(slot),
        windowStart,
        windowEnd,
      ),
    );
  }

  ComputeHardware _generationHardware(ReasonerSlot slot) => switch (slot) {
        LlamaSlot(:final runtime) => runtime.confirmedHardware,
        _ => slot.backendLabel.endsWith('gpu') ? ComputeHardware.gpu : ComputeHardware.cpu,
      };

  void _collect(SynthesisOutput out, List<double> total, List<double> prefill,
      List<double> decode, List<double> tps) {
    total.add(out.elapsedMs.toDouble());
    if (out.prefillMs != null) prefill.add(out.prefillMs!.toDouble());
    if (out.decodeMs != null) decode.add(out.decodeMs!.toDouble());
    final tokens = out.tokens;
    // Decode tok/s when the runtime splits phases; otherwise end-to-end.
    final denomMs = out.decodeMs ?? out.elapsedMs;
    if (tokens != null && tokens > 0 && denomMs > 0) {
      tps.add(tokens * 1000 / denomMs);
    }
  }

  GenerationStats _stats(ReasonerSlot slot, List<double> total, List<double> prefill,
          List<double> decode, List<double> tps) =>
      GenerationStats(
        reasoner: slot.kind.label,
        model: slot.modelLabel,
        backend: slot.backendLabel,
        hardware: _generationHardware(slot).name,
        total: LatencyStats(total),
        prefill: LatencyStats(prefill),
        decode: LatencyStats(decode),
        tokensPerSecond: tps,
      );

  void _set(PipelinePhase phase, String detail) {
    _phase = phase;
    _detail = detail;
    if (!_disposed) notifyListeners();
  }

  Future<void> _yield() => Future<void>.delayed(const Duration(milliseconds: 8));

  @override
  void dispose() {
    _disposed = true;
    _cancel = true;
    super.dispose();
  }
}
