# Vault architecture

The system as built on branch `vault/coprocessor-gemma-capsule`. For the
threat model see [`SECURITY.md`](SECURITY.md); for NPU bring-up see
[`vault_rag_test/NPU_QNN.md`](vault_rag_test/NPU_QNN.md).

## 1. Topology

```
 LAPTOP (untrusted)            CLIPBOARD (ciphertext)          PHONE · iQOO 15 (trusted)
 ─────────────────             ───────────────────────          ────────────────────────
 vaultlink.py      ── sealed request ──▶ Office Kit ──▶  VaultLinkService
   pair / enroll                                          │
   ask / verify    ◀── sealed, signed capsule ───────────  VaultEngine ── ask()
 capsule_verify.py                                        │
 (bridge_server.py, lan flavor only: WebSocket)           ├─ MiniLM encoder   (NPU → CPU)
                                                          ├─ VectorStore      (SQLite + RAM matrix)
                                                          ├─ ReasonerCoordinator (one model, GPU)
                                                          └─ KeystoreChannel  (StrongBox / TEE)
```

The phone never listens on a port. In the default `airgap` build it has no
network permission at all. The laptop never receives chunks, only the
capsule.

## 2. Layers

| Layer | Responsibility | Key files |
|---|---|---|
| **L3 Laptop tools** | pair, enroll, ask, verify; clipboard scrub | `bridge/testdata/vaultlink.py`, `bridge/vault_cli/capsule_verify.py`, `vaultlink_protocol.py` |
| **L2 Transport** | VAULTLINK/2 frames over the clipboard; LAN WebSocket in `lan` | `lib/link/vault_link_service.dart`, `vaultlink_secure.dart`, `bridge/bridge_server.py` |
| **L1 Vault engine** | chunk, embed, encrypted store, rank, decrypt, reason, capsule, sign | `lib/core/vault_engine.dart`, `vector_store.dart`, `lib/core/llm/`, `lib/core/security/` |
| **L0 Silicon & keys** | NPU (QNN HTP), GPU (OpenCL), CPU, StrongBox | `android/app/src/main/cpp/`, `KeystoreChannel.kt`, `QnnChannel.kt` |

## 3. Ingest

```
pick file → chunk → WordPiece tokens (int32 LE) → MiniLM 384-d → normalise
          → AES-256-GCM(content) with vault_tee_aes_master
          → SQLite: id, file, embedding BLOB, content_cipher (IV ‖ ct ‖ tag)
          → append to the contiguous Float32List matrix in RAM
```

Schema v2 stores ciphertext only. Migrating a plaintext v1 database encrypts
the rows before touching the file, then runs `secure_delete` and `VACUUM`.

## 4. Query

1. **Embed** the question: the same encoder and tokenizer as ingest.
2. **Rank** over the RAM matrix: cached norms and a bounded top-K heap. No
   SQLite and no decryption happen while ranking.
3. **Decrypt** only the top 5, in one keystore batch.
4. **Reason**: if a reasoner is loaded and generation is on, it writes the
   answer for every query that has retrieved context. There is no similarity
   gate. Otherwise the best chunk is quoted (`extractive_fallback`).
5. **Capsule**: fixed JSON schema (`capsule_prompt.dart`). Every `key_facts`
   quote is substring-checked against the chunks (`verified: true|false`).
6. **Sign**: ECDSA P-256 over the canonical payload `vault-capsule-sig/v1`
   with `vault_tee_attestation`.

## 5. Reasoner: one at a time

`ReasonerCoordinator` makes "one reasoner" a hard invariant:

- **Runtimes:** llama.cpp GGUF (SmolLM2, Qwen3, Gemma GGUF; CPU / OpenCL GPU /
  NPU device names) or MediaPipe `.task` (Gemma).
- **Swapping:** a successful load unloads the other runtime. A failed load
  changes nothing, and activations are serialised.
- **Routing:** the selection is persisted (`activeReasoner`), `ask()` routes
  only to it, and startup auto-loads only that runtime.
- **llama.cpp details:** capsule prompts are passed unwrapped, so each model's
  own chat template applies. The prompt is bounded by the session KV budget.

## 6. Encoder on the NPU

- **Fallback order:** `qnnHtp → xnnpack → cpu`, with `GGML_HEXAGON` off.
- **Delegate:** Qualcomm's QNN HTP delegate 2.50.0, loaded through a C shim
  over the TFLite external-delegate plugin ABI.
- **Acceptance:** QNN is kept only if it passes coverage (the delegate's own
  "N nodes delegated" log), output equivalence against XNNPACK on a fixed
  corpus, and latency gates.
- **Verdicts:** *QNN HTP verified*, *QNN unavailable* or *XNNPACK fallback*.
  The capsule records the encoder backend.
- **Model:** `modelprep/export_htp.py` produces the NPU-shaped MiniLM (664 →
  305 nodes, no SHAPE or int64, FP16-safe mask).

## 7. Compute placement and telemetry

| Hardware | Work |
|---|---|
| NPU (Hexagon V81) | MiniLM embeddings, once QNN is verified |
| GPU (Adreno, OpenCL) | the reasoner |
| CPU | tokenizer, vector ranking, fallbacks |
| StrongBox / TEE | key generation, chunk decryption, signing |

- **Leases:** `ComputeLedger` records a lease per hardware per operation, so
  NPU and GPU work show up independently and their overlap is measured.
- **Stats tab:** live device counters (tagged measured / proxy / derived /
  unavailable, never a guessed zero) plus three benchmarks: encoder,
  reasoning, and the two-model pipeline (MiniLM, CPU search, retrieval-only,
  prefill/decode/tok/s, indexing during generation, RSS, thermal).

## 8. App

Flutter, Material 3 in the Now in Android style (`lib/ui/theme.dart`). Five
tabs:

| Tab | Purpose |
|---|---|
| **Vault** | ask, read and copy the capsule (20 s clipboard), manage the corpus |
| **Model** | active reasoner, on-device pipeline, llama.cpp and MediaPipe loaders |
| **Bridge** | air-gap notice; the LAN bridge in the `lan` flavor |
| **Link** | VaultLink session, pairing code, key id, legacy v1 switch |
| **Stats** | live utilisation, device clocks, benchmarks |

`test/screenshots/` renders every tab at phone size for design review
(`VAULT_SCREENSHOTS=1 flutter test test/screenshots --update-goldens`).

## 9. Build flavors

| Flavor | Network | Use |
|---|---|---|
| `airgap` (default) | none; `src/airgapRelease` strips `INTERNET` | VaultLink over the clipboard |
| `lan` | `INTERNET` | WebSocket bridge to `bridge_server.py` |

Check with `aapt2 dump permissions build/app/outputs/flutter-apk/app-airgap-release.apk`.
