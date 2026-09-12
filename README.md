# Vault — on-device RAG, iQOO Hackathon 2026

A zero-trust retrieval system where your documents never leave your phone.
The phone holds the corpus, the index and the encoder; your laptop sends a
query and gets back only the passages it needs.

Three things live here.

## `vault_rag_test/` — the phone app

Flutter app, runs on a real Android phone today. Two models divide the work
and neither leaves the device:

| model | job |
|---|---|
| **MiniLM-L6-v2** | encodes chunks and queries to 384-dim vectors |
| **Gemma 2B int4** | reads what retrieval found and writes a JSON capsule |

Four screens:

- **Vault** — local ingest and search, no network involved.
- **Model** — inspect and load the Gemma weights (MediaPipe `.task`/`.bin`).
- **Bridge** — acts as a retrieval co-processor for a laptop over the LAN,
  so an IDE or MCP client can query the phone's private index.
- **Stats** — live CPU / GPU / NPU utilisation charts and a benchmark
  harness, for measuring what the hardware is actually doing.

Gemma is optional and never sees anything retrieval did not hand it. With no
model loaded a query still returns a valid capsule — the answer is a line
quoted verbatim from the corpus rather than written prose.

**Verified on a realme RMX3660 (Snapdragon 695, Android 14):**

| | |
|---|---|
| Query embedding, 256 tokens | **233 ms** (XNNPACK) |
| Model load | 567 ms |
| Permissions requested, release build | **`INTERNET`, and nothing else** |

That last row used to read *none*, and the change is worth stating plainly
rather than burying. Adding the desktop bridge means the app can open a
socket, so the OS-level guarantee — "it cannot exfiltrate anything because
the permission was never granted" — no longer holds on its own.

What replaces it is narrower and honest: the bridge is opt-in per session,
starts disconnected, is the only code path in the app that touches the
network, and the screen that enables it says so. Leave the Bridge tab alone
and the app behaves exactly as it did before. Confirm the permission set for
yourself with:

```powershell
aapt2 dump permissions build\app\outputs\flutter-apk\app-release.apk
```

which prints `INTERNET` plus one self-scoped signature permission AndroidX
injects, and nothing else.

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

## `bridge/` — the desktop half

FastAPI server plus an MCP server and a CLI. The laptop listens, the phone
dials in, and `iqoo_index_code` / `iqoo_query_agent` let an agent consult
material that is only ever embedded on the device. See
[`bridge/README.md`](bridge/README.md) for the wire protocol and the one
ordering constraint in it that fails silently.

Two commands, both talking to the phone through it:

```powershell
cd bridge
pip install -r requirements.txt      # the server
pip install -e .                     # vault-embed and vault-query
python bridge_server.py

vault-embed corpus\ --recursive      # push documents, embedded on-device
vault-query "What is the order limit?"
vault-query "..." --json > capsule.json
```

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
