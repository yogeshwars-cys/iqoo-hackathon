import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {
  Backdrop,
  Laptop,
  Mono,
  Panel,
  Phone,
  ramp,
  SceneHeader,
  useReveal,
} from '../components/ui';
import {color, font, space, type} from '../theme';

/**
 * Scene 4 — What Is New.
 *
 * Four claims, each given its own beat and its own supporting visual. The
 * claims are numbered on screen because the narration numbers them: if a
 * viewer hears "third", they should be able to find it without hunting.
 */

const S = 30;

const Claim: React.FC<{
  n: string;
  at: number;
  hold: number;
  title: string;
  body: string;
  children?: React.ReactNode;
}> = ({n, at, hold, title, body, children}) => {
  const reveal = useReveal(at * S, hold * S);
  return (
    <AbsoluteFill
      style={{alignItems: 'center', justifyContent: 'center', ...reveal, paddingBottom: 100}}
    >
      <div style={{display: 'flex', alignItems: 'center', gap: space(9), maxWidth: 1500}}>
        <div style={{width: 620}}>
          <div
            style={{
              ...type.display,
              fontSize: 120,
              color: color.accentDim,
              fontFamily: font.family,
              lineHeight: 1,
            }}
          >
            {n}
          </div>
          <div
            style={{
              ...type.title,
              fontSize: 52,
              color: color.fg,
              fontFamily: font.family,
              marginTop: -10,
            }}
          >
            {title}
          </div>
          <div
            style={{
              ...type.body,
              color: color.fgMuted,
              fontFamily: font.family,
              marginTop: space(2),
            }}
          >
            {body}
          </div>
        </div>
        <div style={{width: 640, display: 'flex', justifyContent: 'center'}}>{children}</div>
      </div>
    </AbsoluteFill>
  );
};

export const Scene4Novelty: React.FC = () => {
  const frame = useCurrentFrame();
  const shrink = ramp(frame, [32.4 * S, 37 * S], [1, 0.02]);

  return (
    <AbsoluteFill>
      <Backdrop tint={color.accent} intensity={0.5} />
      <SceneHeader chapter="FOUR" title="What Is New" />

      {/* ------------------------------------------------ 01 direction of trust */}
      <Claim
        n="01"
        at={3.3}
        hold={12.2}
        title="The direction of trust"
        body="Normally the small device asks the big one for help. Here the personal device is the trusted core and the workstation is the untrusted edge — the opposite of every cloud architecture."
      >
        <div style={{display: 'flex', alignItems: 'center', gap: space(4)}}>
          <Phone glow={color.accent} label="TRUSTED CORE" style={{transform: 'scale(0.72)'}} />
          <div style={{...type.display, fontSize: 40, color: color.fgFaint, fontFamily: font.family}}>
            ←
          </div>
          <Laptop label="UNTRUSTED EDGE" tone={color.fgFaint} style={{transform: 'scale(0.66)'}} />
        </div>
      </Claim>

      {/* --------------------------------------------- 02 enforced, not promised */}
      <Claim
        n="02"
        at={15.8}
        hold={13.2}
        title="Enforced, not promised"
        body="A missing permission is a property an auditor verifies in seconds. It does not rest on a policy document, a privacy page, or a vendor's continued good behaviour."
      >
        <Panel accent={color.accent} glow style={{width: 560}}>
          <div style={{...type.micro, color: color.fgFaint, fontFamily: font.family}}>
            VERIFY IT YOURSELF
          </div>
          <div
            style={{
              marginTop: 14,
              fontFamily: font.mono,
              fontSize: 17,
              color: color.fg,
              lineHeight: 1.8,
            }}
          >
            <span style={{color: color.fgFaint}}>$</span> aapt2 dump permissions app.apk
            <br />
            <span style={{color: color.accent}}>→ no INTERNET permission</span>
          </div>
          <div style={{marginTop: 16, ...type.body, fontSize: 21, color: color.fgMuted, fontFamily: font.family}}>
            A claim anyone can check, not one they have to believe.
          </div>
        </Panel>
      </Claim>

      {/* ------------------------------------------------- 03 minimal disclosure */}
      <Claim
        n="03"
        at={29.2}
        hold={9.4}
        title="Minimal disclosure"
        body="Even the side you trust only ever sees the passages it needs. The corpus itself is never exported — not to the cloud, and not to your own laptop."
      >
        <div style={{textAlign: 'center'}}>
          <div
            style={{
              width: 420,
              height: 240,
              borderRadius: 18,
              border: `1px solid ${color.accent}`,
              background: color.accentDim,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              position: 'relative',
            }}
          >
            <div style={{...type.body, color: color.accent, fontFamily: font.family}}>
              the corpus — stays
            </div>
            <div
              style={{
                position: 'absolute',
                right: -70,
                top: '50%',
                transform: `translateY(-50%) scaleY(${Math.max(shrink, 0.02)})`,
                width: 54,
                height: 200,
                borderRadius: 10,
                background: color.fg,
                opacity: 0.85,
              }}
            />
          </div>
          <div style={{marginTop: 30}}>
            <Mono tone={color.fgMuted}>only the answer leaves →</Mono>
          </div>
        </div>
      </Claim>

      {/* ---------------------------------------------------- 04 free silicon */}
      <Claim
        n="04"
        at={39}
        hold={19}
        title="Silicon you already own"
        body="No new hardware, no per-token cost, no rate limit, no queue. And because capture is local, a photograph of a whiteboard becomes searchable knowledge without ever touching a server."
      >
        <div style={{display: 'flex', flexDirection: 'column', gap: space(2), width: 560}}>
          {[
            ['Marginal cost per query', '0'],
            ['Rate limit', 'none'],
            ['Network round trips', '0'],
          ].map(([k, v]) => (
            <Panel key={k} style={{display: 'flex', justifyContent: 'space-between', padding: space(2.5)}}>
              <span style={{...type.body, fontSize: 22, color: color.fgMuted, fontFamily: font.family}}>
                {k}
              </span>
              <span style={{...type.heading, color: color.accent, fontFamily: font.family}}>{v}</span>
            </Panel>
          ))}
        </div>
      </Claim>
    </AbsoluteFill>
  );
};
