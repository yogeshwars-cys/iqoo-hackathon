# Vault Co-Processor (phone app)

Flutter app for the iQOO 15 (Snapdragon 8 Elite Gen 5, SM8850). It holds the
encrypted corpus, the encoder and one reasoning model. It answers questions
from a paired laptop with a signed context capsule.

| Model | Job | Runs on |
|---|---|---|
| **all-MiniLM-L6-v2** | text → 384-dim vectors, every ingest and query | NPU (QNN HTP) once verified, else XNNPACK |
| **one reasoner** | writes the capsule from the retrieved chunks | GPU: llama.cpp GGUF (SmolLM2, Qwen3) or MediaPipe `.task` (Gemma) |

## Build and run

```powershell
git submodule update --init --recursive          # llama.cpp
flutter build apk --release --flavor airgap      # default: no network permission
flutter build apk --release --flavor lan         # adds INTERNET for the LAN bridge
adb install build\app\outputs\flutter-apk\app-airgap-release.apk
```

Models are side-loaded. In the **Model** tab, pick a `.gguf` (llama.cpp) or
`.task` (MediaPipe) and load it. The choice is remembered and auto-loaded
next launch.

## Tabs

| Tab | What it does |
|---|---|
| **Vault** | ask on device; read the capsule (answer, verified key facts, sources); copy it with a 20 s clipboard lifetime; add files to the corpus |
| **Model** | the active reasoner and its metrics; the on-device pipeline with the encoder verdict; llama.cpp loader (CPU / GPU / NPU) and smoke test; MediaPipe inspect-then-load |
| **Bridge** | air-gap build: a notice and what still works offline. `lan` build: connect to `bridge_server.py` |
| **Link** | VaultLink session, pairing code (hidden until tapped), key id, legacy VAULTLINK/1 switch |
| **Stats** | live CPU/GPU/NPU utilisation with runtime leases, device clocks and thermal, encoder / reasoning / two-model pipeline benchmarks |

The UI follows Material 3 as used by Google's *Now in Android* app: tonal
green scheme, NiA type scale, 48 dp touch targets and reduced-motion support
(`lib/ui/theme.dart`, `lib/ui/widgets/common.dart`).

## Layout

```
lib/
  core/
    vault_engine.dart          orchestration; serialises every interpreter call
    chunking.dart, tokenizer.dart
    embedding_service.dart     QNN HTP → XNNPACK → CPU, with acceptance
    vector_store.dart          SQLite schema v2 (ciphertext) + RAM matrix
    vector/                    Float32 matrix, top-K heap, rank benchmark
    gating.dart                llm_synthesized | extractive_fallback
    compute_ledger.dart        per-hardware operation leases
    llm/
      reasoner_coordinator.dart  the one-reasoner invariant
      llama_runtime.dart         llama.cpp over JNI
      llm_runtime.dart           MediaPipe over a method channel
      model_probe.dart           identifies a model file before loading
      capsule.dart, capsule_prompt.dart, model_settings.dart
    qnn/                       QnnHtpDelegate (FFI), acceptance gates
    security/                  keystore, capsule signing, ephemeral clipboard
  link/                        VaultLink service, VAULTLINK/2 crypto
  bridge/                      LAN WebSocket client (lan flavor)
  telemetry/                   probes, sampler, three benchmark runners
  ui/                          app chrome, five pages, theme, widgets
android/app/src/main/
  kotlin/…/                    KeystoreChannel, QnnChannel, SensitiveClipboardChannel, llama JNI
  cpp/                         llama.cpp (submodule), vault_qnn_delegate.cpp
modelprep/export_htp.py        NPU-shaped MiniLM export and verification
```

## Notes that matter

- **Encryption:** chunk text is AES-256-GCM under an AndroidKeyStore key
  (StrongBox, with TEE fallback). Ranking touches only vectors in RAM; only the
  top five chunks are decrypted.
- **Capsules:** fixed JSON schema. Every quoted fact is substring-checked
  against the retrieved text (`verified: false` means the quote is not in the
  source). The parser repairs fences, trailing commas and truncation without
  inventing content. Capsules are signed with ECDSA P-256; see
  [`../SECURITY.md`](../SECURITY.md).
- **One reasoner:** loading llama.cpp or MediaPipe unloads the other, and a
  failed load changes nothing. With a model loaded, it writes every answer;
  there is no similarity gate.
- **llama.cpp prompts:** capsule prompts are passed unwrapped so the model's
  own chat template applies. The prompt is bounded by the session KV budget
  (the earlier generate-time crash).
- **NPU:** the full bring-up, including acceptance gates and verdict wording,
  is in [`NPU_QNN.md`](NPU_QNN.md). Nothing is reported as running on the
  NPU unless the runtime proves it.
- **Telemetry:** every probe is tagged measured / proxy / derived /
  unavailable. An unmeasurable lane is greyed with the reason, never drawn as
  zero. Benchmarks report min / median / p90 / max / σ from the interpreter's
  own clock and flag thermal throttling.

## Tests

```powershell
flutter analyze
flutter test                                              # 236 tests, host only
$env:VAULT_SCREENSHOTS='1'; flutter test test/screenshots --update-goldens   # UI renders → build/ui_shots
flutter run --release --flavor airgap -t lib/bench_rank_main.dart            # on-device ranking benchmark
```

Covers signing (cross-language vector shared with `bridge/tests`),
VAULTLINK/2 framing, keystore test doubles, the encrypted vector store and
its migration, the one-reasoner coordinator, QNN acceptance, compute leases,
the capsule parser and telemetry maths.
