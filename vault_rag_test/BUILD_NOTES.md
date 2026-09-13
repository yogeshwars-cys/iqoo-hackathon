# Engineering notes

What was built after 12 Sep 2026, in order, with the decisions and traps
worth knowing before changing the code. Each section ends with what was
verified at the time and what was not.

Later sections supersede earlier ones where they disagree. In particular, the
LAN bridge became the `lan` flavor (§v6), and Gemma became one of two
reasoner runtimes (§v4, §v7).

| § | Date | Topic |
|---|---|---|
| v2 | 12 Sep | co-processor engine, telemetry, benchmarks |
| v3 | 12 Sep | two models: MiniLM encodes, a reasoner writes capsules |
| v4 | 13 Sep | llama.cpp GGUF reasoning path |
| v5 | 13 Sep | VaultLink over the clipboard, synthetic sensitive-doc eval |
| v6 | 13 Sep | hardware-backed encryption, signed capsules, VAULTLINK/2, air-gap flavor |
| v7 | 13 Sep | one reasoner, QNN HTP embeddings, compute leases, pipeline benchmark |
| v8 | 13 Sep | first iQOO 15 sessions: what the device taught us |
| v9 | 13 Sep | Material 3 UI and screenshot harness |

---

# v2 — co-processor, telemetry, benchmarks

12 Sep 2026. The retrieval pipeline itself did not change; what changed is
who can call it, and what the app can tell you about the hardware running it.

## 1. The pipeline had to leave the widget

The interpreter, the database handle and the chunker lived inside
`_VaultHomePageState`. Fine with one caller. The bridge is a second caller
that runs with no widget mounted, so the pipeline moved to
`core/vault_engine.dart`.

The forcing function was not tidiness, it was **reentrancy**. A TFLite
interpreter cannot service two overlapping `embed` calls; the failure is
native, so on a bad day it is a SIGSEGV with no Dart stack. A bridge
indexing a pushed document while the user taps Search locally is not a
hypothetical race — it is the normal case once both exist.

`VaultEngine._serialized` chains every interpreter-touching call onto a
single promise. Callers queue rather than fail, which matters because a
socket peer has no user to re-tap the button.

## 2. What is actually measurable on this hardware

The ask was CPU, GPU and NPU utilisation charts. Two of the three are
straightforward; the third is not, and the honest version of it is more
useful than the plausible one.

| lane | outcome | why |
|---|---|---|
| CPU | real | `/proc/stat` deltas, `/proc/self/stat` as fallback (always readable) |
| GPU | real when policy allows | `/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage`, then `devfreq/gpu_load`, then `gpubusy` |
| NPU | **no counter exists** | fastrpc stats are under `/sys/kernel/debug` — root only |

There is no public NPU busy counter on production Android. Some devices
expose a compute-DSP devfreq node, which gives **clock frequency** — a proxy
for load, not load, since a governor can hold a high clock while idle.

So `Probe` carries a `ProbeKind`: `measured`, `proxy`, `derived`,
`unavailable`. The chart breaks its line at a gap instead of plotting zero,
proxy lanes draw at reduced opacity, and unavailable lanes are greyed with
the reason printed underneath.

This matters more than it looks. A flat NPU lane reading zero would be read
as "the NPU is idle". The true statement is "nothing here can tell you what
the NPU is doing" — and on this device the NPU genuinely is idle, because
LiteRT 1.4 had no working delegate for it on that phone. (The QNN HTP path
that changes this is §v7.)

A fourth lane, **inference duty** (share of wall time inside the
interpreter), is derived from `lastNativeInferenceDurationMicroSeconds`. It
is always available and is the lane that actually answers "is the
accelerator working", as distinct from "is the phone busy".

### The GPU counter that resets when you read it

`gpubusy` returns `busy total` accumulated *since the last read*, and reading
clears it. If anything else on the device samples it too, each reader sees
only part of the interval. It is tried last for that reason — but it is the
only node present on older KGSL, so it stays in the chain.

## 3. Benchmarks report percentiles, not a mean

A single "233 ms per embedding" run is fine as a sanity check; as a
benchmark it is not, because a phone runs the same
workload in at least three regimes: cold governor (slow), warmed (fast), and
thermally limited (slow again, for an unrelated reason). A mean describes
none of them.

