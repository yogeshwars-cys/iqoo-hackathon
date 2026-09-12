"""VAULTLINK/2 — laptop side of the sealed clipboard protocol.

Mirrors vault_rag_test/lib/link/vaultlink_secure.dart. Pure functions and a
small codec; the Win32 clipboard handling lives in bridge/testdata/vaultlink.py.

    root  = HMAC-SHA256(key=b"vaultlink/2 pairing", msg=normalised code)
    K_req = HMAC-SHA256(root, b"vaultlink/2 req")      laptop -> phone
    K_rep = HMAC-SHA256(root, b"vaultlink/2 rep")      phone -> laptop
    kid   = hex(HMAC-SHA256(root, b"vaultlink/2 kid"))[:16]

    frame = "VAULTLINK/2\\n" + {"kid": kid, "dir": "req"|"rep",
                                "ct": base64(IV(12) || AES-256-GCM(ct || tag(16)))}
    AAD   = b"VAULTLINK/2|" + dir + b"|" + kid

The root is stored on disk only under Windows DPAPI (CryptProtectData, user
scope): unreadable to other Windows accounts, readable to anything running as
this user. The pairing code itself is never stored.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import sys
import time
import uuid
from dataclasses import dataclass
from pathlib import Path

try:
    from cryptography.exceptions import InvalidTag
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    HAVE_CRYPTOGRAPHY = True
except ImportError:  # pragma: no cover
    HAVE_CRYPTOGRAPHY = False

V1_PREFIX = "VAULTLINK/1\n"
V2_PREFIX = "VAULTLINK/2\n"
CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
PAIRING_CODE_LENGTH = 20


class FrameRejected(Exception):
    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


def normalise_pairing_code(code: str) -> str | None:
    out = []
    for ch in code.upper():
        if ch in "- ":
            continue
        ch = {"O": "0", "I": "1", "L": "1"}.get(ch, ch)
        if ch not in CROCKFORD:
            return None
        out.append(ch)
    return "".join(out) if len(out) == PAIRING_CODE_LENGTH else None


@dataclass(frozen=True)
class LinkKeys:
    request_key: bytes
    reply_key: bytes
    kid: str

    @classmethod
    def from_root(cls, root: bytes) -> "LinkKeys":
        if len(root) != 32:
            raise ValueError("pairing root must be 32 bytes")
        d = lambda label: hmac.new(root, label, hashlib.sha256).digest()  # noqa: E731
        return cls(d(b"vaultlink/2 req"), d(b"vaultlink/2 rep"),
                   d(b"vaultlink/2 kid").hex()[:16])


def root_from_pairing_code(code: str) -> bytes:
    normalised = normalise_pairing_code(code)
    if normalised is None:
        raise ValueError("not a valid 20-character VaultLink pairing code")
    return hmac.new(b"vaultlink/2 pairing", normalised.encode("ascii"),
                    hashlib.sha256).digest()


def _aad(direction: str, kid: str) -> bytes:
    return f"VAULTLINK/2|{direction}|{kid}".encode("utf-8")


def seal(keys: LinkKeys, direction: str, body: dict) -> str:
    key = keys.request_key if direction == "req" else keys.reply_key
    iv = os.urandom(12)
    ct = AESGCM(key).encrypt(iv, json.dumps(body).encode("utf-8"), _aad(direction, keys.kid))
    outer = {"kid": keys.kid, "dir": direction, "ct": base64.b64encode(iv + ct).decode("ascii")}
    return V2_PREFIX + json.dumps(outer)


def open_frame(keys: LinkKeys, direction: str, frame: str) -> dict:
    if not frame.startswith(V2_PREFIX):
        raise FrameRejected("not_v2")
    try:
        outer = json.loads(frame[len(V2_PREFIX):])
        blob = base64.b64decode(outer["ct"], validate=True)
    except (ValueError, KeyError, TypeError) as e:
        raise FrameRejected("malformed") from e
    if outer.get("kid") != keys.kid:
        raise FrameRejected("wrong_key")
    if outer.get("dir") != direction:
        raise FrameRejected("wrong_direction")
    if len(blob) < 28:
        raise FrameRejected("malformed")
    key = keys.request_key if direction == "req" else keys.reply_key
    try:
        plain = AESGCM(key).decrypt(blob[:12], blob[12:], _aad(direction, keys.kid))
    except InvalidTag as e:
        raise FrameRejected("bad_seal") from e
    try:
        body = json.loads(plain.decode("utf-8"))
    except ValueError as e:
        raise FrameRejected("malformed") from e
    if not isinstance(body, dict):
        raise FrameRejected("malformed")
    return body


def new_request(op: str, **params) -> dict:
    """A fresh request body: unique id, current timestamp in ms."""
    return {"id": f"q_{uuid.uuid4().hex[:12]}", "op": op,
            "ts": int(time.time() * 1000), **params}


# ---------------------------------------------------------------------------
# Pairing storage (DPAPI)
# ---------------------------------------------------------------------------

def pairing_path() -> Path:
    home = Path(os.environ.get("VAULTLINK_HOME", Path.home() / ".vaultlink"))
    return home / "pairing.bin"


def _dpapi(data: bytes, protect: bool) -> bytes:
    if sys.platform != "win32":
        raise OSError("pairing storage uses Windows DPAPI; not available on this OS")
    import ctypes
    import ctypes.wintypes as wt

    class Blob(ctypes.Structure):
        _fields_ = [("cbData", wt.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]

    crypt32 = ctypes.WinDLL("crypt32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    buf = ctypes.create_string_buffer(data, len(data))
    blob_in = Blob(len(data), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char)))
    blob_out = Blob()
    entropy_raw = b"vaultlink/2 pairing root"
    ebuf = ctypes.create_string_buffer(entropy_raw, len(entropy_raw))
    entropy = Blob(len(entropy_raw), ctypes.cast(ebuf, ctypes.POINTER(ctypes.c_char)))
    CRYPTPROTECT_UI_FORBIDDEN = 0x01
    fn = crypt32.CryptProtectData if protect else crypt32.CryptUnprotectData
    # Protect and Unprotect share this signature (the description argument is
    # an in-param for one and an out-param for the other; None for both).
    ok = fn(ctypes.byref(blob_in), None, ctypes.byref(entropy), None, None,
            CRYPTPROTECT_UI_FORBIDDEN, ctypes.byref(blob_out))
    if not ok:
        raise OSError(f"DPAPI {'protect' if protect else 'unprotect'} failed "
                      f"(error {ctypes.get_last_error()})")
    try:
        return ctypes.string_at(blob_out.pbData, blob_out.cbData)
    finally:
        kernel32.LocalFree(blob_out.pbData)


def save_pairing(root: bytes, path: Path | None = None) -> Path:
    path = path or pairing_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(_dpapi(root, protect=True))
    return path


def load_pairing(path: Path | None = None) -> LinkKeys | None:
    path = path or pairing_path()
    if not path.exists():
        return None
    return LinkKeys.from_root(_dpapi(path.read_bytes(), protect=False))


def clear_pairing(path: Path | None = None) -> bool:
    path = path or pairing_path()
    if path.exists():
        path.unlink()
        return True
    return False
