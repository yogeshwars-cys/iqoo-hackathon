import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {
  Backdrop,
  Chip,
  Doc,
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
 * Scene 2 — How It Is Solved.
 *
 * The visual argument is one gesture: the arrow that pointed *out* in Scene 1
 * now points *in*, and stops. Everything else supports that inversion.
 *
 * Beat A (0-13s):  the cloud is struck out; the phone becomes the vault.
 * Beat B (13-41s): corpus flows in once; only query/answer cross the gap.
 * Beat C (44-60s): the asymmetry stated numerically.
 */

const S = 30;

/** A packet travelling along a horizontal wire between the two devices. */
const Packet: React.FC<{
  at: number;
  dur: number;
  from: number;
  to: number;
  tone: string;
  label: string;
  y: number;
}> = ({at, dur, from, to, tone, label, y}) => {
  const frame = useCurrentFrame();
  const p = ramp(frame, [at, at + dur], [0, 1]);
  const visible = frame >= at && frame <= at + dur;
  if (!visible) return null;
  return (
    <div
      style={{
        position: 'absolute',
        top: y,
        left: from + (to - from) * p,
        transform: 'translateX(-50%)',
        display: 'flex',
        alignItems: 'center',
        gap: 8,
        padding: '7px 14px',
        borderRadius: 999,
        background: 'rgba(11,17,32,0.9)',
        border: `1px solid ${tone}`,
        boxShadow: `0 0 24px -4px ${tone}`,
        whiteSpace: 'nowrap',
      }}
    >
      <span style={{width: 6, height: 6, borderRadius: 999, background: tone}} />
      <span style={{fontFamily: font.mono, fontSize: 16, color: tone}}>{label}</span>
    </div>
  );
};

export const Scene2Solution: React.FC = () => {
  const frame = useCurrentFrame();

  const invert = useReveal(0.6 * S, 12 * S);
  const strike = ramp(frame, [3 * S, 6 * S], [0, 1]);

  const stage = useReveal(13.4 * S, 29 * S);
  const ingest = ramp(frame, [15 * S, 21 * S], [0, 1]);
  const vaultLit = ramp(frame, [18 * S, 22 * S], [0.25, 1]);

  const asym = useReveal(43.6 * S);

  return (
    <AbsoluteFill>
      <Backdrop tint={color.accent} intensity={0.55} />
      <SceneHeader chapter="TWO" title="How It Is Solved" />

      {/* -------------------------------------------- beat A: the inversion */}
      <AbsoluteFill
        style={{alignItems: 'center', justifyContent: 'center', ...invert, paddingBottom: 90}}
      >
        <div style={{display: 'flex', alignItems: 'center', gap: space(8)}}>
          <div style={{position: 'relative'}}>
            <Panel style={{width: 340, opacity: 1 - strike * 0.55}}>
              <div style={{...type.heading, color: color.fgMuted, fontFamily: font.family}}>
                The cloud
              </div>
              <div style={{marginTop: 8}}>
                <Mono tone={color.fgFaint}>not in the loop</Mono>
              </div>
            </Panel>
            <div
              style={{
                position: 'absolute',
                top: '50%',
                left: 0,
                width: `${strike * 100}%`,
                height: 3,
                background: color.danger,
                boxShadow: `0 0 18px ${color.danger}`,
              }}
            />
          </div>
          <div style={{...type.display, fontSize: 54, color: color.fgFaint, fontFamily: font.family}}>
            →
          </div>
          <div style={{textAlign: 'left', maxWidth: 620}}>
            <div style={{...type.title, color: color.fg, fontFamily: font.family}}>
              Invert the topology
            </div>
            <div
              style={{
                ...type.body,
                color: color.fgMuted,
                fontFamily: font.family,
                marginTop: space(2),
              }}
            >
              The phone stops being a thin client for someone else&apos;s server
              and becomes a private inference appliance that happens to fit in
              your pocket.
            </div>
          </div>
        </div>
      </AbsoluteFill>

      {/* --------------------------------------- beat B: the working topology */}
      <AbsoluteFill style={{...stage, paddingBottom: 90}}>
        <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center'}}>
          <div style={{display: 'flex', alignItems: 'center', gap: space(6)}}>
            {/* corpus flowing in, once */}
            <div style={{width: 210, display: 'flex', flexDirection: 'column', gap: 14}}>
              {[0, 1, 2].map((i) => {
                const p = ramp(frame, [15 * S + i * 12, 21 * S + i * 12], [0, 1]);
                return (
                  <div
                    key={i}
                    style={{
                      transform: `translateX(${p * 120}px)`,
                      opacity: (1 - p) * ingest + 0.15,
                    }}
                  >
                    <Doc tone={color.accent} size={34} />
                  </div>
                );
              })}
              <Mono tone={color.fgFaint}>ingested once</Mono>
            </div>

            <Phone glow={color.accent} label="THE VAULT" style={{opacity: vaultLit}}>
              <div style={{textAlign: 'center', padding: 12}}>
                <div style={{...type.micro, color: color.accent, fontFamily: font.family}}>
                  CORPUS · INDEX · ENCODER
                </div>
                <div
                  style={{
                    marginTop: 14,
                    ...type.display,
                    fontSize: 44,
                    color: color.fg,
                    fontFamily: font.family,
                  }}
                >
                  1.2 GB
                </div>
                <div style={{marginTop: 8}}>
                  <Mono tone={color.accent}>never leaves</Mono>
                </div>
              </div>
            </Phone>

            {/* the narrow gap */}
            <div style={{position: 'relative', width: 380, height: 220}}>
              <div
                style={{
                  position: 'absolute',
                  top: 74,
                  left: 0,
                  right: 0,
                  height: 1,
                  background: color.borderStrong,
                }}
              />
              <div
                style={{
                  position: 'absolute',
                  top: 146,
                  left: 0,
                  right: 0,
                  height: 1,
                  background: color.borderStrong,
                }}
              />
              <Packet at={27 * S} dur={3.4 * S} from={380} to={0} tone={color.fgMuted} label="query" y={62} />
              <Packet at={33 * S} dur={3.4 * S} from={0} to={380} tone={color.accent} label="top-k passages" y={134} />
              <div
                style={{
                  position: 'absolute',
                  bottom: 6,
                  width: '100%',
                  textAlign: 'center',
                  ...type.micro,
                  color: color.fgFaint,
                  fontFamily: font.family,
                }}
              >
                DIRECT DEVICE-TO-DEVICE LINK
              </div>
            </div>

            <Laptop label="WHERE YOU WORK" tone={color.fgMuted}>
              <div style={{textAlign: 'center'}}>
                <div style={{...type.heading, color: color.fg, fontFamily: font.family}}>
                  Reasoning
                </div>
                <div style={{marginTop: 8}}>
                  <Mono>generation, your choice</Mono>
                </div>
              </div>
            </Laptop>
          </div>
        </AbsoluteFill>

        <div
          style={{
            position: 'absolute',
            bottom: 210,
            width: '100%',
            display: 'flex',
            justifyContent: 'center',
            gap: space(2),
          }}
        >
          <Chip label="Retrieval — private, on device" tone="good" />
          <Chip label="Generation — wherever you choose" tone="neutral" />
        </div>
      </AbsoluteFill>

      {/* ------------------------------------------- beat C: the asymmetry */}
      <AbsoluteFill
        style={{alignItems: 'center', justifyContent: 'center', ...asym, paddingBottom: 120}}
      >
        <div style={{display: 'flex', alignItems: 'stretch', gap: space(4)}}>
          <Panel accent={color.accent} glow style={{width: 520, textAlign: 'center'}}>
            <div style={{...type.display, fontSize: 74, color: color.accent, fontFamily: font.family}}>
              100%
            </div>
            <div style={{...type.body, color: color.fg, fontFamily: font.family, marginTop: 8}}>
              of the corpus stays on the device
            </div>
          </Panel>
          <Panel style={{width: 520, textAlign: 'center'}}>
            <div style={{...type.display, fontSize: 74, color: color.fg, fontFamily: font.family}}>
              ~400
            </div>
            <div style={{...type.body, color: color.fgMuted, fontFamily: font.family, marginTop: 8}}>
              tokens of relevant context cross the gap
            </div>
          </Panel>
        </div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
