# Synthetic sensitive-document test

A randomized, entirely fake "confidential" document plus a ground-truth
question set, for exercising retrieval + generation against something with
sharper edges than the four-document demo corpus in `bridge/corpus/` —
salaries, national IDs, medical leave, credentials, an undisclosed
acquisition, an undisclosed breach. Two people share a role and city on
purpose, to test whether generation can tell them apart when it has to.

**Everything in the generated document is synthetic and invalid by
construction** — see the safety notes in `gen_sensitive_doc.py`'s docstring
(bogus ID ranges, a card number that fails Luhn, an unassigned IBAN country
code, `FAKE_`-prefixed keys). The file itself carries the same disclosure at
the top. Generated output lives under `out/`, which is covered by the
repo's root `.gitignore` (`out/`) — nothing here gets committed.

## Generate a document

```powershell
python gen_sensitive_doc.py                 # random seed
python gen_sensitive_doc.py --seed 42       # reproducible
```

Writes `out/confidential_hr_finance_<seed>.md` and
`out/ground_truth_sensitive.json` (14 questions, each tagged with a category
and the substrings a correct answer must contain; one is deliberately
`unanswerable` — the document says nothing about it, and the only correct
response is a refusal).

## Three ways to run the loop

### `vaultlink.py` — clipboard-native, fully automated, no bridge at all

The one built to answer "automate it without the WebSocket bridge." Unlike
`officekit_clip.py` below, there's no manual paste/run/copy per question —
the phone side runs itself. It requires the app build with the **Link**
tab (`vault_rag_test/lib/link/vault_link_service.dart` +
`lib/ui/link_page.dart`), which adds a `VaultLink session` switch. Turn it
on once, leave the screen open, and every question after that needs zero
taps on the phone:

```powershell
python vaultlink.py ping                  # is a session running over there?
python vaultlink.py list
python vaultlink.py ask s02               # scores it against ground truth
python vaultlink.py ask "free text"       # scoring skipped for non-ground-truth text
python vaultlink.py all                   # the whole ground-truth set, one command
```

**Protocol**, in full — this is the entire surface, deliberately: no Wi-Fi,
TCP, HTTP, BLE or MCP anywhere in it, only `clipboard in -> parse -> execute
-> clipboard out`, with Office Kit doing the cross-device carrying:

```text
VAULTLINK/1
{"id":"q_7f3a","op":"query","q":"how does retry backoff work?","k":5,"generate":true}
```

phone replies (an interim frame first, since generation can take 10+ seconds
and the laptop needs to tell "the phone has it" from "never arrived"):

```text
VAULTLINK/1
{"id":"q_7f3a","status":"processing"}
```
```text
VAULTLINK/1
{"id":"q_7f3a","ok":true,"status":"complete","answer":"...","sources":[...],...}
```

Only a request carries `op`; only a reply carries `status`. That's what
lets the phone's own poll loop recognise and ignore its own echoed reply
without comparing clipboard text byte-for-byte, and what lets
`vaultlink.py` on the laptop tell a genuine answer from the frame it just
wrote itself. Any clipboard content that doesn't start with `VAULTLINK/1`
is left completely alone by both sides.

**Why this needed an app rebuild and the other two paths didn't:** the
phone has to notice the request on its own — nothing else can tap "run"
for it. That's implemented as a foreground `Timer.periodic` polling
`Clipboard.getData` (Android has refused background clipboard reads since
Android 10, so this can only run in the foreground, and the session is
opt-in for exactly that reason — see the on-screen notice in the Link tab).
It adds zero new Android permissions: this is the same `Clipboard` API
`vault_page.dart`'s Copy button already called.

### `ask_one.py` — direct, no clipboard, no typing an IP

Talks to `bridge_server.py` over local HTTP, the same way `vault-query`
does, and automates everything on the laptop side of that:

```powershell
python ask_one.py --list              # show the question set
python ask_one.py s02                 # ask by id, score the answer
python ask_one.py "free text"         # ask anything; scoring is skipped
python ask_one.py s02 --no-generate   # retrieval only, ~250 ms, no reasoner needed
python ask_one.py --all               # run the whole ground-truth set, print a tally
```

It starts `bridge_server.py` itself if nothing answers on `:8000` (log goes
to `out/bridge_server.log`), then waits for the phone to be linked — printing
the LAN addresses from `/api/status` if it isn't, since dialing out from the
**Bridge** tab is a one-time physical step on the phone that nothing on the
laptop can do for you. Past that, no address is ever typed into this script;
`vault_cli.client`'s `127.0.0.1:8000` default is what makes that possible.

