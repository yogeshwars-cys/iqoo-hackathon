/// telemetry_sources.dart
///
/// Raw probes for on-device compute utilisation. Everything here reads
/// procfs/sysfs through dart:io — no plugin, no native code.
///
/// READ THIS BEFORE TRUSTING A NUMBER ON THE STATS SCREEN.
///
/// Android is not instrumented for this the way a desktop is. Of the three
/// engines people ask about, exactly one has a counter that an unprivileged
/// app is guaranteed to be able to read:
///
///   CPU  — real. /proc/stat is world-readable, and /proc/self/stat always
///          is. Both give honest busy/idle deltas.
///
///   GPU  — usually real, not guaranteed. Adreno exposes busy counters under
///          /sys/class/kgsl/kgsl-3d0/. Those files are 0444, but SELinux
///          policy on some OEM builds (OriginOS and MIUI both do this)
///          denies untrusted_app the read. When that happens we get a
///          permission error, not a wrong number, so it degrades honestly.
///
///   NPU  — there is no public per-device counter for the Hexagon NPU.
///          None. The fastrpc/adsprpc statistics live under
///          /sys/kernel/debug, which is root-only on a production build.
///          What *is* sometimes exposed is a devfreq node for the compute
///          DSP, which gives clock frequency — a proxy for load, not load.
///
/// So rather than invent a plausible-looking NPU curve, every probe returns
/// a [Probe] tagged with how the number was obtained: [ProbeKind.measured]
/// for a real busy counter, [ProbeKind.proxy] for frequency-derived,
/// [ProbeKind.derived] for something this app computed itself, and
/// [ProbeKind.unavailable] when the device will not tell us. The UI renders
/// those differently and never draws a solid line for a number it did not
/// actually measure. A flat "NPU unavailable" lane is a true finding about
/// this hardware; a fabricated one would quietly invalidate every benchmark
/// taken with it.

library;

import 'dart:io';

/// How much a reported number can be trusted.
enum ProbeKind {
  /// A real busy/idle counter from the kernel.
  measured,

  /// Derived from clock frequency, which correlates with load but is not
  /// load — a governor can hold a high clock while idle, and vice versa.
  proxy,

  /// Computed by this app from its own instrumentation (e.g. time spent
  /// inside the TFLite interpreter). Accurate about what it measures, but
  /// it measures our work, not the whole device's.
  derived,

  /// The device does not expose this, or policy denies the read.
  unavailable,
}

class Probe {
  /// 0..100 for utilisation probes, or an absolute value for clocks.
  final double? value;
  final ProbeKind kind;

  /// Which file produced this, so a surprising number can be chased.
  final String? source;

  /// Short human explanation, shown in the UI when [kind] is not
  /// [ProbeKind.measured].
  final String? note;

  const Probe(this.value, this.kind, {this.source, this.note});

  const Probe.unavailable({this.note, this.source})
      : value = null,
        kind = ProbeKind.unavailable;

  bool get isAvailable => value != null && kind != ProbeKind.unavailable;

  Map<String, dynamic> toJson() => {
        'value': value,
        'kind': kind.name,
        if (source != null) 'source': source,
        if (note != null) 'note': note,
      };
}

/// Reads a sysfs/procfs file, returning null on any failure.
///
/// Every read here can fail for a reason that is not a bug: the node does
/// not exist on this SoC, SELinux denies it, or the driver is unloaded.
/// Callers treat null as "this device will not say", never as an error.
String? _readOrNull(String path) {
  try {
    final f = File(path);
    if (!f.existsSync()) return null;
    return f.readAsStringSync().trim();
  } catch (_) {
    return null;
  }
}

double? _firstNumber(String? s) {
  if (s == null) return null;
  final m = RegExp(r'-?\d+(\.\d+)?').firstMatch(s);
  if (m == null) return null;
  return double.tryParse(m.group(0)!);
}

// ---------------------------------------------------------------------------
// CPU
// ---------------------------------------------------------------------------

