# Vault — on-device RAG, iQOO Hackathon 2026

A zero-trust retrieval system where your documents never leave your phone.
The phone holds the corpus, the index and the encoder; your laptop sends a
query and gets back only the passages it needs.

Two things live here.

## `vault_rag_test/` — the working prototype

Flutter app, runs on a real Android phone today. Ingests text and source
files, chunks them, embeds on-device with MiniLM-L6-v2, stores vectors in
SQLite, and retrieves by cosine similarity.

**Verified on a realme RMX3660 (Snapdragon 695, Android 14):**

| | |
|---|---|
| Query embedding, 256 tokens | **233 ms** (XNNPACK) |
| Model load | 567 ms |
| Permissions requested, release build | **none** |

That last row is the point of the project. The release APK requests zero
permissions — no `INTERNET` — confirmed with `aapt2 dump permissions` and
on-device `dumpsys`. It cannot exfiltrate anything because the OS never gave
it the ability.

Read **[`vault_rag_test/BUILD_NOTES.md`](vault_rag_test/BUILD_NOTES.md)** before
touching it. It documents several traps that cost real time, including two
that fail *silently*:

- `tflite_flutter` writes int64 tensors big-endian and int32 little-endian, so
  an int64 model embeds byte-swapped garbage on ARM with no error anywhere.
- The dynamic-range-quantized export of MiniLM returns **NaN**. It loads fine
  and ranks pure noise.
- XNNPACK is worth **12×** over the default CPU kernels (2782 ms → 224 ms),
  but constructing its delegate with `XNNPackDelegateOptions` segfaults the
  process.

Model weights are not committed. `vault_rag_test/modelprep/` regenerates them
end to end and verifies the result against an onnxruntime reference.

## `vault_video/` — the five-minute explainer

A [Remotion](https://remotion.dev) video covering the problem, the solution,
the architecture, what is novel, and where it goes. Conceptual: it describes
the system as it should be built, not what the prototype currently does. The
gap between the two is tabled in
[`vault_video/README.md`](vault_video/README.md) — read it before presenting.

```bash
cd vault_video
npm install
npm run tts       # generate the voiceover (Piper, en_US-ryan-high)
npx remotion studio
npm run render    # → out/vault.mp4
```

Voiceover is already committed, so `npm run tts` is only needed if you change
the script. Branding comes from `render-props.json`.
