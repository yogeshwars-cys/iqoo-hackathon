/// compute_telemetry.dart
///
/// Polls every probe in telemetry_sources.dart on a fixed cadence and keeps
/// a bounded history for the chart.
///
/// THREE DESIGN DECISIONS WORTH THE WORDS:
///
/// 1. It is a [ChangeNotifier], not app state passed down through setState.
///    A 1 Hz ticker that rebuilds the whole widget tree is the classic way
///    to make a dashboard drop frames; only the chart and the tiles listen,
///    so a tick repaints a few hundred pixels rather than the page.
///
/// 2. History is a fixed-capacity ring, not a growing List. At 1 Hz over a
///    long benchmark an unbounded list is a slow memory leak, and the chart
///    only ever draws the last [historyCapacity] points anyway.
///
/// 3. Sampling is pausable, and pausing is a first-class control rather than
///    a debug affordance. A moving chart cannot be read carefully, and
///    someone recording a benchmark needs to freeze the window to read it.
///
/// The fourth series, "inference duty", is this app's own instrumentation:
/// the fraction of each sampling window actually spent inside the TFLite
/// interpreter. Unlike CPU/GPU/NPU it is always available, and for
/// benchmarking it is the most directly useful number on the screen — it
/// separates "the accelerator is working" from "the phone is busy".

library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'device_info.dart';
import 'telemetry_sources.dart';

/// Counts time spent inside the model, so the telemetry service can turn it
/// into a duty cycle. The embedding service feeds this.
class InferenceMeter {
  int _cumulativeMicros = 0;
  int _cumulativeCount = 0;

  int _lastReadMicros = 0;
  int _lastReadCount = 0;

  int get totalMicros => _cumulativeMicros;
  int get totalCount => _cumulativeCount;

  void record(int micros) {
    _cumulativeMicros += micros;
    _cumulativeCount++;
  }

  void reset() {
    _cumulativeMicros = 0;
    _cumulativeCount = 0;
    _lastReadMicros = 0;
    _lastReadCount = 0;
  }

  /// Microseconds of inference since the previous call. Consuming, because
  /// the duty cycle is a per-window quantity.
  ({int micros, int count}) drain() {
    final micros = _cumulativeMicros - _lastReadMicros;
    final count = _cumulativeCount - _lastReadCount;
    _lastReadMicros = _cumulativeMicros;
    _lastReadCount = _cumulativeCount;
    return (micros: micros, count: count);
  }
}

/// One row of the telemetry history.
class TelemetrySample {
  final DateTime at;
  final Probe cpu;
  final Probe gpu;
  final Probe npu;

  /// Percent of this sampling window spent inside the interpreter.
  final Probe duty;

  /// Embeddings completed during this window.
  final int inferences;

  const TelemetrySample({
    required this.at,
    required this.cpu,
    required this.gpu,
    required this.npu,
    required this.duty,
    required this.inferences,
  });

  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(),
        'cpu': cpu.toJson(),
        'gpu': gpu.toJson(),
        'npu': npu.toJson(),
        'duty': duty.toJson(),
        'inferences': inferences,
      };
}

/// The four lanes the stats screen draws.
enum ComputeLane { cpu, gpu, npu, duty }

extension ComputeLaneInfo on ComputeLane {
  String get label => switch (this) {
        ComputeLane.cpu => 'CPU',
        ComputeLane.gpu => 'GPU',
        ComputeLane.npu => 'NPU',
        ComputeLane.duty => 'Inference',
      };

  String get description => switch (this) {
        ComputeLane.cpu => 'System-wide busy time from /proc/stat.',
        ComputeLane.gpu => 'Adreno KGSL busy counter.',
        ComputeLane.npu => 'Hexagon compute-DSP devfreq node.',
        ComputeLane.duty => 'Share of wall time inside the TFLite interpreter.',
      };
}

/// A window of [TelemetrySample]s reduced to one number per lane.
///
/// [averagePercent] is null for a lane that was never available during the
/// window, never zero — the difference between "measured, and it was idle"
/// and "nothing here can say" is the entire point of [ProbeKind], and
/// averaging must not erase it the way plotting a flat zero would on the
/// chart.
class ComputeUsageSummary {
  final Map<ComputeLane, double?> averagePercent;
  final Map<ComputeLane, ProbeKind> kind;
  final int sampleCount;
  final ThermalState? thermal;

  const ComputeUsageSummary({
    required this.averagePercent,
    required this.kind,
    required this.sampleCount,
    this.thermal,
  });

  Map<String, dynamic> toJson() => {
        'samples': sampleCount,
        for (final lane in ComputeLane.values)
          lane.name: {
            'avg_percent': averagePercent[lane],
            'kind': kind[lane]?.name,
          },
        if (thermal != null && thermal!.isKnown) 'thermal': thermal!.toJson(),
      };
}