/// System-wide CPU busy percentage from /proc/stat.
///
/// /proc/stat's counters are cumulative since boot, so a single read tells
/// you nothing — utilisation is the delta between two reads. This class
/// holds the previous sample.
class SystemCpuSampler {
  int _prevBusy = 0;
  int _prevTotal = 0;
  bool _primed = false;

  /// True once a second sample has been taken and the delta is meaningful.
  bool get isPrimed => _primed;

  Probe sample() {
    final raw = _readOrNull('/proc/stat');
    if (raw == null) {
      return const Probe.unavailable(
        source: '/proc/stat',
        note: 'Not readable on this build; falling back to process CPU.',
      );
    }

    // First line: "cpu  user nice system idle iowait irq softirq steal ..."
    final line = raw.split('\n').first;
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 8 || parts.first != 'cpu') {
      return const Probe.unavailable(
        source: '/proc/stat',
        note: 'Unrecognised format.',
      );
    }

    final fields =
        parts.skip(1).map((p) => int.tryParse(p) ?? 0).toList(growable: false);
    final idle = fields[3] + (fields.length > 4 ? fields[4] : 0); // idle+iowait
    final total = fields.fold<int>(0, (a, b) => a + b);
    final busy = total - idle;

    final dBusy = busy - _prevBusy;
    final dTotal = total - _prevTotal;
    _prevBusy = busy;
    _prevTotal = total;

    if (!_primed) {
      _primed = true;
      // The first call only establishes the baseline.
      return const Probe(null, ProbeKind.measured, source: '/proc/stat');
    }
    if (dTotal <= 0) {
      return const Probe(0, ProbeKind.measured, source: '/proc/stat');
    }
    return Probe(
      (dBusy / dTotal * 100).clamp(0, 100).toDouble(),
      ProbeKind.measured,
      source: '/proc/stat',
    );
  }
}

/// This process's own CPU usage, normalised across all cores.
///
/// Always available — a process can always read its own /proc/self/stat —
/// so this is the fallback when /proc/stat is restricted, and it is also
/// the more honest number for "how hard is the vault working", since it
/// excludes whatever else the phone is doing.
class ProcessCpuSampler {
  /// Linux USER_HZ. There is no sysconf(_SC_CLK_TCK) binding in Dart, but
  /// this is 100 on every Android ARM kernel in production — the constant
  /// is part of the ABI, not a per-device setting.
  static const _clockTicksPerSecond = 100.0;

  final int cores;

  int _prevTicks = 0;
  int? _prevAtMicros;

  ProcessCpuSampler({int? cores}) : cores = cores ?? Platform.numberOfProcessors;

  Probe sample() {
    final raw = _readOrNull('/proc/self/stat');
    if (raw == null) {
      return const Probe.unavailable(source: '/proc/self/stat');
    }

    // Field 2 is the executable name in parentheses and may itself contain
    // spaces or ')', so the only safe split point is the LAST ')'.
    final close = raw.lastIndexOf(')');
    if (close < 0) return const Probe.unavailable(source: '/proc/self/stat');
    final rest = raw.substring(close + 1).trim().split(RegExp(r'\s+'));

    // rest[0] is field 3 (state), so field N sits at rest[N - 3].
    // utime = field 14, stime = field 15.
    if (rest.length < 13) {
      return const Probe.unavailable(source: '/proc/self/stat');
    }
    final utime = int.tryParse(rest[11]) ?? 0;
    final stime = int.tryParse(rest[12]) ?? 0;
    final ticks = utime + stime;
    final now = DateTime.now().microsecondsSinceEpoch;

    final prevAt = _prevAtMicros;
    _prevAtMicros = now;
    final dTicks = ticks - _prevTicks;
    _prevTicks = ticks;

    if (prevAt == null) {
      return const Probe(null, ProbeKind.measured, source: '/proc/self/stat');
    }
    final elapsedSeconds = (now - prevAt) / 1e6;
    if (elapsedSeconds <= 0) {
      return const Probe(0, ProbeKind.measured, source: '/proc/self/stat');
    }

    final cpuSeconds = dTicks / _clockTicksPerSecond;
    // Normalise by core count so a fully-busy 8-core phone reads 100, not 800.
    final percent = cpuSeconds / elapsedSeconds / cores * 100;
    return Probe(
      percent.clamp(0, 100).toDouble(),
      ProbeKind.measured,
      source: '/proc/self/stat',
      note: 'This process only, averaged over $cores cores.',
    );
  }
}

