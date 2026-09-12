"""`vault-query` — ask the phone a question, get a context capsule back.

    vault-query "What is the maximum notional order limit?"
    vault-query "..." --json > capsule.json
    vault-query "..." --no-generate      # retrieval only, no LLM
    vault-query --status

Two models run on the device: MiniLM encodes the query and finds the
chunks, then Gemma reads those chunks and writes them up as a fixed-schema
JSON capsule. If no model is loaded the capsule still comes back — with the
answer quoted verbatim from the corpus instead of written. That degradation
is the design, not a fallback nobody expects, so the output labels which one
you got every time.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from typing import Any, Dict, List

from .client import (
    RULE,
    TIMEOUT_ASK,
    TIMEOUT_STATUS,
    BridgeError,
    fail,
    get,
    heading,
    post,
    wrap,
)


def show_status() -> int:
    try:
        data = get("/api/status", timeout=TIMEOUT_STATUS)
    except BridgeError as exc:
        return fail(str(exc))

    connected = data.get("phone_connected", False)
    heading(f"vault · bridge online · phone "
            f"{'LINKED' if connected else 'not connected'}")

    if not connected:
        print("  Connect the phone app's Bridge tab to one of:")
        for address in data.get("bridge_addresses", []):
            print(f"      {address}:8000")
        print()
        return 1

    info = data.get("phone_device_info", {}) or {}
    compute = info.get("compute", {}) or {}
    device = compute.get("device", {}) or {}
    llm = info.get("llm", {}) or {}

    name = " ".join(
        str(v) for v in (device.get("manufacturer"), device.get("model")) if v
    )
    print(f"  Device:   {name or 'unknown'} "
          f"{device.get('soc_model') or ''}".rstrip())
    print(f"  Encoder:  MiniLM-L6-v2 · {info.get('backend')} · "
          f"{info.get('embedding_dim')}-dim")

    if llm.get("state") == "ready":
        print(f"  Reasoner: {llm.get('model')} · "
              f"{llm.get('backend', '?').upper()} · "
              f"loaded in {llm.get('load_ms', '?')} ms")
    else:
        print(f"  Reasoner: not loaded ({llm.get('state', 'unknown')}) — "
              f"capsules will be retrieval-only")
    print(f"  Corpus:   {info.get('total_indexed', 0)} chunks")

    # Each lane is tagged with how it was obtained. "NPU unavailable" is the
    # expected answer on production Android, not a failure of this tool.
    print()
    for label, value_key, kind_key in (
        ("CPU", "cpu_percent", "cpu_kind"),
        ("GPU", "gpu_percent", "gpu_kind"),
        ("NPU", "npu_percent", "npu_kind"),
    ):
        value = compute.get(value_key)
        kind = compute.get(kind_key, "?")
        rendered = f"{value:5.1f} %" if value is not None else "unavailable"
        print(f"  {label:<9} {rendered:>12}   [{kind}]")
    duty = compute.get("inference_duty_percent") or 0.0
    print(f"  {'Infer':<9} {f'{duty:5.1f} %':>12}   [derived]")

    thermal = compute.get("thermal") or {}
    if thermal.get("throttling"):
        print(f"\n  Thermal:  {thermal.get('label')} — clocks are being "
              f"limited.")
    print()
    return 0


def render(capsule: Dict[str, Any], roundtrip_ms: float) -> None:
    generation = capsule.get("generation", {}) or {}
    generated = generation.get("ran") and not generation.get("parse_error")

    heading(f"vault-query · {capsule.get('query', '')}")

    retrieval = capsule.get("retrieval", {}) or {}
    line = (f"  retrieval {retrieval.get('latency_ms', '?')} ms "
            f"(encoder {retrieval.get('embed_ms', '?')} ms) · "
            f"{retrieval.get('chunks_scanned', '?')} chunks scanned")
    if generation.get("ran"):
        line += (f" · generation {generation.get('elapsed_ms', '?')} ms "
                 f"on {str(generation.get('backend', '?')).upper()}")
    print(line)
    print(f"  roundtrip {roundtrip_ms:.0f} ms")

    print()
    label = "ANSWER (generated on-device)" if generated \
        else "ANSWER (extracted verbatim — no model ran)"
    print(f"  {label}   confidence: {capsule.get('confidence', '?')}")
    print()
    print(wrap(capsule.get("answer", ""), indent="    "))
    print()

    facts: List[Dict[str, Any]] = capsule.get("key_facts") or []
    if facts:
        print("  KEY FACTS")
        for fact in facts:
            # The badge is a substring check against the retrieved text, not
            # a judgement about truth. A model that invents a quote is caught
            # here, which is the whole reason verbatim is mandatory.
            mark = "OK " if fact.get("verified") else "?? "
            print(f"    [{mark}] {fact.get('fact')}")
            if fact.get("verbatim"):
                print(f"           {fact['verbatim'][:70]}")
            if fact.get("source"):
                print(f"           — {fact['source']}")
        print()

    caveats = capsule.get("caveats") or []
    if caveats:
        print("  CAVEATS")
        for caveat in caveats:
            print(wrap(f"- {caveat}", indent="    ", hanging="      "))
        print()

    sources = capsule.get("sources") or []
    if sources:
        print("  SOURCES")
        for source in sources:
            print(f"    {source.get('similarity'):.4f}  {source.get('file')}")
        print()

    if generation.get("parse_error"):
        print(f"  NOTE: {generation['parse_error']}")
        print()
    print(RULE)


def run_query(text: str, top_k: int, generate: bool,
              as_json: bool, show_context: bool) -> int:
    started = time.perf_counter()
    try:
        capsule = post(
            "/api/ask",
            {"query": text, "top_k": top_k, "generate": generate},
            timeout=TIMEOUT_ASK,
        )
    except BridgeError as exc:
        return fail(str(exc))

    if "error" in capsule:
        return fail(capsule["error"])

    roundtrip = (time.perf_counter() - started) * 1000

    if as_json:
        # Straight to stdout so it pipes and redirects cleanly. Everything
        # human-facing in this command goes to stderr for the same reason.
        json.dump(capsule, sys.stdout, indent=2, ensure_ascii=False)
        print()
        return 0

    render(capsule, roundtrip)

    if show_context:
        print()
        for i, chunk in enumerate(capsule.get("context") or [], 1):
            print(f"  --- context {i} · {chunk.get('file')} "
                  f"· cosine {chunk.get('similarity')} ---")
            print(chunk.get("content", ""))
            print()
    return 0


def main(argv: List[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="vault-query",
        description="Ask the phone a question and receive a context capsule.",
    )
    parser.add_argument("prompt", nargs="*", help="the question")
    parser.add_argument("--status", action="store_true",
                        help="show link, models and live compute telemetry")
    parser.add_argument("-k", "--top-k", type=int, default=5,
                        help="chunks to retrieve (default 5)")
    parser.add_argument("--no-generate", action="store_true",
                        help="skip the reasoning model; retrieval only")
    parser.add_argument("--json", action="store_true",
                        help="print the raw capsule JSON to stdout")
    parser.add_argument("--context", action="store_true",
                        help="also print the full retrieved chunks")
    args = parser.parse_args(argv)

    if args.status:
        return show_status()
    if not args.prompt:
        parser.print_help()
        return 2

    return run_query(
        " ".join(args.prompt),
        args.top_k,
        not args.no_generate,
        args.json,
        args.context,
    )


if __name__ == "__main__":
    raise SystemExit(main())
