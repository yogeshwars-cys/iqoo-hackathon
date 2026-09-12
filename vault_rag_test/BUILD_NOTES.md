# Build notes — what actually happened

Companion to `../implementation.md`. That document described the plan; this
one records where reality differed, what was verified, and what is still
untested. Read the **Before you trust a result** section before drawing any
conclusion from the app.

---

## Toolchain installed for this build

Nothing Flutter-related existed on the machine beforehand, so:

| Component | Version | Location |
|---|---|---|
| Flutter SDK | 3.47.2 (stable), Dart 3.13.2 | `D:\flutter` |
| Android SDK platform | android-36 + build-tools 36.0.0 | `%LOCALAPPDATA%\Android\Sdk` |
| Android NDK | r28c (pulled automatically by Gradle) | `%LOCALAPPDATA%\Android\Sdk\ndk` |
| Model-prep venv | Python 3.13, TF 2.21, onnx2tf, onnxruntime | `D:\modelprep\.venv` |

`flutter` is **not** on the system PATH. Either prepend it per shell:

```powershell
$env:PATH = "D:\flutter\bin;$env:LOCALAPPDATA\Android\Sdk\platform-tools;$env:PATH"
```

or add `D:\flutter\bin` to PATH permanently.

---

## Deviations from implementation.md

### 1. The jniLibs install step is gone

implementation.md step 5 says to run `tflite_flutter`'s native-binary install
script. That was correct for 0.10.x. **0.12.1 pulls the native libraries from
Maven itself** (`com.google.ai.edge.litert:litert:1.4.0`), so there is no
script to run and no `jniLibs/` to populate. The "#1 cause of works-on-my-
machine" failure this step guarded against no longer applies.

The plugin declares `compileSdk 36`, which is why `android/app/build.gradle.kts`
pins `compileSdk = 36` instead of inheriting `flutter.compileSdkVersion`.

### 2. Dependencies moved forward

Supported upload formats are enforced in `main.dart` (`_allowedExtensions`):
`txt md csv json yaml yml html css dart py js ts java kt c h cpp rs go sh`.
Plain text only — `.docx` is zipped XML and `.pdf` needs a real parser, so
both are rejected with `Skipped — .docx not allowed`. Adding `.docx` is about
40 lines with `archive` + `xml` if it becomes necessary.

| Package | Plan | Used | Why |
|---|---|---|---|
| `tflite_flutter` | ^0.10.4 | ^0.12.1 | 0.10.x predates the Maven native-lib change and does not build against current AGP |
| `file_picker` | ^8.0.0 | ^12.2.0 | 8.x is incompatible with Flutter 3.47 |
| `path_provider` | ^2.1.3 | ^2.1.6 | — |
| `sqlite3` | ^2.4.0 | ^2.9.0 | stayed on 2.x deliberately, see below |
| `sqlite3_flutter_libs` | ^0.5.20 | ^0.5.42 | — |

`sqlite3` 3.x is published and `sqlite3_flutter_libs` is now marked EOL, but
3.x replaces that plugin with **Dart build hooks**, which are still
experimental for Flutter Android. Staying on 2.x + the "EOL" plugin is the
boring, working combination. Revisit after the hackathon, not before.

`file_picker` 12 is a breaking API change: `FilePicker.platform.pickFiles()`
became a static `FilePicker.pickFiles()`, and `FilePickerResult` is gone —
it returns `List<PlatformFile>` directly, empty on cancel.

### 3. The file picker no longer filters by extension

The original code passed `FileType.custom` with an extension allowlist.
On Android that filter is applied as **MIME types**, and `.dart`, `.kt`, `.rs`
and friends have no registered MIME type — so the picker would grey out
exactly the files this test exists to ingest. The picker now accepts anything
and `main.dart` enforces `_allowedExtensions` itself, marking rejects as
`Skipped — .xyz not allowed`.

### 4. `embedding_service.dart` was rewritten

Not a redesign — the same TFLite-wrapper shape — but it now refuses to assume
three things that each silently produced a *plausible but wrong* vector
during model prep. All three are documented in the file header. Briefly:

- **Input order** is resolved by tensor **name**, not position. Our own export
  reports its signature as `(attention_mask, input_ids, token_type_ids)` while
  the tensor indices are `(input_ids, attention_mask, token_type_ids)`.
  `runForMultipleInputs` feeds `inputs[i]` to tensor `i`, so trusting the
  signature order would have embedded the attention mask as if it were tokens.
