# Desktop bridge

The laptop half of the co-processor. The phone holds the model and the
index; this turns local HTTP calls into WebSocket round-trips to it.

```
  IDE / MCP client / query.py
            │  HTTP  (127.0.0.1:8000)
            ▼
     bridge_server.py                    ← this directory
            │  WebSocket  (LAN)
            ▼
  Vault Co-Processor app  ← embeds, stores and searches. Nothing else does.
```

## Run it

```powershell
pip install -r requirements.txt
python bridge_server.py
```

It prints the addresses it can be reached on. Type one into the phone app's
**Bridge** tab and tap Connect.

The phone dials out; the laptop never dials in. A phone makes a poor server
— Android reaps background sockets, the IP changes with every DHCP lease,
and shared Wi-Fi often has client isolation — and this way there is no
listening port on the device for anything to find.

## The two commands

```powershell
pip install -e .        # puts vault-embed and vault-query on PATH
```

Not installing is fine too — `vault-embed.cmd` / `vault-query.cmd` (and the
POSIX equivalents) call `python -m vault_cli.*` directly from this folder.

### `vault-embed` — put documents on the phone

```powershell
vault-embed notes.md
vault-embed src\ --recursive --ext py,dart
vault-embed corpus\ -r --dry-run
type report.txt | vault-embed --stdin --name report.txt
```

The text goes to the phone, MiniLM embeds it there, and the vectors stay
there. Nothing is embedded on this machine. Directory walks skip `.git`,
`node_modules`, `build` and friends, and anything that is not valid UTF-8 is
skipped with a reason rather than uploaded for the device to reject.

One document per request, and a request has to fit in a single WebSocket
frame — about 1 MB. That ceiling is the receiver's, not ours: a client that
is handed a larger frame does not drop it, it closes the connection with
status 1009, which would strand every other request in flight. So oversized
files are refused (exit code 1) rather than risked. The command checks the
file size early and the bridge re-checks the serialised frame, because JSON
escaping inflates non-ASCII badly — an emoji is 4 bytes on disk and 12 on
the wire — so a file comfortably under the cap can still be refused with a
`413`. Split the document if you hit it.

Exit codes are meant for scripts: `0` only when everything named was
actually embedded, `1` if any upload failed or nothing got through at all
(every file binary, empty, or too large).

### `vault-query` — ask, and get a capsule

```powershell
vault-query "What is the maximum notional order limit?"
vault-query "..." --json > capsule.json
vault-query "..." --no-generate          # retrieval only, ~250 ms
vault-query "..." --context              # also print the full chunks
vault-query --status                     # link, models, live telemetry
```

Human-readable output goes to stderr and the capsule to stdout, so `--json`
pipes and redirects cleanly.

`python query.py` still works and forwards to these, with a note saying so.

`--status` prints CPU / GPU / NPU utilisation read from the phone. Each
reading is tagged with how it was obtained:

| tag | meaning |
|---|---|
| `measured` | a real kernel busy counter |
| `proxy` | derived from clock frequency — a hint, not utilisation |
| `derived` | computed by the app from its own instrumentation |
| `unavailable` | the device exposes no counter |

**`NPU unavailable` is the expected answer, not a failure.** Production
Android has no public NPU busy counter; the fastrpc statistics live under
`/sys/kernel/debug` and need root. See
`../vault_rag_test/lib/telemetry/telemetry_sources.dart` for the full
reasoning and what the app tries before giving up.

## As an MCP server

```powershell
claude mcp add iqoo-phone -- python D:\Downloads\projects\iqootest\bridge\iqoo_mcp_server.py
```

Five tools: `iqoo_get_status`, `iqoo_get_telemetry`, `iqoo_query_agent`
(raw chunks), `iqoo_ask_capsule` (the structured capsule), and
`iqoo_index_code`. `bridge_server.py` must be running and a phone linked.

The point of the pairing: `iqoo_index_code` pushes a file to the phone, it is
embedded there, and the vectors stay there. A later `iqoo_query_agent`
returns only the chunks that matched — so an agent can consult proprietary
material without a cloud model ever seeing the whole file.

## The context capsule

`vault-query` returns a fixed-schema JSON object rather than prose, because
the consumer is usually a program:

```json
{
  "capsule_version": "1.0",
  "query": "What is the maximum notional order limit?",
  "answer": "The matching engine rejects any single order above 15,000,000 USD…",
  "confidence": "high",
  "key_facts": [
    {
      "fact": "Maximum notional per order is 15,000,000 USD.",
      "source": "settlement_risk_policy.md",
      "verbatim": "MAX_NOTIONAL_PER_ORDER_USD = 15_000_000.00",
      "verified": true
    }
  ],
  "caveats": ["The context does not say what happens to a rejected order."],
  "sources":  [{"file": "…", "similarity": 0.8123}],
  "context":  [{"file": "…", "similarity": 0.8123, "content": "…"}],
  "extracted_answer": "MAX_NOTIONAL_PER_ORDER_USD = 15_000_000.00",
  "generation": {"ran": true, "model": "gemma2-2b-it-cpu-int4.task",
                 "backend": "cpu", "tokens": 148, "elapsed_ms": 11840},
  "retrieval":  {"encoder": "all-MiniLM-L6-v2", "latency_ms": 244,
                 "chunks_scanned": 312}
}
```

Three fields do most of the work:

- **`verified`** on each fact is a substring check of `verbatim` against the
  retrieved text. `false` means the model produced a quote that does not
  occur in the source — the signal to distrust that fact specifically. It is
  a mechanical check, not a judgement, so it means exactly one thing.
- **`extracted_answer`** is always present and never generated: a line
  quoted verbatim by the retrieval stage. A consumer that does not trust
  written text has something to use.
- **`generation.ran`** says whether a model was involved at all. With no
  model loaded the capsule still comes back, with `answer` set to the
  extracted line. That degradation is the design.

## HTTP API

| method | path | purpose |
|---|---|---|
| `GET` | `/api/status` | link state, device info, this machine's LAN addresses |
| `GET` | `/api/telemetry` | cached compute telemetry from the phone |
| `GET` | `/api/llm` | which models are loaded on the device |
| `POST` | `/api/query` | `{query, top_k}` → ranked chunks + extracted answer |
| `POST` | `/api/ask` | `{query, top_k, generate}` → the full context capsule |
| `POST` | `/api/index` | `{filename, content}` → chunk count |

`/api/ask` is separate from `/api/query` rather than a flag on it because
their timeouts are an order of magnitude apart: retrieval answers in about
250 ms, generation in 5–40 s.

## Wire protocol

```
desktop → phone   {"id": "q_…", "action": "search"|"ask"|"index"|"ping",
                   "data": {…}}
phone → desktop   {"id": "q_…", "action": "result", "data": {…}}
phone → desktop   {"action": "telemetry", "data": {…}}      (every 2 s)
```

One ordering constraint, and it bites silently: the server checks `action`
**before** `id`, so a reply must never use the action name `telemetry` — it
would be swallowed as a status frame and the caller would time out with no
error logged anywhere. The Dart client sends `result`. The bridge now prints
a warning when a `telemetry` frame carries the `id` of a live request, which
is the only cheap way to tell that footgun apart from a slow phone.

## Tests

```powershell
python -m pytest tests\           # or: python tests\test_units.py
```

No phone and no device needed. `tests/fake_phone.py` runs the real
`bridge_server` app on an ephemeral port and links a WebSocket client that
speaks the protocol — including badly on purpose, which is the only way to
cover the cases that matter here: a reply that is not a JSON object, an
unparseable frame, a second phone, a hang-up mid-request, a payload over the
frame limit. `test_units.py` needs nothing but the stdlib; `test_protocol.py`
needs the bridge's own `requirements.txt`. Both files also run as plain
scripts, so pytest is convenient rather than required.

## Running the bridge on another port

Port 8000 is popular. `VAULT_BRIDGE_URL` moves the client side:

```powershell
$env:VAULT_BRIDGE_URL = "http://127.0.0.1:8100"
```

Both `vault-*` commands and the MCP server read it. The server's own port is
still the `uvicorn.run(...)` call at the bottom of `bridge_server.py`.

## A note on the corpus

`corpus/` holds one fictional sample document with no credentials in it. Use
files you would not mind sitting on a loaner phone. Anything retrieved over
the bridge leaves the device by design — that is what the bridge is for —
so the air-gap property only holds while the phone is disconnected.
