"""VaultLink — laptop side. Ask the phone a question with zero manual paste
per query, over Office Kit's clipboard mirror. No bridge_server.py, no LAN
address, no adb.

Requires the phone to be running the build with the **Link** tab (VaultLink
session started there) — see vault_rag_test/lib/link/vault_link_service.dart.

    python vaultlink.py pair XXXXX-XXXXX-XXXXX-XXXXX   # once: code from the phone's Link tab
    python vaultlink.py enroll                # once: pin the phone's signing key
    python vaultlink.py ping                  # is a session running over there?
    python vaultlink.py list                  # show the ground-truth question set
    python vaultlink.py ask s01               # ask by id, verify + score the answer
    python vaultlink.py ask "free text"       # ask anything; scoring is skipped
    python vaultlink.py ask s01 --no-generate # retrieval only
    python vaultlink.py all                   # run the whole ground-truth set
    python vaultlink.py verify capsule.json   # verify a saved capsule offline
    python vaultlink.py unpair / unenroll

SECURITY MODEL (details in SECURITY.md at the repo root):

  * Requests and replies are VAULTLINK/2 frames: AES-256-GCM under keys
    derived from the pairing code, which is typed in, never pasted. Other
    clipboard readers see ciphertext; other clipboard writers cannot query.
  * Every capsule is verified with process_received_capsule(): canonical
    digest, ECDSA-P256 signature, and the key pinned by `enroll`. Only a
    capsule signed by the pinned key prints the hardware-verified line.
  * After a reply is read, the clipboard is scrubbed at t=0 of a 20-second
    countdown, and only if it still holds that exact reply.

`--insecure-v1` speaks the old plaintext protocol (the phone must have legacy
mode switched on). Nothing it receives is treated as trusted.

Windows only (Win32 clipboard directly, so non-ASCII text survives).
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
sys.path.insert(0, str(HERE.parent))

from vault_cli import capsule_verify as cv  # noqa: E402
from vault_cli import vaultlink_protocol as vp  # noqa: E402

CLIPBOARD_TTL_S = 20
CF_UNICODETEXT = 13
GMEM_MOVEABLE = 0x0002

u32 = ctypes.WinDLL("user32", use_last_error=True)
k32 = ctypes.WinDLL("kernel32", use_last_error=True)
u32.OpenClipboard.argtypes = [wt.HWND]
u32.OpenClipboard.restype = wt.BOOL
u32.EmptyClipboard.restype = wt.BOOL
u32.CloseClipboard.restype = wt.BOOL
u32.GetClipboardData.argtypes = [wt.UINT]
u32.GetClipboardData.restype = wt.HANDLE
u32.SetClipboardData.argtypes = [wt.UINT, wt.HANDLE]
u32.SetClipboardData.restype = wt.HANDLE
u32.GetClipboardSequenceNumber.restype = wt.DWORD
u32.RegisterClipboardFormatW.argtypes = [wt.LPCWSTR]
u32.RegisterClipboardFormatW.restype = wt.UINT
k32.GlobalAlloc.argtypes = [wt.UINT, ctypes.c_size_t]
k32.GlobalAlloc.restype = wt.HGLOBAL
k32.GlobalLock.argtypes = [wt.HGLOBAL]
k32.GlobalLock.restype = wt.LPVOID
k32.GlobalUnlock.argtypes = [wt.HGLOBAL]
k32.GlobalFree.argtypes = [wt.HGLOBAL]


# ---------------------------------------------------------------------------
# Win32 clipboard
# ---------------------------------------------------------------------------

def _open() -> None:
    for _ in range(20):
        if u32.OpenClipboard(None):
            return
        time.sleep(0.05)
    raise OSError("clipboard is held by another process")


def _read_locked() -> str:
    """Caller must hold the clipboard open."""
    h = u32.GetClipboardData(CF_UNICODETEXT)
    if not h:
        return ""
    p = k32.GlobalLock(h)
    if not p:
        return ""
    try:
        return ctypes.wstring_at(p)
    finally:
        k32.GlobalUnlock(h)


def clip_get() -> str:
    _open()
    try:
        return _read_locked()
    finally:
        u32.CloseClipboard()


def _set_dword_format(name: str, value: int) -> None:
    fmt = u32.RegisterClipboardFormatW(name)
    h = k32.GlobalAlloc(GMEM_MOVEABLE, 4)
    p = k32.GlobalLock(h)
    ctypes.memmove(p, ctypes.byref(wt.DWORD(value)), 4)
    k32.GlobalUnlock(h)
    if not u32.SetClipboardData(fmt, h):
        k32.GlobalFree(h)


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
            k32.GlobalFree(h)
            raise OSError("SetClipboardData failed")
        # Keep our own frames out of Win+V history and Windows cloud
        # clipboard. Not ExcludeClipboardContentFromMonitorProcessing: that
        # would also hide the frame from Office Kit, which carries it.
        _set_dword_format("CanIncludeInClipboardHistory", 0)
        _set_dword_format("CanUploadToCloudClipboard", 0)
    finally:
        u32.CloseClipboard()


def clip_scrub_if_unchanged(expected: str) -> str:
    """Empties the clipboard only if it still holds exactly ``expected``.

    Read, compare and EmptyClipboard all happen inside one OpenClipboard
    session, so no other process can write in between. Returns
    "cleared", "replaced" or "failed:<reason>" — never claims success it did
    not get from the API.
    """
    try:
        _open()
    except OSError as e:
        return f"failed:{e}"
    try:
        if _read_locked() != expected:
            return "replaced"
        if not u32.EmptyClipboard():
            return f"failed:EmptyClipboard error {ctypes.get_last_error()}"
        return "cleared"
    finally:
        u32.CloseClipboard()


def ephemeral_countdown(expected: str, ttl: int = CLIPBOARD_TTL_S) -> str:
    """Visible 20..1 countdown, then a conditional scrub at t=0.

    Ctrl+C skips the wait and scrubs immediately — interrupting should make
    the clipboard safer, not leave the capsule on it.
    """
    tty = sys.stderr.isatty()
    try:
        for remaining in range(ttl, 0, -1):
            msg = f"[clipboard] capsule auto-destructs in {remaining:2d}s"
            print(f"\r{msg}" if tty else msg, end="" if tty else "\n",
                  file=sys.stderr, flush=True)
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        if tty:
            print(file=sys.stderr)
    outcome = clip_scrub_if_unchanged(expected)
    if outcome == "cleared":
        print("[clipboard] t=0: capsule erased (EmptyClipboard succeeded)", file=sys.stderr)
    elif outcome == "replaced":
        print("[clipboard] t=0: clipboard changed since the reply — left untouched",
              file=sys.stderr)
    else:
        print(f"[clipboard] t=0: scrub NOT confirmed ({outcome}) — clear it manually",
              file=sys.stderr)
    return outcome


# ---------------------------------------------------------------------------
# Capsule verification
# ---------------------------------------------------------------------------

def security_line(level: str | None, device: str | None) -> str | None:
    """The verified-enclave line, built only from signed capsule fields.

    Produces e.g. "Hardware Enclave: Qualcomm TEE (Qualcomm SM8750) - Verified
    ECDSA-P256 Signature". The vendor word appears only when the signed
    device string names it; nothing about the SoC is assumed.
    """
    if level not in ("tee", "strongbox"):
        return None
    parts = [p.strip() for p in (device or "").split("·")]
    soc = next((p for p in parts if p.lower().startswith("qualcomm")), None)
    if level == "strongbox":
        enclave = "StrongBox secure element"
    else:
        enclave = "Qualcomm TEE" if soc else "TEE"
    where = f" ({soc})" if soc else (f" ({parts[0]})" if parts and parts[0] else "")
    return f"[🛡️ SECURITY] Hardware Enclave: {enclave}{where} - Verified ECDSA-P256 Signature"


def process_received_capsule(capsule: dict, trust_store: cv.TrustStore | None = None
                             ) -> cv.VerificationResult:
    """Verifies a capsule and prints what was, and was not, established."""
    store = trust_store or cv.TrustStore()
    result = cv.verify_capsule(capsule, store)
    out = sys.stdout
    if result.trusted:
        prov = capsule.get("provenance", {})
        line = security_line(result.security_level, prov.get("device"))
        if line:
            print(line, file=out)
        else:
            # Pinned key verified, but the phone did not report secure
            # hardware for it. Say exactly that.
            print(f"[SECURITY] Verified ECDSA-P256 signature from the pinned device key "
                  f"(key security level reported: {result.security_level!r} — "
                  f"not hardware-backed)", file=out)
        attestation = (store.get() or {}).get("attestation") or {}
        proof = ("attestation root verified at enrollment" if attestation.get("root_trusted")
                 else "hardware level is device-reported; attestation root not verified")
        print(f"           key {result.fingerprint} · {proof}", file=out)
    elif result.status is cv.Status.NOT_ENROLLED:
        print("[SECURITY] Signature is valid but NO device key is pinned — not trusted. "
              "Run `vaultlink.py enroll`.", file=out)
        print(f"           presented key {result.fingerprint}", file=out)
    else:
        print(f"[SECURITY] REJECTED: {result.status.value}"
              f"{f' ({result.detail})' if result.detail else ''}", file=out)
    return result


# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

def _keys_or_exit() -> vp.LinkKeys:
    keys = vp.load_pairing()
    if keys is None:
        sys.exit("not paired — run: python vaultlink.py pair <code from the phone's Link tab>")
    return keys


def send_request(op: str, keys: vp.LinkKeys | None, **params) -> str:
    """Seals and writes a request; returns its id. keys=None means legacy v1."""
    if keys is None:
        body = {"id": f"q_{uuid.uuid4().hex[:8]}", "op": op, **params}
        clip_set(vp.V1_PREFIX + json.dumps(body))
    else:
        body = vp.new_request(op, **params)
        clip_set(vp.seal(keys, "req", body))
    return body["id"]


def wait_for_reply(req_id: str, keys: vp.LinkKeys | None, timeout: float = 300.0,
                   quiet: bool = False) -> tuple[dict, str]:
    """Polls the clipboard for the reply to ``req_id``.

    Returns (reply body, raw clipboard text) — the raw text is what the
    countdown later compares against before scrubbing.
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
        if keys is not None:
            try:
                msg = vp.open_frame(keys, "rep", text)
            except vp.FrameRejected:
                continue  # our own request, another pairing, or tampering
        else:
            if not text.startswith(vp.V1_PREFIX):
                continue
            try:
                msg = json.loads(text[len(vp.V1_PREFIX):])
            except json.JSONDecodeError:
                continue
            if "op" in msg:
                continue
        if msg.get("id") != req_id:
            continue
        if msg.get("status") == "processing":
            if not seen_processing and not quiet:
                print("  (phone picked it up, generating...)", file=sys.stderr)
            seen_processing = True
            continue
        return msg, text
    raise TimeoutError(
        f"no reply to {req_id} within {timeout}s — is a VaultLink session running on "
        f"the phone's Link tab{'' if keys is None else ', paired with this laptop'}?")


