import React from 'react';
import {AbsoluteFill, Easing, interpolate, useCurrentFrame} from 'remotion';
import {color, EXPO_OUT, font, space, type} from '../theme';

const expo = Easing.bezier(...(EXPO_OUT as unknown as [number, number, number, number]));

/** Clamped interpolate — the default extrapolation is almost never what we want. */
export const ramp = (
  frame: number,
  input: readonly [number, number],
  output: readonly [number, number],
  easing: (n: number) => number = expo,
) =>
  interpolate(frame, input as unknown as number[], output as unknown as number[], {
    easing,
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

/**
 * Enter/exit envelope for any element. Returns opacity plus a small upward
 * drift, so things arrive rather than blink. Motion carries meaning here:
 * everything enters from the direction it conceptually comes from.
 */
export const useReveal = (at: number, hold = Infinity, rise = 26) => {
  const frame = useCurrentFrame();
  const inOpacity = ramp(frame, [at, at + 16], [0, 1]);
  const outOpacity = hold === Infinity ? 1 : ramp(frame, [at + hold, at + hold + 14], [1, 0]);
  const y = ramp(frame, [at, at + 22], [rise, 0]);
  return {opacity: Math.min(inOpacity, outOpacity), transform: `translateY(${y}px)`};
};

/* ------------------------------------------------------------------ backdrop */

/**
 * Ambient background: two slow-drifting light blobs over a technical grid,
 * with a vignette to keep the centre readable. The blobs move on a long
 * sine so no two frames of the five minutes look quite the same.
 */
export const Backdrop: React.FC<{tint?: string; intensity?: number}> = ({
  tint = color.primary,
  intensity = 1,
}) => {
  const frame = useCurrentFrame();
  const drift = (phase: number, amp: number) => Math.sin((frame / 240) * Math.PI * 2 + phase) * amp;

  return (
    <AbsoluteFill style={{backgroundColor: color.bg}}>
      <AbsoluteFill
        style={{
          backgroundImage: `linear-gradient(${color.border} 1px, transparent 1px),
                            linear-gradient(90deg, ${color.border} 1px, transparent 1px)`,
          backgroundSize: '64px 64px',
          maskImage: 'radial-gradient(ellipse 80% 70% at 50% 45%, #000 40%, transparent 100%)',
          WebkitMaskImage:
            'radial-gradient(ellipse 80% 70% at 50% 45%, #000 40%, transparent 100%)',
          opacity: 0.7,
        }}
      />
      <div
        style={{
          position: 'absolute',
          width: 1100,
          height: 1100,
          left: 40 + drift(0, 90),
          top: -220 + drift(1.1, 60),
          borderRadius: '50%',
          background: `radial-gradient(circle, ${tint} 0%, transparent 62%)`,
          filter: 'blur(90px)',
          opacity: 0.5 * intensity,
        }}
      />
      <div
        style={{
          position: 'absolute',
          width: 900,
          height: 900,
          right: -160 + drift(2.4, 70),
          bottom: -240 + drift(3.3, 80),
          borderRadius: '50%',
          background: `radial-gradient(circle, ${color.secondary} 0%, transparent 60%)`,
          filter: 'blur(100px)',
          opacity: 0.42 * intensity,
        }}
      />
      <AbsoluteFill
        style={{
          background: `radial-gradient(ellipse 90% 80% at 50% 50%, transparent 45%, ${color.void} 100%)`,
        }}
      />
    </AbsoluteFill>
  );
};

/* -------------------------------------------------------------------- panels */

export const Panel: React.FC<{
  style?: React.CSSProperties;
  accent?: string;
  glow?: boolean;
  children?: React.ReactNode;
}> = ({style, accent, glow, children}) => (
  <div
    style={{
      background: 'rgba(16,25,46,0.72)',
      backdropFilter: 'blur(14px)',
      border: `1px solid ${accent ?? color.border}`,
      borderRadius: 18,
      padding: space(3),
      boxShadow: glow && accent ? `0 0 46px -8px ${accent}` : '0 18px 48px -24px rgba(0,0,0,0.8)',
      ...style,
    }}
  >
    {children}
  </div>
);

export const Chip: React.FC<{
  label: string;
  tone?: 'neutral' | 'good' | 'bad';
  style?: React.CSSProperties;
}> = ({label, tone = 'neutral', style}) => {
  const tint =
    tone === 'good' ? color.accent : tone === 'bad' ? color.danger : color.fgMuted;
  const bg =
    tone === 'good' ? color.accentDim : tone === 'bad' ? color.dangerDim : 'rgba(255,255,255,0.05)';
  return (
    <div
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 10,
        padding: '10px 18px',
        borderRadius: 999,
        background: bg,
        border: `1px solid ${tone === 'neutral' ? color.border : tint}`,
        color: tone === 'neutral' ? color.fgMuted : tint,
        fontFamily: font.family,
        ...type.label,
        ...style,
      }}
    >
      <span style={{width: 7, height: 7, borderRadius: 999, background: tint}} />
      {label}
    </div>
  );
};

