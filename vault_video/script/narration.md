# Narration & timing sheet

Generated from `src/script.ts` by `script/gen-narration.mjs` — edit the
source array, not this file.

Absolute timecodes assume each scene is exactly 60s and scenes play back to
back. `IN` is when the line should start; `DUR` is the budget for it. Every
scene has a few seconds of headroom at the end, so a slightly long read will
not collide with the next scene.

**Direction:** measured and level, closer to documentary than advertisement.
Land the numbers plainly and let the pauses carry the emphasis — the visuals
are already doing the arguing.

## Scene 1 — The Problem

`00:00.0`–`01:00.0` · 139 words · 58.6s used of 60s (1.4s headroom)

| IN (abs) | IN (scene) | DUR | Line |
|---|---|---|---|
| `00:00.5` | `0.5s` | `4.0s` | To use AI on your own documents, you are asked to upload them. |
| `00:04.7` | `4.7s` | `4.5s` | Contracts. Medical records. Source code. Research you haven't published yet. |
| `00:09.4` | `9.4s` | `4.2s` | The moment they leave your machine, you lose control of the copy. |
| `00:13.8` | `13.8s` | `4.0s` | Retained. Indexed. Subpoenaed. Sometimes trained on. |
| `00:18.0` | `18.0s` | `5.2s` | Encryption in transit doesn't help — the server must read the plaintext to embed it. |
| `00:23.4` | `23.4s` | `3.2s` | So you try running it locally instead. |
| `00:26.8` | `26.8s` | `4.6s` | Now a transformer is competing with your compiler for the same cores. |
| `00:31.6` | `31.6s` | `4.4s` | The laptop heats up, the fans spin, and the whole machine throttles. |
| `00:36.2` | `36.2s` | `4.6s` | Meanwhile the most capable idle processor you own is in your pocket. |
| `00:41.0` | `41.0s` | `5.4s` | Phones ship neural accelerators rated in tens of trillions of operations per second. |
| `00:46.6` | `46.6s` | `4.0s` | They sit near zero utilisation while you work. |
| `00:51.0` | `51.0s` | `2.4s` | Two problems, one shape: |
| `00:53.6` | `53.6s` | `5.0s` | the data is in the wrong place, and the work is on the wrong processor. |

## Scene 2 — How It Is Solved

`01:00.0`–`02:00.0` · 134 words · 56.8s used of 60s (3.2s headroom)

| IN (abs) | IN (scene) | DUR | Line |
|---|---|---|---|
| `01:00.5` | `0.5s` | `3.2s` | The fix is to invert the topology. |
| `01:04.0` | `4.0s` | `4.0s` | Stop treating the phone as a thin client for the cloud. |
| `01:08.2` | `8.2s` | `5.0s` | Treat it as a private inference appliance that happens to fit in your pocket. |
| `01:13.4` | `13.4s` | `4.4s` | Your documents are ingested once, on the device, and never leave it. |
| `01:18.0` | `18.0s` | `4.0s` | The phone holds the corpus, the index, and the encoder. |
| `01:22.2` | `22.2s` | `4.6s` | The laptop keeps what it is actually good at: writing and reasoning. |
| `01:27.0` | `27.0s` | `4.0s` | When you ask a question, only the question crosses the gap. |
| `01:31.2` | `31.2s` | `5.0s` | The vault embeds it, searches its own index, and returns a handful of passages. |
| `01:36.4` | `36.4s` | `4.4s` | Retrieval is private. Generation happens wherever you choose. |
| `01:41.0` | `41.0s` | `2.8s` | That separation is the whole idea. |
| `01:44.0` | `44.0s` | `3.4s` | A gigabyte of private material stays put. |
| `01:47.6` | `47.6s` | `4.4s` | A few hundred tokens of relevant context is all that moves. |
| `01:52.2` | `52.2s` | `4.6s` | And it moves over a direct device-to-device link, not the internet. |

## Scene 3 — How It Is Built

`02:00.0`–`03:00.0` · 130 words · 58.7s used of 60s (1.3s headroom)