def _transport(args) -> vp.LinkKeys | None:
    if getattr(args, "insecure_v1", False):
        print("WARNING: legacy VAULTLINK/1 — plaintext and unauthenticated.", file=sys.stderr)
        return None
    return _keys_or_exit()


# ---------------------------------------------------------------------------
# Ground truth
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_pair(args) -> int:
    try:
        root = vp.root_from_pairing_code(args.code)
    except ValueError as e:
        sys.exit(str(e))
    path = vp.save_pairing(root)
    keys = vp.LinkKeys.from_root(root)
    print(f"paired: key id {keys.kid} (must match the phone's Link tab)")
    print(f"stored under Windows DPAPI at {path}")
    print("next: python vaultlink.py enroll")
    return 0


def cmd_unpair(_args) -> int:
    print("pairing removed" if vp.clear_pairing() else "was not paired")
    return 0


def cmd_enroll(args) -> int:
    keys = _keys_or_exit()
    req_id = send_request("enroll", keys)
    print(f"enroll sent ({req_id}), waiting for the phone...", file=sys.stderr)
    reply, raw = wait_for_reply(req_id, keys, timeout=30.0)
    try:
        if not reply.get("ok"):
            print(f"phone refused: {reply.get('error')}")
            return 1
        key_der = bytes.fromhex(reply["public_key"])
        root_der = Path(args.attestation_root).read_bytes() if args.attestation_root else None
        if root_der and root_der.lstrip().startswith(b"-----BEGIN"):
            from cryptography import x509
            from cryptography.hazmat.primitives import serialization
            root_der = x509.load_pem_x509_certificate(root_der).public_bytes(
                serialization.Encoding.DER)
        att = cv.check_attestation_chain(reply.get("attestation_chain") or [], key_der, root_der)

        print(f"device key   {cv.key_fingerprint(key_der)}")
        print(f"reported     {reply.get('enclave')}  {reply.get('key_status')}")
        if att["present"]:
            kd = att["key_description"] or {}
            print(f"attestation  chain_valid={att['chain_valid']} "
                  f"leaf_matches_key={att['leaf_matches_key']} "
                  f"root_trusted={att['root_trusted']}")
            print(f"             attestation level={kd.get('attestation_security_level')} "
                  f"keymint level={kd.get('keymint_security_level')}")
            if not att["root_trusted"]:
                print("             root not checked against a trusted Google root "
                      "(pass --attestation-root) — hardware level is UNPROVEN")
            if att["chain_valid"] and not att["leaf_matches_key"]:
                print("REFUSING: attestation chain is for a different key")
                return 1
        else:
            print("attestation  none supplied by the device")

        store = cv.TrustStore()
        record = store.pin(key_der, meta={
            "enclave": reply.get("enclave"),
            "key_status": reply.get("key_status"),
            "attestation": {k: att[k] for k in ("chain_valid", "leaf_matches_key",
                                                "root_trusted", "key_description")},
        })
        print(f"pinned in {store.path} — fingerprint {record['fingerprint']}")
        return 0
    except ValueError as e:
        print(f"enrollment failed: {e}")
        return 1
    finally:
        ephemeral_countdown(raw, args.ttl) if args.ttl > 0 else clip_scrub_if_unchanged(raw)


