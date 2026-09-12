# Vault — final architecture, iQOO Hackathon 2026

Decision record for the 30-hour build. Supersedes `implementation.md` (which
described the v0 bench harness) wherever the two disagree. `vault_rag_test/
BUILD_NOTES.md` remains authoritative for *measured facts and traps* — none of
that knowledge is discarded, all of it carries forward.

---

## 0. The thesis, unchanged

The phone is the trusted core. The laptop is the edge.

Your corpus, your index and your encoder live on the phone and never leave it.
The laptop sends a question over a direct device-to-device link and gets back
an answer plus citations — never the corpus. Neither side touches the network
to do it, and on the phone side that is enforced by a missing permission rather
than promised by a policy.

---

## 1. What changed from the v0 bench harness

v0 proved the plumbing: chunk → embed → store → rank, with Claude on the laptop
doing the reasoning and adb standing in for the bridge. That configuration
**does not hold the zero-trust claim** — retrieved chunks leave the device by
design.

The event build closes that loop. Three structural changes:

| | v0 bench harness | Event build |
|---|---|---|
| Reasoning | Claude on the laptop, chunks pasted in by hand | **On-device SLM.** Chunks never leave. |
| Bridge | adb pull / clipboard | **Office Kit** clipboard + file transfer |
| Direction | phone exports chunks *to* laptop | **laptop asks the vault a question; vault answers** |

That third row is the one that matters. Vault stops being an exporter and
becomes a private answer service. The laptop never sees a chunk — only the
answer and its citations. It is a better story, it is the honest end state the
video already describes, and it is what makes the Office Kit bridge load-bearing
instead of decorative.

---

## 2. Component decisions

Each row is locked. The fallback column is the pre-agreed retreat — take it
without debate when the gate in §5 fires.

| Layer | Decision | Why this and not the alternative | Fallback |
|---|---|---|---|
| **Shell** | Flutter, native Android | Already proven end-to-end on hardware; stack is explicitly welcome | — |
| **Ingest** | File picker, plain-text allowlist | `.docx` is zipped XML, `.pdf` needs a real parser; neither is worth hackathon hours | — |
| **Capture** | **Camera → ML Kit OCR → vault** | System camera *intent* needs no `CAMERA` permission; ML Kit **bundled** needs no network. Delivers the video's whiteboard claim *and* is the strongest "creative phone use" beat available | drop the feature whole; never weaken the permission story for it |
| **Chunker** | 256-word windows, 32-word overlap | Word≈token approximation is deliberate and documented — the real WordPiece tokenizer re-runs over each chunk anyway | — |
| **Tokenizer** | Hand-rolled WordPiece | Verified 6/6 against the real HuggingFace tokenizer, ids frozen as goldens | — |
| **Encoder** | MiniLM-L6-v2, **float32** TFLite, int32 inputs | float16 fails to load; dynamic-range quant **returns NaN**. float32 reproduces onnxruntime to cosine 1.00000 | none — this is the only variant that works |
| **Backend** | Measure on iQOO, then pick | XNNPACK was 12× the default CPU kernels on SD695. The iQOO may expose a real NPU delegate — **measure, do not assume** | XNNPACK |
| **Index** | Brute-force cosine over Float32 BLOBs, **vectors pre-normalised at insert** | sqlite-vec is a native extension load into Android's bundled SQLite — a real integration project, and worthless under ~20k chunks. Pre-normalising makes cosine a plain dot product | — |
| **At rest** | **SQLCipher, key in Android Keystore** | Backs a claim the deck already makes. ~1–2 h | ship unencrypted, **and cut the claim from the deck** |
| **Generation** | **Gemma 3 1B IT int4 `.task` via `flutter_gemma`** (MediaPipe) | Closes the trust loop; explicitly rewarded by the event's own "tip to win" | Gemma 3 270M → extractive-only |
| **Bridge** | **Office Kit clipboard + file transfer** | Same serialisation v0 already writes; only the transport swaps | adb (dev only — never demo on it) |
| **Laptop client** | `vault-bridge` watcher (Node or Python) | Watches clipboard / incoming-files folder for the envelope, assembles the prompt, hands back the answer | manual paste |

### Model delivery — the detail that keeps the permission story intact

The app requests **no `INTERNET` permission**, so it cannot download a model.
Two options: bundle as an asset (90 MB MiniLM + ~550 MB Gemma = ~640 MB APK),
or side-load.

**Decision: side-load.** Models are pushed into the app's own external files
directory and loaded by path. The APK stays ~35 MB, and the demo gains a line
worth saying out loud: *even the model arrived over a cable.* At the venue the
push happens over **Office Kit file transfer**, which turns a chore into an
Office Kit scoring moment.

Cost: a wipe or reinstall means re-pushing. Keep both model files on the
laptop and on a USB stick.

---

## 3. The wire protocol

One envelope, versioned, identical over clipboard or file. Office Kit or adb
is just the pipe.

**Laptop → vault:**

