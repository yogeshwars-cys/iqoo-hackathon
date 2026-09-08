import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {Backdrop, Mono, Panel, Phone, ramp, SceneHeader, useReveal} from '../components/ui';
import {color, font, space, type} from '../theme';

/**
 * Scene 5 — Where It Goes.
 *
 * Three horizons on a timeline, then the closing thesis. The timeline is the
 * only place in the video that shows something not yet built, so it is drawn
 * deliberately dimmer as it moves right — near-term solid, far-term faint.
 */

const S = 30;

const NODES = [
  {x: 0, y: 0, label: 'PHONE'},
  {x: 300, y: -130, label: 'LAPTOP'},
  {x: 300, y: 130, label: 'WORKSTATION'},
];

const Horizon: React.FC<{
  at: number;
  when: string;
  title: string;
  body: string;
  dim: number;
  x: number;
}> = ({at, when, title, body, dim, x}) => {
  const reveal = useReveal(at * S, Infinity, 20);
  return (
    <div style={{position: 'absolute', left: x, top: 0, width: 400, ...reveal, opacity: (reveal.opacity as number) * dim}}>
      <div style={{...type.micro, color: color.accent, fontFamily: font.family}}>{when}</div>
      <div style={{...type.heading, color: color.fg, fontFamily: font.family, marginTop: 10}}>
        {title}
      </div>
      <div
        style={{
          ...type.body,
          fontSize: 21,
          color: color.fgMuted,
          fontFamily: font.family,
          marginTop: 12,
        }}
      >
        {body}
      </div>
    </div>
  );
};

