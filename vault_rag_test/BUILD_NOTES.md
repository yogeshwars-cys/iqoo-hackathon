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