```json
{ "v": 1, "type": "query", "id": "q_7f3a", "q": "how does the retry backoff work?", "k": 5, "mode": "answer" }
```

**Vault → laptop:**

```json
{ "v": 1, "type": "answer", "id": "q_7f3a",
  "answer": "Backoff is exponential with full jitter, capped at 30 s …",
  "citations": [ { "file": "retry.dart", "chunk": "c_0031", "score": 0.612 } ],
  "generated_on": "device",
  "model": "gemma-3-1b-it-int4",
  "corpus_bytes": 1103872000,
  "bytes_out": 3841,
  "ms": { "embed": 233, "rank": 4, "generate": 2870 } }
```

`mode: "answer"` returns prose + citations and **no chunk text**. `mode:
"passages"` returns the chunks — keep it for debugging, and say plainly during
the demo that it is the v0 behaviour you replaced.

`corpus_bytes` / `bytes_out` are the hero numbers, **computed live**. The deck's
"1 part in 250,000" stops being a design estimate on a slide and becomes a
counter on screen. That is the single most demo-able thing in the build.

---

## 4. Build order, mapped to the red/green windows

Green = laptop free. Red = phone only, or the laptop *through* Office Kit remote
control. Red windows are therefore scheduled as on-device test, capture, and
rehearsal — which is also when Office Kit usage is being scored.

| Window | | Work | Exit gate |
|---|---|---|---|
| **11:00–14:00** | 🟢 3 h | Talk to an organiser (§6) **first**. Fresh repo. Port core four files from known-good design. Push models, load by path. | Ingest + retrieve running **on the iQOO** |
| **14:00–15:30** | 🔴 1.5 h | Pair Office Kit, map its clipboard + file-transfer folders. Build the 10-doc / 10-question ground-truth corpus on the phone. | Top-1 accuracy measured on 10 known-answer questions |
| **15:30–16:30** | 🟢 1 h | Backend bake-off on the iQOO: XNNPACK vs GPU vs NNAPI. Record the table. | A measured ms/embedding for this phone |
| **16:30–19:00** | 🔴 2.5 h | Camera → OCR → ingest (code via Office Kit remote). Rehearse eval round 1. | Whiteboard photo becomes a retrievable chunk |
| **19:00–22:00** | 🟢 3 h | On-device generation. Streaming answer with citations. | Vault answers a question with no laptop involved |
| **22:00–01:00** | 🔴 3 h | `vault-bridge` laptop client. Full loop over Office Kit. | Laptop asks → vault answers → laptop receives, both offline |
| **01:00–06:30** | 🟢 5.5 h | UI pass. SQLCipher. Trust-boundary screen. Release APK. **Freeze 05:30.** | Release APK installed, `aapt2` clean, demo rehearsed twice |
| **06:30–09:00** | 🔴 2.5 h | Rehearse. Update deck slide 09 to measured numbers. Eval round 2. | Deck numbers match reality exactly |

**Freeze rules.** No new dependency after 02:00 — every package can inject a
permission and the entire pitch is that none are requested. Re-run `aapt2 dump
permissions` after *each* dependency is added, not once at the end.

---

## 5. Kill gates

Pre-agreed, so nobody argues at 03:00.

| If, by | this isn't true | then |
|---|---|---|
| 16:30 | retrieval works on the iQOO | stop adding features; the rest of the build is worthless without it |
| 16:30 | a backend beats 500 ms/embedding | take XNNPACK, stop tuning, never mention the NPU |
| 22:00 | Gemma answers *anything* | drop to 270M; if that fails by 23:00, ship extractive-only and re-cut the pitch around retrieval + zero permissions |
| 01:00 | Office Kit carries the envelope | demo the loop on adb, say openly it is a stand-in, take the 10% hit |
| 03:00 | SQLCipher is in and green | ship unencrypted **and delete the encryption claim from the deck** |
| 05:30 | — | freeze regardless of state; rehearsal beats one more feature |

The extractive-only path always works and is already proven. **Build the demo
so it never depends on the LLM loading** — generation is a layer on top of a
working retrieval demo, behind a toggle, not a load-bearing step.

---

## 6. Provenance — handle this in the first 30 minutes

The build rules say: *"Original work only: code written during the event
window. No shipping a pre-built product,"* and *"Organisers may verify a project
was built inside the event window."*

`vault_rag_test` is a complete working prototype committed on **8 September**,
four days before the window opened. Carrying it in as-is is squarely what that
rule prohibits, and the single git commit makes the date trivially checkable.

**Do both of these, in this order:**

1. **Tell an organiser at check-in.** Say there was a pre-event spike, describe
   it, and ask how they want it handled. A direct contact is shared at check-in
   and the query desk is open through close. Asked up front this is a non-issue;
   discovered in Q&A it is a disqualification conversation.

2. **Rebuild in the window.** Fresh repo, first commit timestamped after the
   start. This costs far less than it sounds — roughly 1,250 lines where every
   trap is already documented, and you are rewriting most of it anyway for
   on-device generation, encryption, capture and a real UI. Budget 3 hours.

What legitimately carries across, and why:

