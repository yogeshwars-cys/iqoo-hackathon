import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {Backdrop, Mono, Panel, ramp, SceneHeader, useReveal} from '../components/ui';
import {color, font, space, type} from '../theme';

/**
 * Scene 3 — How It Is Built.
 *
 * A pipeline assembled left to right, one stage per narration beat, so the
 * diagram is finished exactly as the voiceover finishes describing it. The
 * stack panel on the right fills in alongside it.
 *
 * This is the "real tech stack" scene: every label here is a component you
 * would actually pick in a 30-hour build, not a placeholder.
 */

const S = 30;

type Stage = {
  at: number;
  key: string;
  title: string;
  detail: string;
  tech: string;
};

const STAGES: Stage[] = [
  {at: 3.5, key: 'extract', title: 'Extract', detail: 'documents · code · OCR', tech: 'text extractors + ML Kit OCR'},
  {at: 8.1, key: 'chunk', title: 'Chunk', detail: '256 tokens · 32 overlap', tech: 'boundary-aware windower'},
  {at: 17.7, key: 'embed', title: 'Embed', detail: 'MiniLM-L6 · 384-dim', tech: 'LiteRT + NPU delegate'},
  {at: 27.9, key: 'index', title: 'Index', detail: 'vectors + metadata', tech: 'SQLite + sqlite-vec'},
  {at: 32.7, key: 'seal', title: 'Seal', detail: 'encrypted at rest', tech: 'SQLCipher + Keystore'},
];

const StageCard: React.FC<{stage: Stage; i: number}> = ({stage, i}) => {
  const frame = useCurrentFrame();
  const at = stage.at * S;
  const p = ramp(frame, [at, at + 20], [0, 1]);
  const lit = ramp(frame, [at, at + 26], [0, 1]);
  return (
    <div style={{display: 'flex', alignItems: 'center'}}>
      {i > 0 ? (
        <div
          style={{
            width: 54,
            height: 2,
            background: color.accent,
            opacity: p * 0.55,
            boxShadow: `0 0 12px ${color.accentGlow}`,
          }}
        />
      ) : null}
      <div
        style={{
          opacity: p,
          transform: `translateY(${(1 - p) * 22}px)`,
          width: 216,
          padding: `${space(2.5)}px ${space(2)}px`,
          borderRadius: 16,
          background: 'rgba(16,25,46,0.8)',
          border: `1px solid ${lit > 0.5 ? color.accent : color.border}`,
          boxShadow: lit > 0.5 ? `0 0 34px -10px ${color.accentGlow}` : 'none',
          textAlign: 'center',
        }}
      >
        <div style={{...type.micro, color: color.accent, fontFamily: font.family}}>
          {String(i + 1).padStart(2, '0')}
        </div>
        <div
          style={{
            ...type.heading,
            fontSize: 28,
            color: color.fg,
            fontFamily: font.family,
            marginTop: 6,
          }}
        >
          {stage.title}
        </div>
        <div style={{marginTop: 8}}>
          <Mono tone={color.fgMuted}>{stage.detail}</Mono>
        </div>
      </div>
    </div>
  );
};