export const Scene5Future: React.FC = () => {
  const frame = useCurrentFrame();

  const closed = useReveal(2.8 * S, 11 * S);
  const mesh = useReveal(14.1 * S, 12 * S);
  const timeline = useReveal(26.4 * S, 8.5 * S);
  const thesis = useReveal(34.6 * S, 19.6 * S);
  const outro = useReveal(54.4 * S);

  const link = (i: number) => ramp(frame, [17 * S + i * 10, 21 * S + i * 10], [0, 1]);

  return (
    <AbsoluteFill>
      <Backdrop tint={color.accent} intensity={0.6} />
      <SceneHeader chapter="FIVE" title="Where It Goes" />

      {/* ------------------------------------------- near term: closing the loop */}
      <AbsoluteFill
        style={{alignItems: 'center', justifyContent: 'center', ...closed, paddingBottom: 100}}
      >
        <div style={{display: 'flex', alignItems: 'center', gap: space(8)}}>
          <Phone glow={color.accent} label="THE WHOLE LOOP">
            <div style={{textAlign: 'center', padding: 14}}>
              <div style={{...type.micro, color: color.accent, fontFamily: font.family}}>
                RETRIEVE
              </div>
              <div style={{...type.display, fontSize: 34, color: color.fgFaint, fontFamily: font.family}}>
                ↓
              </div>
              <div style={{...type.micro, color: color.accent, fontFamily: font.family}}>
                GENERATE
              </div>
              <div style={{marginTop: 14}}>
                <Mono tone={color.fg}>on-device SLM</Mono>
              </div>
            </div>
          </Phone>
          <div style={{width: 620}}>
            <div style={{...type.title, fontSize: 50, color: color.fg, fontFamily: font.family}}>
              Generation moves in
            </div>
            <div
              style={{
                ...type.body,
                color: color.fgMuted,
                fontFamily: font.family,
                marginTop: space(2),
              }}
            >
              A small language model reads the retrieved passages on the same
              device that stored them. The laptop becomes optional, and the
              privacy boundary closes completely.
            </div>
          </div>
        </div>
      </AbsoluteFill>

      {/* ---------------------------------------------------- federated vaults */}
      <AbsoluteFill
        style={{alignItems: 'center', justifyContent: 'center', ...mesh, paddingBottom: 100}}
      >
        <div style={{position: 'relative', width: 900, height: 420}}>
          <svg width={900} height={420} style={{position: 'absolute', inset: 0}}>
            {NODES.slice(1).map((n, i) => (
              <line
                key={n.label}
                x1={220}
                y1={210}
                x2={220 + n.x}
                y2={210 + n.y}
                stroke={color.accent}
                strokeWidth={2}
                strokeDasharray="6 8"
                opacity={link(i) * 0.8}
              />
            ))}
          </svg>
          {NODES.map((n, i) => (
            <div
              key={n.label}
              style={{
                position: 'absolute',
                left: 220 + n.x,
                top: 210 + n.y,
                transform: 'translate(-50%, -50%)',
                opacity: i === 0 ? 1 : link(i - 1),
                textAlign: 'center',
              }}
            >
              <div
                style={{
                  width: 128,
                  height: 128,
                  borderRadius: 22,
                  border: `2px solid ${color.accent}`,
                  background: color.accentDim,
                  boxShadow: `0 0 40px -10px ${color.accentGlow}`,
                }}
              />
              <div
                style={{
                  marginTop: 12,
                  ...type.micro,
                  color: color.accent,
                  fontFamily: font.family,
                }}
              >
                {n.label}
              </div>
            </div>
          ))}
          <div
            style={{
              position: 'absolute',
              right: 0,
              bottom: 0,
              width: 320,
              ...type.body,
              fontSize: 21,
              color: color.fgMuted,
              fontFamily: font.family,
            }}
          >
            One personal index, synchronised peer to peer. No server in the
            middle to trust or subpoena.
          </div>
        </div>
      </AbsoluteFill>

      {/* --------------------------------------------------------- horizons */}
      <div
        style={{
          position: 'absolute',
          top: 400,
          left: 160,
          right: 160,
          height: 300,
          ...timeline,
        }}
      >
        <div
          style={{
            position: 'absolute',
            top: -30,
            left: 0,
            right: 0,
            height: 1,
            background: `linear-gradient(90deg, ${color.accent}, transparent)`,
          }}
        />
        <Horizon
          at={26.8}
          when="NOW"
          title="Ambient ingestion"
          body="Meetings, screenshots, notes — indexed continuously and locally, never uploaded."
          dim={1}
          x={0}
        />
        <Horizon
          at={28.4}
          when="NEXT"
          title="Federated vaults"
          body="Devices reconcile one private index directly between themselves."
          dim={0.78}
          x={600}
        />
        <Horizon
          at={30}
          when="LATER"
          title="Agents with a boundary"
          body="Autonomy is safe when the data it acts on provably cannot leave."
          dim={0.55}
          x={1200}
        />
      </div>

      {/* ----------------------------------------------------------- thesis */}
      <AbsoluteFill
        style={{alignItems: 'center', justifyContent: 'center', ...thesis, paddingBottom: 130}}
      >
        <div style={{textAlign: 'center', maxWidth: 1440}}>
          <div style={{...type.body, color: color.fgMuted, fontFamily: font.family}}>
            Every year, more neural silicon ships inside devices people already carry.
          </div>
          <div
            style={{
              ...type.display,
              fontSize: 66,
              color: color.fg,
              fontFamily: font.family,
              marginTop: space(4),
            }}
          >
            The data is already there.
            <br />
            The compute is already there.
          </div>
          <div
            style={{
              ...type.title,
              fontSize: 42,
              color: color.accent,
              fontFamily: font.family,
              marginTop: space(4),
            }}
          >
            The only thing missing is the assumption that it has to leave.
          </div>
        </div>
      </AbsoluteFill>

      {/* ------------------------------------------------------------ outro */}
      <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', ...outro}}>
        <Panel accent={color.accent} glow style={{padding: `${space(6)}px ${space(10)}px`, textAlign: 'center'}}>
          <div style={{...type.display, fontSize: 76, color: color.fg, fontFamily: font.family}}>
            Build the vault.
          </div>
          <div
            style={{
              ...type.display,
              fontSize: 76,
              color: color.accent,
              fontFamily: font.family,
              marginTop: 8,
            }}
          >
            Keep the corpus.
          </div>
        </Panel>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