def cmd_unenroll(_args) -> int:
    print("pinned key removed" if cv.TrustStore().unpin() else "no key was pinned")
    return 0


def cmd_ping(args) -> int:
    keys = _transport(args)
    req_id = send_request("ping", keys)
    print(f"ping sent ({req_id}), waiting for the phone...", file=sys.stderr)
    reply, raw = wait_for_reply(req_id, keys, timeout=15.0)
    clip_scrub_if_unchanged(raw)
    if not reply.get("ok"):
        print(f"phone reported an error: {reply.get('error')}")
        return 1
    print(f"VaultLink session is up on the phone ({'sealed' if keys else 'LEGACY v1'}).")
    print(f"  engine:   {reply.get('engine')} · {reply.get('backend')}")
    print(f"  corpus:   {reply.get('total_indexed', '?')} chunks")
    return 0


def _save_capsule(name: str, capsule: dict) -> Path:
    OUT.mkdir(exist_ok=True)
    path = OUT / name
    path.write_text(json.dumps(capsule, indent=2, ensure_ascii=False), encoding="utf-8")
    return path


def cmd_ask(args) -> int:
    keys = _transport(args)
    query, q = resolve(args.query)
    req_id = send_request("query", keys, q=query, k=args.top_k,
                          generate=not args.no_generate)
    print(f"asking ({req_id}): {query}", file=sys.stderr)
    t0 = time.perf_counter()
    capsule, raw = wait_for_reply(req_id, keys, timeout=args.timeout)
    ms = (time.perf_counter() - t0) * 1000
    try:
        if not capsule.get("ok", True):
            print(f"phone reported an error: {capsule.get('error')}")
            return 1
        result = process_received_capsule(capsule)
        print(f"answer  ({ms:.0f} ms): {capsule.get('answer')}")
        print(f"gating: {capsule.get('gating', {}).get('path')}   "
              f"confidence: {capsule.get('confidence')}   "
              f"generated={capsule.get('generation', {}).get('ran')}")
        path = _save_capsule(f"capsule_{q['id'] if q else req_id}.json", capsule)
        print(f"saved: {path}  (decrypted vault content — delete when done)", file=sys.stderr)
        if q:
            score(capsule, q)
        return 0 if result.trusted else 2
    finally:
        if args.ttl > 0:
            ephemeral_countdown(raw, args.ttl)
        else:
            clip_scrub_if_unchanged(raw)