- **The knowledge in `BUILD_NOTES.md`.** Knowing that int64 tensors get
  byte-swapped is not code. It is the reason the rebuild takes 3 hours instead
  of 30.
- **The converted `.tflite`.** A build artifact derived from an open-source
  model (`sentence-transformers/all-MiniLM-L6-v2`), regenerable from
  `modelprep/` in minutes. Same category as any other downloaded dependency —
  attribute it.
- **The deck and the video.** Pitch assets, not product.

Keep `vault_rag_test/` as the cited bench harness it is. Do not delete it and
do not present it as this weekend's work.

---

## 7. Claims ledger

Every number on a slide traces to something measured, or it comes off the slide.

**Safe to claim — after re-measuring on the iQOO:**

- Zero permissions in the release APK (`aapt2 dump permissions` + on-device
  `dumpsys`). **Re-verify on the iQOO** — this is the strongest claim in the
  deck and it must be true of the phone in the judge's hand.
- Query embedding latency, model load time — re-measure; SD695 numbers do not
  transfer to a flagship.
- Cosine 1.00000 against an onnxruntime reference.
- Corpus bytes vs bytes crossed — live from the running app.

**Do not claim unless measured at the venue:**

- Anything about the NPU. On SD695 that path never materialised, and the 12× win
  came from XNNPACK on CPU. Upgrade the claim only with a number next to it.
- Any latency figure carried over from the realme.

**Coming off the deck and the video regardless:**

- **sqlite-vec.** Not being built, and brute force is the correct call at this
  corpus size. Replace the claim with the threshold — *"brute force to ~20k
  chunks, and here is where that stops being right."* Judges reward the reasoning
  over the checkbox.
- **Encryption at rest**, if §5's 03:00 gate fires.

Slide 09 already carries the divergence table. Keep that slide honest and it
inoculates the whole pitch — a gap you state is engineering judgement; a gap a
judge finds is a credibility problem.

---

## 8. UI

Tokens come from `vault_video/src/theme.ts` verbatim, so app, deck and video are
one system by construction. Ground `#0F172A` (never pure black — it smears on
OLED), green `#22C55E` means on-device, red `#DC2626` means it left the device,
and **nothing else in the palette is saturated** so those two always read as
meaning rather than decoration. Inter for type, expo-out `cubic-bezier(0.16, 1,
0.3, 1)` for motion.

Put the palette in a single `ThemeData` and pull every colour through
`Theme.of(context)` — no `Color(0xFF…)` scattered at call sites.

Four screens, in build priority:

1. **Vault** — corpus list, ingest, capture button. What the judge sees first.
2. **Ask** — question in, streaming answer out, citations tappable to the source
   chunk.
3. **Trust** — the instrument. Permissions read live from `PackageManager`
   rendered as a list that is *empty*, next to the bytes-crossed counter and the
   corpus size. This screen is the pitch.
4. **Bridge** — Office Kit status, last request, what crossed.

Screen 3 is worth more than any polish elsewhere. A judge can verify it in
seconds on the device in their hand, and verification is the entire novelty
claim.

---

## 9. Risk register

| Risk | Signal | Mitigation |
|---|---|---|
| A dependency injects a permission | `aapt2` shows a new line | `tools:node="remove"` in the manifest — already the established pattern for the three injected storage/phone-state permissions |
| ML Kit pulls the Play-Services variant | `INTERNET` appears | Force the **bundled** artifact (`com.google.mlkit:text-recognition`); if it cannot be forced, cut capture |
| `image_picker` requires CAMERA at runtime | Runtime denial dialog | Only true if `CAMERA` is *declared*; keep it out of the manifest and remove it if a dependency merges it in |
| SQLCipher vs `sqlite3_flutter_libs` conflict | Link or symbol errors | Use one, never both — swap the dependency, do not add it |
| Gemma prefill too slow on ~800 tokens | >8 s to first token | Drop k to 3, cap chunk length, stream so latency reads as progress; then 270M |
| 90 MB float32 encoder bloats install | Slow push, large APK | Side-loading already solves it. Sub-30 MB quantisation is a *post-event* task — the one variant that shrinks it returns NaN |
| Demo phone wiped / model missing | Vault empty at pitch | Models on the laptop **and** a USB stick; re-push is ~2 min; rehearse the cold-start path once |
| Judged on a debug build | `INTERNET` present | Flutter injects `INTERNET` into debug manifests for hot reload. **Demo the release APK only.** Iterate on debug, pitch on release |

---

## 10. Where the score actually is

Weights: end product 30 · novelty 20 · creative phone use 15 · technical depth
15 · Office Kit 10 · demo 10.

The technical depth is already banked — `BUILD_NOTES.md` is stronger evidence
than most teams will have. Novelty is strong and needs no new code. The gaps are
**end product** (v0 is a debug harness — the UI pass is the single highest-value
work in the 30 hours), **Office Kit** (currently zero), and **creative phone use**
(camera capture and on-device generation are the answer).

Build in that order when time forces a choice.
