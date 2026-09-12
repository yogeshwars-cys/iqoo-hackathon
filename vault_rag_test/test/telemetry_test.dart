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
import 'package:vault_rag_test/telemetry/telemetry_sources.dart';

void main() {
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

  group('ComputeLane', () {
    test('every lane has a label and a description', () {
      for (final lane in ComputeLane.values) {
        expect(lane.label, isNotEmpty);
        expect(lane.description, isNotEmpty);
      }
    });
  });
}
