"""Ask the phone one question end to end, with no manual clipboard step and
no need to know the bridge's LAN address.

`vault_cli.client` already talks to `http://127.0.0.1:8000` by default (the
bridge is a local HTTP server; only the *phone* dials the LAN address, and
only once, from its Bridge tab). This script leans on that: it starts
`bridge_server.py` itself if nothing is listening, waits for the phone to be
linked, sends one query straight over HTTP, and scores the answer against
`out/ground_truth_sensitive.json` if the id matches one of those questions.

    python ask_one.py --list                 # show the question set
    python ask_one.py s01                     # ask by id, score it
    python ask_one.py "free text question"    # ask anything, no scoring
    python ask_one.py s01 --no-generate        # retrieval only (fast, ~250 ms)
    python ask_one.py --all                    # run the whole ground truth set

No Office Kit, no clipboard, no typing an IP anywhere in this file — the one
IP-shaped step left is the physical one, done once on the phone itself
(Bridge tab -> Connect), which `--status` still prints if it's needed.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).parent
BRIDGE_DIR = HERE.parent
OUT = HERE / "out"
TRUTH = OUT / "ground_truth_sensitive.json"
BRIDGE_URL = "http://127.0.0.1:8000"


def _get(path: str, timeout: float = 5.0) -> dict:
    with urllib.request.urlopen(f"{BRIDGE_URL}{path}", timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def _post(path: str, payload: dict, timeout: float) -> dict:
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        f"{BRIDGE_URL}{path}", data=body, method="POST",
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def ensure_bridge_running(startup_timeout: float = 15.0) -> None:
    """Starts bridge_server.py in the background if nothing answers on :8000."""
    try:
        _get("/api/status", timeout=2.0)
        return
    except Exception:
        pass

    print("bridge not running — starting bridge_server.py ...", file=sys.stderr)
    log = open(OUT / "bridge_server.log", "a", encoding="utf-8")
    OUT.mkdir(exist_ok=True)
    subprocess.Popen(
        [sys.executable, "bridge_server.py"],
        cwd=BRIDGE_DIR, stdout=log, stderr=subprocess.STDOUT,
        creationflags=subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0,
    )
    deadline = time.time() + startup_timeout
    while time.time() < deadline:
        try:
            _get("/api/status", timeout=2.0)
            print("bridge is up.", file=sys.stderr)
            return
        except Exception:
            time.sleep(0.5)
    sys.exit(f"bridge_server.py did not come up within {startup_timeout}s — "
              f"see {OUT / 'bridge_server.log'}")


def wait_for_phone(timeout: float = 300.0) -> dict:
    status = _get("/api/status")
    if status.get("phone_connected"):
        return status
    print("phone not linked. On the phone: Bridge tab -> Connect to one of:",
          file=sys.stderr)
    for addr in status.get("bridge_addresses", []):
        print(f"    {addr}:8000", file=sys.stderr)
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(1.0)
        status = _get("/api/status")
        if status.get("phone_connected"):
            print("phone linked.", file=sys.stderr)
            return status
    sys.exit("timed out waiting for the phone to link")


def load_truth() -> dict | None:
    return json.loads(TRUTH.read_text(encoding="utf-8")) if TRUTH.exists() else None


def resolve(arg: str) -> tuple[str, dict | None]:
    truth = load_truth()
    if truth:
        for q in truth["questions"]:
            if q["id"] == arg:
                return q["question"], q
    return arg, None


def score(capsule: dict, q: dict) -> bool:
    """Scores the *generated* answer and the extractive floor separately —
    a capsule can have a correct extractive quote sitting right next to a
    generated answer that got the wrong person's number. Collapsing the two
    into one substring check over both fields would hide exactly that gap
    (see s02/s08 in the seed-413172 run: extractive was right, generated
    was not)."""
    expected = q["expected_substrings"]
    gen = capsule.get("answer") or ""
    extracted = capsule.get("extracted_answer") or ""

    if not expected:
        ok = capsule.get("confidence") == "none"
        print(f"  [{'PASS' if ok else 'FAIL'}] unanswerable — "
              f"confidence={capsule.get('confidence')!r}")
        if not ok:
            print(f"        answer said: {gen[:120]!r}")
        return ok

    gen_ok = all(e in gen for e in expected)
    ext_ok = all(e in extracted for e in expected)
    print(f"  [{'PASS' if gen_ok else 'FAIL'}] generated answer   "
          f"({expected} {'in' if gen_ok else 'NOT in'} {gen!r})")
    print(f"  [{'PASS' if ext_ok else 'FAIL'}] extractive floor   "
          f"({expected} {'in' if ext_ok else 'NOT in'} {extracted!r})")
    return gen_ok


def ask(query: str, top_k: int = 5, generate: bool = True) -> dict:
    return _post("/api/ask", {"query": query, "top_k": top_k, "generate": generate},
                  timeout=300.0)


def run_one(arg: str, generate: bool, save: bool = True) -> bool | None:
    query, q = resolve(arg)
    print(f"asking: {query}", file=sys.stderr)
    t0 = time.perf_counter()
    capsule = ask(query, generate=generate)
    ms = (time.perf_counter() - t0) * 1000
    print(f"answer  ({ms:.0f} ms): {capsule.get('answer')}")
    print(f"confidence: {capsule.get('confidence')}   "
          f"generated={capsule.get('generation', {}).get('ran')}")
    if save:
        OUT.mkdir(exist_ok=True)
        name = f"capsule_{q['id'] if q else int(time.time())}.json"
        (OUT / name).write_text(json.dumps(capsule, indent=2, ensure_ascii=False),
                                 encoding="utf-8")
        print(f"saved: {OUT / name}", file=sys.stderr)
    if q:
        return score(capsule, q)
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("query", nargs="?", help="question id (s01...) or free text")
    ap.add_argument("--list", action="store_true", help="show the ground-truth question set")
    ap.add_argument("--all", action="store_true", help="run every ground-truth question")
    ap.add_argument("--no-generate", action="store_true", help="retrieval only, no reasoner")
    ap.add_argument("--phone-timeout", type=float, default=300.0)
    args = ap.parse_args()

    if args.list:
        truth = load_truth()
        if not truth:
            sys.exit(f"no ground truth at {TRUTH} — run gen_sensitive_doc.py first")
        print(f"{truth['document']}  (seed {truth['seed']})")
        for q in truth["questions"]:
            print(f"  {q['id']}  [{q['category']}]  {q['question']}")
        return 0

    ensure_bridge_running()
    wait_for_phone(args.phone_timeout)

    if args.all:
        truth = load_truth()
        if not truth:
            sys.exit(f"no ground truth at {TRUTH} — run gen_sensitive_doc.py first")
        passed = 0
        for q in truth["questions"]:
            print(f"\n--- {q['id']}: {q['question']}")
            ok = run_one(q["id"], not args.no_generate)
            passed += bool(ok)
        print(f"\n{passed}/{len(truth['questions'])} generated answers passed")
        return 0

    if not args.query:
        ap.print_help()
        return 2

    run_one(args.query, not args.no_generate)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
