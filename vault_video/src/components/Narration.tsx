import React from 'react';
import {Audio, Sequence, staticFile, useVideoConfig} from 'remotion';
import manifest from '../voManifest.json';
import {color, font, type} from '../theme';

type Clip = {
  scene: number;
  index: number;
  file: string;
  t: number;
  budget: number;
  duration: number;
  lengthScale: number;
};

const CLIPS = manifest as Clip[];

/**
 * Places one voiceover clip per narration line at its own frame offset.
 *
 * Deliberately not one long take: the line timings in script.ts drive both the
 * captions and these offsets, so audio and captions cannot drift apart. A clip
 * that ends early just leaves a natural pause.
 *
 * Renders nothing until `tts/synthesize.py` has been run — the committed
 * manifest is an empty array so the project builds without the audio.
 */
export const Narration: React.FC<{scene: number}> = ({scene}) => {
  const {fps} = useVideoConfig();
  const clips = CLIPS.filter((c) => c.scene === scene);
  if (clips.length === 0) return null;

  return (
    <>
      {clips.map((c) => (
        <Sequence
          key={c.file}
          from={Math.round(c.t * fps)}
          durationInFrames={Math.ceil(c.duration * fps) + 2}
        >
          <Audio src={staticFile(`vo/${c.file}`)} />
        </Sequence>
      ))}
    </>
  );
};

/** True once the voiceover has been generated — used to hide the "no audio" hint. */
export const hasNarration = CLIPS.length > 0;

/**
 * Persistent corner lockup. Small, low-contrast, out of the caption's way —
 * present for attribution on every frame without competing with the content.
 */
export const Branding: React.FC<{team: string; project: string}> = ({team, project}) => (
  <div
    style={{
      position: 'absolute',
      right: 56,
      top: 60,
      textAlign: 'right',
      fontFamily: font.family,
      opacity: 0.75,
    }}
  >
    <div style={{...type.micro, color: color.accent, letterSpacing: 2.6}}>
      {project.toUpperCase()}
    </div>
    <div style={{...type.micro, color: color.fgFaint, letterSpacing: 1.8, marginTop: 6}}>
      {team.toUpperCase()}
    </div>
  </div>
);