`BenchmarkRunner` discards 3 warm-ups, times 20 runs off the interpreter's
own clock, and reports min/median/p90/max/σ. Percentiles are nearest-rank —
interpolating between two samples invents a measurement nobody took, which
at n=20 is the wrong call.

Throttling is surfaced explicitly via `PowerManager.getCurrentThermalStatus()`
through a method channel, because there is no sysfs equivalent an app can
read and a benchmark that cannot say "the clocks were being held down" is
close to meaningless.

The optional backend sweep builds a **separate** `MiniLMEmbeddingService`
per backend. Reconfiguring the live one would break any bridge query in
flight, and — given `EmbeddingBackend`'s warning about native crashes — a
failed delegate build must not be able to take the working interpreter with
it.

## 4. The permission count went from zero to one

`INTERNET`, for the bridge. Nothing else changed; `aapt2 dump permissions`
on the release APK prints `INTERNET` plus the self-scoped signature
permission AndroidX injects, and nothing more.

This retired the strongest version of the earlier claim. "It cannot exfiltrate
anything because the OS never granted the ability" is no longer true, and
the README now says so rather than quietly keeping the old line. What
replaces it: the bridge is opt-in per session, starts disconnected, is the
only code path that opens a socket, and the screen that enables it states
plainly that retrieved chunks leave the device once it is up.

Deliberately **not** added: `android:usesCleartextTraffic="true"`. `ws://` to
a LAN address is cleartext, but that attribute governs the platform HTTP
stack and `dart:io`'s WebSocket uses the Dart VM's own sockets, which never
consult it. Setting it would weaken the declared posture for every future
component while doing nothing for this one. Android's network security
config cannot express "private ranges only" either — it keys on domains, not
CIDR — so there is no narrower flag worth having.

## 5. Zero new Flutter dependencies

The bridge uses `dart:io`'s built-in `WebSocket`, not
`package:web_socket_channel`. The chart is `CustomPaint`, not a charting
package. Given how much of this file is about dependency resolution going
wrong, that was worth the extra hundred lines — and the painter is the
better choice anyway, since it can render a *gap* for a missing sample where
most chart libraries would interpolate through it or draw a zero.

## 6. Verified this pass

- `flutter analyze` — clean.
- `flutter test` — 38 passing, including new coverage for the extractive
  answer synthesizer and the telemetry maths (percentiles, meter draining,
  probe availability). No device or model needed.
- `flutter build apk --release` — succeeds; 159 MB (the model and four ABIs
  of native libs dominate).
- `aapt2 dump permissions` — `INTERNET` only, as above.
- Wire protocol end-to-end against a simulated phone: status, index and
  query all round-trip correctly, the offline path returns a clean 503, and
  a mid-session disconnect fails in-flight requests immediately rather than
  making the caller wait out its own timeout.

### Still not verified

- Anything in §5 above on the actual handset. All v2 verification was done
  on the host and against a simulated phone; the sysfs probe results, the
  chart under real load, and the benchmark numbers all need a device run.
- Which of the GPU/NPU sysfs nodes OriginOS 6 actually permits. The code
  degrades cleanly either way, but which branch it takes is unknown until
  it runs there.
- Retrieval quality against ground truth — the thing that finally matters.
  (Measured in §v5 and §v8.)

---

# v3 — Gemma for reasoning, MiniLM for encoding

Two models now, with a strict division: MiniLM encodes (every ingest, every
query, ~230 ms) and Gemma 2B int4 reasons over what retrieval already found
(once per query, seconds). Gemma never sees anything the retriever did not
hand it, and the app works completely without it.

## 1. The format problem, which is the one that bites first

"Gemma 2B int4" names a set of weights, not a file format. The same weights
ship as:

| container | magic | runnable here |
|---|---|---|
| MediaPipe `.task` | `PK\x03\x04` (a zip) | yes |
| MediaPipe `.bin` | `TFL3` at offset 4 | yes |
| GGUF (llama.cpp) | `GGUF` at offset 0 | no |
| safetensors | u64 length, then `{` | no |

`.bin` is used by three different ecosystems, so the extension proves
nothing — and guessing wrong is not a Dart exception. A wrong container
reaches native code and aborts the process, which no `try`/`catch` can
intercept.

