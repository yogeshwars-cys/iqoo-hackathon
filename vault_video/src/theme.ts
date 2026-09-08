/**
 * Design tokens.
 *
 * Style: "Modern Dark (Cinema Mobile)" — dark-primary, cinematic, ambient
 * light, glassmorphism. Two semantic accents carry the whole argument:
 * GREEN means on-device / private / verifiable, RED means it left the device.
 * Nothing else in the palette is allowed to be saturated, so those two
 * colours always read as meaning rather than decoration.
 */

export const FPS = 30;
export const SCENE_SECONDS = 60;
export const SCENE_FRAMES = FPS * SCENE_SECONDS;
export const WIDTH = 1920;
export const HEIGHT = 1080;

export const color = {
  /** Deepest ground. Deliberately not #000 — pure black smears on OLED. */
  void: '#0B1120',
  bg: '#0F172A',
  panel: '#10192E',
  primary: '#1E3A5F',
  secondary: '#334155',

  /** On-device, private, safe. */
  accent: '#22C55E',
  accentDim: 'rgba(34,197,94,0.16)',
  accentGlow: 'rgba(34,197,94,0.42)',

  /** Left the device, exposed, hot. */
  danger: '#DC2626',
  dangerDim: 'rgba(220,38,38,0.16)',
  dangerGlow: 'rgba(220,38,38,0.40)',

  fg: '#FFFFFF',
  /** 4.6:1 on --bg, so body text stays WCAG AA. */
  fgMuted: '#94A3B8',
  fgFaint: '#64748B',
  border: 'rgba(255,255,255,0.08)',
  borderStrong: 'rgba(255,255,255,0.16)',
} as const;

export const font = {
  family:
    'Inter, ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif',
  mono: '"JetBrains Mono", ui-monospace, "SF Mono", Menlo, Consolas, monospace',
} as const;

/** Expo-out. The house easing: fast commit, long settle. */
export const EXPO_OUT = [0.16, 1, 0.3, 1] as const;

export const space = (n: number) => n * 8;

export const type = {
  chapter: {fontSize: 22, fontWeight: 600, letterSpacing: 6},
  display: {fontSize: 92, fontWeight: 700, letterSpacing: -2.5, lineHeight: 1.04},
  title: {fontSize: 60, fontWeight: 600, letterSpacing: -1.4, lineHeight: 1.1},
  heading: {fontSize: 34, fontWeight: 600, letterSpacing: -0.4},
  body: {fontSize: 25, fontWeight: 400, lineHeight: 1.5},
  label: {fontSize: 19, fontWeight: 500, letterSpacing: 0.3},
  micro: {fontSize: 15, fontWeight: 500, letterSpacing: 1.6},
} as const;
