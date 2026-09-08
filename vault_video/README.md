# Vault — five-minute conceptual explainer

A Remotion video arguing the on-device RAG vault architecture: **the problem,
how it is solved, how it is built, what is new, and where it goes.**

Deliberately *not* a walkthrough of the `vault_rag_test` prototype. It
describes the architecture as it should be built for real, with the stack a
30-hour hackathon team would actually pick. See **Where this diverges from the
prototype** below — that gap is intentional, but you should know exactly where
it is before you present this.

## Run it

```bash
cd vault_video
npm install          # already done
npx remotion studio  # live preview, scrub the timeline
npm run render       # → out/vault.mp4  (1920×1080, 30fps, 5:00)
```

`npx remotion studio` is the fast way to iterate — it hot-reloads, and you can
scrub to any frame instead of re-rendering.

> Not yet rendered or type-checked. Run `npm run typecheck` and a `npm run
> still -- --frame=900` before committing to the full render; the first render
> also downloads a headless Chrome (~150 MB).

## Structure

```
src/
  script.ts        narration + timings — the single source of truth
  theme.ts         design tokens
  Video.tsx        stitches the 5 scenes with <Series>
  Root.tsx         <Composition id="Vault">
  components/ui.tsx  Backdrop, Panel, Meter, Phone, Laptop, Captions…
  scenes/          one file per scene
script/
  gen-narration.mjs  regenerates the voiceover sheet from script.ts
  narration.md       timing sheet for the VO artist
```

### Editing the words

`src/script.ts` drives both the on-screen captions and `script/narration.md`.
Change a line there, then:

```bash
node script/gen-narration.mjs
```

Scene visuals key off the same second-offsets, so if you move a line more than
a beat or two, check the corresponding `useReveal(...)` in that scene file.

## Design

From the `ui-ux-pro-max` design system (*Modern Dark / Cinema Mobile*):

| Token | Value | Meaning |
|---|---|---|
| Background | `#0F172A` | never pure black — it smears on OLED |
| Accent | `#22C55E` | **on-device, private, verifiable** |
| Danger | `#DC2626` | **it left the device** |
| Type | Inter | technical, high-legibility at distance |
| Easing | `cubic-bezier(0.16, 1, 0.3, 1)` | expo-out: fast commit, long settle |

Only two colours are saturated, and both carry meaning rather than decoration
— green and red are the argument, so nothing else competes with them. Motion
is directional: things enter from where they conceptually come from.

Captions are burnt in and always on. Most of this gets watched muted, and the
whole piece has to work with no audio at all.

## The narration

641 words over 5:00 — about **128 wpm**, slower than the 150 wpm rule of
thumb. That is deliberate: it is a dense technical argument, and every scene
keeps 1–5 s of headroom so a human read running long never collides with the
next scene. If you want it closer to 150 wpm, there is room to add roughly one
more line per scene.

## Where this diverges from the prototype

The video describes the target architecture. The prototype in
`../vault_rag_test` made different calls under time pressure, all documented
in its `BUILD_NOTES.md`. Do not claim the prototype does these things:

| Video says | Prototype actually does |
|---|---|
| Embedding on the **NPU** via vendor delegate | NNAPI was unavailable; **XNNPACK on CPU**, 224 ms/embedding |
| **sqlite-vec** vector index | brute-force cosine over Float32 BLOBs in SQLite — the right call under a few thousand chunks |
| **Encrypted at rest** (SQLCipher + Keystore) | not implemented yet |
| **Office Kit** cross-device bridge | adb / clipboard stand-in |
| **On-device generation** | Claude on the laptop |

Two are worth saying out loud if anyone asks, because they are the honest
version of the story:

- **The NPU claim.** On a Snapdragon 695 the NPU path did not materialise, and
  the optimised CPU path (XNNPACK) was 12× faster than the default CPU
  kernels — 2782 ms → 224 ms. The hackathon hardware may expose a working
  NPU delegate; do not assume it until measured.
- **The no-network claim is real and is the strongest thing here.** The
  release APK requests zero permissions — verified with
  `aapt2 dump permissions` and on-device `dumpsys`. That one is not
  aspirational, and it is the claim to lead with.