export const Scene3Implementation: React.FC = () => {
  const frame = useCurrentFrame();

  const pipeline = useReveal(2.6 * S, 40 * S);
  const query = useReveal(37 * S, 16 * S);
  const permission = useReveal(53.6 * S);

  // Similarity bars filling as the query beat plays.
  const rank = (i: number) => ramp(frame, [41 * S + i * 6, 45 * S + i * 6], [0, [0.94, 0.78, 0.61][i]]);

  return (
    <AbsoluteFill>
      <Backdrop tint={color.primary} intensity={0.7} />
      <SceneHeader chapter="THREE" title="How It Is Built" />

      {/* ------------------------------------------------ the build pipeline */}
      <div
        style={{
          position: 'absolute',
          top: 320,
          left: 0,
          right: 0,
          display: 'flex',
          justifyContent: 'center',
          ...pipeline,
        }}
      >
        <div style={{display: 'flex', alignItems: 'center'}}>
          {STAGES.map((s, i) => (
            <StageCard key={s.key} stage={s} i={i} />
          ))}
        </div>
      </div>

      {/* stack list, filling in alongside the pipeline */}
      <div
        style={{
          position: 'absolute',
          top: 560,
          left: 0,
          right: 0,
          display: 'flex',
          justifyContent: 'center',
          ...pipeline,
        }}
      >
        <Panel style={{width: 1240}}>
          <div style={{...type.micro, color: color.fgFaint, fontFamily: font.family}}>
            THE STACK
          </div>
          <div
            style={{
              marginTop: space(2),
              display: 'grid',
              gridTemplateColumns: 'repeat(5, 1fr)',
              gap: space(2),
            }}
          >
            {STAGES.map((s) => {
              const p = ramp(frame, [s.at * S + 6, s.at * S + 24], [0, 1]);
              return (
                <div key={s.key} style={{opacity: p}}>
                  <div style={{...type.micro, color: color.accent, fontFamily: font.family}}>
                    {s.title.toUpperCase()}
                  </div>
                  <div style={{marginTop: 8, fontFamily: font.mono, fontSize: 17, color: color.fg}}>
                    {s.tech}
                  </div>
                </div>
              );
            })}
          </div>
        </Panel>
      </div>

      {/* ------------------------------------------------------ query path */}
      <div
        style={{
          position: 'absolute',
          top: 760,
          left: 0,
          right: 0,
          display: 'flex',
          justifyContent: 'center',
          ...query,
        }}
      >
        <div style={{display: 'flex', gap: space(3), alignItems: 'stretch'}}>
          <Panel style={{width: 420}}>
            <div style={{...type.micro, color: color.fgFaint, fontFamily: font.family}}>
              AT QUERY TIME
            </div>
            <div
              style={{
                marginTop: 12,
                fontFamily: font.mono,
                fontSize: 18,
                color: color.fg,
                lineHeight: 1.7,
              }}
            >
              embed(question) → 384-d
              <br />
              cosine over index → top-k
              <br />
              serialise → bridge → IDE
            </div>
          </Panel>
          <Panel style={{width: 480}}>
            <div style={{...type.micro, color: color.fgFaint, fontFamily: font.family}}>
              RANKED PASSAGES
            </div>
            <div style={{marginTop: 14, display: 'flex', flexDirection: 'column', gap: 12}}>
              {[0, 1, 2].map((i) => (
                <div key={i} style={{display: 'flex', alignItems: 'center', gap: 12}}>
                  <Mono tone={color.fgFaint}>{`#${i + 1}`}</Mono>
                  <div
                    style={{
                      flex: 1,
                      height: 10,
                      borderRadius: 999,
                      background: 'rgba(255,255,255,0.07)',
                      overflow: 'hidden',
                    }}
                  >
                    <div
                      style={{
                        width: `${rank(i) * 100}%`,
                        height: '100%',
                        background: color.accent,
                        boxShadow: `0 0 16px ${color.accentGlow}`,
                      }}
                    />
                  </div>
                  <Mono tone={color.accent}>{rank(i).toFixed(2)}</Mono>
                </div>
              ))}
            </div>
          </Panel>
        </div>
      </div>

      {/* ------------------------------------------- the enforcement clause */}
      <AbsoluteFill
        style={{alignItems: 'center', justifyContent: 'center', ...permission, paddingBottom: 120}}
      >
        <Panel accent={color.accent} glow style={{width: 1000, textAlign: 'center', padding: space(5)}}>
          <div style={{...type.micro, color: color.fgFaint, fontFamily: font.family}}>
            ANDROIDMANIFEST.XML
          </div>
          <div
            style={{
              marginTop: 18,
              fontFamily: font.mono,
              fontSize: 30,
              color: color.fg,
              lineHeight: 1.7,
            }}
          >
            <span style={{color: color.fgFaint}}>&lt;uses-permission</span>{' '}
            <span style={{textDecoration: 'line-through', color: color.danger}}>
              android.permission.INTERNET
            </span>{' '}
            <span style={{color: color.fgFaint}}>/&gt;</span>
          </div>
          <div style={{...type.body, color: color.accent, fontFamily: font.family, marginTop: 20}}>
            It cannot phone home. The operating system never granted the ability.
          </div>
        </Panel>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