/// Current clock of the fastest online core, in MHz.
Probe readCpuClockMhz() {
  var best = 0.0;
  String? source;
  for (var cpu = 0; cpu < Platform.numberOfProcessors; cpu++) {
    final path = '/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_cur_freq';
    final khz = _firstNumber(_readOrNull(path));
    if (khz != null && khz / 1000 > best) {
      best = khz / 1000;
      source = path;
    }
  }
  if (source == null) {
    return const Probe.unavailable(
      source: '/sys/devices/system/cpu/*/cpufreq',
      note: 'cpufreq not exposed to apps on this build.',
    );
  }
  return Probe(best, ProbeKind.measured, source: source);
}

// ---------------------------------------------------------------------------
// GPU (Adreno / KGSL)
// ---------------------------------------------------------------------------

/// Adreno GPU busy percentage.
///
/// Tries three nodes in descending order of directness:
///
///  1. `gpu_busy_percentage` — the driver's own answer, e.g. "37 %".
///  2. `devfreq/gpu_load`    — 0..100, the same thing by another name.
///  3. `gpubusy`             — two numbers, "busy total", in GPU clock
///     ticks accumulated *since the last read*. Reading it resets it, which
///     is why it is last: if anything else on the device samples it too, we
///     each see only part of the interval. Good enough for a trend, and it
///     is the only one present on older KGSL.
class GpuSampler {
  static const _base = '/sys/class/kgsl/kgsl-3d0';

  Probe sample() {
    final pct = _firstNumber(_readOrNull('$_base/gpu_busy_percentage'));
    if (pct != null) {
      return Probe(pct.clamp(0, 100).toDouble(), ProbeKind.measured,
          source: '$_base/gpu_busy_percentage');
    }

    final load = _firstNumber(_readOrNull('$_base/devfreq/gpu_load'));
    if (load != null) {
      return Probe(load.clamp(0, 100).toDouble(), ProbeKind.measured,
          source: '$_base/devfreq/gpu_load');
    }

    final busyRaw = _readOrNull('$_base/gpubusy');
    if (busyRaw != null) {
      final nums = RegExp(r'\d+')
          .allMatches(busyRaw)
          .map((m) => int.parse(m.group(0)!))
          .toList();
      if (nums.length >= 2 && nums[1] > 0) {
        return Probe(
          (nums[0] / nums[1] * 100).clamp(0, 100).toDouble(),
          ProbeKind.measured,
          source: '$_base/gpubusy',
          note: 'Delta counter — resets on read.',
        );
      }
    }

    return const Probe.unavailable(
      source: _base,
      note: 'No KGSL busy counter readable. Either this is not an Adreno '
          'GPU, or SELinux denies untrusted_app access to /sys/class/kgsl '
          'on this ROM.',
    );
  }

  Probe clockMhz() {
    final hz = _firstNumber(_readOrNull('$_base/gpuclk'));
    if (hz != null) {
      return Probe(hz / 1e6, ProbeKind.measured, source: '$_base/gpuclk');
    }
    final cur = _firstNumber(_readOrNull('$_base/devfreq/cur_freq'));
    if (cur != null) {
      return Probe(cur / 1e6, ProbeKind.measured,
          source: '$_base/devfreq/cur_freq');
    }
    return const Probe.unavailable(source: '$_base/gpuclk');
  }
}

