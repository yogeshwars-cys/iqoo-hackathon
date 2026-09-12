# Vault Co-Processor

On-device retrieval for Android. The phone holds the encoder, the corpus and
the index; nothing is embedded anywhere else.

Two models, strictly divided:

| model | job | when |
|---|---|---|
| **MiniLM-L6-v2** | encoding — text to 384-dim vectors | every ingest, every query, always loaded, ~230 ms |
| **Gemma 2B int4** | reasoning — writes the context capsule | once per query, only when loaded, seconds |

Gemma never sees anything retrieval did not hand it, and the app works
completely without it: with no model loaded a query still returns a capsule,
with the answer quoted verbatim from the corpus instead of written.

Four screens:

| tab | what it does |
|---|---|
| **Vault** | pick files, embed them, ask — entirely offline |
| **Model** | inspect and load the Gemma weights |
| **Bridge** | serve retrieval to a laptop over the LAN, opt-in |
| **Stats** | live CPU/GPU/NPU charts and a benchmark harness |

Build and run:

```powershell
$env:PATH = "D:\flutter\bin;$env:LOCALAPPDATA\Android\Sdk\platform-tools;$env:PATH"
adb devices
flutter run --release
```

Read [`BUILD_NOTES.md`](BUILD_NOTES.md) before changing anything in
`core/embedding_service.dart`. It documents failure modes that produce a
*plausible wrong answer* rather than an error.

---

## Layout

```
lib/
  core/          the pipeline. No Flutter widgets, no telemetry imports.
    chunking.dart            overlapping windows over raw text
    tokenizer.dart           WordPiece, matched to the bundled vocab
    embedding_service.dart   TFLite MiniLM-L6-v2, delegate selection
    vector_store.dart        SQLite blobs + brute-force cosine
    answer_synthesizer.dart  extractive answer: quotes, never generates
    vault_engine.dart        orchestration + the interpreter lock
    llm/
      model_probe.dart       identifies a model file before loading it
      llm_runtime.dart       MediaPipe channel, GPU→CPU fallback
      capsule.dart           the schema, and a very forgiving parser
      capsule_prompt.dart    the fixed, versioned generator prompt
      model_settings.dart    remembers the chosen path
  telemetry/     measurement
    telemetry_sources.dart   procfs/sysfs probes, each tagged for trust
    compute_telemetry.dart   1 Hz sampler, bounded history
    device_info.dart         SoC identity + thermal, via method channel
    benchmark_runner.dart    repeatable load, percentile reporting
  bridge/        the desktop link
    bridge_client.dart       outbound WebSocket, reconnect, protocol
    bridge_settings.dart     last host, local IP
  ui/            four screens + a hand-drawn chart
  main.dart      composition root — builds the five long-lived objects
```

## Why the pipeline left the widget layer

v0 kept everything inside one `State` object: the interpreter, the database
handle, the chunker and the UI. That is the right shape for a test harness
with a single caller.

It stops being right the moment a second caller exists. The bridge has to
ingest and query with no widget mounted, possibly while the user is on
another tab, and possibly at the same instant as a local search. **A TFLite
interpreter is not reentrant** — two overlapping `embed` calls is undefined
behaviour in native code, which on a bad day is a SIGSEGV that Dart cannot
catch.

So `VaultEngine` owns the pipeline and serialises every call that touches
the interpreter through a promise chain. Callers queue rather than fail,
because a socket peer cannot retry the way a user re-tapping a button can.
The widgets are one client of the engine; the bridge is the other; neither
owns it.

## What the telemetry can and cannot measure

This is the part most worth understanding before quoting a number off the
Stats screen.

| lane | status on a Snapdragon 695 | source |
|---|---|---|
| CPU | **real** | `/proc/stat`, falling back to `/proc/self/stat` |
| GPU | **usually real** | `/sys/class/kgsl/kgsl-3d0/…` |
| NPU | **unavailable, and that is the true answer** | `/sys/class/devfreq/*` |
| Inference | **real, app-instrumented** | the interpreter's own clock |

Android exposes no public NPU busy counter. The fastrpc statistics that
would provide one live under `/sys/kernel/debug` and need root. Some devices
expose a compute-DSP devfreq node giving *clock frequency*, which is a proxy
for load and not load — a governor can hold a high clock while idle.

Every probe therefore returns a `Probe` tagged `measured`, `proxy`,
`derived` or `unavailable`, and the UI renders those differently:
unavailable lanes are greyed with the reason printed underneath, proxy lanes
are drawn at reduced opacity, and the chart **breaks the line** at a gap
rather than plotting a zero through it. A flat "NPU unavailable" lane is a
real finding about this hardware. A fabricated curve would quietly
invalidate every benchmark taken with it.

