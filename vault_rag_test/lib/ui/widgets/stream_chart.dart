/// stream_chart.dart
///
/// The streaming utilisation chart: four lanes, 0–100 %, oldest sample on
/// the left.
///
/// Hand-drawn with [CustomPaint] rather than a charting package. Three
/// reasons, in order of weight:
///
///  1. This repaints every second for as long as the screen is open. A
///     general-purpose chart library rebuilds a widget tree per frame to do
///     that; a painter touches the canvas and nothing else. On a mid-range
///     phone that is the difference between a smooth chart and a chart that
///     costs frames while the model is trying to run — which would corrupt
///     the very measurement being displayed.
///  2. Gaps. A lane the device refuses to report must render as a *break*,
///     not as zero. Most chart libraries treat a missing point as either
///     zero or an interpolated line through it; both are lies here, and the
///     whole point of the NPU lane is to be honest about not knowing.
///  3. No dependency, which matters in a project whose build notes are
///     mostly about dependency resolution going wrong.
///
/// ACCESSIBILITY: series are distinguished by stroke pattern as well as
/// colour — solid, dashed, dotted, dash-dot — so the chart survives every
/// common form of colour-vision deficiency and monochrome screenshots. The
/// chart is decorative-redundant: every value it draws is also printed as
/// text in the tiles above it, which is the actual accessible path.

library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../telemetry/compute_telemetry.dart';
import '../../telemetry/telemetry_sources.dart';
import '../theme.dart';

/// Stroke identity for one lane: colour plus a dash pattern in logical
/// pixels ([] means solid).
class ComputeSeriesStyle {
  final Color color;
  final List<double> dash;
  final bool fill;

  const ComputeSeriesStyle(this.color, this.dash, {this.fill = false});

  static const cpu = ComputeSeriesStyle(VaultColors.cpu, [], fill: true);
  static const gpu = ComputeSeriesStyle(VaultColors.gpu, [7, 4]);
  static const npu = ComputeSeriesStyle(VaultColors.npu, [2, 4]);
  static const duty = ComputeSeriesStyle(VaultColors.duty, [10, 3, 2, 3]);

  static ComputeSeriesStyle of(ComputeLane lane) => switch (lane) {
        ComputeLane.cpu => cpu,
        ComputeLane.gpu => gpu,
        ComputeLane.npu => npu,
        ComputeLane.duty => duty,
      };
}

class ChartSeries {
  final ComputeLane lane;

  /// Oldest first. Null entries are gaps and are never drawn through.
  final List<double?> values;
  final ProbeKind kind;
  final bool visible;

  const ChartSeries({
    required this.lane,
    required this.values,
    required this.kind,
    this.visible = true,
  });
}

class StreamChart extends StatelessWidget {
  final List<ChartSeries> series;

  /// Sample count the x-axis is scaled to, so the line grows in from the
  /// right on a fresh start instead of stretching two points across the
  /// whole width.
  final int windowSize;

  final Duration sampleInterval;
  final double height;

  const StreamChart({
    super.key,
    required this.series,
    required this.windowSize,
    required this.sampleInterval,
    this.height = 208,
  });

  @override
  Widget build(BuildContext context) {
    final seconds = windowSize * sampleInterval.inMilliseconds / 1000;
    return Semantics(
      label: 'Compute utilisation over the last ${seconds.round()} seconds. '
          'Current values are listed as text above this chart.',
      // The chart itself carries no information the tiles do not; excluding
      // its children keeps a screen reader from crawling painted noise.
      excludeSemantics: true,
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: _StreamChartPainter(
            series: series,
            windowSize: windowSize,
            windowSeconds: seconds,
          ),
        ),
      ),
    );
  }
}

class _StreamChartPainter extends CustomPainter {
  final List<ChartSeries> series;
  final int windowSize;
  final double windowSeconds;

  _StreamChartPainter({
    required this.series,
    required this.windowSize,
    required this.windowSeconds,
  });

  static const _gutter = 34.0; // room for the y-axis labels
  static const _padTop = 10.0;
  static const _padBottom = 18.0;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(
      _gutter,
      _padTop,
      size.width,
      size.height - _padBottom,
    );
    if (plot.width <= 1 || plot.height <= 1) return;

