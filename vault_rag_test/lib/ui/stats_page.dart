/// stats_page.dart
///
/// Live compute telemetry and the benchmark harness.
///
/// The layout answers three questions in descending order of how often they
/// are asked: what is running right now (tiles), what has it been doing
/// (chart), and how fast is it really (benchmark).
///
/// Every tile states its provenance. A lane the device does not report is
/// rendered greyed with the reason underneath, never as a confident zero —
/// on a Snapdragon 695 the NPU lane is expected to read "unavailable", and
/// that is a real finding about the hardware rather than a bug in this
/// screen. See telemetry_sources.dart for why no honest alternative exists.

library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/embedding_service.dart';
import '../core/llm/llm_runtime.dart';
import '../core/vault_engine.dart';
import '../telemetry/benchmark_runner.dart';
import '../telemetry/compute_telemetry.dart';
import '../telemetry/device_info.dart';
import '../telemetry/llm_benchmark_runner.dart';
import '../telemetry/telemetry_sources.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/stream_chart.dart';
import '../telemetry/pipeline_benchmark_runner.dart';
import '../core/compute_ledger.dart';

class StatsPage extends StatefulWidget {
  final ComputeTelemetry telemetry;
  final BenchmarkRunner benchmark;
  final LlmBenchmarkRunner llmBenchmark;
  final LlmRuntime llm;
  final VaultEngine engine;
  final String vocabText;

  /// Staged + overlapping benchmark of MiniLM, vector search and the
  /// selected reasoner. Null hides the section (tests).
  final PipelineBenchmarkRunner? pipeline;

