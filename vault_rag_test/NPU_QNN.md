# NPU (QNN HTP) bring-up for MiniLM on the iQOO 15

Split of the work:
- **NPU:** MiniLM embeddings only.
- **GPU:** the single selected reasoner. That's llama.cpp over OpenCL, or MediaPipe.

`GGML_HEXAGON` stays off. Nothing is reported as running on the NPU unless the
runtime proves it.

## What the device is

| | |
|---|---|
| Phone | iQOO 15 |
| SoC | Snapdragon 8 Elite Gen 5 (**SM8850**) |
| NPU | Hexagon, **HTP arch V81** |
| Runtime used | Qualcomm AI Engine Direct (QNN) **2.50.0** from Maven Central |

`Build.SOC_MODEL` is logged next to every QNN verdict (the `environment` block).
Compare it against the table above. Don't assume it.

## What has to be true before the NPU can run anything

Each item maps to a specific file.

1. **Libraries packaged (arm64-v8a).** `com.qualcomm.qti:qnn-runtime:2.50.0` and
   `qnn-litert-delegate:2.50.0` (see `android/app/build.gradle.kts`) provide:
   - `libQnnTFLiteDelegate.so`, `libQnnHtp.so`, `libQnnHtpPrepare.so`, `libQnnSystem.so`
   - `libQnnHtpV81Stub.so` + `libQnnHtpV81Skel.so` (plus V79 for SM8750)

   Other Hexagon versions, `libQnnGpu.so` and the DSP backend are excluded.
2. **Libraries extracted to disk.** The skel runs on the DSP and is loaded by
   path through FastRPC. `packaging.jniLibs.useLegacyPackaging = true`.
3. **Vendor FastRPC reachable.** `libQnnHtpV81Stub.so` links `libcdsprpc.so`,
   and on Android 12+ an app may only load it when declared:
   `<uses-native-library android:name="libcdsprpc.so" android:required="false"/>`
   (`src/main/AndroidManifest.xml`). `libOpenCL.so` is declared the same way for
   llama.cpp's Adreno GPU backend.
4. **Skel search path.** `ADSP_LIBRARY_PATH` and the delegate's
   `skel_library_dir` both point at `nativeLibraryDir`. They're set in
   `vault_qnn_delegate.cpp` before the first FastRPC session.
5. **Protection domain.** Unsigned PD (`htp_pd_session=0`). SM8850 supports
   unsigned PD, so no Qualcomm signing is needed.
6. **Precision.** MiniLM is a float model, so `htp_precision=1` (FP16).
   Performance mode is `2` (burst), because the encoder runs in short bursts.
   The enum values were read from the AAR's own `QnnDelegate$Options$*` classes.
7. **An NPU-shaped graph.** The first export (`modelprep/convert.py`) was
   numerically correct but carried ONNX's runtime shape arithmetic: 664 nodes,
   82 `SHAPE`, int64 tensors, bool `SELECT` masks and a −3.4e38 attention-mask
   constant that overflows FP16. On the iQOO 15 that failed with *"Unable to
   create interpreter"*. `modelprep/export_htp.py` re-exports it:
   - constant-folds shapes (onnxsim) and removes the int64 index casts;
   - rewrites the mask as `(1 − mask) × −1e4`;
   - verifies before shipping: 305 nodes, no `SHAPE`/int64/dynamic tensors,
     cosine **1.000000** against both the ONNX reference and the previous model
     on 6 texts, and top-1 retrieval matches.

   Because the embeddings are identical, an existing vault needs no re-index.
   2 `LESS` + 2 `SELECT` remain on the token-id inputs (onnx2tf's
   negative-index guard); at worst they run on CPU at the graph edge.

Missing packaging or a missing vendor library is reported up front as
**QNN unavailable** with the missing piece named (`QnnEnvironment.blockingReason`).

## How the delegate is created

```
Dart QnnHtpDelegate ──FFI──▶ libvault_qnn_delegate.so ──dlopen──▶ libQnnTFLiteDelegate.so
                                (vault_qnn_delegate.cpp)            tflite_plugin_create_delegate(keys, values, n)
```

**Why the plugin ABI.** It's TFLite's stable external-delegate contract with
string options. `TfLiteQnnDelegateCreate` instead takes an options struct whose
layout belongs to one SDK version. The shim needs no Qualcomm headers and builds
without the SDK.

## When "QNN HTP verified" is reported

`MiniLMEmbeddingService.load` tries `qnnHtp → xnnpack → cpu`. The QNN
interpreter is kept only if all of the following pass
(`lib/core/qnn/qnn_acceptance.dart`):

| Gate | Evidence | Default |
|---|---|---|
| Smoke test | finite, unit-length output | norm within 1e-3 |
| Coverage | the delegate's own log line `… N nodes delegated out of M nodes with P partitions` (read from this process's logcat by `QnnChannel.kt`) | ≥ 75% of nodes. No report means rejected |
| Equivalence | 12 passages + 4 queries embedded on QNN and on a temporary XNNPACK reference | min cosine ≥ 0.995; top-1 identical for every query; top-3 overlap ≥ 0.9 |
| Latency | 7 interleaved runs each | QNN median ≤ 1.10× XNNPACK |

**Possible outcomes:**
- **QNN HTP verified**: MiniLM runs on the NPU. Its telemetry lease is `npu`.
- **QNN unavailable**: the delegate or interpreter couldn't be created. XNNPACK serves.
- **XNNPACK fallback**: QNN ran but failed a gate. The reason is shown on the
  Model tab and in `describe().embedding_status`.

Capsules carry `retrieval.encoder_backend` / `encoder_hardware` from that verdict.

## Checking it on the phone

```powershell
flutter run --release --flavor airgap
adb logcat -s vault_qnn:* tflite:* flutter:*   # look for "[Qnn Delegate] … nodes delegated"
```

Then:
- **Model tab:** the MiniLM role reads *QNN HTP verified / QNN unavailable /
  XNNPACK fallback*, with the reason.
- **Stats tab → Live utilisation:** *APP DISPATCH* shows NPU / GPU / CPU leases
  independently.
- **Stats tab → Two-model pipeline benchmark:** exports JSON with MiniLM P50/P95,
  CPU vector search, retrieval-only early exit (reported separately),
  generation prefill/decode/tok/s, the overlap window with
  `npu_gpu_overlap_ms`, RSS, thermal before and after, the QNN verdict, and
  llama.cpp's own `backend_status`.

## Not yet proven (needs the device)

- Whether the 2.50.0 delegate is ABI-compatible with the LiteRT 1.4.0 C runtime
  that tflite_flutter ships. Delegates use the stable `TfLiteDelegate` /
  `TfLiteContext` C interface, but this is only verified once an interpreter
  builds on the phone.
- How much of this MiniLM graph HTP actually accepts. The coverage gate decides
  this; if the op mix, e.g. an int32 `GATHER` embedding lookup, stays on CPU,
  the result will be "XNNPACK fallback" rather than a false NPU claim.
- The first launch pays for HTP graph preparation. The compiled graph is cached
  in `codeCache/qnn_htp_cache`, and later launches restore it.
- Validation runs about 30 extra inferences at every startup. That's deliberate
  (no cached "trust"), and costs roughly a second on XNNPACK.
- Reading its own logcat is permitted for an app's own PID, but OEM ROMs can
  restrict `logcat`. If they do, coverage is unproven and QNN is rejected: an
  honest miss, not a silent pass.
- Licence: the QNN AARs are under the *Qualcomm AI Hub Model License*
  (LICENSE.pdf inside each AAR). Review it before distributing the APK.