    _paintFrame(canvas, plot);
    for (final s in series) {
      if (!s.visible) continue;
      if (s.kind == ProbeKind.unavailable) continue;
      _paintSeries(canvas, plot, s);
    }
    _paintXAxis(canvas, plot, size);
  }

  double _yFor(Rect plot, double percent) =>
      plot.bottom - (percent.clamp(0, 100) / 100) * plot.height;

  double _xFor(Rect plot, int index) {
    if (windowSize <= 1) return plot.left;
    return plot.left + (index / (windowSize - 1)) * plot.width;
  }

  void _paintFrame(Canvas canvas, Rect plot) {
    final grid = Paint()
      ..color = VaultColors.border.withValues(alpha: 0.55)
      ..strokeWidth = 1;

    for (final percent in const [0.0, 25.0, 50.0, 75.0, 100.0]) {
      final y = _yFor(plot, percent);
      // 0 and 100 are the axis itself and read as solid; the interior lines
      // are dashed so they never compete with a data series.
      if (percent == 0 || percent == 100) {
        canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      } else {
        _drawDashedLine(
          canvas,
          Offset(plot.left, y),
          Offset(plot.right, y),
          const [2, 5],
          Paint()
            ..color = VaultColors.border.withValues(alpha: 0.35)
            ..strokeWidth = 1,
        );
      }

      if (percent == 25 || percent == 75) continue; // too dense to label
      _label(
        canvas,
        '${percent.round()}',
        Offset(_gutter - 6, y),
        align: _LabelAlign.right,
      );
    }
  }

  void _paintXAxis(Canvas canvas, Rect plot, Size size) {
    _label(
      canvas,
      '−${windowSeconds.round()}s',
      Offset(plot.left, size.height - _padBottom + 4),
      align: _LabelAlign.left,
    );
    _label(
      canvas,
      'now',
      Offset(plot.right, size.height - _padBottom + 4),
      align: _LabelAlign.right,
    );
  }

  void _paintSeries(Canvas canvas, Rect plot, ChartSeries s) {
    final style = ComputeSeriesStyle.of(s.lane);
    // Right-align the data: the newest sample sits at the right edge and the
    // history trails off to the left, which is what "now" means on a live
    // chart. A half-full buffer therefore grows in from the right.
    final offset = windowSize - s.values.length;

    // Split into runs of consecutive non-null samples. Each run is drawn
    // independently, so a gap is a visible break rather than a line through
    // data that does not exist.
    final runs = <List<Offset>>[];
    var current = <Offset>[];
    for (var i = 0; i < s.values.length; i++) {
      final v = s.values[i];
      if (v == null) {
        if (current.length > 1) runs.add(current);
        current = <Offset>[];
        continue;
      }
      current.add(Offset(_xFor(plot, offset + i), _yFor(plot, v)));
    }
    if (current.isNotEmpty) runs.add(current);
    if (runs.isEmpty) return;

    // A proxy measurement is drawn at reduced opacity — the chart should
    // look less certain where the number is less certain.
    final alpha = s.kind == ProbeKind.proxy ? 0.55 : 1.0;

    for (final run in runs) {
      if (style.fill && run.length > 1) {
        final fillPath = Path()..moveTo(run.first.dx, plot.bottom);
        for (final p in run) {
          fillPath.lineTo(p.dx, p.dy);
        }
        fillPath
          ..lineTo(run.last.dx, plot.bottom)
          ..close();
        canvas.drawPath(
          fillPath,
          Paint()
            ..shader = ui.Gradient.linear(
              Offset(0, plot.top),
              Offset(0, plot.bottom),
              [
                style.color.withValues(alpha: 0.26 * alpha),
                style.color.withValues(alpha: 0.01),
              ],
            ),
        );
      }

      final stroke = Paint()
        ..color = style.color.withValues(alpha: alpha)
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;

      if (run.length == 1) {
        canvas.drawCircle(run.first, 2, stroke..style = PaintingStyle.fill);
        continue;
      }

      if (style.dash.isEmpty) {
        final path = Path()..moveTo(run.first.dx, run.first.dy);
        for (final p in run.skip(1)) {
          path.lineTo(p.dx, p.dy);
        }
        canvas.drawPath(path, stroke);
      } else {
        _drawDashedPolyline(canvas, run, style.dash, stroke);
      }
    }

    // Head marker on the newest point, so the current value is findable at
    // a glance even when four lanes overlap.
    final head = runs.last.last;
    if ((head.dx - plot.right).abs() < 2) {
      canvas
        ..drawCircle(head, 4.5,
            Paint()..color = VaultColors.background.withValues(alpha: 0.9))
        ..drawCircle(head, 3, Paint()..color = style.color.withValues(alpha: alpha));
    }
  }

  // ---- dash helpers -------------------------------------------------------
  //
  // Flutter has no dashed-stroke paint, and PathMetric-based dashing
  // allocates a new Path per frame. Walking the points and emitting line
  // segments directly allocates nothing per frame, which matters for a
  // painter that runs at 1 Hz forever with four series on it.

  void _drawDashedPolyline(
    Canvas canvas,
    List<Offset> points,
    List<double> pattern,
    Paint paint,
  ) {
    var patternIndex = 0;
    var remaining = pattern[0];
    var drawing = true;

    for (var i = 0; i < points.length - 1; i++) {
      var from = points[i];
      final to = points[i + 1];
      var segmentLength = (to - from).distance;

      while (segmentLength > 0) {
        final step = math.min(remaining, segmentLength);
        final t = step / segmentLength;
        final next = Offset(
          from.dx + (to.dx - from.dx) * t,
          from.dy + (to.dy - from.dy) * t,
        );
        if (drawing) canvas.drawLine(from, next, paint);

        from = next;
        segmentLength -= step;
        remaining -= step;
        if (remaining <= 0.0001) {
          patternIndex = (patternIndex + 1) % pattern.length;
          remaining = pattern[patternIndex];
          drawing = !drawing;
        }
      }
    }
  }

  void _drawDashedLine(
    Canvas canvas,
    Offset a,
    Offset b,
    List<double> pattern,
    Paint paint,
  ) =>
      _drawDashedPolyline(canvas, [a, b], pattern, paint);

  void _label(
    Canvas canvas,
    String text,
    Offset at, {
    required _LabelAlign align,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: VaultColors.faint,
          fontSize: 10,
          fontFeatures: [ui.FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final dx = switch (align) {
      _LabelAlign.left => at.dx,
      _LabelAlign.right => at.dx - painter.width,
    };
    painter.paint(canvas, Offset(dx, at.dy - painter.height / 2));
  }

  @override
  bool shouldRepaint(_StreamChartPainter old) =>
      old.series != series || old.windowSize != windowSize;
}

enum _LabelAlign { left, right }
