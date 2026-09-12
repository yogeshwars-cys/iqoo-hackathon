/// common.dart
///
/// Small shared pieces: panels, metric tiles, the link status dot.
///
/// The metric tile is the load-bearing one. Every number the telemetry chart
/// draws is also printed as text in a tile, which is what makes the chart
/// optional rather than essential — a screen reader, a monochrome
/// screenshot, or a glance too short to parse four overlapping lines all
/// still get the reading.

library;

import 'package:flutter/material.dart';

import '../theme.dart';

/// A titled panel. The optional [trailing] slot is where a pause control or
/// a count chip goes.
class SectionCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets padding;

  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
    this.padding = const EdgeInsets.all(VaultSpace.lg),
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title.toUpperCase(),
                        style: const TextStyle(
                          color: VaultColors.muted,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.9,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: VaultSpace.xs),
                        Text(
                          subtitle!,
                          style: const TextStyle(
                            color: VaultColors.faint,
                            fontSize: 12,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: VaultSpace.md),
            child,
          ],
        ),
      ),
    );
  }
}

/// A single number with its label and unit.
///
/// [accent] tints the value only — never the label — so colour carries
/// emphasis without becoming the only way to read the tile.
class MetricTile extends StatelessWidget {
  final String label;
  final String value;
  final String? unit;
  final Color? accent;
  final String? footnote;

  /// Renders the tile as inactive. Used for a lane the device does not
  /// report: greyed and dashed rather than showing a confident "0".
  final bool unavailable;

  const MetricTile({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    this.accent,
    this.footnote,
    this.unavailable = false,
  });

  @override
  Widget build(BuildContext context) {
    final valueColor = unavailable
        ? VaultColors.faint
        : (accent ?? VaultColors.foreground);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: VaultSpace.md,
        vertical: VaultSpace.md,
      ),
      decoration: BoxDecoration(
        color: VaultColors.surfaceHigh,
        borderRadius: BorderRadius.circular(VaultSpace.radiusSm),
        border: Border.all(
          color: unavailable
              ? VaultColors.border
              : (accent ?? VaultColors.border).withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: VaultColors.muted,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.7,
            ),
          ),
          const SizedBox(height: VaultSpace.xs + 2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: VaultText.mono.copyWith(
                    color: valueColor,
                    fontSize: 21,
                    fontWeight: FontWeight.w600,
                    height: 1.0,
                  ),
                ),
              ),
              if (unit != null) ...[
                const SizedBox(width: 3),
                Text(
                  unit!,
                  style: const TextStyle(
                    color: VaultColors.faint,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
          if (footnote != null) ...[
            const SizedBox(height: VaultSpace.xs),
            Text(
              footnote!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: VaultColors.faint,
                fontSize: 10,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Status dot + text. The dot never carries the meaning alone — the label
/// beside it always spells the state out.
class StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  final bool pulsing;

  const StatusPill({
    super.key,
    required this.label,
    required this.color,
    this.pulsing = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Dot(color: color, pulsing: pulsing),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _Dot extends StatefulWidget {
  final Color color;
  final bool pulsing;

  const _Dot({required this.color, required this.pulsing});

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Honour the OS reduced-motion setting. A pulsing dot is decorative —
    // the pill's text already says "LINKED" — so it simply stops.
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.pulsing && !reduceMotion) {
      if (!_controller.isAnimating) _controller.repeat(reverse: true);
    } else {
      _controller.stop();
      _controller.value = 1;
    }
  }

  @override
  void didUpdateWidget(_Dot old) {
    super.didUpdateWidget(old);
    if (old.pulsing != widget.pulsing) didChangeDependencies();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = 0.45 + 0.55 * _controller.value;
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: t),
            shape: BoxShape.circle,
            boxShadow: widget.pulsing
                ? [
                    BoxShadow(
                      color: widget.color.withValues(alpha: 0.5 * t),
                      blurRadius: 6,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
        );
      },
    );
  }
}

/// Monospaced block for chunk previews and JSON.
class CodeBlock extends StatelessWidget {
  final String text;
  final int? maxLines;

  const CodeBlock(this.text, {super.key, this.maxLines});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(VaultSpace.md),
      decoration: BoxDecoration(
        color: VaultColors.background,
        borderRadius: BorderRadius.circular(VaultSpace.radiusSm),
        border: Border.all(color: VaultColors.border),
      ),
      child: Text(
        text,
        maxLines: maxLines,
        overflow: maxLines == null ? null : TextOverflow.ellipsis,
        style: VaultText.mono.copyWith(
          color: VaultColors.muted,
          fontSize: 11.5,
          height: 1.5,
        ),
      ),
    );
  }
}

/// Empty-state placeholder. Always says what to do next, never just what is
/// missing.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: VaultSpace.xl),
      child: Column(
        children: [
          Icon(icon, size: 30, color: VaultColors.faint),
          const SizedBox(height: VaultSpace.md),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: VaultColors.muted,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: VaultSpace.xs),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: VaultColors.faint,
              fontSize: 12,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