- **Input dtype must be int32** — see the next section, this one is nasty.
- **The model is smoke-tested at load**, and NNAPI falls back to CPU
  automatically if the accelerated path throws *or* returns garbage.

`sequenceLength` and `embeddingDim` are now read from the model instead of
being constructor constants, and the `[1, dim]` pre-pooled output case
implementation.md warned about is handled automatically.

### 5. Three Gradle fixes were needed to build at all

Flutter 3.47 scaffolds with AGP 9.1 / Gradle 9.3.1 / Kotlin 2.4, which are
stricter than what these plugins were written against. All three fixes are
commented at their site.

- **`android/build.gradle.kts` — JVM target normalisation.** `tflite_flutter`
  0.12.1 declares Java 11 while its Kotlin tasks inherit the JDK running
  Gradle (21), and AGP 9 fails the build on the mismatch. Two non-obvious
  details: the check reads AGP's `android { compileOptions { } }` extension,
  so setting `JavaCompile.sourceCompatibility` is not enough; and the override
  must run *after* the plugin's own build script, but `afterEvaluate` throws
  because the pre-existing `evaluationDependsOn(":app")` has already evaluated
  some subprojects — hence the `if (state.executed)` guard.
- **`android/gradle.properties` — `kotlin.incremental=false`.** Kotlin's
  incremental compiler could not close its memory-mapped `.tab` caches here,
  failing `:android_file_picker:compileDebugKotlin` every run.
- **`android/app/build.gradle.kts` — `compileSdk = 36`**, pinned rather than
  inherited, because the plugin declares 36 and a library cannot be compiled
  against a newer SDK than its consumer. (Flutter 3.47's default is also 36,
  so this is currently belt-and-braces — but it stops a future Flutter
  default from silently breaking the build.)

The first Gradle run also downloads NDK r28c (~1.5 GB) and CMake 3.22.1
automatically. That is why the first build took ~35 minutes and later ones
take ~35 s (debug) / ~2.5 min (release).

### 6. Three permissions had to be explicitly removed

`aapt2 dump permissions` on the first APK showed it requesting
`READ_PHONE_STATE`, `READ_EXTERNAL_STORAGE` and `WRITE_EXTERNAL_STORAGE`.
No plugin and no file in this project asks for them — the manifest merger
injects them through its legacy implied-permission rules. An app whose entire
pitch is "asks for nothing" would have shipped asking for external storage and
the phone state.

`android/app/src/main/AndroidManifest.xml` now removes all three with
`tools:node="remove"`. Verified below.

---

## The int64 trap (read this one)

`tflite_flutter`'s `ByteConversionUtils` writes **int32 tensors little-endian
but int64 tensors big-endian**:

```dart
if (tensorType.value == TfLiteType.kTfLiteInt32) bdata.setInt32(0, o, Endian.little);
if (tensorType.value == TfLiteType.kTfLiteInt64) bdata.setInt64(0, o, Endian.big);
```

Android is little-endian. A model with int64 inputs therefore receives every
token id byte-swapped, produces a perfectly well-formed unit vector from
nonsense input, and reports no error anywhere.

The stock `all-MiniLM-L6-v2` ONNX export has **int64 inputs**, so this was the
default outcome. `modelprep/fix_onnx.py` rewrites the graph to take int32 and
cast internally; `embedding_service.dart` refuses to load a model whose inputs
are anything but int32, with an error that explains why.

---

## Model prep results

Source: `sentence-transformers/all-MiniLM-L6-v2`, the repo's own
`onnx/model.onnx`. Pipeline: `fix_onnx.py` → `convert.py` (onnx2tf) →
`verify.py`. The ONNX rewrite is numerically identical to the original
(max abs diff **1.97e-06**).

Three TFLite variants were produced and checked against an onnxruntime
reference, comparing mean-pooled, L2-normalised embeddings:

| Variant | Size | Result |
|---|---|---|
| `float32` | 90.4 MB | **cosine 1.00000** — bit-faithful. **Shipped.** |
| `float16` | 45.3 MB | Fails to load: `Node number 30 (MEAN) failed to prepare` |
| `dynamic_range_quant` | 90.4 MB | **Returns NaN**, and did not shrink at all |

