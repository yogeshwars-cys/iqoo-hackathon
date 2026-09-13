/// common.dart
///
/// Shared building blocks: panels, metric tiles, status pills, notices.
///
/// Style follows Now in Android's design system (see theme.dart): tonal
/// filled surfaces instead of outlined boxes, sentence-case titles in the
/// type scale instead of tiny all-caps labels, and tonal "tag" chips for
/// state. Nothing here uses text smaller than 12 sp except `labelSmall`
/// (11 sp) on the navigation-independent unit suffix.
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
/// a count chip goes; [leading] is an optional icon shown in a tonal badge.
class SectionCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final IconData? icon;
  final Widget child;
  final EdgeInsets padding;

  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
    this.icon,
    this.padding = const EdgeInsets.all(VaultSpace.lg),
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  IconBadge(icon: icon!),
                  const SizedBox(width: VaultSpace.md),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(title, style: text.titleMedium),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: text.bodyMedium!
                              .copyWith(color: VaultColors.muted),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: VaultSpace.sm),
                  trailing!,
                ],
              ],
            ),
            const SizedBox(height: VaultSpace.lg),
            child,
          ],
        ),
      ),
    );
  }
}

/// A 40 dp tonal circle holding an icon — NiA's topic-icon treatment.
class IconBadge extends StatelessWidget {
  final IconData icon;
  final Color? color;
  final Color? background;
  final double size;

  const IconBadge({
    super.key,
    required this.icon,
    this.color,
    this.background,
    this.size = 40,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background ?? VaultColors.accentDim,
        borderRadius: BorderRadius.circular(VaultSpace.radiusMd),
      ),
      alignment: Alignment.center,
      child: ExcludeSemantics(
        child: Icon(icon, size: size * 0.55, color: color ?? VaultColors.onAccentDim),
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
    final text = Theme.of(context).textTheme;
    final valueColor =
        unavailable ? VaultColors.faint : (accent ?? VaultColors.foreground);

    return Semantics(
      label: '$label: $value${unit == null ? '' : ' $unit'}'
          '${footnote == null ? '' : '. $footnote'}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
            VaultSpace.md, VaultSpace.md, VaultSpace.md, VaultSpace.md),
        decoration: BoxDecoration(
          color: VaultColors.surfaceHigh,
          borderRadius: BorderRadius.circular(VaultSpace.radiusMd),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.labelMedium!.copyWith(color: VaultColors.muted),
            ),
            const SizedBox(height: VaultSpace.sm),
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
                      fontSize: 22,
                      height: 1.0,
                    ),
                  ),
                ),
                if (unit != null) ...[
                  const SizedBox(width: VaultSpace.xs),
                  Text(
                    unit!,
                    style: text.labelMedium!.copyWith(color: VaultColors.faint),
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
                style: text.bodySmall!.copyWith(color: VaultColors.faint),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Status dot + text on a tonal container. The dot never carries the meaning
/// alone — the label beside it always spells the state out.
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
    final text = Theme.of(context).textTheme;
    return Container(
      constraints: const BoxConstraints(minHeight: 32),
      padding: const EdgeInsets.symmetric(horizontal: VaultSpace.md),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
            color.withValues(alpha: 0.16), VaultColors.surfaceHigh),
        borderRadius: BorderRadius.circular(VaultSpace.radiusSm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Dot(color: color, pulsing: pulsing),
          const SizedBox(width: VaultSpace.sm),
          Text(
            label,
            style: text.labelLarge!.copyWith(color: _readable(color)),
          ),
        ],
      ),
    );
  }
}

/// Keeps pill text legible when a caller passes a dark semantic colour.
Color _readable(Color c) =>
    c.computeLuminance() < 0.25 ? VaultColors.foreground : c;

/// Small tonal tag, NiA's `NiaTopicTag`: [selected] uses primaryContainer.
class VaultTag extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color? color;
  final bool selected;

  const VaultTag(
    this.label, {
    super.key,
    this.icon,
    this.color,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final fg = color ?? (selected ? VaultColors.onAccentDim : VaultColors.muted);
    final bg = color != null
        ? Color.alphaBlend(color!.withValues(alpha: 0.16), VaultColors.surfaceHigh)
        : (selected ? VaultColors.accentDim : VaultColors.surfaceHighest);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: VaultSpace.sm, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(VaultSpace.radiusSm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: VaultSpace.xs),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.labelMedium!.copyWith(color: fg),
            ),
          ),
        ],
      ),
    );
  }
}

