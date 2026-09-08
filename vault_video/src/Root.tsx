import React from 'react';
import {Composition} from 'remotion';
import {SCENES} from './script';
import {FPS, HEIGHT, SCENE_FRAMES, WIDTH} from './theme';
import {defaultVaultProps, VaultVideo} from './Video';

export const RemotionRoot: React.FC = () => (
  <>
    {/* The full five-minute piece.
        Branding comes from defaultProps and can be overridden at render time:
          npx remotion render Vault out/vault.mp4 --props=./render-props.json */}
    <Composition
      id="Vault"
      component={VaultVideo}
      durationInFrames={SCENE_FRAMES * SCENES.length}
      fps={FPS}
      width={WIDTH}
      height={HEIGHT}
      defaultProps={defaultVaultProps}
    />
  </>
);
