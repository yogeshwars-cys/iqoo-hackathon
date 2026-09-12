# Test corpus

Four documents, one ground-truth question set, one eval script. This is the
"RAG correctness test" the PocketRAG plan asks for — the thing BUILD_NOTES.md
kept naming as still open ("retrieval quality against ground truth — still
open, still the only thing that finally matters") now actually exists.

## Why four documents, not one

The original corpus was a single document
(`vault_test_suite.md`). Retrieval against one document is not a test of
retrieval — every chunk that could possibly match a query already comes from
the only source there is, so ranking, discrimination between documents, and
resistance to a lexically-similar-but-wrong document are all untested by
construction.

The three added documents (`platform_reliability_runbook.md`,
`mobile_release_policy.md`, `device_data_handling_policy.md`) share
vocabulary with the original and with each other on purpose — "kill switch,"
"escalation," "retention," "automatic rollback" all appear in more than one
document, each time meaning something numerically different. A retrieval
step that matches on keywords rather than actual relevance, or a generation
step that reaches for whichever number sounds plausible, both fail visibly
against this corpus in a way they never could against one document.

## Ground truth (`ground_truth.json`)

20 questions, each tagged with a category:

| category | tests |
|---|---|
| `single_fact` | Baseline — one number, stated once, in one document. |
| `multi_fact` | Combining two or more facts from the same document. |
| `cross_document_distractor` | The question's wording matches a *different* document than the one that actually answers it. |
| `cross_document_synthesis` | The correct answer genuinely needs facts from two documents. |
| `unanswerable` | Not covered anywhere. The only correct answer is a refusal (`confidence: "none"`) — a plausible-sounding invented answer is a failure regardless of how well-written it is. |

Two questions are marked `"scoring": "manual"` — ones with a deliberately
ambiguous or comparative expected answer that a substring check cannot score
honestly. Run with `--save-capsules` to get the full capsule text for those
in the results file.

## Running it

From `bridge/`, with a phone connected via the app's Bridge tab:

```
python corpus/run_eval.py --label gemma-2b-cpu
```

Tag every run with `--label <model>-<backend>` — e.g. `gemma-2b-cpu`,
`qwen3-1.7b-gpu`, `qwen3-1.7b-npu`. Results land in
`bridge/corpus/results/<label>_<timestamp>.json`, so the same corpus and
question set can be compared across every model/backend combination the
PocketRAG plan benchmarks, exactly as it asks: "keep the retrieval corpus
identical across all runs."

## Extending this corpus

Keep the same shape when adding a document: numbered `CONFIG_NAME = value`
blocks plus prose, similar density to the existing four, and — this is the
part that actually matters — reuse a term or a numeric-threshold pattern
from an existing document somewhere in the new one. A corpus where every
document is on a visibly different topic with no shared vocabulary is easier
to retrieve against than any real internal wiki ever is, and stops being a
useful test the moment that's true.

When adding a question, prefer `expected_key_facts` (verbatim strings that
must appear in the answer or a `key_facts[].verbatim` field) over
`expected_answer` alone — the eval script only scores against
`expected_key_facts`; `expected_answer` is there for a human skimming the
JSON, not for `run_eval.py`.