The fourth lane, **Inference**, is the one that earns its place for
benchmarking: the share of each second spent inside the interpreter. It is
always available and it separates "the accelerator is working" from "the
phone is busy".

## The reasoning model

Point the **Model** tab at a Gemma 2B int4 file and load it. The flow is
three steps — pick, inspect, load — rather than one button, and the middle
step is the one that earns its place: it reads sixteen bytes and tells you
what the file actually is.

"Gemma 2B int4" names a set of weights, not a format. The same weights ship
as a MediaPipe `.task` (a zip), a MediaPipe `.bin` (a TFLite flatbuffer), a
GGUF for llama.cpp, and raw safetensors — and `.bin` is used by three
different ecosystems, so the extension proves nothing. Guessing wrong means
a wrong container reaches native code and aborts the process, which no Dart
`try`/`catch` can intercept. So `model_probe.dart` checks magic numbers and
the UI says what it found, including the first bytes in hex when it
recognises nothing (a truncated download or an HTML error page is the usual
cause).

Only the two MediaPipe containers are supported. GGUF would mean building
llama.cpp with the NDK and driving it over FFI — a project in itself, and
CPU-only on this SoC. The app says so, with the conversion route, rather
than failing obscurely.

Loading tries GPU first and falls back to CPU, reporting which it got — the
same pattern the embedding service uses for its delegates.

## The context capsule

Generation emits a fixed-schema JSON object, not prose. The consumer is
usually a program, and a capsule is addressable: take `answer` alone, check
`confidence` before acting, or follow `key_facts[].verbatim` back to a
source line without re-parsing English.

**Every quoted fact is checked against the retrieved text.** `verified:
false` means the model produced a span that does not occur in the source —
a mechanical substring check, not a judgement, so it means exactly one
thing. The UI badges it and the CLI marks it `[?? ]`.

`capsule_prompt.dart` is the "output generator": a versioned instruction
template with one worked example. For a 2B instruct model that is the
difference between usable structured output and prose with braces in it.
Fields are emitted in priority order so a truncation loses `caveats` rather
than `answer`, and the highest-value line in the file is the one telling the
model that "the context does not say" is a permitted, expected answer —
without it, a 2B model confabulates one with total confidence.

The parser is deliberately forgiving, because a 2B model at int4 is not a
JSON API. It handles ``` fences, chatty preambles, trailing commas, smart
quotes, unquoted keys, Python literals, repeated objects, and truncation
mid-object or mid-string. Every repair is syntactic; it never invents
content. When nothing is recoverable the capsule falls back to retrieval
alone and records why — generation is an enhancement layered on retrieval,
never a dependency of it.

## Benchmarking

`Run benchmark` discards 3 warm-ups, then times 20 embeddings using
`lastNativeInferenceDurationMicroSeconds` — the interpreter's own clock, not
a Dart `Stopwatch` around the call. The gap between those two is marshalling
overhead, and conflating them cost the previous build hours.

It reports **min / median / p90 / max / σ**, not a mean. A phone is a
thermally-throttled, frequency-scaled shared machine: the first inference
after idle is slow because the governor has not ramped, the tenth is fast,
and the two-hundredth is slow again because the SoC is hot. A mean folds
three regimes into one number describing none of them. The spread is the
throttling signal — and when `PowerManager` reports the platform is actively
limiting clocks, a banner says so above the button, because a benchmark that
does not mention throttling is close to meaningless.

The optional backend sweep builds a **separate** interpreter per backend, so
a failed delegate cannot take the running one down with it, and a sweep
cannot disturb a bridge query in flight.

## Permissions

One: `INTERNET`, for the bridge. It used to be zero.

The bridge is opt-in per session, starts disconnected, and is the only code
path in the app that opens a socket. Everything else works with the radios
off. `lib/ui/bridge_page.dart` says this on screen, next to the button that
changes it — a user who is here for the air-gap property should not have to
read a manifest to discover it moved.

Note there is deliberately **no** `android:usesCleartextTraffic="true"`,
even though `ws://` to a LAN address is cleartext. That attribute governs the
platform HTTP stack; `dart:io`'s WebSocket uses the Dart VM's own sockets and
never consults it. Setting it would weaken the app's declared posture for
every future component without being needed by this one.

## Tests

```powershell
flutter test        # 70 tests, no device or model needed
```

Covers chunking, the tokenizer against HuggingFace goldens, the extractive
answer synthesizer, the telemetry maths, the capsule parser against the
shapes a small model really emits, and the model-format probe. The sysfs probes themselves
cannot be tested off-device, but the parts that decide what a number *means*
are pure — and they are the parts that would silently produce a wrong
benchmark.