  const StatsPage({
    super.key,
    required this.telemetry,
    required this.benchmark,
    required this.llmBenchmark,
    required this.llm,
    required this.engine,
    required this.vocabText,
    this.pipeline,
  });

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  final Set<ComputeLane> _hidden = {};
  final Set<EmbeddingBackend> _sweepBackends = {};

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        VaultSpace.lg,
        VaultSpace.md,
        VaultSpace.lg,
        VaultSpace.xxl,
      ),
      children: [
        _liveSection(),
        const SizedBox(height: VaultSpace.md),
        _clocksSection(),
        const SizedBox(height: VaultSpace.md),
        _benchmarkSection(),
        const SizedBox(height: VaultSpace.md),
        _reasoningBenchmarkSection(),
        const SizedBox(height: VaultSpace.md),
        if (widget.pipeline != null) ...[
          _pipelineBenchmarkSection(widget.pipeline!),
          const SizedBox(height: VaultSpace.md),
        ],
        _combinedReportSection(),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Live utilisation
  // ---------------------------------------------------------------------

  Widget _liveSection() {
    // Scoped to the telemetry notifier only. A 1 Hz tick repaints this card
    // and nothing else on the page — rebuilding the whole ListView every
    // second would cost frames while the model is trying to run, which
    // would corrupt the measurement being displayed.
    return ListenableBuilder(
      listenable: widget.telemetry,
      builder: (context, _) {
        final t = widget.telemetry;
        return SectionCard(
          title: 'Live utilisation',
          subtitle: '1 Hz · last ${t.historyCapacity} s',
          trailing: _PauseButton(
            paused: t.isPaused,
            onChanged: t.setPaused,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _laneTiles(t),
              const SizedBox(height: VaultSpace.md),
              _dispatchRow(t),
              const SizedBox(height: VaultSpace.lg),
              StreamChart(
                windowSize: t.historyCapacity,
                sampleInterval: t.interval,
                series: [
                  for (final lane in ComputeLane.values)
                    ChartSeries(
                      lane: lane,
                      values: t.seriesFor(lane),
                      kind: t.laneKinds[lane] ?? ProbeKind.unavailable,
                      visible: !_hidden.contains(lane),
                    ),
                ],
              ),
              const SizedBox(height: VaultSpace.md),
              _legend(t),
            ],
          ),
        );
      },
    );
  }

  /// Hardware the app itself has work running on, from runtime leases —
  /// independent per hardware, so NPU embedding and GPU generation show as
  /// active at the same time when they overlap. Distinct from the lanes
  /// above, which are device-wide counters and may be unavailable.
  Widget _dispatchRow(ComputeTelemetry t) {
    final s = t.latest;
    final active = t.meter.activeHardware;
    Widget pill(ComputeHardware h, String name) {
      final on = active.contains(h);
      final busy = s?.appBusyPercent[h];
      return Semantics(
        label: '$name ${on ? 'active' : 'idle'}'
            '${busy == null ? '' : ', ${busy.toStringAsFixed(0)} percent busy'}',
        child: StatusPill(
          label: '$name ${on ? 'ACTIVE' : 'IDLE'}'
              '${busy == null ? '' : ' · ${busy.toStringAsFixed(0)}%'}',
          color: on ? VaultColors.accent : VaultColors.faint,
          pulsing: on,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'APP DISPATCH (RUNTIME LEASES)',
          style: TextStyle(
            color: VaultColors.muted,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: VaultSpace.xs),
        Wrap(
          spacing: VaultSpace.sm,
          runSpacing: VaultSpace.xs,
          children: [
            pill(ComputeHardware.npu, 'NPU'),
            pill(ComputeHardware.gpu, 'GPU'),
            pill(ComputeHardware.cpu, 'CPU'),
          ],
        ),
        const SizedBox(height: VaultSpace.xs),
        Text(
          'Encoder: ${widget.engine.embeddings.acceleratorStatus.label}',
          style: const TextStyle(color: VaultColors.faint, fontSize: 11),
        ),
      ],
    );
  }

  Widget _pipelineBenchmarkSection(PipelineBenchmarkRunner runner) {
    return ListenableBuilder(
      listenable: runner,
      builder: (context, _) {
        final r = runner.report;
        return SectionCard(
          title: 'Two-model pipeline benchmark',
          subtitle: 'MiniLM, CPU vector search and the selected reasoner timed '
              'separately, then indexing while a capsule generates. '
              'Retrieval-only numbers are reported on their own.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.telemetry.thermal.throttling)
                _throttleWarning(widget.telemetry.thermal),
              if (runner.isRunning) ...[
                const LinearProgressIndicator(
                  backgroundColor: VaultColors.surfaceHigh,
                  color: VaultColors.accent,
                ),
                const SizedBox(height: VaultSpace.sm),
                Text(runner.detail,
                    style: const TextStyle(color: VaultColors.muted, fontSize: 12)),
                const SizedBox(height: VaultSpace.md),
                OutlinedButton.icon(
                  onPressed: runner.cancel,
                  icon: const Icon(Icons.stop_rounded, size: 18),
                  label: const Text('Cancel'),
                ),
              ] else
                FilledButton.icon(
                  onPressed: widget.engine.isReady ? () => runner.run() : null,
                  icon: const Icon(Icons.stacked_line_chart_rounded, size: 19),
                  label: const Text('Run pipeline benchmark'),
                ),
              if (r != null && !runner.isRunning) ...[
                const SizedBox(height: VaultSpace.md),
                _pipelineSummary(r),
                const SizedBox(height: VaultSpace.md),
                CodeBlock(const JsonEncoder.withIndent('  ').convert(r.toJson())),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _pipelineSummary(PipelineBenchmarkReport r) {
    String ms(double v) => '${v.toStringAsFixed(v < 10 ? 2 : 0)} ms';
    final rows = <(String, String)>[
      ('MiniLM (${r.embeddingHardware.toUpperCase()})',
          'P50 ${ms(r.embedding.median)} · P95 ${ms(r.embedding.p95)}'),
      ('Vector search, 1000×384 (CPU)',
          'P50 ${ms(r.syntheticVectorSearch.medianMs)} · P95 ${ms(r.syntheticVectorSearch.p95Ms)}'),
      if (!r.retrievalOnlyEarlyExit.isEmpty)
        ('Retrieval-only, generation off (no LLM)',
            'P50 ${ms(r.retrievalOnlyEarlyExit.median)} · P95 ${ms(r.retrievalOnlyEarlyExit.p95)}'),
      if (r.generation != null)
        ('Generation (${r.generation!.hardware.toUpperCase()})',
            'P50 ${ms(r.generation!.total.median)} · '
                '${r.generation!.medianTokensPerSecond.toStringAsFixed(1)} tok/s'),
      if (r.overlap != null)
        ('NPU∩GPU overlap',
            '${r.overlap!.npuGpuOverlap.inMilliseconds} ms · '
                '${r.overlap!.indexedChunks} chunks indexed during generation'),
      if (r.skippedGenerationReason != null)
        ('Generation', 'skipped: ${r.skippedGenerationReason}'),
    ];
    return Column(
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: VaultSpace.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(label,
                      style: const TextStyle(color: VaultColors.muted, fontSize: 12)),
                ),
                const SizedBox(width: VaultSpace.sm),
                Flexible(
                  child: Text(value,
                      textAlign: TextAlign.end,
                      style: VaultText.mono.copyWith(
                          color: VaultColors.foreground, fontSize: 11.5)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _laneTiles(ComputeTelemetry t) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Two columns on a phone, four once there is room. Below ~150 dp a
        // tile starts clipping its value, which is the number that matters.
        final columns = constraints.maxWidth >= 560 ? 4 : 2;
        final spacing = VaultSpace.sm;
        final tileWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final lane in ComputeLane.values)
              SizedBox(
                width: tileWidth,
                child: _laneTile(lane, t.probeFor(lane)),
              ),
          ],
        );
      },
    );
  }

  Widget _laneTile(ComputeLane lane, Probe probe) {
    final style = ComputeSeriesStyle.of(lane);
    final available = probe.isAvailable;

    return MetricTile(
      label: lane.label,
      value: available ? probe.value!.toStringAsFixed(0) : '—',
      unit: available ? '%' : null,
      accent: style.color,
      unavailable: !available,
      footnote: switch (probe.kind) {
        ProbeKind.measured => 'measured',
        ProbeKind.proxy => 'clock proxy',
        ProbeKind.derived => 'app-instrumented',
        ProbeKind.unavailable => 'not exposed',
      },
    );
  }

  Widget _legend(ComputeTelemetry t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: VaultSpace.sm,
          runSpacing: VaultSpace.sm,
          children: [
            for (final lane in ComputeLane.values)
              _LegendChip(
                lane: lane,
                kind: t.laneKinds[lane] ?? ProbeKind.unavailable,
                hidden: _hidden.contains(lane),
                onTap: () => setState(() {
                  if (!_hidden.remove(lane)) _hidden.add(lane);
                }),
              ),
          ],
        ),
        ..._unavailableNotes(t),
      ],
    );
  }

  /// Spells out, in plain words, why a lane is flat. Without this the chart
  /// silently under-reports and the reader assumes the hardware is idle
  /// rather than unmeasured.
  List<Widget> _unavailableNotes(ComputeTelemetry t) {
    final notes = <Widget>[];
    for (final lane in ComputeLane.values) {
      final probe = t.probeFor(lane);
      if (probe.kind == ProbeKind.measured || probe.kind == ProbeKind.derived) {
        continue;
      }
      final note = probe.note;
      if (note == null) continue;
      notes.add(Padding(
        padding: const EdgeInsets.only(top: VaultSpace.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              probe.kind == ProbeKind.proxy
                  ? Icons.info_outline
                  : Icons.block_outlined,
              size: 13,
              color: VaultColors.faint,
            ),
            const SizedBox(width: VaultSpace.sm),
            Expanded(
              child: Text(
                '${lane.label}: $note',
                style: const TextStyle(
                  color: VaultColors.faint,
                  fontSize: 11,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
      ));
    }
    return notes;
  }

  // ---------------------------------------------------------------------
  // Clocks / memory
  // ---------------------------------------------------------------------

  Widget _clocksSection() {
    return ListenableBuilder(
      listenable: widget.telemetry,
      builder: (context, _) {
        final snap = widget.telemetry.snapshot();
        String fmt(Object? v, {int digits = 0}) =>
            v is num ? v.toStringAsFixed(digits) : '—';

        final thermal = widget.telemetry.thermal;

        return SectionCard(
          title: 'Device',
          subtitle: '${widget.telemetry.deviceFacts.summary}\n'
              '${snap['cores']} cores · ${widget.engine.backend} delegate · '
              '${widget.engine.embeddingDim}-dim encoder',
          trailing: thermal.isKnown
              ? StatusPill(
                  label: thermal.throttling
                      ? 'THROTTLING'
                      : 'THERMAL OK',
                  color: thermal.throttling
                      ? VaultColors.warn
                      : VaultColors.accent,
                )
              : null,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 560 ? 4 : 2;
              final spacing = VaultSpace.sm;
              final w =
                  (constraints.maxWidth - spacing * (columns - 1)) / columns;
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: [
                  SizedBox(
                    width: w,
                    child: MetricTile(
                      label: 'CPU CLOCK',
                      value: fmt(snap['cpu_clock_mhz']),
                      unit: 'MHz',
                      unavailable: snap['cpu_clock_mhz'] == null,
                    ),
                  ),
                  SizedBox(
                    width: w,
                    child: MetricTile(
                      label: 'GPU CLOCK',
                      value: fmt(snap['gpu_clock_mhz']),
                      unit: 'MHz',
                      unavailable: snap['gpu_clock_mhz'] == null,
                    ),
                  ),
                  SizedBox(
                    width: w,
                    child: MetricTile(
                      label: 'RSS',
                      value: fmt(snap['rss_mb']),
                      unit: 'MB',
                      unavailable: snap['rss_mb'] == null,
                    ),
                  ),
                  SizedBox(
                    width: w,
                    child: MetricTile(
                      label: 'VAULT',
                      value: '${widget.engine.chunkCount}',
                      unit: 'chunks',
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  /// Shown above the benchmark button while the platform reports thermal
  /// limiting.
  ///
  /// This is the single most common way phone benchmarks mislead: the same
  /// workload on the same device returns a very different number depending
  /// on how warm it already was, and nothing else on screen would say so.
  /// PowerManager knows; there is no sysfs equivalent an unprivileged app
  /// can read, which is the reason the method channel exists at all.
  Widget _throttleWarning(ThermalState thermal) {
    return Container(
      margin: const EdgeInsets.only(bottom: VaultSpace.md),
      padding: const EdgeInsets.all(VaultSpace.md),
      decoration: BoxDecoration(
        color: VaultColors.warn.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(VaultSpace.radiusSm),
        border: Border.all(color: VaultColors.warn.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.thermostat_rounded,
              size: 15, color: VaultColors.warn),
          const SizedBox(width: VaultSpace.sm),
          Expanded(
            child: Text(
              'The platform reports thermal state "${thermal.label}" and is '
              'actively limiting clocks. Numbers taken now will be slower '
              'than this device is capable of. Let it cool and re-run.',
              style: const TextStyle(
                color: VaultColors.muted,
                fontSize: 11,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Benchmark
  // ---------------------------------------------------------------------

  Widget _benchmarkSection() {
    return ListenableBuilder(
      listenable: widget.benchmark,
      builder: (context, _) {
        final b = widget.benchmark;
        return SectionCard(
          title: 'Benchmark',
          subtitle: '20 timed embeddings after 3 discarded warm-ups, timed '
              'with the interpreter’s own clock.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.telemetry.thermal.throttling)
                _throttleWarning(widget.telemetry.thermal),
              if (b.isRunning) ...[
                LinearProgressIndicator(
                  value: b.progress == 0 ? null : b.progress,
                  backgroundColor: VaultColors.surfaceHigh,
                  color: VaultColors.accent,
                ),
                const SizedBox(height: VaultSpace.sm),
                Text(
                  b.detail,
                  style: const TextStyle(
                    color: VaultColors.muted,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: VaultSpace.md),
                OutlinedButton.icon(
                  onPressed: b.cancel,
                  icon: const Icon(Icons.stop_rounded, size: 18),
                  label: const Text('Cancel'),
                ),
              ] else ...[
                _BackendSweepPicker(
                  selected: _sweepBackends,
                  onChanged: (v) => setState(() {
                    if (!_sweepBackends.remove(v)) _sweepBackends.add(v);
                  }),
                ),
                const SizedBox(height: VaultSpace.md),
                FilledButton.icon(
                  onPressed: widget.engine.isReady ? _runBenchmark : null,
                  icon: const Icon(Icons.speed_rounded, size: 19),
                  label: Text(
                    b.report == null ? 'Run benchmark' : 'Run again',
                  ),
                ),
              ],
              if (b.report != null) ...[
                const SizedBox(height: VaultSpace.lg),
                _reportView(b.report!),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _runBenchmark() async {
    await widget.benchmark.run(
      compareBackends: _sweepBackends.toList(),
      vocabText: widget.vocabText,
    );
  }

  Widget _reportView(BenchmarkReport r) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _statRow('Embedding · ${r.liveBackend}', r.live,
            usage: r.liveComputeUsage),
        if (r.retrieval != null) ...[
          const SizedBox(height: VaultSpace.sm),
          _statRow('Retrieval · ${r.corpusChunks} chunks', r.retrieval!),
        ],
        if (r.comparison.isNotEmpty) ...[
          const SizedBox(height: VaultSpace.lg),
          const Text(
            'BACKEND COMPARISON',
            style: TextStyle(
              color: VaultColors.muted,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: VaultSpace.sm),
          for (final c in r.comparison) ...[
            if (c.isAvailable)
              _statRow(c.backend, c.stats!, usage: c.computeUsage)
            else
              Padding(
                padding: const EdgeInsets.only(bottom: VaultSpace.sm),
                child: Row(
                  children: [
                    const Icon(Icons.block_outlined,
                        size: 14, color: VaultColors.faint),
                    const SizedBox(width: VaultSpace.sm),
                    Expanded(
                      child: Text(
                        '${c.backend} unavailable — ${c.unavailableReason}',
                        style: const TextStyle(
                          color: VaultColors.faint,
                          fontSize: 11,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
        const SizedBox(height: VaultSpace.lg),
        OutlinedButton.icon(
          onPressed: () => _copyReport(r),
          icon: const Icon(Icons.copy_rounded, size: 17),
          label: const Text('Copy report as JSON'),
        ),
      ],
    );
  }

  /// One distribution as a row of numbers.
  ///
  /// Median leads, not mean: on a thermally-throttled phone the tail is
  /// long and asymmetric, so the mean sits somewhere no individual run
  /// actually landed. p90 and max are printed beside it because the spread
  /// is the throttling signal.
  Widget _statRow(String label, LatencyStats s, {ComputeUsageSummary? usage}) {
    Widget cell(String k, String v, {Color? color}) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                k,
                style: const TextStyle(
                  color: VaultColors.faint,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                v,
                style: VaultText.mono.copyWith(
                  color: color ?? VaultColors.foreground,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );

    return Container(
      margin: const EdgeInsets.only(bottom: VaultSpace.sm),
      padding: const EdgeInsets.all(VaultSpace.md),
      decoration: BoxDecoration(
        color: VaultColors.surfaceHigh,
        borderRadius: BorderRadius.circular(VaultSpace.radiusSm),
        border: Border.all(color: VaultColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: VaultColors.muted,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: VaultSpace.md),
          Row(
            children: [
              cell('MEDIAN', '${s.median.toStringAsFixed(0)} ms',
                  color: VaultColors.accent),
              cell('P90', '${s.p90.toStringAsFixed(0)} ms'),
              cell('MIN', '${s.min.toStringAsFixed(0)} ms'),
              cell('MAX', '${s.max.toStringAsFixed(0)} ms'),
              cell('σ', '${s.stdDev.toStringAsFixed(1)} ms'),
            ],
          ),
          const SizedBox(height: VaultSpace.sm),
          Text(
            '${s.throughputPerSecond.toStringAsFixed(2)}/s over ${s.count} runs',
            style: const TextStyle(color: VaultColors.faint, fontSize: 10.5),
          ),
          if (usage != null) ...[
            const SizedBox(height: VaultSpace.sm),
            _usageLine(usage),
          ],
        ],
      ),
    );
  }

  /// One line of CPU/GPU/NPU averages for the window a benchmark row timed —
  /// the number this whole feature exists to surface, next to the latency it
  /// was measured alongside rather than on a separate screen.
  Widget _usageLine(ComputeUsageSummary usage) {
    String fmt(ComputeLane lane) {
      final v = usage.averagePercent[lane];
      if (v == null) return '${lane.label} —';
      final kind = usage.kind[lane];
      final suffix = kind == ProbeKind.proxy ? '%*' : '%';
      return '${lane.label} ${v.toStringAsFixed(0)}$suffix';
    }

    return Text(
      '${ComputeLane.values.map(fmt).join('  ·  ')}  ·  '
      '${usage.sampleCount} samples'
      '${usage.thermal?.throttling == true ? '  ·  THROTTLING' : ''}',
      style: TextStyle(
        color: usage.thermal?.throttling == true
            ? VaultColors.warn
            : VaultColors.faint,
        fontSize: 10,
        fontFamily: VaultText.mono.fontFamily,
      ),
    );
  }

  Future<void> _copyReport(BenchmarkReport r) async {
    final json = const JsonEncoder.withIndent('  ').convert({
      ...r.toJson(),
      'device': widget.telemetry.snapshot(),
    });
    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Benchmark report copied')),
    );
  }

  // ---------------------------------------------------------------------
  // Reasoning benchmark
  // ---------------------------------------------------------------------

  /// Deliberately never offers a backend sweep the way [_benchmarkSection]
  /// does. See `llm_benchmark_runner.dart` for why: a wrong TFLite delegate
  /// throws, a wrong MediaPipe backend on mismatched weights segfaults the
  /// whole process, and there is no safe way to build "try GPU, fall back to
  /// CPU" into an automated sweep for that. This times whatever [LlmRuntime]
  /// already has loaded through the Model tab's crash-checked path.
  Widget _reasoningBenchmarkSection() {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.llmBenchmark, widget.llm]),
      builder: (context, _) {
        final b = widget.llmBenchmark;
        final llm = widget.llm;
        return SectionCard(
          title: 'Reasoning benchmark',
          subtitle: llm.isReady
              ? '5 timed generations after 1 discarded warm-up, on '
                  '${llm.backendLabel.toUpperCase()} — CPU/GPU/NPU '
                  'utilisation averaged over the run.'
              : 'Load a model on the Model tab, then benchmark generation '
                  'here.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.telemetry.thermal.throttling)
                _throttleWarning(widget.telemetry.thermal),
              if (b.isRunning) ...[
                LinearProgressIndicator(
                  value: b.progress == 0 ? null : b.progress,
                  backgroundColor: VaultColors.surfaceHigh,
                  color: VaultColors.accent,
                ),
                const SizedBox(height: VaultSpace.sm),
                Text(
                  b.detail,
                  style:
                      const TextStyle(color: VaultColors.muted, fontSize: 12),
                ),
                const SizedBox(height: VaultSpace.md),
                OutlinedButton.icon(
                  onPressed: b.cancel,
                  icon: const Icon(Icons.stop_rounded, size: 18),
                  label: const Text('Cancel'),
                ),
              ] else
                FilledButton.icon(
                  onPressed: llm.isReady ? () => b.run() : null,
                  icon: const Icon(Icons.psychology_rounded, size: 19),
                  label: Text(b.report == null ? 'Run benchmark' : 'Run again'),
                ),
              if (b.report != null) ...[
                const SizedBox(height: VaultSpace.lg),
                _llmReportView(b.report!),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _llmReportView(LlmBenchmarkReport r) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${r.modelLabel} · loaded in ${r.loadMs} ms',
          style: const TextStyle(color: VaultColors.faint, fontSize: 11),
        ),
        const SizedBox(height: VaultSpace.sm),
        _statRow(
          'Generation · ${r.backend.toUpperCase()}',
          r.latency,
          usage: r.computeUsage,
        ),
        if (r.meanTokensPerSecond != null) ...[
          const SizedBox(height: VaultSpace.xs),
          Text(
            '${r.meanTokensPerSecond!.toStringAsFixed(1)} tokens/s mean · '
            '${r.tokensPerSecond.length}/${r.latency.count} runs reported '
            'a token count',
            style: const TextStyle(color: VaultColors.faint, fontSize: 10.5),
          ),
        ],
        if (r.error != null) ...[
          const SizedBox(height: VaultSpace.sm),
          Container(
            padding: const EdgeInsets.all(VaultSpace.md),
            decoration: BoxDecoration(
              color: VaultColors.warn.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(VaultSpace.radiusSm),
              border:
                  Border.all(color: VaultColors.warn.withValues(alpha: 0.3)),
            ),
            child: Text(
              r.error!,
              style: const TextStyle(
                color: VaultColors.muted,
                fontSize: 11.5,
                height: 1.5,
              ),
            ),
          ),
        ],
        const SizedBox(height: VaultSpace.lg),
        OutlinedButton.icon(
          onPressed: () => _copyLlmReport(r),
          icon: const Icon(Icons.copy_rounded, size: 17),
          label: const Text('Copy report as JSON'),
        ),
      ],
    );
  }

  Future<void> _copyLlmReport(LlmBenchmarkReport r) async {
    final json = const JsonEncoder.withIndent('  ').convert({
      ...r.toJson(),
      'device': widget.telemetry.snapshot(),
    });
    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Reasoning benchmark report copied')),
    );
  }

  // ---------------------------------------------------------------------
  // Combined report — the artefact the hardware/model split decision
  // actually gets made from.
  // ---------------------------------------------------------------------

  Widget _combinedReportSection() {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.benchmark, widget.llmBenchmark]),
      builder: (context, _) {
        final hasEmbedding = widget.benchmark.report != null;
        final hasReasoning = widget.llmBenchmark.report != null;
        return SectionCard(
          title: 'Hardware split report',
          subtitle: 'One export combining both benchmarks above — encoder '
              'and reasoning model, each against the CPU/GPU/NPU numbers '
              'measured while it ran.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${hasEmbedding ? 'embedding ✓' : 'embedding — not run yet'}'
                '   ·   '
                '${hasReasoning ? 'reasoning ✓' : 'reasoning — not run yet'}',
                style:
                    const TextStyle(color: VaultColors.faint, fontSize: 11.5),
              ),
              const SizedBox(height: VaultSpace.md),
              OutlinedButton.icon(
                onPressed: (hasEmbedding || hasReasoning)
                    ? _copyCombinedReport
                    : null,
                icon: const Icon(Icons.description_outlined, size: 18),
                label: const Text('Copy combined report as JSON'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _copyCombinedReport() async {
    final json = const JsonEncoder.withIndent('  ').convert({
      'generated_at': DateTime.now().toIso8601String(),
      'device': widget.telemetry.snapshot(),
      if (widget.benchmark.report != null)
        'embedding': widget.benchmark.report!.toJson(),
      if (widget.llmBenchmark.report != null)
        'reasoning': widget.llmBenchmark.report!.toJson(),
    });
    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Combined hardware report copied')),
    );
  }
}

class _PauseButton extends StatelessWidget {
  final bool paused;
  final ValueChanged<bool> onChanged;

  const _PauseButton({required this.paused, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    // A live chart cannot be read carefully, and a benchmark screenshot
    // needs a frozen window. Pause is a real control, not a debug toggle,
    // which is also what the streaming-chart accessibility guidance asks for.
    return Tooltip(
      message: paused ? 'Resume sampling' : 'Pause sampling',
      child: IconButton(
        onPressed: () => onChanged(!paused),
        // 44 dp minimum touch target.
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        icon: Icon(
          paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
          color: paused ? VaultColors.accent : VaultColors.muted,
        ),
      ),
    );
  }
}

class _LegendChip extends StatelessWidget {
  final ComputeLane lane;
  final ProbeKind kind;
  final bool hidden;
  final VoidCallback onTap;

  const _LegendChip({
    required this.lane,
    required this.kind,
    required this.hidden,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final style = ComputeSeriesStyle.of(lane);
    final unavailable = kind == ProbeKind.unavailable;
    final dim = hidden || unavailable;

    return Semantics(
      button: !unavailable,
      label: '${lane.label} series, ${hidden ? 'hidden' : 'shown'}',
      child: InkWell(
        onTap: unavailable ? null : onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          // 44 dp is unreachable for an inline legend chip without wrecking
          // the layout; 34 with generous horizontal padding is the
          // compromise, and every chip has a larger duplicate control (the
          // tile above) that is not a tap target at all.
          constraints: const BoxConstraints(minHeight: 34),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: VaultColors.surfaceHigh,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: dim ? VaultColors.border : style.color.withValues(alpha: 0.5),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The legend swatch reproduces the stroke pattern, not just
              // the colour, so the key works in monochrome.
              CustomPaint(
                size: const Size(18, 8),
                painter: _SwatchPainter(
                  color: dim ? VaultColors.faint : style.color,
                  dash: style.dash,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                lane.label,
                style: TextStyle(
                  color: dim ? VaultColors.faint : VaultColors.foreground,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  decoration: hidden ? TextDecoration.lineThrough : null,
                ),
              ),
              if (unavailable) ...[
                const SizedBox(width: 5),
                const Text(
                  'n/a',
                  style: TextStyle(color: VaultColors.faint, fontSize: 10),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SwatchPainter extends CustomPainter {
  final Color color;
  final List<double> dash;

  _SwatchPainter({required this.color, required this.dash});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final y = size.height / 2;

    if (dash.isEmpty) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      return;
    }
    var x = 0.0;
    var i = 0;
    var on = true;
    while (x < size.width) {
      final step = dash[i % dash.length];
      final end = (x + step).clamp(0.0, size.width);
      if (on) canvas.drawLine(Offset(x, y), Offset(end, y), paint);
      x = end;
      i++;
      on = !on;
    }
  }

  @override
  bool shouldRepaint(_SwatchPainter old) =>
      old.color != color || old.dash != dash;
}

/// Which additional encoder backends to build a throwaway interpreter for
/// and time, on top of the live one the app already runs.
///
/// One checkbox per [EmbeddingBackend] rather than [BenchmarkRunner]'s old
/// single "compare" toggle, because the four backends are not equally
/// costly or equally likely to exist. QNN HTP is the verified Hexagon NPU
/// path (validated against XNNPACK before it is trusted); GPU and NNAPI can
/// legitimately come back `unavailable` — see [BackendResult] — which is a
/// finding, not a failure. NNAPI is NOT labelled "NPU": LiteRT 1.4 has
/// largely moved past it and it proves nothing about Hexagon execution.
/// Plain CPU and XNNPACK are slower to time honestly because the workload
/// itself is slower on them, not because building the interpreter is.
class _BackendSweepPicker extends StatelessWidget {
  final Set<EmbeddingBackend> selected;
  final ValueChanged<EmbeddingBackend> onChanged;

  const _BackendSweepPicker({required this.selected, required this.onChanged});

  static const _options = [
    (EmbeddingBackend.xnnpack, 'XNNPACK', 'accelerated CPU kernels'),
    (EmbeddingBackend.cpu, 'CPU', 'unaccelerated baseline, slow'),
    (EmbeddingBackend.gpu, 'GPU', 'Adreno, may refuse to build'),
    (EmbeddingBackend.qnnHtp, 'QNN HTP', 'Hexagon NPU, validated vs XNNPACK'),
    (EmbeddingBackend.nnapi, 'NNAPI', 'legacy route, may refuse to build'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'ALSO SWEEP',
          style: TextStyle(
            color: VaultColors.muted,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: VaultSpace.xs),
        for (final (backend, label, detail) in _options)
          InkWell(
            onTap: () => onChanged(backend),
            borderRadius: BorderRadius.circular(VaultSpace.radiusSm),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Checkbox(
                    value: selected.contains(backend),
                    onChanged: (_) => onChanged(backend),
                    side: const BorderSide(color: VaultColors.borderStrong),
                  ),
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        style: const TextStyle(
                          color: VaultColors.faint,
                          fontSize: 11.5,
                          height: 1.4,
                        ),
                        children: [
                          TextSpan(
                            text: '$label  ',
                            style: const TextStyle(
                              color: VaultColors.foreground,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          TextSpan(text: detail),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (selected.isNotEmpty) ...[
          const SizedBox(height: VaultSpace.xs),
          Text(
            '${selected.length} backend${selected.length == 1 ? '' : 's'} '
            'selected — each builds its own interpreter and times it '
            'separately, on top of the live run. A failed build is '
            'reported, not hidden.',
            style: const TextStyle(color: VaultColors.faint, fontSize: 10.5),
          ),
        ],
      ],
    );
  }
}
