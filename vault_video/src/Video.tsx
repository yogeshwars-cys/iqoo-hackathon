import React from 'react';
import {AbsoluteFill, Series, useVideoConfig} from 'remotion';
import {Branding, Narration} from './components/Narration';
import {Captions} from './components/ui';
import {SCENES} from './script';
import {Scene1Problem} from './scenes/Scene1Problem';
import {Scene2Solution} from './scenes/Scene2Solution';
import {Scene3Implementation} from './scenes/Scene3Implementation';
import {Scene4Novelty} from './scenes/Scene4Novelty';
import {Scene5Future} from './scenes/Scene5Future';
import {color, SCENE_FRAMES} from './theme';

const COMPONENTS = [
  Scene1Problem,
  Scene2Solution,
  Scene3Implementation,
  Scene4Novelty,
  Scene5Future,
] as const;

export type VaultProps = {
  /** Shown in the corner lockup on every frame. */
  teamName: string;
  /** Product name, sits above the team name. */
  projectName: string;
};

export const defaultVaultProps: VaultProps = {
  teamName: 'YOUR TEAM NAME',
  projectName: 'Vault',
};

/**
 * Each scene is wrapped so its captions and voiceover restart at frame 0 of
 * that scene — which is why the `t` values in script.ts are scene-relative
 * and stay readable instead of climbing to 280.
 */
const Chapter: React.FC<{index: number}> = ({index}) => {
  const {fps} = useVideoConfig();
  const Scene = COMPONENTS[index];
  return (
    <AbsoluteFill style={{backgroundColor: color.bg}}>
      <Scene />
      <Captions lines={SCENES[index].lines} fps={fps} />
      <Narration scene={index} />
    </AbsoluteFill>
  );
};

export const VaultVideo: React.FC<VaultProps> = ({teamName, projectName}) => (
  <AbsoluteFill style={{backgroundColor: color.bg}}>
    <Series>
      {SCENES.map((scene, i) => (
        <Series.Sequence key={scene.id} durationInFrames={SCENE_FRAMES}>
          <Chapter index={i} />
        </Series.Sequence>
      ))}
    </Series>
    {/* Outside the Series so it persists across every scene. */}
    <Branding team={teamName} project={projectName} />
  </AbsoluteFill>
);