def cmd_all(args) -> int:
    keys = _transport(args)
    truth = load_truth()
    if not truth:
        sys.exit(f"no ground truth at {TRUTH} — run gen_sensitive_doc.py first")
    passed = trusted = 0
    raw = None
    try:
        for q in truth["questions"]:
            print(f"\n--- {q['id']}: {q['question']}")
            req_id = send_request("query", keys, q=q["question"], k=5,
                                  generate=not args.no_generate)
            try:
                capsule, raw = wait_for_reply(req_id, keys, timeout=args.timeout, quiet=True)
            except TimeoutError as e:
                print(f"  ERROR: {e}")
                continue
            if not capsule.get("ok", True):
                print(f"  ERROR: {capsule.get('error')}")
                continue
            trusted += process_received_capsule(capsule).trusted
            print(f"  answer: {capsule.get('answer')}")
            _save_capsule(f"capsule_{q['id']}.json", capsule)
            passed += score(capsule, q)
    finally:
        # Each request overwrites the previous reply, so one countdown at the
        # end covers the only capsule still on the clipboard.
        if raw is not None:
            ephemeral_countdown(raw, args.ttl) if args.ttl > 0 else clip_scrub_if_unchanged(raw)
    n = len(truth["questions"])
    print(f"\n{passed}/{n} generated answers passed · {trusted}/{n} capsules trusted")
    return 0