Every run is saved to `out/capsule_<id>.json` for later inspection.

### `officekit_clip.py` — the Office Kit clipboard path

For testing the actual demo path end to end (query copied to the phone,
answer copied back), rather than the bridge:

```powershell
python officekit_clip.py list
python officekit_clip.py send s02     # puts the question on the laptop clipboard
# paste into Vault tab on the phone, run it, tap Copy
python officekit_clip.py recv s02     # waits for the capsule, saves + scores it
python officekit_clip.py ask s02      # send + recv in one call
```

Uses the Win32 clipboard directly (not `pyperclip`) so non-ASCII survives.
Polls the clipboard sequence number rather than sleeping in a loop, and
ignores any capsule whose `query` doesn't match what was just sent.

**Note:** this path depends on Office Kit actually mirroring the phone's
clipboard back to the laptop. In testing that sync didn't come through — the
listener sat waiting indefinitely with no clipboard change ever observed —
so `ask_one.py` (which bypasses the clipboard and Office Kit entirely) is
what the seed-413172 run below actually used. Treat `officekit_clip.py` as
ready for whenever that sync is confirmed working, or as a manual fallback:
read the answer off the phone screen yourself.

## Scoring: generated answer vs. extractive floor, separately

Both scripts check two fields independently rather than folding them into
one "does anything in the capsule contain the expected value" pass:

- **generated answer** (`capsule.answer`) — what the on-device reasoner wrote
- **extractive floor** (`capsule.extracted_answer`) — the verbatim quote
  retrieval alone produces, independent of the LLM

Checking only their concatenation would have hidden the two real failures
found so far (below): both had a *correct* extractive floor sitting right
next to a *wrong* generated answer. A consumer that trusts `answer` without
looking at `extracted_answer` would get the wrong value with `confidence:
high` and no visible warning.

For the `unanswerable` question, "pass" means `confidence == "none"` — not
the absence of expected substrings, since there are none to check.

## Findings — seed 413172 run

Full run: 14/14 questions answered, corpus fully ingested (3 chunks, 687
words), reasoner `smollm2-1.7b-instruct-q4_k_m.gguf` via llama.cpp/GPU on a
vivo I2501 (SM8850). Raw capsules in `out/run_results.json` (gitignored;
regenerate by rerunning `ask_one.py --all` against a phone holding this
seed's document).

| # | question | generated | extractive |
|---|---|---|---|
| s01–s07, s09–s13 | (12 questions) | pass | pass |
| **s02** | Dmitri Novak's national ID | **fail — answered Dmitri Moreau's ID instead** | pass |
| **s08** | break-glass password | **fail — `FAKE-...` written as `FAKE_...`** | pass |
| s14 | Oskar Brennan's address (unanswerable) | `confidence: none` (correct signal), but `answer` text is ~40 repeated national-ID fragments from *other* people, formatted like an address | n/a |

1. **Cross-entity confusion (s02).** The document has three people named
   Dmitri; two of them (Moreau, Novak) share the same role and city
   deliberately. The retrieved chunk had both IDs correctly labelled
   side by side, and the extractive floor picked the right one — but
   generation swapped in the neighbour's ID. This is the exact class of
   error a single-document corpus can't surface.

2. **Credential corruption (s08).** One-character substitution
   (hyphen → underscore) in a copied secret. Cosmetically tiny, functionally
   a wrong password — for a pipeline whose purpose is returning exact
   secrets, this is a real defect, not a rounding error.

3. **Hallucinated non-answer text (s14).** The safety signal worked — retrieval
   correctly found nothing and `confidence` came back `none` — but the model
   still wrote a confident-looking `answer` string, and what it wrote was
   fabricated from other employees' IDs. Anyone reading only `capsule.answer`
   (skipping `confidence`) would see fluent PII-shaped nonsense with no
   indication it's fabricated. Worth raising as a reasoner-prompt issue:
   on `confidence: none`, `answer` should say it doesn't know, not produce
   prose that happens to be labelled unreliable elsewhere in the schema.

## Files

| file | purpose |
|---|---|
| `gen_sensitive_doc.py` | generates the fake document + ground truth |
| `ask_one.py` | direct HTTP loop through the bridge — no clipboard, no IP typed |
| `officekit_clip.py` | Office Kit clipboard loop — the actual demo path |
| `out/` | generated docs, capsules, run results (gitignored) |