So `core/llm/model_probe.dart` reads sixteen bytes and identifies the
container before anything tries to load it. When it recognises nothing it
reports the first bytes in hex, because the usual cause is a truncated
download or an HTML error page saved under a `.task` name, and that is
visible at a glance from the hex. It also flags a supported container that
is implausibly small: a 2B int4 model is 1.2–1.5 GB, so anything under a few
hundred MB is a partial download whatever its magic says.

This is all pure Dart. It answers "is this the right file" in milliseconds
and sixteen bytes, where the alternative is thirty seconds of loading
followed by a crash.

## 2. MediaPipe over a method channel, not a plugin

`com.google.mediapipe:tasks-genai`, driven from about 120 lines of Kotlin in
`LlmChannel.kt`. No pub package.

Given how much of this file is about dependency resolution going wrong, one
Gradle coordinate is a smaller surface than a transitive Dart dependency
tree — and it means the generation parameters are ours rather than whatever
a wrapper chose to expose. The app already owned a method channel for device
facts, so the pattern was established.

Threading matters here more than for the device channel.
`createFromOptions` loads over a gigabyte from storage and `generateResponse`
blocks for seconds; both run on a single-thread executor. Blocking the
platform thread would stop Flutter servicing *any* channel — no progress
indicator, no cancel, nothing — for the whole load. A single thread rather
than a pool because the session is not safe to drive concurrently, which is
the same constraint the TFLite interpreter has and is handled the same way.

`catch (e: Throwable)`, not `Exception`: a failed GPU init surfaces as an
`UnsatisfiedLinkError` or another `Error` subclass often enough that
catching `Exception` alone lets the process die on exactly the case the Dart
side is designed to recover from by retrying on CPU.

### Two R8 failures, in sequence

Adding the AAR broke `flutter build apk --release` twice, each time with a
different missing-class set:

```
ERROR: R8: Missing class com.google.auto.value.AutoValue$Builder
ERROR: R8: Missing class com.google.protobuf.Internal$ProtoMethodMayReturnNull
```

then, after those were suppressed:

```
ERROR: R8: Missing class com.google.mediapipe.framework.image.MPImage
```

Neither set is genuinely missing. AutoValue is a compile-time annotation
processor and the protobuf `Internal$*` types are javac-only markers, so
both are referenced by bytecode that never executes. The image classes live
in `tasks-vision`, which this app does not depend on because it only calls
`generateResponse` with text — pulling in a vision library to satisfy a
reference on a dead code path would add tens of megabytes to an APK that is
already large.

`android/app/proguard-rules.pro` explains all three and also *keeps*
`com.google.mediapipe.**`, because MediaPipe resolves much of its graph by
reflection and reaches Java objects from JNI. Without the keep, R8 strips
classes the native layer then fails to find — and it fails at model-load
time, not build time, which is a far worse place to discover it.

## 3. The capsule, and why the parser is so forgiving

Generation emits a fixed-schema JSON object rather than prose. The consumer
is a program — an MCP client, `vault-query`, a script — and a capsule is
addressable in a way a paragraph is not.

`capsule_prompt.dart` is the "output generator": a versioned instruction
template plus one worked example. Four things in it are load-bearing rather
than decorative:

1. **Gemma's own turn markers.** `<start_of_turn>` / `<end_of_turn>` are
   what Gemma 2 instruct was trained on. Omitting them costs more drift and
   repetition than any wording change. Gemma has no system role, so the
   instructions live inside the first user turn.
2. **One worked example.** A schema description alone gets roughly the right
   keys with the wrong shapes — a string where a list belongs, most often.
   An example fixes shape far better than adjectives about shape.
3. **Field order is priority order.** `answer` and `confidence` come first,
   so a truncation at the token limit loses `caveats`.
4. **An explicit permission to refuse.** Given a corpus that does not contain
   the answer, an unprompted 2B model confabulates one with total
   confidence. Stating that "the context does not say" is a correct and
   expected answer is the single highest-value line in the file.