enum NoticeTone { info, warn, danger, success, neutral }

/// Inline banner for explanations and warnings: tonal container, leading
/// icon, optional title. Replaces ad-hoc bordered boxes on every page.
class Notice extends StatelessWidget {
  final String? title;
  final String message;
  final NoticeTone tone;
  final IconData? icon;
  final Widget? action;

  const Notice({
    super.key,
    this.title,
    required this.message,
    this.tone = NoticeTone.info,
    this.icon,
    this.action,
  });

  static (Color fg, Color bg, IconData icon) _style(NoticeTone t) => switch (t) {
        NoticeTone.info => (
            VaultColors.info,
            VaultColors.infoContainer.withValues(alpha: 0.55),
            Icons.info_outline_rounded
          ),
        NoticeTone.warn => (
            VaultColors.warn,
            VaultColors.warnContainer.withValues(alpha: 0.7),
            Icons.warning_amber_rounded
          ),
        NoticeTone.danger => (
            VaultColors.danger,
            VaultColors.dangerContainer.withValues(alpha: 0.45),
            Icons.error_outline_rounded
          ),
        NoticeTone.success => (
            VaultColors.accent,
            VaultColors.accentDim.withValues(alpha: 0.6),
            Icons.verified_outlined
          ),
        NoticeTone.neutral => (
            VaultColors.muted,
            VaultColors.surfaceHigh,
            Icons.info_outline_rounded
          ),
      };

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final (fg, bg, defaultIcon) = _style(tone);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(VaultSpace.md),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(VaultSpace.radiusMd),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon ?? defaultIcon, size: 20, color: fg),
          ),
          const SizedBox(width: VaultSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null) ...[
                  Text(title!, style: text.titleSmall!.copyWith(color: fg)),
                  const SizedBox(height: 2),
                ],
                Text(
                  message,
                  style: text.bodyMedium!.copyWith(color: VaultColors.foreground),
                ),
                if (action != null) ...[
                  const SizedBox(height: VaultSpace.sm),
                  action!,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A label / value line for key facts (backend, key level, digest...).
class InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool mono;
  final Color? valueColor;

  const InfoRow(this.label, this.value,
      {super.key, this.mono = false, this.valueColor});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final valueStyle = mono
        ? VaultText.mono.copyWith(fontSize: 13, height: 20 / 13)
        : text.bodyMedium!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 116,
            child: Text(label,
                style: text.bodyMedium!.copyWith(color: VaultColors.muted)),
          ),
          const SizedBox(width: VaultSpace.md),
          Expanded(
            child: Text(
              value,
              style: valueStyle.copyWith(color: valueColor ?? VaultColors.foreground),
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
    _sync();
  }

  void _sync() {
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
    if (old.pulsing != widget.pulsing) _sync();
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
        color: VaultColors.surfaceHigh,
        borderRadius: BorderRadius.circular(VaultSpace.radiusMd),
      ),
      child: Text(
        text,
        maxLines: maxLines,
        overflow: maxLines == null ? null : TextOverflow.ellipsis,
        style: VaultText.mono.copyWith(
          color: VaultColors.muted,
          fontSize: 12.5,
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
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
          vertical: VaultSpace.xl, horizontal: VaultSpace.lg),
      child: Column(
        children: [
          IconBadge(
            icon: icon,
            size: 56,
            background: VaultColors.surfaceHigh,
            color: VaultColors.muted,
          ),
          const SizedBox(height: VaultSpace.lg),
          Text(title, textAlign: TextAlign.center, style: text.titleSmall),
          const SizedBox(height: VaultSpace.xs),
          Text(
            message,
            textAlign: TextAlign.center,
            style: text.bodyMedium!.copyWith(color: VaultColors.muted),
          ),
        ],
      ),
    );
  }
}