/** Small monospaced tag used for stack names and file types. */
export const Mono: React.FC<{children: React.ReactNode; tone?: string}> = ({
  children,
  tone = color.fgMuted,
}) => (
  <span style={{fontFamily: font.mono, fontSize: 19, color: tone, letterSpacing: 0.2}}>
    {children}
  </span>
);

/* -------------------------------------------------------------------- meters */

export const Meter: React.FC<{
  label: string;
  value: number; // 0..1
  tone: string;
  sub?: string;
  width?: number;
}> = ({label, value, tone, sub, width = 340}) => (
  <div style={{width, fontFamily: font.family}}>
    <div style={{display: 'flex', justifyContent: 'space-between', alignItems: 'baseline'}}>
      <span style={{...type.label, color: color.fg}}>{label}</span>
      <span style={{...type.label, color: tone, fontVariantNumeric: 'tabular-nums'}}>
        {Math.round(value * 100)}%
      </span>
    </div>
    <div
      style={{
        marginTop: 10,
        height: 12,
        borderRadius: 999,
        background: 'rgba(255,255,255,0.07)',
        overflow: 'hidden',
        border: `1px solid ${color.border}`,
      }}
    >
      <div
        style={{
          width: `${value * 100}%`,
          height: '100%',
          background: tone,
          boxShadow: `0 0 22px ${tone}`,
          borderRadius: 999,
        }}
      />
    </div>
    {sub ? (
      <div style={{marginTop: 8, ...type.micro, color: color.fgFaint, textTransform: 'uppercase'}}>
        {sub}
      </div>
    ) : null}
  </div>
);

/* ------------------------------------------------------------------- devices */

export const Phone: React.FC<{
  glow?: string;
  label?: string;
  children?: React.ReactNode;
  style?: React.CSSProperties;
}> = ({glow = color.accent, label, children, style}) => (
  <div style={{display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 16, ...style}}>
    <div
      style={{
        width: 190,
        height: 380,
        borderRadius: 30,
        border: `2px solid ${glow}`,
        background: 'linear-gradient(160deg, rgba(30,58,95,0.55), rgba(11,17,32,0.9))',
        boxShadow: `0 0 60px -6px ${glow}`,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        position: 'relative',
        overflow: 'hidden',
      }}
    >
      <div
        style={{
          position: 'absolute',
          top: 12,
          left: '50%',
          transform: 'translateX(-50%)',
          width: 54,
          height: 6,
          borderRadius: 999,
          background: color.borderStrong,
        }}
      />
      {children}
    </div>
    {label ? (
      <div style={{...type.micro, color: glow, fontFamily: font.family, letterSpacing: 2.4}}>
        {label}
      </div>
    ) : null}
  </div>
);