And then the parser assumes all of that will sometimes fail anyway, because
a 2B model at int4 is not a JSON API. `capsule_test.dart` covers the shapes
it actually emits: fenced blocks, chatty preambles, trailing commas, smart
quotes, unquoted keys, Python `True`/`None`, the same object twice, and
truncation mid-object or mid-string.

Two real bugs came out of writing those tests rather than out of theory:

- **`String.replaceAll` does not expand `$1`.** The trailing-comma repair
  used `replaceAll(RegExp(...), r'$1')` and silently substituted the literal
  text `$1`, producing worse JSON than it was given. Only
  `replaceAllMapped` does backreferences.
- **The truncation recovery counted braces and ignored brackets.** Closing
  `{"key_facts": [` with `}` yields something still unparseable, and
  `key_facts` is the longest field, so it is the most likely thing to be
  open when the limit hits. It now tracks a stack of `{` and `[`, drops a
  dangling trailing element (a bare comma, a key with no value, a key with
  no colon), and closes in reverse order.

Every repair is syntactic. The parser never invents content — when nothing
is recoverable the capsule falls back to retrieval alone and records why in
`generation.parse_error`.

### Verification, not trust

Each `key_facts` entry must carry a `verbatim` span, which is then checked
against the retrieved text by substring, after normalising whitespace (the
model reflows quotes constantly, and a fact should not be called unverified
over a line break). `verified: false` means the model produced a quote that
does not occur in the source.

That is a mechanical check, not a judgement, which is exactly why it is
worth having: it means one thing and can be trusted to mean it.

### Generation never gates retrieval

`ContextCapsule.fromRetrievalOnly` is a complete, schema-valid capsule with
`generation.ran: false` and the extractive line as `answer`. Every failure
path lands there: no model loaded, wrong format, load failed, generation
threw, output unparseable, output parsed but empty. Retrieval is the
product; generation is an enhancement on top of it.

## 4. `ask` is a separate action from `search`

Not a flag on the existing one. Retrieval answers in ~250 ms; generation
takes 5–40 s depending on backend and context length. Folding both into one
action means either a fast path carrying a five-minute timeout or a slow
path aborting at twenty seconds. `/api/ask` and `/api/query` are separate
endpoints with separate timeouts for the same reason.

`ask` is also deliberately not wrapped in the engine's serialisation lock:
it calls `search`, which takes the lock itself, and nesting the two would
deadlock on the first query. Generation has its own queue inside
`LlmRuntime`, so the two stages serialise independently and an embedding can
start while a previous query is still being written up.

## 5. Two commands, one client

`vault-embed` and `vault-query`, as console scripts from
`bridge/pyproject.toml`, with `.cmd`/POSIX shims for use without installing.
Both are stdlib-only — `pip install requests` is a step between someone and
a working demo.

`query.py` is now a shim that forwards to them and says so. Two
implementations of the same client is how they drift apart.

`vault-query` writes human output to stderr and the capsule to stdout, so
`--json` redirects cleanly.

## 6. Verified this pass

- `flutter analyze` — clean.
- `flutter test` — 70 passing, up from 38. The new ones cover the capsule
  parser, the fallback paths, fact verification, the prompt budget, and the
  format probe (including a GGUF file renamed to `.task`, which must still
  be refused).
- `flutter build apk --release` — succeeds after the two R8 fixes above.
  191.6 MB universal; `--split-per-abi` gives 123.2 MB for arm64-v8a, which
  is the one worth installing.
- `aapt2 dump permissions` — still `INTERNET` only. MediaPipe added no
  permission.
- `libllm_inference_engine_jni.so` present for all three ABIs in the release
  APK.
- Desktop half end-to-end against a simulated phone speaking the v2
  protocol: `vault-embed` (single, recursive, dry-run), `vault-query` with
  and without generation, `--json` piped into a parser, `--status` showing
  both models, and `pip install -e .` producing working `vault-embed.exe` /
  `vault-query.exe`.

### Still not verified

- **Everything about Gemma on the actual handset.** No real model has been
  loaded. Whether MediaPipe's GPU backend initialises on an Adreno 619 with
  6 GB, what a real generation costs in seconds and watts, and — most
  importantly — how often the capsule prompt actually produces clean JSON
  from a real 2B int4 model are all unknown. The parser is built for the
  failure modes; the *rate* of those failures is a device measurement
  nobody has taken yet.