| IN (abs) | IN (scene) | DUR | Line |
|---|---|---|---|
| `02:00.5` | `0.5s` | `2.8s` | Concretely, here is the pipeline. |
| `02:03.5` | `3.5s` | `4.6s` | Ingestion extracts plain text from documents, code, and captured images. |
| `02:08.1` | `8.1s` | `4.8s` | A chunker splits it into overlapping windows of roughly 256 tokens, |
| `02:13.1` | `13.1s` | `4.4s` | overlapped so an idea spanning a boundary is never cut in half. |
| `02:17.7` | `17.7s` | `5.0s` | Each chunk goes through a sentence encoder — MiniLM, 384 dimensions, |
| `02:22.9` | `22.9s` | `4.8s` | quantised and compiled for the phone's neural engine through the vendor delegate. |
| `02:27.9` | `27.9s` | `4.6s` | The vectors land in a local SQLite database with a vector index, |
| `02:32.7` | `32.7s` | `4.4s` | encrypted at rest with a key held in hardware-backed storage. |
| `02:37.3` | `37.3s` | `3.6s` | At query time the same encoder embeds the question, |
| `02:41.1` | `41.1s` | `4.4s` | cosine similarity ranks the index, and the top passages are serialised. |
| `02:45.7` | `45.7s` | `4.2s` | The cross-device bridge carries them to an editor extension, |
| `02:50.1` | `50.1s` | `3.8s` | which assembles the prompt for whichever model you trust. |
| `02:54.1` | `54.1s` | `4.6s` | And the application requests no network permission at all. |

## Scene 4 — What Is New

`03:00.0`–`04:00.0` · 123 words · 57.0s used of 60s (3.0s headroom)

| IN (abs) | IN (scene) | DUR | Line |
|---|---|---|---|
| `03:00.5` | `0.5s` | `2.8s` | So what is actually new here? |
| `03:03.5` | `3.5s` | `2.6s` | First: the direction of trust. |
| `03:06.3` | `6.3s` | `4.0s` | Normally the small device asks the big one for help. |
| `03:10.5` | `10.5s` | `5.2s` | Here the personal device is the trusted core, and the workstation is the edge. |
| `03:16.0` | `16.0s` | `3.8s` | Second: privacy is enforced, not promised. |
| `03:20.0` | `20.0s` | `4.6s` | A missing permission is a property an auditor can verify in seconds. |
| `03:24.8` | `24.8s` | `4.4s` | It does not rest on a policy document or a vendor's good behaviour. |
| `03:29.4` | `29.4s` | `2.8s` | Third: minimal disclosure. |
| `03:32.4` | `32.4s` | `4.4s` | Even the side you trust only ever sees the passages it needs, |
| `03:37.0` | `37.0s` | `2.0s` | never the corpus. |
| `03:39.2` | `39.2s` | `4.6s` | Fourth: it runs on silicon you already own and are not using. |
| `03:44.0` | `44.0s` | `4.2s` | No new hardware, no per-token cost, no rate limit. |
| `03:48.4` | `48.4s` | `4.0s` | And because capture is local, a photograph of a whiteboard |
| `03:52.6` | `52.6s` | `4.4s` | becomes searchable knowledge without ever touching a server. |

## Scene 5 — Where It Goes

`04:00.0`–`05:00.0` · 115 words · 58.3s used of 60s (1.7s headroom)

| IN (abs) | IN (scene) | DUR | Line |
|---|---|---|---|
| `04:00.5` | `0.5s` | `2.4s` | Where this goes next. |
| `04:03.1` | `3.1s` | `3.8s` | In the near term, generation moves on-device too. |
| `04:07.1` | `7.1s` | `3.4s` | A small language model reads the retrieved passages, |
| `04:10.7` | `10.7s` | `3.4s` | and the loop closes entirely inside the vault. |
| `04:14.3` | `14.3s` | `2.8s` | After that, vaults federate. |
| `04:17.3` | `17.3s` | `5.2s` | Phone, laptop, workstation — one personal index, synchronised directly, |
| `04:22.7` | `22.7s` | `3.8s` | peer to peer, with no server in the middle. |
| `04:26.7` | `26.7s` | `2.8s` | Then ingestion becomes ambient. |
| `04:29.7` | `29.7s` | `5.2s` | Meetings, screenshots, notes — indexed continuously, locally, never uploaded. |
| `04:34.9` | `34.9s` | `4.8s` | The longer arc is about where personal AI should live by default. |
| `04:39.9` | `39.9s` | `4.8s` | Every year more neural silicon ships inside devices people already carry. |
| `04:44.9` | `44.9s` | `4.4s` | The data is already there. The compute is already there. |
| `04:49.5` | `49.5s` | `5.0s` | The only thing still missing is the assumption that it has to leave. |
| `04:54.7` | `54.7s` | `3.6s` | Build the vault. Keep the corpus. |

---

**Total:** 641 words over 5 minutes — 128 wpm.
