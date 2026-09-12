"""Laptop side of the Office Kit clipboard round-trip.

Office Kit mirrors the Windows clipboard to the phone and back. This script
puts a query on the laptop clipboard, then waits for the phone to copy a
context capsule back (Vault tab -> Copy), and scores it against the
ground truth written by gen_sensitive_doc.py.

    python officekit_clip.py list                 # show the question set
    python officekit_clip.py send s01             # put question s01 on the clipboard
    python officekit_clip.py send "free text?"    # or any query
    python officekit_clip.py recv [s01]           # wait for the capsule, save + score it
    python officekit_clip.py ask s01              # send, then recv, in one go

Windows only (uses the Win32 clipboard directly so Unicode survives).
"""

from __future__ import annotations

import ctypes
import ctypes.wintypes as wt
import json
import sys
import time
from pathlib import Path

HERE = Path(__file__).parent
OUT = HERE / "out"
TRUTH = OUT / "ground_truth_sensitive.json"
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


def load_truth() -> dict:
    if not TRUTH.exists():
        sys.exit(f"no ground truth at {TRUTH} — run gen_sensitive_doc.py first")
    return json.loads(TRUTH.read_text(encoding="utf-8"))


def resolve(arg: str) -> tuple[str, dict | None]:
    if TRUTH.exists():
        for q in load_truth()["questions"]:
            if q["id"] == arg:
                return q["question"], q
    return arg, None


def score(capsule: dict, q: dict) -> None:
    expected = q["expected_substrings"]
    answer = capsule.get("answer", "")
    extracted = capsule.get("extracted_answer") or ""
    context = " ".join(c.get("content", "") for c in capsule.get("context", []))
    if not expected:
        ok = capsule.get("confidence") == "none"
        print(f"  [{'PASS' if ok else 'FAIL'}] unanswerable — confidence={capsule.get('confidence')!r}")
        return
    for label, text in (("answer", answer + " " + extracted), ("context", context)):
        hits = [e for e in expected if e in text]
        verdict = "PASS" if len(hits) == len(expected) else "FAIL"
        print(f"  [{verdict}] {label:<8} {len(hits)}/{len(expected)} expected values present")
    top = capsule.get("context", [{}])[0]
    print(f"  top chunk similarity {top.get('similarity')}  from {top.get('file')}")


def recv(q: dict | None, sent_query: str | None, timeout: float = 600) -> None:
    start_seq = u32.GetClipboardSequenceNumber()
    print("waiting for a capsule on the clipboard (Vault tab -> Copy on the phone) ...", file=sys.stderr)
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(0.5)
        if u32.GetClipboardSequenceNumber() == start_seq:
            continue
        start_seq = u32.GetClipboardSequenceNumber()
        text = clip_get().strip()
        try:
            capsule = json.loads(text)
        except json.JSONDecodeError:
            continue
        if not isinstance(capsule, dict) or "capsule_version" not in capsule:
            continue
        if sent_query and capsule.get("query", "").strip() != sent_query.strip():
            print(f"  (ignoring capsule for a different query: {capsule.get('query')!r})", file=sys.stderr)
            continue
        OUT.mkdir(exist_ok=True)
        name = f"capsule_{q['id'] if q else int(time.time())}.json"
        (OUT / name).write_text(json.dumps(capsule, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"query      {capsule.get('query')}")
        print(f"answer     {capsule.get('answer')}")
        print(f"confidence {capsule.get('confidence')}   generated={capsule.get('generation', {}).get('ran')}")
        print(f"saved      {OUT / name}")
        if q:
            score(capsule, q)
        return
    sys.exit("timed out waiting for a capsule")


def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] not in {"list", "send", "recv", "ask"}:
        sys.exit(__doc__)
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "list":
        t = load_truth()
        print(f"{t['document']}  (seed {t['seed']})")
        for q in t["questions"]:
            print(f"  {q['id']}  [{q['category']}]  {q['question']}")
    elif cmd == "send":
        query, _ = resolve(" ".join(args))
        clip_set(query)
        print(f"on clipboard: {query}")
    elif cmd == "recv":
        query, q = resolve(args[0]) if args else (None, None)
        recv(q, query if q else None)
    elif cmd == "ask":
        query, q = resolve(" ".join(args))
        clip_set(query)
        print(f"on clipboard: {query}\n-> paste into the Vault query box on the phone, run it, tap Copy", file=sys.stderr)
        recv(q, query)


if __name__ == "__main__":
    main()