- Memory headroom. A 1.3 GB model plus the TFLite interpreter plus Flutter
  on a 6 GB phone is tight, and the GPU backend needs contiguous memory. The
  GPU→CPU fallback exists for this and has never been exercised for real.
- Which sysfs nodes OriginOS 6 permits (carried over from v2).
- Retrieval quality against ground truth — still open, still the only thing
  that finally matters.

---

# v4 — llama.cpp GGUF reasoning path

- **Engine:** llama.cpp is a pinned submodule
  (`android/app/src/main/cpp/third_party/llama.cpp`), built from source for
  arm64-v8a and driven over JNI with `RegisterNatives` (`LlamaEngine.kt`,
  `LlamaChannel.kt`, `llama_runtime.dart`). It runs Qwen3, SmolLM2 or Gemma
  GGUF models on CPU, Adreno GPU (OpenCL) or a named NPU device.
- **Prompts are not wrapped** by the app. Each model's own chat template
  applies, because a Gemma-style turn wrapper around a Qwen3 prompt degrades
  its output.
- **Generate-time crash:** the prompt overflowed the session's KV budget. The
  prompt is now bounded by that budget before decoding.
- **Dispose race:** `LlmRuntime` could be disposed mid-load. Fixed.
- **Benchmarks:** CPU/GPU/NPU reports added. `bridge/corpus/` gained a
  four-document ground-truth RAG eval set.

# v5 — VaultLink and the sensitive-document eval

- **VaultLink** (`lib/link/`, Link tab): the laptop asks over the phone's own
  clipboard, which Office Kit mirrors. There is no socket, no LAN address
  and no new permission.
  - A foreground timer polls for a request frame and runs it through the
    same `VaultEngine.ask()` the bridge uses.
  - Only requests carry `op` and only replies carry `status`, which is how
    each side tells a request from its own echoed reply.
  - Sessions are foreground-only because Android refuses background
    clipboard reads.
- **`bridge/testdata/`:**
  - `gen_sensitive_doc.py`: a randomized, invalid-by-construction
    "confidential" document with 14 ground-truth questions.
  - `vaultlink.py`, `ask_one.py`, `officekit_clip.py`: three ways to run the
    loop.
- **Finding (seed 413172):** two reproducible generation bugs, a same-role /
  same-city name mix-up and a one-character credential corruption. The
  extractive floor got both right. Both reproduced identically over the
  bridge and over VaultLink, so the bug is in the reasoner, not the
  transport.

# v6 — encryption, signed capsules, VAULTLINK/2

The full threat model is in [`../SECURITY.md`](../SECURITY.md). The decisions:

- **Keys:** AndroidKeyStore only (`KeystoreChannel.kt`).
  - AES-256-GCM `vault_tee_aes_master` protects chunk text; ECDSA P-256
    `vault_tee_attestation` signs capsules.
  - StrongBox is attempted, with TEE fallback, and the level is reported from
    `KeyInfo`.
  - The host test double can never be selected on Android or in release.
    Everything else fails closed.
- **Canonical signature** `vault-capsule-sig/v1` uses length-prefixed
  fields. A pipe-joined string was rejected: it is non-injective and would
  have left the quoted evidence unsigned. A cross-language vector is asserted
  by both the Dart and Python suites.
- **Storage schema v2** stores `chunks.content_cipher`. The v1 migration
  encrypts before touching the file, then runs `secure_delete` + `VACUUM`.
- **Ranking** uses a contiguous `Float32List` matrix with cached norms and a
  bounded top-K heap. There is no SQLite and no decryption while ranking;
  only the winners are decrypted, in one batch.
- **VAULTLINK/2:** pairing code → HMAC-SHA256 key schedule → AES-GCM frames.
  - Keys are direction-separated, with a ±5 min clock window and a replay
    cache.
  - `enroll` pins the signing key on the laptop.
  - v1 survives only behind an explicit toggle.
- **Clipboard residue:** 20 s on both ends, cleared only if the contents are
  unchanged.
- **Flavors:** `airgap` (the default; `src/airgapRelease` strips network
  permissions) and `lan`.
- **Verified:** 213 Flutter tests, 66 pytest, JCA ↔ Python interop, and
  `aapt2` on both flavors.