/// Reduces [samples] to one [ComputeUsageSummary], averaging only over the
/// readings each lane actually reported.
///
/// A lane that drops out mid-run (SELinux starts denying a read, a devfreq
/// node disappears) should not have those gaps silently pull its average
/// toward zero — that would look like the accelerator went idle, when the
/// truth is this run stopped being able to ask it.
ComputeUsageSummary summarizeUsage(
  Iterable<TelemetrySample> samples, {
  ThermalState? thermal,
}) {
  final list = samples.toList(growable: false);
  final avg = <ComputeLane, double?>{};
  final kind = <ComputeLane, ProbeKind>{};

  for (final lane in ComputeLane.values) {
    final probes = list.map((s) => switch (lane) {
          ComputeLane.cpu => s.cpu,
          ComputeLane.gpu => s.gpu,
          ComputeLane.npu => s.npu,
          ComputeLane.duty => s.duty,
        });
    final available = probes.where((p) => p.isAvailable).toList();
    avg[lane] = available.isEmpty
        ? null
        : available.map((p) => p.value!).reduce((a, b) => a + b) /
            available.length;
    kind[lane] =
        probes.isEmpty ? ProbeKind.unavailable : probes.last.kind;
  }

  return ComputeUsageSummary(
    averagePercent: avg,
    kind: kind,
    sampleCount: list.length,
    thermal: thermal,
  );
}

class ComputeTelemetry extends ChangeNotifier {
  /// 1 Hz. Fast enough that a 250 ms embedding shows up as a visible bump,
  /// slow enough that reading eight sysfs files never competes with the
  /// model for CPU.
  final Duration interval;

  /// Ring capacity. 180 samples at 1 Hz is a three-minute window, which
  /// comfortably contains a full benchmark sweep.
  final int historyCapacity;

  final InferenceMeter meter;

  final _systemCpu = SystemCpuSampler();
  final _processCpu = ProcessCpuSampler();
  final _gpu = GpuSampler();
  final _npu = NpuSampler();

  final ListQueue<TelemetrySample> _history;

  Timer? _timer;
  bool _paused = false;
  DateTime? _lastTickAt;

  /// Set by [dispose]. Read by [_notify]; see it.
  bool _disposed = false;

  /// Static facts, fetched once at [start].
  DeviceFacts deviceFacts = DeviceFacts.unknown;

  /// Thermal throttling state. Polled on a slow cadence rather than every
  /// tick: it is a platform channel round-trip, and thermal state changes
  /// on the order of tens of seconds, not one.
  ThermalState thermal = ThermalState.unknown;
  int _ticksSinceThermalPoll = 0;
  static const _thermalEveryNTicks = 5;

  ComputeTelemetry({
    required this.meter,
    this.interval = const Duration(seconds: 1),
    this.historyCapacity = 180,
  }) : _history = ListQueue<TelemetrySample>(historyCapacity);

  UnmodifiableListView<TelemetrySample> get history =>
      UnmodifiableListView(_history);

  TelemetrySample? get latest => _history.isEmpty ? null : _history.last;

  bool get isPaused => _paused;

  bool get isRunning => _timer != null;

  /// Which lanes this device actually reports, resolved after the first
  /// tick. The UI uses this to grey out lanes rather than drawing a
  /// misleading flat zero.
  final Map<ComputeLane, ProbeKind> laneKinds = {
    ComputeLane.cpu: ProbeKind.measured,
    ComputeLane.gpu: ProbeKind.unavailable,
    ComputeLane.npu: ProbeKind.unavailable,
    ComputeLane.duty: ProbeKind.derived,
  };

