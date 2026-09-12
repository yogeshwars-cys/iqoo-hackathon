/// Host-side tests for the telemetry maths.
///
/// The sysfs probes themselves cannot be tested off-device — there is no
/// /sys/class/kgsl on a Windows host — but the parts that decide what a
/// number *means* are pure, and they are the parts that would silently
/// produce a wrong benchmark.

library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_rag_test/telemetry/benchmark_runner.dart';
import 'package:vault_rag_test/telemetry/compute_telemetry.dart';
import 'package:vault_rag_test/telemetry/device_info.dart';
import 'package:vault_rag_test/telemetry/telemetry_sources.dart';

void main() {
  // ComputeTelemetry.start() talks to the `vault/device` method channel.
  // There is no Android on the other end here, so the calls fail and fall
  // back to DeviceFacts.unknown — but they still complete asynchronously,
  // which is the behaviour the disposal test below depends on.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('InferenceMeter', () {
    test('drain returns only what accumulated since the last call', () {
      final meter = InferenceMeter();
      meter.record(1000);
      meter.record(2000);

      var drained = meter.drain();
      expect(drained.micros, 3000);
      expect(drained.count, 2);

      // Nothing new: a second drain must be empty, not a repeat. If this
      // regressed, the duty-cycle lane would report the same work forever.
      drained = meter.drain();
      expect(drained.micros, 0);
      expect(drained.count, 0);

      meter.record(500);
      drained = meter.drain();
      expect(drained.micros, 500);
      expect(drained.count, 1);
    });

    test('keeps a cumulative total independent of draining', () {
      final meter = InferenceMeter();
      meter.record(100);
      meter.drain();
      meter.record(200);
      expect(meter.totalMicros, 300);
      expect(meter.totalCount, 2);
    });
  });

  group('Probe', () {
    test('an unavailable probe is never treated as a value', () {
      const probe = Probe.unavailable(note: 'nope');
      expect(probe.isAvailable, isFalse);
      expect(probe.value, isNull);
      expect(probe.kind, ProbeKind.unavailable);
    });

    test('a null-valued measured probe is still not available', () {
      // This is the priming state of a delta sampler: the kind is honest
      // but there is no number yet, and the chart must break rather than
      // plot a zero.
      const probe = Probe(null, ProbeKind.measured);
      expect(probe.isAvailable, isFalse);
    });

    test('serialises its provenance', () {
      const probe = Probe(42.0, ProbeKind.proxy,
          source: '/sys/x/cur_freq', note: 'clock ratio');
      expect(probe.toJson(), {
        'value': 42.0,
        'kind': 'proxy',
        'source': '/sys/x/cur_freq',
        'note': 'clock ratio',
      });
    });
  });

  group('ProcessCpuSampler', () {
    test('first sample only primes, it does not report', () {
      final sampler = ProcessCpuSampler(cores: 8);
      final first = sampler.sample();
      // On a host without /proc this is unavailable; on Linux it is a
      // measured probe with a null value. Neither may be plotted.
      expect(first.isAvailable, isFalse);
    });
  });

  group('LatencyStats', () {
    test('percentiles use nearest-rank, not interpolation', () {
      // Interpolating would invent a measurement that never happened, which
      // for n=5 on a phone is exactly the wrong call.
      final stats = LatencyStats([50, 10, 30, 20, 40]);
      expect(stats.min, 10);
      expect(stats.max, 50);
      expect(stats.median, 30);
      expect(stats.p90, 50);
      expect(stats.count, 5);
    });

    test('sorts the samples it was handed', () {
      final stats = LatencyStats([3, 1, 2]);
      expect(stats.samplesMs, [1, 2, 3]);
    });

    test('mean and stddev describe the spread', () {
      final stats = LatencyStats([10, 10, 10, 10]);
      expect(stats.mean, 10);
      expect(stats.stdDev, 0);

      final spread = LatencyStats([5, 15]);
      expect(spread.mean, 10);
      expect(spread.stdDev, 5);
    });

    test('throughput derives from the median, not the mean', () {
      // A long tail should not flatter the throughput figure.
      final stats = LatencyStats([100, 100, 100, 100, 5000]);
      expect(stats.median, 100);
      expect(stats.throughputPerSecond, closeTo(10.0, 1e-9));
    });

    test('an empty set degrades to zeros rather than throwing', () {
      final stats = LatencyStats([]);
      expect(stats.isEmpty, isTrue);
      expect(stats.median, 0);
      expect(stats.throughputPerSecond, 0);
    });

    test('serialises every field the report needs', () {
      final json = LatencyStats([10, 20, 30]).toJson();
      expect(json['count'], 3);
      expect(json['median_ms'], 20);
      expect(json.containsKey('p90_ms'), isTrue);
      expect(json.containsKey('stddev_ms'), isTrue);
    });
  });

  group('BackendResult', () {
    test('an unavailable backend is a reportable result, not an error', () {
      const result = BackendResult(
        backend: 'GPU',
        unavailableReason: 'interpreter refused to build',
      );
      expect(result.isAvailable, isFalse);
      expect(result.toJson()['unavailable'], contains('refused'));
    });
  });

  group('summarizeUsage', () {
    TelemetrySample sampleAt(
      int seconds, {
      Probe? cpu,
      Probe? gpu,
      Probe? npu,
    }) =>
        TelemetrySample(
          at: DateTime(2026, 1, 1).add(Duration(seconds: seconds)),
          cpu: cpu ?? const Probe(0, ProbeKind.measured),
          gpu: gpu ?? const Probe.unavailable(),
          npu: npu ?? const Probe.unavailable(),
          duty: const Probe(0, ProbeKind.derived),
          inferences: 0,
        );

    test('averages only the readings a lane actually reported', () {
      final samples = [
        sampleAt(0, gpu: const Probe(20, ProbeKind.measured)),
        sampleAt(1, gpu: const Probe.unavailable()),
        sampleAt(2, gpu: const Probe(40, ProbeKind.measured)),
      ];
      final usage = summarizeUsage(samples);

      // (20 + 40) / 2, not / 3 — the middle gap must not drag the average
      // toward zero, which is exactly the "flat line reads as idle" mistake
      // telemetry_sources.dart exists to avoid.
      expect(usage.averagePercent[ComputeLane.gpu], 30.0);
      expect(usage.sampleCount, 3);
    });

    test('a lane never available in the window averages to null, not zero',
        () {
      final samples = [sampleAt(0), sampleAt(1)];
      final usage = summarizeUsage(samples);

      expect(usage.averagePercent[ComputeLane.npu], isNull);
      expect(usage.kind[ComputeLane.npu], ProbeKind.unavailable);
    });

    test('an empty window degrades to nulls rather than throwing', () {
      final usage = summarizeUsage(const []);
      expect(usage.sampleCount, 0);
      for (final lane in ComputeLane.values) {
        expect(usage.averagePercent[lane], isNull);
      }
    });

    test('carries the thermal state through to JSON when known', () {
      const thermal =
          ThermalState(status: 1, label: 'light', throttling: false);
      final usage = summarizeUsage(
        [sampleAt(0, gpu: const Probe(10, ProbeKind.measured))],
        thermal: thermal,
      );
      expect(usage.toJson()['thermal'], thermal.toJson());
    });

    test('omits thermal from JSON when unknown', () {
      final usage = summarizeUsage(const [], thermal: ThermalState.unknown);
      expect(usage.toJson().containsKey('thermal'), isFalse);
    });
  });

  group('ComputeLane', () {
    test('every lane has a label and a description', () {
      for (final lane in ComputeLane.values) {
        expect(lane.label, isNotEmpty);
        expect(lane.description, isNotEmpty);
      }
    });
  });

  group('ComputeTelemetry lifecycle', () {
    test('a platform round-trip landing after dispose does not notify',
        () async {
      // start() kicks off _loadPlatformFacts(), which awaits two method
      // channel calls and then notifies. AppLifecycleListener disposal, a
      // hot restart, or simply backgrounding during a cold start can put
      // dispose() inside that window.
      final telemetry = ComputeTelemetry(
        meter: InferenceMeter(),
        // Long enough that no tick can fire; this is about the async load,
        // not the sampler.
        interval: const Duration(hours: 1),
      );
      telemetry.start();
      telemetry.dispose();

      // The assertion is the absence of an uncaught async error: notifying a
      // disposed ChangeNotifier throws inside the unawaited future that
      // start() left running, and package:test fails the test for it.
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    test('work done while the sampler was stopped is not dumped into the '
        'first window after it restarts', () async {
      // The lifecycle listener stops sampling in the background, but the
      // bridge keeps serving the desktop while the app is backgrounded —
      // that is the point of it. The meter counts that work with nobody
      // draining it.
      final meter = InferenceMeter();
      final telemetry = ComputeTelemetry(
        meter: meter,
        interval: const Duration(milliseconds: 20),
      );

      telemetry.start();
      telemetry.stop(); // onPause

      meter.record(30 * 1000 * 1000); // 30 s of bridge-driven inference

      telemetry.start(); // onResume
      await Future<void>.delayed(const Duration(milliseconds: 90));
      telemetry.dispose();

      expect(telemetry.history, isNotEmpty);
      final first = telemetry.history.first;
      // Before the fix this read 100 % duty (30 s of work divided by a 20 ms
      // window, clamped) with every background inference stamped onto one
      // sample — a spike that never happened, in the middle of a benchmark.
      expect(first.duty.value, lessThan(5.0));
      expect(first.inferences, 0);
    });
  });
}