# v7 — one reasoner, QNN HTP, leases, pipeline benchmark

- **One reasoner** (`reasoner_coordinator.dart`):
  - A successful load of either runtime unloads the other; a failed load
    changes nothing. Activations are serialised.
  - `activeReasoner` is persisted. `ask()` routes only to it, and startup
    auto-loads only it.
- **QNN HTP for MiniLM only.** Details are in [`NPU_QNN.md`](NPU_QNN.md).
  - Maven `qnn-runtime` / `qnn-litert-delegate` 2.50.0 with V81 + V79 skels,
    `useLegacyPackaging`, and `<uses-native-library>` for `libcdsprpc.so` /
    `libOpenCL.so`.
  - A C shim over the TFLite external-delegate plugin ABI creates the
    delegate.
  - The delegate is accepted only after coverage, equivalence and latency
    gates.
  - `modelprep/export_htp.py` re-exports MiniLM in an NPU-friendly shape:
    664 → 305 nodes, no SHAPE or int64, and an FP16-safe mask
    `(1 - mask) * -1e4`. Cosine against the original is 1.000000.
- **Telemetry leases:** one lease per hardware per operation replaces a
  single "active hardware" notion. NPU and GPU are shown independently, with
  their overlap measured from lease intervals.
- **Pipeline benchmark:**
  - MiniLM P50/P95, CPU vector search, and retrieval-only reported on its own.
  - Prefill/decode/tok/s and indexing during generation.
  - RSS, thermal before/after, the QNN verdict and llama.cpp backend status.
- **Verified:** 241 Flutter tests; release APK built.

# v8 — first iQOO 15 sessions

Run over VaultLink (legacy v1 mode) against the synthetic sensitive document:

| Measured | Result |
|---|---|
| SoC / keys | SM8850; AES and ECDSA keys at StrongBox level; valid signatures |
| Encoder | MiniLM on XNNPACK: 58 ms load benchmark, 113–137 ms in-query |
| Retrieval | ≈2.0 s, dominated by StrongBox decryption |
| Reasoner | SmolLM2-1.7B Q4_K_M, llama.cpp GPU: ≈10.5 tok/s end to end (163–198 tokens in 15.7–18.2 s) |
| NPU | first MiniLM export failed with "Unable to create interpreter"; fixed by `export_htp.py`, not yet re-run |
| Answers | 2 of 5 correct; 3 refused by the 0.82 / 0.50 similarity gates |

What it taught us:

- **The gates were wrong.** Correct passages scored 0.30–0.45 under MiniLM,
  so the gates refused answerable questions and bypassed the reasoner.
  - They were removed: a loaded reasoner now answers every query that has
    retrieved context.
  - `gating_path` is now `llm_synthesized | extractive_fallback` and stays
    signed. Tests: 236.
- **Chunks overflow the encoder.** 256-word chunks run about 400 tokens, so
  MiniLM's 254-token window never sees 35–38% of each chunk. Next:
  token-aware chunks (≤ ~200 tokens, ~40 overlap) and a re-index.
- **Latency is the keystore.** Next: move the chunk key to the TEE and keep
  the signing key in StrongBox.

# v9 — Material 3 UI

- **Design:** rebuilt on Material 3 as Google's *Now in Android* uses it.
  - A tonal green scheme generated with `material_color_utilities`, and the
    NiA type scale limited to weights 400/500/700.
  - Tonal cards instead of bordered boxes, plus new `IconBadge`, `VaultTag`,
    `Notice` and `InfoRow` widgets.
  - 48 dp touch targets, filled-when-selected navigation icons, and support
    for reduced motion.
- **Model tab:** reorganised around the one-reasoner invariant: active
  reasoner, then pipeline, then loaders.
- **Air-gap Bridge tab:** now a proper page (`system_screens.dart`) that
  points to VaultLink.
- **Screenshot harness:** `test/screenshots/screens_test.dart` renders every
  tab at 412×915 dp with real Roboto fonts, since no phone is attached to the
  build machine:
  `VAULT_SCREENSHOTS=1 flutter test test/screenshots --update-goldens`.
  Weight-600 text renders as boxes there (there's no matching font file),
  which is one more reason the theme uses only 400/500/700.