export const Laptop: React.FC<{
  label?: string;
  tone?: string;
  children?: React.ReactNode;
  style?: React.CSSProperties;
}> = ({label, tone = color.fgMuted, children, style}) => (
  <div style={{display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 16, ...style}}>
    <div>
      <div
        style={{
          width: 400,
          height: 252,
          borderRadius: 14,
          border: `2px solid ${tone}`,
          background: 'linear-gradient(160deg, rgba(51,65,85,0.4), rgba(11,17,32,0.92))',
          boxShadow: `0 0 60px -14px ${tone}`,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          overflow: 'hidden',
        }}
      >
        {children}
      </div>
      <div
        style={{
          width: 470,
          height: 12,
          marginLeft: -35,
          borderRadius: '0 0 12px 12px',
          background: color.secondary,
        }}
      />
    </div>
    {label ? (
      <div style={{...type.micro, color: tone, fontFamily: font.family, letterSpacing: 2.4}}>
        {label}
      </div>
    ) : null}
  </div>
);

/** A document glyph. Used everywhere a file is in motion. */
export const Doc: React.FC<{tone?: string; size?: number; label?: string}> = ({
  tone = color.fgMuted,
  size = 44,
  label,
}) => (
  <div style={{display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6}}>
    <svg width={size} height={size * 1.28} viewBox="0 0 44 56" fill="none">
      <path
        d="M6 3h22l10 10v40a3 3 0 0 1-3 3H6a3 3 0 0 1-3-3V6a3 3 0 0 1 3-3Z"
        stroke={tone}
        strokeWidth={2.5}
        fill="rgba(255,255,255,0.04)"
      />
      <path d="M28 3v11h10" stroke={tone} strokeWidth={2.5} fill="none" />
      <path d="M11 26h22M11 34h22M11 42h14" stroke={tone} strokeWidth={2.5} strokeLinecap="round" />
    </svg>
    {label ? <Mono tone={tone}>{label}</Mono> : null}
  </div>
);

/* -------------------------------------------------- scene frame + captions */

/** Chapter eyebrow + scene title, top-left. Consistent anchor across scenes. */
export const SceneHeader: React.FC<{chapter: string; title: string; at?: number}> = ({
  chapter,
  title,
  at = 0,
}) => {
  const reveal = useReveal(at, Infinity, 18);
  return (
    <div style={{position: 'absolute', top: space(7), left: space(9), ...reveal}}>
      <div
        style={{
          ...type.chapter,
          color: color.accent,
          fontFamily: font.family,
          textTransform: 'uppercase',
        }}
      >
        {chapter}
      </div>
      <div style={{...type.title, color: color.fg, fontFamily: font.family, marginTop: 10}}>
        {title}
      </div>
    </div>
  );
};

/**
 * Caption band. Timed from the same data the voiceover is read from, so the
 * video is fully comprehensible muted — which is how most of it gets watched.
 */
export const Captions: React.FC<{lines: {t: number; d: number; text: string}[]; fps: number}> = ({
  lines,
  fps,
}) => {
  const frame = useCurrentFrame();
  const active = lines.find((l) => {
    const from = l.t * fps;
    return frame >= from && frame < from + l.d * fps;
  });
  if (!active) return null;

  const from = active.t * fps;
  const opacity = Math.min(
    ramp(frame, [from, from + 7], [0, 1], Easing.out(Easing.quad)),
    ramp(frame, [from + active.d * fps - 8, from + active.d * fps], [1, 0], Easing.in(Easing.quad)),
  );

  return (
    <div
      style={{
        position: 'absolute',
        left: 0,
        right: 0,
        bottom: space(8),
        display: 'flex',
        justifyContent: 'center',
        opacity,
      }}
    >
      <div
        style={{
          maxWidth: 1360,
          textAlign: 'center',
          padding: '18px 34px',
          borderRadius: 16,
          background: 'rgba(11,17,32,0.72)',
          backdropFilter: 'blur(10px)',
          border: `1px solid ${color.border}`,
          fontFamily: font.family,
          ...type.body,
          fontSize: 30,
          color: color.fg,
          textWrap: 'balance',
        }}
      >
        {active.text}
      </div>
    </div>
  );
};