This is worth dwelling on: implementation.md recommends dynamic-range
quantization, and that variant is the one that silently emits NaN. Had it
shipped unverified, the app would have loaded fine, ingested files fine, and
returned a ranked result list of pure noise. The bundled asset is float32.

**Consequence:** `assets/models/minilm_l6_v2.tflite` is 90 MB, so the debug
APK is large. Fine over USB; revisit before anything ships. Getting a working
sub-30 MB model is the single highest-value follow-up here — try
`TFLiteConverter` dynamic-range quantisation from a SavedModel rather than
onnx2tf's own quantiser.

The asset is named `minilm_l6_v2.tflite`, not `..._quant.tflite`, because it
is not quantized and a filename that says otherwise would be a trap.

### Tokenizer: the "known gap" is closed

implementation.md lists the simplified WordPiece tokenizer as an untested
risk. `modelprep/verify.py` check 1 runs a line-for-line Python port of
`tokenizer.dart` against the **real HuggingFace tokenizer** on prose, Dart
source, Python source and a punctuation-heavy URL: **6/6 identical**.

Those ids are now frozen as goldens in `test/pipeline_test.dart`, so
`flutter test` catches any regression on the host in about a second.

---

## Verified so far

- `flutter analyze` — clean, no issues
- `flutter test` — 13/13 passing (chunker boundaries and overlap, tokenizer
  goldens, padding/masking, truncation, `[UNK]` fallback, error paths)
- **Both APKs build.** `app-debug.apk` 261.7 MB (debug bundles every ABI),
  `app-release.apk` 126.6 MB (arm64 only)
- **Permissions, measured with `aapt2 dump permissions`:**
  - release: *none* — only `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`, which
    androidx.core defines for its own broadcast receiver. It is a
    self-declared permission, not a system capability, and grants access to
    nothing outside the app.
  - debug: the above plus `INTERNET`, injected by Flutter's tooling.
  - The three injected storage/phone-state permissions are gone from both.
- ONNX rewrite numerically identical to upstream
- Shipped TFLite reproduces onnxruntime to cosine 1.00000
- Retrieval sanity check on a 5-document corpus: 3/4 queries returned the
  expected top-1. The miss ("which hardware accelerator runs the model?" →
  expected the NNAPI chunk) scored 0.182, i.e. the model found *no* good
  match rather than confidently picking the wrong one. That is MiniLM being
  weak on a 5-document corpus, not a pipeline fault — but it is exactly the
  kind of result to re-check on real files.

## On-device results — realme RMX3660, Snapdragon 695, Android 14

The app runs, ingests, persists across restarts, and retrieves. Measured:

| | |
|---|---|
| Model load | 567 ms |
| Query embedding (256 tokens) | **233 ms** |
| Permissions requested (release) | none |

### XNNPACK is worth 12x, and was nearly missed

The first on-device build ran at **2936 ms per embedding**. The first guess
was that `runForMultipleInputs` was to blame — it materialises the
`[1, 256, 384]` output as ~98,000 *boxed* Dart doubles per call and then
deep-copies them. Reading `Tensor.data` as a `Float32List` instead removed all
of that... and changed the total by about 4 ms. The hypothesis was wrong:
`lastNativeInferenceDurationMicroSeconds` showed 2936 of the 2940 ms were
inside the native interpreter.

That measurement is what pointed at the delegate. Timing every backend:

| Backend | Per embedding | Notes |
|---|---|---|
| **XNNPACK** | **224 ms** | now the default |
| CPU (default kernels) | 2782 ms | fallback only |
| GPU (`GpuDelegateV2`) | — | interpreter refuses to build; throws, degrades cleanly |
| NNAPI | — | unavailable; LiteRT 1.4.0 has largely moved past it |

So the "no NPU on this phone" problem was mostly not a hardware problem. The
default CPU kernels are simply very slow for transformer matmuls, and the
optimised CPU path was one delegate away.

The raw-buffer change was kept regardless: it removes ~98k allocations per
call, and the model-vs-wall-clock split it exposed is what made the real
cause visible. It just is not where the time was.

### The XNNPACK crash worth knowing about

`XNNPackDelegateOptions` in tflite_flutter `calloc`s a **zeroed**
`TfLiteXNNPackDelegateOptions` rather than calling TFLite's
`TfLiteXNNPackDelegateOptionsDefault()`. The uninitialised fields make
`TfLiteXNNPackDelegateCreateWithThreadpool` dereference a null pointer:

```
Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0xc9
  #00 TfLiteXNNPackDelegateCreateWithThreadpool+772
```

That is a native crash Dart cannot catch — the app dies at startup with no
Flutter-level error. Constructing `XNNPackDelegate()` with **no options** uses
TFLite's own defaults and works. `EmbeddingBackend` documents this at the
point of use.

Because an untested delegate can take the whole process down, backends are an
explicit opt-in list (`backendsToTry`), never probed speculatively. Each
candidate's result is `print`ed as it is measured, so a crash in one still
leaves the earlier numbers in logcat — which is how the table above survived
the crash that produced it.

## Still not verified

- Retrieval quality against a corpus with known ground truth. This is step 5
  of implementation.md and the only thing that actually matters; the numbers
  above say the plumbing is fast, not that it retrieves the right chunks.
- Ingest throughput on a large file (only small ones so far)
- Whether `getExternalStorageDirectory()` gives the `adb pull` path below

---

## Running it

```powershell
$env:PATH = "D:\flutter\bin;$env:LOCALAPPDATA\Android\Sdk\platform-tools;$env:PATH"
cd D:\Downloads\projects\pocketRAG\vault_rag_test
adb devices          # confirm the phone is listed and authorised
flutter run
```

Wait for the status line to read `Model ready (...)`. It reports the backend,
dimensions, sequence length and load time — if it says `Failed to load model`,
the message names the cause.

Then: **Upload files** → **Convert to Vector DB** → type a query → **Search**.
The status line reports ms/chunk; the search line reports how many chunks were
scanned and how long ranking took. **Copy results as JSON** puts the payload on
the clipboard and writes it to:

```
/storage/emulated/0/Android/data/com.example.vault_rag_test/files/query_result.json
```

so `adb pull` it if the clipboard does not sync:

```powershell
adb pull /storage/emulated/0/Android/data/com.example.vault_rag_test/files/query_result.json .\result.json
```

The trash icon next to **Upload files** clears the vault, so you can re-run a
test from a known-empty state.

### Before you trust a result

The point of this build is step 5 of implementation.md's test plan: *are the
top results the chunks that should have matched?* Two things to do before
believing a good-looking answer:

1. Ask something the files genuinely do not cover. A confident, well-grounded
   answer to that means Claude is answering from its own knowledge and
   ignoring your context — not that retrieval works.
2. Check the scores, not just the order. The retrieval check above returned a
   *wrong* top-1 at 0.182 while correct ones sat at 0.41–0.49. A low top score
   means "nothing matched", however plausible the chunk looks.

---

## Zero-trust caveat for this build

Flutter's tooling injects `INTERNET` into the *debug* and *profile* manifests
(`android/app/src/debug/AndroidManifest.xml`), because that is how
`flutter run` talks to the Dart VM for hot reload. It is not in
`src/main/AndroidManifest.xml` and not in the release APK — confirmed above.

So **`flutter run` installs a build that can reach the network.** The claim in
implementation.md holds for release builds only. A release APK is already
built at `build\app\outputs\flutter-apk\app-release.apk`; install it with:

```powershell
adb install -r build\app\outputs\flutter-apk\app-release.apk
```

Re-check the permissions any time with:

```powershell
& "$env:LOCALAPPDATA\Android\Sdk\build-tools\36.0.0\aapt2.exe" `
  dump permissions build\app\outputs\flutter-apk\app-release.apk
```

Use the debug build to iterate (hot reload, readable errors) and the release
build whenever the no-network property is the thing being demonstrated.

Separately, and more importantly: with Claude on the laptop doing the
reasoning, retrieved chunks leave the device by design. No manifest can fix
that. Keep using non-sensitive files until an on-device model replaces that
step.

---

# v2 — co-processor, telemetry, benchmarks

Second pass. The retrieval pipeline itself did not change; what changed is
who can call it, and what the app can tell you about the hardware running it.

## 1. The pipeline had to leave the widget

v0 put the interpreter, the database handle and the chunker inside
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
LiteRT 1.4 has no working delegate for it, which is the §"XNNPACK is worth
12x" finding from v0 restated in hardware terms.

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

v0's headline was "233 ms per embedding" from a single run. As a sanity
check that is fine; as a benchmark it is not, because a phone runs the same
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

This retires the strongest version of the v0 claim. "It cannot exfiltrate
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
- Retrieval quality against ground truth — still the open item from v0, and
  still the only thing that finally matters.

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