def cmd_verify(args) -> int:
    try:
        capsule = json.loads(Path(args.file).read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        sys.exit(f"cannot read capsule: {e}")
    return 0 if process_received_capsule(capsule).trusted else 2


def cmd_list(_args) -> int:
    truth = load_truth()
    if not truth:
        sys.exit(f"no ground truth at {TRUTH} — run gen_sensitive_doc.py first")
    print(f"{truth['document']}  (seed {truth['seed']})")
    for q in truth["questions"]:
        print(f"  {q['id']}  [{q['category']}]  {q['question']}")
    return 0


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def transport_flags(p):
        p.add_argument("--insecure-v1", action="store_true",
                       help="legacy plaintext protocol (phone must enable it)")
        p.add_argument("--ttl", type=int, default=CLIPBOARD_TTL_S,
                       help="seconds before the reply is scrubbed (0 = immediately)")

    p = sub.add_parser("pair"); p.add_argument("code"); p.set_defaults(func=cmd_pair)
    sub.add_parser("unpair").set_defaults(func=cmd_unpair)
    p = sub.add_parser("enroll")
    p.add_argument("--attestation-root", help="trusted attestation root certificate (PEM/DER)")
    p.add_argument("--ttl", type=int, default=0)
    p.set_defaults(func=cmd_enroll)
    sub.add_parser("unenroll").set_defaults(func=cmd_unenroll)

    p = sub.add_parser("ping"); transport_flags(p); p.set_defaults(func=cmd_ping)
    sub.add_parser("list").set_defaults(func=cmd_list)
    p = sub.add_parser("verify"); p.add_argument("file"); p.set_defaults(func=cmd_verify)

    p_ask = sub.add_parser("ask")
    p_ask.add_argument("query")
    p_ask.add_argument("--no-generate", action="store_true")
    p_ask.add_argument("-k", "--top-k", type=int, default=5)
    p_ask.add_argument("--timeout", type=float, default=300.0)
    transport_flags(p_ask)
    p_ask.set_defaults(func=cmd_ask)

    p_all = sub.add_parser("all")
    p_all.add_argument("--no-generate", action="store_true")
    p_all.add_argument("--timeout", type=float, default=300.0)
    transport_flags(p_all)
    p_all.set_defaults(func=cmd_all)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
