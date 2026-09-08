import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {
  Backdrop,
  Doc,
  Laptop,
  Meter,
  Mono,
  Panel,
  Phone,
  ramp,
  SceneHeader,
  useReveal,
} from '../components/ui';
import {color, font, space, type} from '../theme';

/**
 * Scene 1 — The Problem.
 *
 * Beat A (0-18s):  documents leave the device and multiply in someone else's
 *                  datacentre. Red = it left.
 * Beat B (23-36s): the local alternative pegs the laptop and throttles it.
 * Beat C (36-60s): the idle NPU reveal, then the two-line thesis.
 */

const S = 30; // fps

const CloudCopy: React.FC<{i: number; at: number}> = ({i, at}) => {
  const frame = useCurrentFrame();
  const p = ramp(frame, [at, at + 26], [0, 1]);
  return (
    <div
      style={{
        position: 'absolute',
        left: 26 + i * 34,
        top: 22 + (i % 2) * 26,
        opacity: p * 0.9,
        transform: `scale(${0.7 + p * 0.3})`,
      }}
    >
      <Doc tone={color.danger} size={30} />
    </div>
  );
};

export const Scene1Problem: React.FC = () => {
  const frame = useCurrentFrame();

  // Beat A — the upload.
  const beatA = useReveal(0.6 * S, 20 * S);
  const flight = ramp(frame, [3.2 * S, 7.5 * S], [0, 1]);
  const leaks = useReveal(13 * S, 7 * S);

  // Beat B — the laptop melts.
  const beatB = useReveal(23 * S, 12.5 * S);
  const load = ramp(frame, [25 * S, 31 * S], [0.12, 0.98]);
  const heat = ramp(frame, [27 * S, 33 * S], [0.1, 0.94]);

  // Beat C — the idle NPU.
  const beatC = useReveal(36 * S, 14 * S);
  const thesis = useReveal(51 * S);

  return (
    <AbsoluteFill>
      <Backdrop tint={color.danger} intensity={0.5} />
      <SceneHeader chapter="ONE" title="The Problem" />

      {/* ---------------------------------------------------------- beat A */}
      <AbsoluteFill
        style={{alignItems: 'center', justifyContent: 'center', ...beatA, paddingBottom: 90}}
      >
        <div style={{display: 'flex', alignItems: 'center', gap: space(10)}}>
          <div style={{display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 18}}>
            <Doc tone={color.fgMuted} size={72} />
            <Mono>your corpus</Mono>
          </div>

          {/* the one-way trip */}
          <div style={{position: 'relative', width: 420, height: 90}}>
            <div
              style={{
                position: 'absolute',
                top: 44,
                left: 0,
                right: 0,
                height: 2,
                background: `linear-gradient(90deg, ${color.danger}, ${color.dangerGlow})`,
                opacity: 0.5,
              }}
            />
            <div
              style={{
                position: 'absolute',
                top: 30,
                left: flight * 380,
                opacity: flight > 0.02 && flight < 0.99 ? 1 : 0,
              }}
            >
              <Doc tone={color.danger} size={28} />
            </div>
            <div
              style={{
                position: 'absolute',
                top: 0,
                width: '100%',
                textAlign: 'center',
                ...type.micro,
                color: color.danger,
                fontFamily: font.family,
              }}
            >
              UPLOAD
            </div>
          </div>

          <Panel accent={color.danger} glow style={{width: 430, height: 250, position: 'relative'}}>
            <div style={{...type.heading, color: color.fg, fontFamily: font.family}}>
              Someone else&apos;s computer
            </div>
            <div style={{marginTop: 10}}>
              <Mono tone={color.fgFaint}>plaintext required to embed</Mono>
            </div>
            <div style={{position: 'absolute', inset: 0, top: 92, ...leaks}}>
              {[0, 1, 2, 3, 4, 5].map((i) => (
                <CloudCopy key={i} i={i} at={13 * S + i * 5} />
              ))}
              <div
                style={{
                  position: 'absolute',
                  bottom: 16,
                  left: 26,
                  ...type.micro,
                  color: color.danger,
                  fontFamily: font.family,
                }}
              >
                RETAINED · INDEXED · SUBPOENAED · TRAINED ON
              </div>
            </div>
          </Panel>
        </div>
      </AbsoluteFill>

      {/* ---------------------------------------------------------- beat B */}
      <AbsoluteFill
        style={{alignItems: 'center', justifyContent: 'center', ...beatB, paddingBottom: 90}}
      >
        <div style={{display: 'flex', alignItems: 'center', gap: space(9)}}>
          <Laptop label="RUN IT LOCALLY INSTEAD" tone={color.danger}>
            <div style={{display: 'flex', flexDirection: 'column', gap: 14, alignItems: 'center'}}>
              <div style={{...type.heading, color: color.danger, fontFamily: font.family}}>
                {Math.round(heat * 96)}°C
              </div>
              <Mono tone={color.danger}>thermal throttling</Mono>
            </div>
          </Laptop>
          <Panel style={{width: 430, display: 'flex', flexDirection: 'column', gap: space(3)}}>
            <Meter label="Laptop CPU" value={load} tone={color.danger} sub="encoder vs compiler" />
            <Meter label="Package temp" value={heat} tone={color.danger} sub="fans at maximum" />
          </Panel>
        </div>
      </AbsoluteFill>

      {/* ---------------------------------------------------------- beat C */}
      <AbsoluteFill
        style={{alignItems: 'center', justifyContent: 'center', ...beatC, paddingBottom: 90}}
      >
        <div style={{display: 'flex', alignItems: 'center', gap: space(11)}}>
          <Phone glow={color.fgFaint} label="IN YOUR POCKET">
            <div style={{textAlign: 'center'}}>
              <div style={{...type.display, fontSize: 64, color: color.fgFaint, fontFamily: font.family}}>
                0%
              </div>
              <div style={{marginTop: 6}}>
                <Mono tone={color.fgFaint}>NPU idle</Mono>
              </div>
            </div>
          </Phone>
          <div style={{width: 520}}>
            <div style={{...type.heading, color: color.fg, fontFamily: font.family}}>
              Tens of trillions of operations per second
            </div>
            <div
              style={{
                ...type.body,
                color: color.fgMuted,
                fontFamily: font.family,
                marginTop: space(2),
              }}
            >
              Purpose-built for exactly this arithmetic. Bought, carried, charged
              — and almost entirely unused while you work.
            </div>
          </div>
        </div>
      </AbsoluteFill>

      {/* ------------------------------------------------------- the thesis */}
      <AbsoluteFill
        style={{alignItems: 'center', justifyContent: 'center', ...thesis, paddingBottom: 120}}
      >
        <div style={{textAlign: 'center', maxWidth: 1300}}>
          <div style={{...type.display, fontSize: 68, color: color.fg, fontFamily: font.family}}>
            The data is in the wrong <span style={{color: color.danger}}>place</span>.
          </div>
          <div
            style={{
              ...type.display,
              fontSize: 68,
              color: color.fg,
              fontFamily: font.family,
              marginTop: 14,
            }}
          >
            The work is on the wrong <span style={{color: color.danger}}>processor</span>.
          </div>
        </div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
