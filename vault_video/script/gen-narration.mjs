/**
 * Generates script/narration.md from src/script.ts.
 *
 * The captions in the video and the timing sheet a voice artist reads from
 * must never drift apart, so both come from the same array. Run this after
 * editing any line or timing:
 *
 *   node script/gen-narration.mjs
 */
import {readFileSync, writeFileSync} from 'node:fs';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '..', 'src', 'script.ts'), 'utf8');

const SCENE_SECONDS = 60;

// Pull each scene block, then each line within it.
const scenes = [...src.matchAll(/id: '([^']+)',\s*\n\s*chapter: '([^']+)',\s*\n\s*title: '([^']+)',\s*\n\s*lines: \[([\s\S]*?)\n\s*\],/g)].map(
  ([, id, chapter, title, body]) => ({
    id,
    chapter,
    title,
    lines: [...body.matchAll(/\{t: ([\d.]+), d: ([\d.]+), text: (?:'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)")\}/g)].map(
      ([, t, d, a, b]) => ({
        t: Number(t),
        d: Number(d),
        text: (a ?? b).replace(/\\'/g, "'").replace(/\\"/g, '"'),
      }),
    ),
  }),
);

const tc = (s) => {
  const m = Math.floor(s / 60);
  const rest = s % 60;
  return `${String(m).padStart(2, '0')}:${rest.toFixed(1).padStart(4, '0')}`;
};

let words = 0;
let out = `# Narration & timing sheet

Generated from \`src/script.ts\` by \`script/gen-narration.mjs\` — edit the
source array, not this file.

Absolute timecodes assume each scene is exactly ${SCENE_SECONDS}s and scenes play back to
back. \`IN\` is when the line should start; \`DUR\` is the budget for it. Every
scene has a few seconds of headroom at the end, so a slightly long read will
not collide with the next scene.

**Direction:** measured and level, closer to documentary than advertisement.
Land the numbers plainly and let the pauses carry the emphasis — the visuals
are already doing the arguing.

`;

scenes.forEach((scene, i) => {
  const base = i * SCENE_SECONDS;
  const sceneWords = scene.lines.reduce((n, l) => n + l.text.split(/\s+/).length, 0);
  words += sceneWords;
  const last = scene.lines.at(-1);
  const used = last.t + last.d;

  out += `## Scene ${i + 1} — ${scene.title}\n\n`;
  out += `\`${tc(base)}\`–\`${tc(base + SCENE_SECONDS)}\` · ${sceneWords} words · `;
  out += `${used.toFixed(1)}s used of ${SCENE_SECONDS}s (${(SCENE_SECONDS - used).toFixed(1)}s headroom)\n\n`;
  out += `| IN (abs) | IN (scene) | DUR | Line |\n|---|---|---|---|\n`;
  for (const l of scene.lines) {
    out += `| \`${tc(base + l.t)}\` | \`${l.t.toFixed(1)}s\` | \`${l.d.toFixed(1)}s\` | ${l.text} |\n`;
  }
  out += `\n`;
});

const minutes = (scenes.length * SCENE_SECONDS) / 60;
out += `---\n\n**Total:** ${words} words over ${minutes} minutes — ${Math.round(words / minutes)} wpm.\n`;

writeFileSync(join(here, 'narration.md'), out, 'utf8');
console.log(`narration.md written — ${scenes.length} scenes, ${words} words, ${Math.round(words / minutes)} wpm`);
