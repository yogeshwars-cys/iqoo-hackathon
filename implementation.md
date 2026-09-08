# Implementation: Vault RAG test build (v0)

Purpose of this build: prove the retrieval pipeline actually works —
upload files, convert to a local vector DB, ask a question, get the right
chunks back — before investing in the on-device LLM, encryption, Office
Kit integration, or any UI polish. This is a plumbing test, not the demo.

## Read this first — how this differs from the real hackathon build

- **Claude, not Gemma/Phi, does the reasoning.** Retrieved chunks leave
  the phone (via clipboard or an adb-pulled file) and get pasted into
  Claude on the laptop by hand. That means the zero-trust story does
  **not** hold in this configuration — only test with your own
  non-sensitive files (your public repo, throwaway notes), never real
  sensitive documents, until Claude is replaced by an on-device model.
- **No Office Kit.** You don't have the hardware to test against outside
  the event, so the phone→laptop bridge here is plain USB debugging
  (adb) plus the system clipboard. At the venue, only this bridge step
  gets swapped for the real Office Kit transport — everything upstream
  of it (chunking, embedding, storage, retrieval) doesn't change.
- **No network permission requested at all**, not even for this test
  build. That wasn't a stretch goal — it's what forced the file/clipboard
  bridge design below instead of a local HTTP server, and it means this
  test build already rehearses the habit you want for the real one.

## Prerequisites

- Flutter SDK installed, `flutter doctor` passing for Android
- The iQOO phone (or any Android phone for now) with Developer Options
  and USB debugging enabled, connected via USB
- Claude Code installed, with `flutter` and `adb` resolvable on PATH
- A converted MiniLM model — see "Model prep" below. The app will build
  without it but the Convert step will throw at runtime.

## Architecture (this test build only)

```
Upload files (file picker)
        |
        v
Chunker (chunking.dart) -- 256-word windows, 32-word overlap
        |
        v
MiniLMEmbeddingService (embedding_service.dart) -- TFLite + NNAPI
        |
        v
VectorStore (vector_store.dart) -- sqlite3, brute-force cosine top-k
        |
        v
Test query -> embed -> topK() -> results shown in-app
        |
        v
Copy results as JSON -> clipboard + query_result.json
        |
        v
adb pull (or clipboard paste) -> paste into Claude on laptop
```

## File map — what's already written vs. what Claude Code still does

Already written and attached, drop these into `lib/` as-is:

- `lib/chunking.dart` — text chunker
- `lib/tokenizer.dart` — minimal WordPiece tokenizer for MiniLM's vocab
- `lib/embedding_service.dart` — TFLite wrapper, NNAPI delegate enabled
- `lib/vector_store.dart` — sqlite3-backed store, cosine top-k
- `lib/main.dart` — the whole UI: upload, convert, query, copy
- `pubspec.yaml` — dependencies

None of this has been run against a real device or a real model file in
this environment — expect small compile fixes. Claude Code's job is to
get it building and fix what doesn't compile, not redesign it.

## Steps for Claude Code to run

1. `flutter create vault_rag_test` in a fresh directory
2. Replace the generated `lib/main.dart` and `pubspec.yaml` with the
   attached versions; add the other three files under `lib/`
3. Complete "Model prep" below (one-time, mostly outside Claude Code)
4. `flutter pub get`
5. Run the `tflite_flutter` native binary install script for Android
   (see the package README — this pulls prebuilt TFLite C binaries into
   `android/app/src/main/jniLibs/`; skipping this is the most common
   cause of a crash that only shows up on the physical phone, not in
   any editor warning)
6. Confirm the phone is detected: `adb devices`
7. `flutter run` — this builds, installs over USB, and launches directly;
   no separate `adb install` step needed
8. Iterate on compile errors — fix and re-run until "Model ready" shows
   in the status line at the top of the app

## Model prep (the one step that isn't code)

1. Get `all-MiniLM-L6-v2` (sentence-transformers) locally
2. Convert to TFLite — e.g. `onnx2tf` from the model's ONNX export, or
   a TF/Keras re-implementation run through `TFLiteConverter`. Dynamic
   range quantization keeps the file small and fast on-device.
3. Confirm the converted model's **output shape**: it should be
   `[1, seq_len, 384]` (token-level embeddings, mean-pooled by our code).
   Some export paths bake pooling in at conversion time and instead
   output `[1, 384]` directly — if so, tell Claude Code to skip
   `_meanPoolAndNormalize`'s pooling step and just L2-normalize the raw
   output.
4. Pull `vocab.txt` from the same model repo (needed for WordPiece)
5. Place both files at `assets/models/minilm_l6_v2_quant.tflite` and
   `assets/models/vocab.txt` — paths already registered in `pubspec.yaml`

## Testing the retrieval loop end-to-end

1. Launch the app, wait for the status line to read "Model ready"
2. Tap **Upload files**, pick 3–5 text/code files you know well (use
   your own repo — see the caveat above about not using real sensitive
   docs yet)
3. Tap **Convert to Vector DB** — watch each file's status flip to
   "Ingested (N chunks)"; anything that fails shows "Skipped —
   unsupported or unreadable" instead of failing silently
4. Type a question you know the ground-truth answer to into **Test
   query**, tap **Search**
5. **The actual test**: are the top results the chunks that should have
   matched? This is the thing that matters — don't skip straight to
   Claude before confirming this looks right
6. Tap **Copy results as JSON**
7. On the laptop, either:
   - Paste directly if your phone's clipboard syncs to the laptop, or
   - Run `adb pull /storage/emulated/0/Android/data/<package_name>/files/query_result.json ./result.json`
     and open that file instead
8. Paste the JSON into a Claude Code or claude.ai conversation with a
   prompt like: *"Here is retrieved context from my local vault:
   `<paste>`. Using only this context, answer: `<your question>`."*
   Confirm the answer is grounded in the retrieved chunks, not
   hallucinated from general knowledge — if it looks right even when
   you deliberately ask something the files don't cover, that's a sign
   Claude is ignoring the context and answering from its own knowledge,
   not a sign the pipeline is working.

## Known gaps — expect to hit these, fix as you go

- WordPiece tokenizer is simplified (see comments in `tokenizer.dart`):
  correct for plain English prose and code, not exhaustively tested
  against every Unicode edge case
- No encryption at rest yet — add before the real demo, not before this
  test
- No file-type allowlist enforcement beyond the picker's extension
  filter — anything that throws on read just gets marked "Skipped"
- NNAPI delegate behavior varies by device/OS build; if `Interpreter.fromAsset`
  throws with NNAPI-related errors, set `useNnApiForAndroid = false` in
  `embedding_service.dart`, confirm CPU inference works, then debug the
  NPU path as a separate problem — don't let it block the retrieval test

## What comes after this works

- Swap Claude-on-laptop for an on-device Gemma/Phi generation step,
  using whichever local LLM runtime the hackathon organizers provide —
  confirm with mentors on Day 1 rather than hand-rolling generative
  inference
- Swap the adb/clipboard bridge for the real Office Kit transport once
  received at check-in
- Add encryption at rest (SQLCipher or Android Keystore-backed) and
  drop the `INTERNET` permission check into the demo itself
- Graph/cluster visualization of the vault contents, if time allows
