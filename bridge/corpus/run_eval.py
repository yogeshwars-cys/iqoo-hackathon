#!/usr/bin/env python3
"""Runs bridge/corpus/ground_truth.json against a connected phone and scores
retrieval + generation quality — the "RAG correctness test" the PocketRAG
plan asks for, one that actually exists now instead of being the perpetually
open item BUILD_NOTES.md keeps naming ("retrieval quality against ground
truth — still open, still the only thing that finally matters").

Deliberately stdlib-only, importing vault_cli.client for the same reason
that module gives for being stdlib-only: this should run the moment the repo
is cloned, with nothing to pip install first.

Usage (from the bridge/ directory, with a phone connected via the Bridge tab):

    python corpus/run_eval.py --label gemma-2b-cpu
    python corpus/run_eval.py --label qwen3-1.7b-npu --top-k 5

Each run writes a timestamped results file next to this script
(results/<label>_<timestamp>.json) so multiple models/backends can be
compared against the identical corpus and question set later — the plan's
own requirement ("keep the retrieval corpus identical across all runs").
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from vault_cli.client import BridgeError, heading, post, wrap  # noqa: E402

CORPUS_DIR = Path(__file__).resolve().parent
GROUND_TRUTH_PATH = CORPUS_DIR / "ground_truth.json"
RESULTS_DIR = CORPUS_DIR / "results"


def _normalize(text: str) -> str:
    """Collapses whitespace so a quote split across a line wrap in the
    corpus still matches text the model reflowed — the same normalisation
    ContextCapsule._verify applies on-device, so a fact this script scores
    as "grounded" and a fact the phone itself marks `verified: true` should
    agree."""
    return re.sub(r"\s+", " ", text.strip().lower())


def _contains(haystack: str, needle: str) -> bool:
    return _normalize(needle) in _normalize(haystack)


@dataclass
class QuestionResult:
    id: str
    category: str
    question: str
    passed: bool | None  # None for "manual" — not auto-scorable
    detail: str
    latency_ms: float | None
    confidence: str | None
    retrieved_files: list[str] = field(default_factory=list)
    raw_capsule: dict[str, Any] | None = None


def score_question(q: dict[str, Any], capsule: dict[str, Any], elapsed_ms: float) -> QuestionResult:
    category = q["category"]
    confidence = capsule.get("confidence")
    answer = capsule.get("answer", "") or ""
    key_facts = capsule.get("key_facts", []) or []
    context = capsule.get("context", []) or capsule.get("sources", []) or []
    retrieved_files = sorted({c.get("file", "") for c in context if c.get("file")})

    fact_text = " ".join(
        f"{f.get('fact', '')} {f.get('verbatim', '')}" for f in key_facts
    )
    combined_text = f"{answer} {fact_text}"

    if q.get("scoring") == "manual":
        return QuestionResult(
            id=q["id"], category=category, question=q["question"], passed=None,
            detail="Requires manual review — see notes in ground_truth.json.",
            latency_ms=elapsed_ms, confidence=confidence,
            retrieved_files=retrieved_files, raw_capsule=capsule,
        )

    if category == "unanswerable":
        passed = confidence in ("none", None) or _contains(
            answer, "does not state"
        ) or _contains(answer, "not covered")
        detail = (
            "Correctly refused." if passed
            else f"Expected a refusal (confidence: none); got confidence="
                 f"{confidence!r}, answer={answer[:120]!r}"
        )
        return QuestionResult(
            id=q["id"], category=category, question=q["question"], passed=passed,
            detail=detail, latency_ms=elapsed_ms, confidence=confidence,
            retrieved_files=retrieved_files, raw_capsule=capsule,
        )

    source_documents = q.get("source_documents", [])
    retrieved_correct = [f for f in source_documents if f in retrieved_files]
    retrieval_ok = bool(retrieved_correct) if source_documents else True

    expected_facts = q.get("expected_key_facts", [])
    facts_hit = [f for f in expected_facts if _contains(combined_text, f)]
    facts_ok = (len(facts_hit) == len(expected_facts)) if expected_facts else True

    passed = retrieval_ok and facts_ok
    problems = []
    if not retrieval_ok:
        problems.append(
            f"none of the expected source(s) {source_documents} were retrieved "
            f"(got {retrieved_files})"
        )
    if not facts_ok:
        missing = [f for f in expected_facts if f not in facts_hit]
        problems.append(f"missing expected fact(s): {missing}")

    detail = "OK" if passed else "; ".join(problems)
    return QuestionResult(
        id=q["id"], category=category, question=q["question"], passed=passed,
        detail=detail, latency_ms=elapsed_ms, confidence=confidence,
        retrieved_files=retrieved_files, raw_capsule=capsule,
    )


def run(label: str, top_k: int, timeout: float, save_capsules: bool) -> int:
    ground_truth = json.loads(GROUND_TRUTH_PATH.read_text(encoding="utf-8"))
    questions = ground_truth["questions"]

    heading(f"RAG correctness eval — {label}  ({len(questions)} questions)")

    results: list[QuestionResult] = []
    for q in questions:
        started = time.perf_counter()
        try:
            capsule = post(
                "/api/ask",
                {"query": q["question"], "top_k": top_k, "generate": True},
                timeout=timeout,
            )
        except BridgeError as exc:
            print(f"  [{q['id']}] FAILED TO REACH PHONE: {exc}")
            results.append(QuestionResult(
                id=q["id"], category=q["category"], question=q["question"],
                passed=False, detail=str(exc), latency_ms=None, confidence=None,
            ))
            continue
        elapsed_ms = (time.perf_counter() - started) * 1000

        result = score_question(q, capsule, elapsed_ms)
        if not save_capsules:
            result.raw_capsule = None
        results.append(result)

        mark = "?" if result.passed is None else ("PASS" if result.passed else "FAIL")
        print(f"  [{q['id']:>4}] {mark:<4} ({q['category']}) {q['question'][:70]}")
        if result.passed is False:
            print(wrap(result.detail, indent="         "))

    _print_summary(results)
    _save_results(label, top_k, results)
    return 0 if all(r.passed is not False for r in results) else 1


def _print_summary(results: list[QuestionResult]) -> None:
    by_category: dict[str, list[QuestionResult]] = {}
    for r in results:
        by_category.setdefault(r.category, []).append(r)

    heading("Summary")
    for category, items in sorted(by_category.items()):
        scored = [r for r in items if r.passed is not None]
        passed = sum(1 for r in scored if r.passed)
        manual = len(items) - len(scored)
        line = f"  {category:<26} {passed}/{len(scored)} passed"
        if manual:
            line += f"  ({manual} needs manual review)"
        print(line)

    latencies = [r.latency_ms for r in results if r.latency_ms is not None]
    if latencies:
        latencies.sort()
        p50 = latencies[len(latencies) // 2]
        p90 = latencies[int(len(latencies) * 0.9)]
        print(f"\n  latency: median {p50:.0f} ms, p90 {p90:.0f} ms, n={len(latencies)}")


def _save_results(label: str, top_k: int, results: list[QuestionResult]) -> None:
    RESULTS_DIR.mkdir(exist_ok=True)
    timestamp = time.strftime("%Y%m%dT%H%M%S")
    out_path = RESULTS_DIR / f"{label}_{timestamp}.json"
    payload = {
        "label": label,
        "top_k": top_k,
        "timestamp": timestamp,
        "questions": [
            {
                "id": r.id,
                "category": r.category,
                "question": r.question,
                "passed": r.passed,
                "detail": r.detail,
                "latency_ms": r.latency_ms,
                "confidence": r.confidence,
                "retrieved_files": r.retrieved_files,
                **({"capsule": r.raw_capsule} if r.raw_capsule is not None else {}),
            }
            for r in results
        ],
    }
    out_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print(f"\n  Results written to {out_path.relative_to(CORPUS_DIR.parent)}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--label", required=True,
        help="Tags this run, e.g. \"gemma-2b-cpu\" or \"qwen3-1.7b-npu\" — "
             "lets later runs be compared against each other.",
    )
    parser.add_argument("--top-k", type=int, default=5)
    parser.add_argument("--timeout", type=float, default=120.0)
    parser.add_argument(
        "--save-capsules", action="store_true",
        help="Include the full capsule JSON per question in the results "
             "file — larger, but needed to manually review the "
             "\"scoring: manual\" questions afterward.",
    )
    args = parser.parse_args(argv)

    try:
        return run(args.label, args.top_k, args.timeout, args.save_capsules)
    except FileNotFoundError:
        print(f"Ground truth file not found: {GROUND_TRUTH_PATH}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
