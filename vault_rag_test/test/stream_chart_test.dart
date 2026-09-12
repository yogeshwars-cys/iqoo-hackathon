/// Painter tests for the streaming utilisation chart.
///
/// The chart's stated contract (see stream_chart.dart) is that it never
/// draws through a gap and never invents a value — but the other half of
/// that contract matters just as much: it must not silently *lose* a
/// reading either. A lane that drops samples looks identical to a lane the
/// device refuses to report, and the two mean opposite things.
///
/// CustomPainter is testable without a golden file: paint() takes a Canvas,
/// and a Canvas that records what it was asked to draw is enough to assert
/// "this measurement reached the screen".

library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_rag_test/telemetry/compute_telemetry.dart';
import 'package:vault_rag_test/telemetry/telemetry_sources.dart';
import 'package:vault_rag_test/ui/widgets/stream_chart.dart';

/// Records which Canvas methods the painter called.
///
/// `implements Canvas` with a noSuchMethod sink rather than a hand-written
/// stub: Canvas has several dozen methods and this test only cares about
/// three of them.
class _RecordingCanvas implements Canvas {
  final _calls = <String>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    _calls.add(invocation.memberName.toString());
    return null;
  }

  int callsTo(String method) =>
      _calls.where((c) => c.contains(method)).length;
}

/// Builds the chart, then drives its painter directly.
Future<_RecordingCanvas> _paintSeries(
  WidgetTester tester,
  List<ChartSeries> series, {
  required int windowSize,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: StreamChart(
          series: series,
          windowSize: windowSize,
          sampleInterval: const Duration(seconds: 1),
        ),
      ),
    ),
  );

  final paint = tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .firstWhere((w) => w.painter != null);

  final canvas = _RecordingCanvas();
  paint.painter!.paint(canvas, const Size(420, 208));
  return canvas;
}

void main() {
  group('StreamChart gaps', () {
    testWidgets('a lone reading between two gaps is still drawn',
        (tester) async {
      // The realistic case: a ROM where the KGSL busy counter is readable
      // only intermittently. Every successful read is an island, so if
      // single-sample runs are discarded the GPU lane draws nothing while
      // the tile above it prints a number.
      final canvas = await _paintSeries(
        tester,
        const [
          ChartSeries(
            lane: ComputeLane.gpu,
            values: [null, 42.0, null],
            kind: ProbeKind.measured,
          ),
        ],
        windowSize: 3,
      );

      // A run of one cannot be stroked, so the painter marks it with a dot.
      expect(canvas.callsTo('drawCircle'), 1);
    });

    testWidgets('a gap still breaks the line rather than being drawn through',
        (tester) async {
      // The other half of the contract, so the fix above cannot be
      // "achieved" by joining the runs back together.
      final joined = await _paintSeries(
        tester,
        const [
          ChartSeries(
            lane: ComputeLane.gpu,
            values: [10.0, 20.0, 30.0, 40.0],
            kind: ProbeKind.measured,
          ),
        ],
        windowSize: 4,
      );
      final broken = await _paintSeries(
        tester,
        const [
          ChartSeries(
            lane: ComputeLane.gpu,
            values: [10.0, 20.0, null, 30.0, 40.0],
            kind: ProbeKind.measured,
          ),
        ],
        windowSize: 5,
      );

      // The GPU lane is dashed, so both are drawn as many short drawLine
      // calls. Breaking the series into two runs cannot produce more ink
      // than drawing it as one continuous line over the same span.
      expect(broken.callsTo('drawLine'), lessThan(joined.callsTo('drawLine')));
    });

    testWidgets('a lane with no readings at all draws no data', (tester) async {
      final canvas = await _paintSeries(
        tester,
        const [
          ChartSeries(
            lane: ComputeLane.npu,
            values: [null, null, null],
            kind: ProbeKind.measured,
          ),
        ],
        windowSize: 3,
      );

      // Grid lines are drawLine calls too, so the tell is the absence of any
      // point marker: an all-gap lane must not acquire one.
      expect(canvas.callsTo('drawCircle'), 0);
      expect(canvas.callsTo('drawPath'), 0);
    });

    testWidgets('an unavailable lane is skipped entirely', (tester) async {
      // Values present but the probe kind says the device would not tell us:
      // the lane must not be plotted regardless of what is in the list.
      final canvas = await _paintSeries(
        tester,
        const [
          ChartSeries(
            lane: ComputeLane.npu,
            values: [10.0, 20.0, 30.0],
            kind: ProbeKind.unavailable,
          ),
        ],
        windowSize: 3,
      );

      expect(canvas.callsTo('drawCircle'), 0);
      expect(canvas.callsTo('drawPath'), 0);
    });
  });
}