  void start() {
    if (_timer != null) return;
    _lastTickAt = DateTime.now();
    _loadPlatformFacts();
    // Prime the delta-based samplers immediately so the first drawn point
    // is a real measurement rather than a zero.
    _systemCpu.sample();
    _processCpu.sample();
    _gpu.sample();
    // The meter is a delta counter too, and it keeps counting while the
    // timer is stopped — the bridge serves queries with the app
    // backgrounded, which is the whole point of it. Without this drain all
    // of that work is attributed to the first window after resume: a phone
    // that spent four minutes in a pocket answering the desktop comes back
    // showing one second of 100 % duty and every one of those inferences
    // stamped on a single sample. Priming here rather than in [stop] so it
    // also covers a start() that follows a long bootstrap.
    meter.drain();
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// [notifyListeners] that tolerates being called after disposal.
  ///
  /// [_loadPlatformFacts] and the thermal poll are method-channel round
  /// trips started by [start] and finished whenever the platform gets to
  /// them. Backgrounding the app during a cold start is enough to have one
  /// land after the widget tree that owned this is gone, and ChangeNotifier
  /// throws if notified then. Same idiom, and same reason, as
  /// VaultEngine._notify.
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  Future<void> _loadPlatformFacts() async {
    if (deviceFacts == DeviceFacts.unknown) {
      deviceFacts = await DeviceFacts.load();
    }
    thermal = await ThermalState.read();
    _notify();
  }

  void setPaused(bool value) {
    if (_paused == value) return;
    _paused = value;
    // Keep the timer running while paused so the delta samplers stay primed;
    // a resumed chart then shows a real value on the very next tick instead
    // of one bogus spike covering the whole paused interval.
    if (!value) _lastTickAt = DateTime.now();
    _notify();
  }

  void clearHistory() {
    _history.clear();
    _notify();
  }

  void _tick() {
    final now = DateTime.now();
    final since = _lastTickAt;
    _lastTickAt = now;

    // Drain unconditionally — otherwise a paused window would dump all its
    // accumulated inference time into the first tick after resuming.
    final drained = meter.drain();

    if (_paused) {
      // Still poll, to keep the delta counters current, but discard.
      _systemCpu.sample();
      _processCpu.sample();
      _gpu.sample();
      return;
    }

    var cpu = _systemCpu.sample();
    if (!cpu.isAvailable) {
      // /proc/stat restricted (or still priming) — the process's own CPU is
      // always readable and is the more relevant number anyway.
      final fallback = _processCpu.sample();
      if (fallback.isAvailable) cpu = fallback;
    } else {
      _processCpu.sample(); // keep primed for a later fallback
    }

    final gpu = _gpu.sample();
    final npu = _npu.sample();

    if (++_ticksSinceThermalPoll >= _thermalEveryNTicks) {
      _ticksSinceThermalPoll = 0;
      // Fire and forget: the await would delay this tick's sample by a
      // platform round-trip, which is exactly the jitter the duty-cycle
      // calculation should not inherit.
      ThermalState.read().then((t) {
        thermal = t;
      });
    }

    final windowMicros = since == null
        ? interval.inMicroseconds
        : now.difference(since).inMicroseconds;
    final dutyPercent = windowMicros <= 0
        ? 0.0
        : (drained.micros / windowMicros * 100).clamp(0, 100).toDouble();

    laneKinds[ComputeLane.cpu] = cpu.kind;
    laneKinds[ComputeLane.gpu] = gpu.kind;
    laneKinds[ComputeLane.npu] = npu.kind;

    _push(TelemetrySample(
      at: now,
      cpu: cpu,
      gpu: gpu,
      npu: npu,
      duty: Probe(
        dutyPercent,
        ProbeKind.derived,
        note: 'Interpreter time / wall time, measured by this app.',
      ),
      inferences: drained.count,
    ));
    _notify();
  }

  void _push(TelemetrySample s) {
    if (_history.length >= historyCapacity) _history.removeFirst();
    _history.add(s);
  }

  /// Series values for one lane, oldest first, with null for samples where
  /// that lane had nothing to report. The chart breaks the line at nulls
  /// rather than drawing through them as zero.
  List<double?> seriesFor(ComputeLane lane) => _history
      .map((s) => switch (lane) {
            ComputeLane.cpu => s.cpu,
            ComputeLane.gpu => s.gpu,
            ComputeLane.npu => s.npu,
            ComputeLane.duty => s.duty,
          })
      .map((p) => p.isAvailable ? p.value : null)
      .toList(growable: false);

  Probe probeFor(ComputeLane lane) {
    final s = latest;
    if (s == null) return const Probe.unavailable();
    return switch (lane) {
      ComputeLane.cpu => s.cpu,
      ComputeLane.gpu => s.gpu,
      ComputeLane.npu => s.npu,
      ComputeLane.duty => s.duty,
    };
  }

  /// Samples recorded at or after [since].
  ///
  /// A benchmark that runs for seconds (generation) rather than
  /// milliseconds (embedding) should not describe its hardware cost with two
  /// point-in-time snapshots — that is the same mistake §3 of BUILD_NOTES
  /// warns against for latency, applied to utilisation instead: a snapshot
  /// taken right as the run starts or ends can land in a governor ramp and
  /// miss the sustained load entirely. [summarizeUsage] turns this window
  /// into the honest per-lane average.
  Iterable<TelemetrySample> samplesSince(DateTime since) =>
      history.where((s) => !s.at.isBefore(since));

  /// Compact snapshot for the bridge telemetry frame and for benchmark
  /// exports.
  Map<String, dynamic> snapshot() {
    final s = latest;
    return {
      'sampled_at': s?.at.toIso8601String(),
      'cpu_percent': s?.cpu.value,
      'cpu_kind': s?.cpu.kind.name,
      'gpu_percent': s?.gpu.value,
      'gpu_kind': s?.gpu.kind.name,
      'npu_percent': s?.npu.value,
      'npu_kind': s?.npu.kind.name,
      'npu_node': _npu.resolvedNode,
      'inference_duty_percent': s?.duty.value,
      'cpu_clock_mhz': readCpuClockMhz().value,
      'gpu_clock_mhz': _gpu.clockMhz().value,
      'rss_mb': readRssMb().value,
      'cores': _processCpu.cores,
      'device': deviceFacts.toJson(),
      'thermal': thermal.isKnown ? thermal.toJson() : null,
    };
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
