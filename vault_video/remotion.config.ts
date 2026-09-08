import {Config} from '@remotion/cli/config';

Config.setVideoImageFormat('jpeg');
Config.setOverwriteOutput(true);
// The scenes are gradient- and blur-heavy; 2 is a good quality/speed tradeoff.
Config.setConcurrency(4);