// ---------------------------------------------------------------------------
// NPU / compute DSP
// ---------------------------------------------------------------------------

/// Best-effort NPU utilisation.
///
/// See the file header: there is no supported busy counter for the Hexagon
/// NPU on a production Android build. This scans /sys/class/devfreq for a
/// node belonging to the compute DSP and reports what it finds:
///
///   * a `load` file      -> real utilisation, [ProbeKind.measured]
///   * cur_freq/max_freq  -> frequency ratio, [ProbeKind.proxy]
///   * nothing            -> [ProbeKind.unavailable]
///
/// On a Snapdragon 695 the expected outcome is `unavailable`, and that is
/// the correct result to display. The NPU lane on the chart then stays flat
/// and labelled, which tells you something true and useful: LiteRT 1.4 has
/// no working delegate for this part, so the NPU is genuinely idle while
/// the vault runs.
class NpuSampler {
  static const _devfreqRoot = '/sys/class/devfreq';

  /// Device-node name fragments that indicate a compute DSP / NPU.
  static final _nameHints = RegExp(
    r'npu|nsp|cdsp|hexagon|dsp|aip|neural',
    caseSensitive: false,
  );

  String? _resolvedNode;
  bool _scanned = false;

  /// The devfreq node this sampler locked onto, for display.
  String? get resolvedNode => _resolvedNode;

  void _scan() {
    _scanned = true;
    try {
      final dir = Directory(_devfreqRoot);
      if (!dir.existsSync()) return;
      for (final entry in dir.listSync()) {
        final name = entry.path.split(RegExp(r'[/\\]')).last;
        // KGSL is the GPU; it matches "dsp"-adjacent hints on some ROMs and
        // would otherwise be double-counted as the NPU.
        if (name.contains('kgsl')) continue;
        if (_nameHints.hasMatch(name)) {
          _resolvedNode = '$_devfreqRoot/$name';
          return;
        }
      }
    } catch (_) {
      // Directory listing denied — same outcome as not present.
    }
  }

  Probe sample() {
    if (!_scanned) _scan();
    final node = _resolvedNode;
    if (node == null) {
      return const Probe.unavailable(
        source: _devfreqRoot,
        note: 'No NPU/compute-DSP devfreq node exposed. Android has no '
            'public NPU busy counter; the fastrpc stats live under '
            '/sys/kernel/debug and need root.',
      );
    }

    final load = _firstNumber(_readOrNull('$node/load'));
    if (load != null) {
      return Probe(load.clamp(0, 100).toDouble(), ProbeKind.measured,
          source: '$node/load');
    }

    final cur = _firstNumber(_readOrNull('$node/cur_freq'));
    final max = _firstNumber(_readOrNull('$node/max_freq'));
    if (cur != null && max != null && max > 0) {
      return Probe(
        (cur / max * 100).clamp(0, 100).toDouble(),
        ProbeKind.proxy,
        source: '$node/cur_freq',
        note: 'Clock ratio, not busy time. The governor can hold a high '
            'clock while idle, so treat this as a hint.',
      );
    }

    return Probe.unavailable(
      source: node,
      note: 'Node found but exposes neither load nor cur_freq/max_freq.',
    );
  }
}

// ---------------------------------------------------------------------------
// Memory
// ---------------------------------------------------------------------------

/// Resident set size of this process, in MB, from /proc/self/statm.
Probe readRssMb() {
  final raw = _readOrNull('/proc/self/statm');
  if (raw == null) return const Probe.unavailable(source: '/proc/self/statm');
  final parts = raw.split(RegExp(r'\s+'));
  if (parts.length < 2) return const Probe.unavailable();
  final pages = int.tryParse(parts[1]);
  if (pages == null) return const Probe.unavailable();
  // 4 KiB pages on every Android ARM64 kernel currently shipping.
  return Probe(pages * 4 / 1024, ProbeKind.measured, source: '/proc/self/statm');
}
