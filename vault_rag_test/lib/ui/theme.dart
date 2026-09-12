/// theme.dart
///
/// Design tokens for the co-processor UI.
///
/// The palette is the "Modern Dark / code dark + run green" system: a slate
/// background ramp with a single green accent reserved for *live* state
/// (link up, benchmark running, NPU engaged). Nothing decorative uses green,
/// so a glance at the screen answers "is it running?" without reading a word.
///
/// Deliberately NOT pure black: this ships to an OLED phone, where #000000
/// smears on scroll. #0B1220 is the floor.
///
/// Series colours for the telemetry chart are chosen for deuteranopia
/// separation (blue / amber / violet / green are distinguishable on all three
/// common CVD types), but the chart never relies on hue alone — every series
/// also carries its own stroke pattern. See [ComputeSeriesStyle].

library;

import 'package:flutter/material.dart';

abstract final class VaultColors {
  /// App background. One step above pure black, on purpose.
  static const background = Color(0xFF0B1220);

  /// Cards, panels, chart plot area.
  static const surface = Color(0xFF151E31);

  /// Raised elements inside a surface (chips, code blocks, inputs).
  static const surfaceHigh = Color(0xFF1E293B);

  static const border = Color(0xFF2C3A52);
  static const borderStrong = Color(0xFF475569);

  static const foreground = Color(0xFFF8FAFC);
  static const muted = Color(0xFF94A3B8);
  static const faint = Color(0xFF64748B);

  /// Reserved for live/active state only.
  static const accent = Color(0xFF22C55E);
  static const accentDim = Color(0xFF15803D);

  static const info = Color(0xFF38BDF8);
  static const warn = Color(0xFFF59E0B);
  static const danger = Color(0xFFEF4444);

  /// Telemetry series.
  static const cpu = Color(0xFF38BDF8); // sky
  static const gpu = Color(0xFFF59E0B); // amber
  static const npu = Color(0xFFA78BFA); // violet
  static const duty = Color(0xFF22C55E); // green
}

abstract final class VaultSpace {
  /// Density 8/10 — a dashboard scale, not a marketing-page scale.
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;

  static const radius = 12.0;
  static const radiusSm = 8.0;
}

abstract final class VaultText {
  /// Numbers that update in place (latency, %, MB) are tabular so digits
  /// don't jitter the layout as they change — the single most noticeable
  /// polish item on a live telemetry screen.
  static const mono = TextStyle(
    fontFamily: 'monospace',
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

ThemeData buildVaultTheme() {
  const scheme = ColorScheme.dark(
    primary: VaultColors.accent,
    onPrimary: Color(0xFF04140A),
    secondary: VaultColors.info,
    onSecondary: Color(0xFF04121A),
    surface: VaultColors.surface,
    onSurface: VaultColors.foreground,
    error: VaultColors.danger,
    onError: Colors.white,
    outline: VaultColors.border,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: VaultColors.background,
    dividerColor: VaultColors.border,
    appBarTheme: const AppBarTheme(
      backgroundColor: VaultColors.background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: VaultColors.foreground,
        fontSize: 18,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
    ),
    cardTheme: CardThemeData(
      color: VaultColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(VaultSpace.radius),
        side: const BorderSide(color: VaultColors.border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: VaultColors.surfaceHigh,
      hintStyle: const TextStyle(color: VaultColors.faint),
      labelStyle: const TextStyle(color: VaultColors.muted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(VaultSpace.radiusSm),
        borderSide: const BorderSide(color: VaultColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(VaultSpace.radiusSm),
        borderSide: const BorderSide(color: VaultColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(VaultSpace.radiusSm),
        borderSide: const BorderSide(color: VaultColors.accent, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: VaultSpace.md,
        vertical: VaultSpace.md,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        // 44dp floor: Touch & Interaction is priority 2 and this is the one
        // rule that a dense dashboard scale is most likely to violate.
        minimumSize: const Size(0, 46),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(VaultSpace.radiusSm),
        ),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 46),
        foregroundColor: VaultColors.foreground,
        side: const BorderSide(color: VaultColors.borderStrong),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(VaultSpace.radiusSm),
        ),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: VaultColors.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: VaultColors.accent.withValues(alpha: 0.16),
      height: 64,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: states.contains(WidgetState.selected)
              ? VaultColors.accent
              : VaultColors.muted,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 22,
          color: states.contains(WidgetState.selected)
              ? VaultColors.accent
              : VaultColors.muted,
        ),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: VaultColors.surfaceHigh,
      contentTextStyle: TextStyle(color: VaultColors.foreground),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
