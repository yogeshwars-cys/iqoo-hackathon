"""VaultLink — laptop side. Ask the phone a question with zero manual paste
per query, over Office Kit's clipboard mirror. No bridge_server.py, no LAN
address, no adb.

Requires the phone to be running the build with the **Link** tab (VaultLink
session started there) — see vault_rag_test/lib/link/vault_link_service.dart
for the protocol and why it has to be clipboard-polling, foreground-only.

    python vaultlink.py ping                  # is a session running over there?
    python vaultlink.py list                  # show the ground-truth question set
    python vaultlink.py ask s01               # ask by id, score the answer
    python vaultlink.py ask "free text"       # ask anything; scoring is skipped
    python vaultlink.py ask s01 --no-generate # retrieval only
    python vaultlink.py all                   # run the whole ground-truth set

Windows only (uses the Win32 clipboard directly, like officekit_clip.py, so
non-ASCII text survives the round trip).
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.wintypes as wt
import json
import sys
import time
import uuid
from pathlib import Path

HERE = Path(__file__).parent
OUT = HERE / "out"
TRUTH = OUT / "ground_truth_sensitive.json"

PREFIX = "VAULTLINK/1\n"
CF_UNICODETEXT = 13
GMEM_MOVEABLE = 0x0002

u32 = ctypes.WinDLL("user32", use_last_error=True)
k32 = ctypes.WinDLL("kernel32", use_last_error=True)
u32.OpenClipboard.argtypes = [wt.HWND]
u32.GetClipboardData.restype = wt.HANDLE
u32.SetClipboardData.argtypes = [wt.UINT, wt.HANDLE]
u32.SetClipboardData.restype = wt.HANDLE
u32.GetClipboardSequenceNumber.restype = wt.DWORD
k32.GlobalAlloc.argtypes = [wt.UINT, ctypes.c_size_t]
k32.GlobalAlloc.restype = wt.HGLOBAL
k32.GlobalLock.argtypes = [wt.HGLOBAL]
k32.GlobalLock.restype = wt.LPVOID
k32.GlobalUnlock.argtypes = [wt.HGLOBAL]


def _open() -> None:
    for _ in range(20):
        if u32.OpenClipboard(None):
            return
        time.sleep(0.05)
    raise OSError("clipboard is held by another process")


def clip_get() -> str:
    _open()
    try:
        h = u32.GetClipboardData(CF_UNICODETEXT)
        if not h:
            return ""
        p = k32.GlobalLock(h)
        try:
            return ctypes.wstring_at(p)
        finally:
            k32.GlobalUnlock(h)
    finally:
        u32.CloseClipboard()


def clip_set(text: str) -> None:
    data = ctypes.create_unicode_buffer(text)
    size = ctypes.sizeof(data)
    _open()
    try:
        u32.EmptyClipboard()
        h = k32.GlobalAlloc(GMEM_MOVEABLE, size)
        p = k32.GlobalLock(h)
        ctypes.memmove(p, data, size)
        k32.GlobalUnlock(h)
        if not u32.SetClipboardData(CF_UNICODETEXT, h):
            raise OSError("SetClipboardData failed")
    finally:
        u32.CloseClipboard()


def send_request(payload: dict) -> str:
    req_id = payload.setdefault("id", f"q_{uuid.uuid4().hex[:8]}")
    clip_set(PREFIX + json.dumps(payload))
    return req_id


def wait_for_reply(req_id: str, timeout: float = 300.0, quiet: bool = False) -> dict:
    """Polls the clipboard for a VaultLink reply matching req_id.

    A reply is any VAULTLINK/1 frame with the right id and no "op" key (only
    the laptop's own requests carry "op" — see vault_link_service.dart). An
    interim {"status": "processing"} frame is swallowed silently so the
    caller only sees "complete".
    """
    seen_processing = False
    deadline = time.time() + timeout
    last_seq = None
    while time.time() < deadline:
        time.sleep(0.3)
        seq = u32.GetClipboardSequenceNumber()
        if seq == last_seq:
            continue
        last_seq = seq
        text = clip_get()
        if not text.startswith(PREFIX):
            continue
        try:
            msg = json.loads(text[len(PREFIX):])
        except json.JSONDecodeError:
            continue
        if msg.get("id") != req_id or "op" in msg:
            continue
        if msg.get("status") == "processing":
            if not seen_processing and not quiet:
                print("  (phone picked it up, generating...)", file=sys.stderr)
            seen_processing = True
            continue
        return msg
    raise TimeoutError(
        f"no reply to {req_id} within {timeout}s — is a VaultLink session "
        f"running on the phone's Link tab?"
    )


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
    """Checks the generated answer and the extractive floor separately —
    see bridge/testdata/README.md for why collapsing them hides real bugs."""
    expected = q["expected_substrings"]
    gen = capsule.get("answer") or ""
    extracted = capsule.get("extracted_answer") or ""

    if not expected:
        ok = capsule.get("confidence") == "none"
        print(f"  [{'PASS' if ok else 'FAIL'}] unanswerable — "
              f"confidence={capsule.get('confidence')!r}")
        return ok

    gen_ok = all(e in gen for e in expected)
    ext_ok = all(e in extracted for e in expected)
    print(f"  [{'PASS' if gen_ok else 'FAIL'}] generated  {gen!r}")
    print(f"  [{'PASS' if ext_ok else 'FAIL'}] extractive {extracted!r}")
    return gen_ok


def cmd_ping(_args) -> int:
    req_id = send_request({"op": "ping"})
    print(f"ping sent ({req_id}), waiting for the phone...", file=sys.stderr)
    reply = wait_for_reply(req_id, timeout=15.0)
    if not reply.get("ok"):
        print(f"phone reported an error: {reply.get('error')}")
        return 1
    print(f"VaultLink session is up on the phone.")
    print(f"  engine:   {reply.get('engine')} · {reply.get('backend')}")
    print(f"  corpus:   {reply.get('total_indexed', '?')} chunks")
    return 0


def cmd_ask(args) -> int:
    query, q = resolve(args.query)
    req_id = send_request({
        "op": "query", "q": query, "k": args.top_k,
        "generate": not args.no_generate,
    })
    print(f"asking ({req_id}): {query}", file=sys.stderr)
    t0 = time.perf_counter()
    capsule = wait_for_reply(req_id, timeout=args.timeout)
    ms = (time.perf_counter() - t0) * 1000
    if not capsule.get("ok", True):
        print(f"phone reported an error: {capsule.get('error')}")
        return 1
    print(f"answer  ({ms:.0f} ms): {capsule.get('answer')}")
    print(f"confidence: {capsule.get('confidence')}   "
          f"generated={capsule.get('generation', {}).get('ran')}")
    OUT.mkdir(exist_ok=True)
    name = f"capsule_{q['id'] if q else req_id}.json"
    (OUT / name).write_text(json.dumps(capsule, indent=2, ensure_ascii=False),
                             encoding="utf-8")
    print(f"saved: {OUT / name}", file=sys.stderr)
    if q:
        score(capsule, q)
    return 0


def cmd_list(_args) -> int:
    truth = load_truth()
    if not truth:
        sys.exit(f"no ground truth at {TRUTH} — run gen_sensitive_doc.py first")
    print(f"{truth['document']}  (seed {truth['seed']})")
    for q in truth["questions"]:
        print(f"  {q['id']}  [{q['category']}]  {q['question']}")
    return 0


def cmd_all(args) -> int:
    truth = load_truth()
    if not truth:
        sys.exit(f"no ground truth at {TRUTH} — run gen_sensitive_doc.py first")
    passed = 0
    for q in truth["questions"]:
        print(f"\n--- {q['id']}: {q['question']}")
        req_id = send_request({
            "op": "query", "q": q["question"], "k": 5,
            "generate": not args.no_generate,
        })
        try:
            capsule = wait_for_reply(req_id, timeout=args.timeout, quiet=True)
        except TimeoutError as e:
            print(f"  ERROR: {e}")
            continue
        if not capsule.get("ok", True):
            print(f"  ERROR: {capsule.get('error')}")
            continue
        print(f"  answer: {capsule.get('answer')}")
        OUT.mkdir(exist_ok=True)
        (OUT / f"capsule_{q['id']}.json").write_text(
            json.dumps(capsule, indent=2, ensure_ascii=False), encoding="utf-8")
        passed += score(capsule, q)
    print(f"\n{passed}/{len(truth['questions'])} generated answers passed")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("ping").set_defaults(func=cmd_ping)
    sub.add_parser("list").set_defaults(func=cmd_list)

    p_ask = sub.add_parser("ask")
    p_ask.add_argument("query")
    p_ask.add_argument("--no-generate", action="store_true")
    p_ask.add_argument("-k", "--top-k", type=int, default=5)
    p_ask.add_argument("--timeout", type=float, default=300.0)
    p_ask.set_defaults(func=cmd_ask)

    p_all = sub.add_parser("all")
    p_all.add_argument("--no-generate", action="store_true")
    p_all.add_argument("--timeout", type=float, default=300.0)
    p_all.set_defaults(func=cmd_all)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
