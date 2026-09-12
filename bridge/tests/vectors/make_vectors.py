"""Regenerates cross_language_vectors.json.

The expected values are computed here by the Python implementation and then
asserted independently by BOTH test suites:

    bridge/tests/test_capsule_verify.py        (Python, recomputes)
    vault_rag_test/test/capsule_signing_test.dart  (Dart, recomputes)

Only rerun this when the protocol version changes on purpose — a silent
regeneration would hide exactly the drift the vectors exist to catch.
"""

from __future__ import annotations

import hashlib
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent.parent))

from vault_cli import capsule_verify as cv  # noqa: E402
from vault_cli import vaultlink_protocol as vp  # noqa: E402

# Deliberately hostile content: separators from the naive pipe format,
# commas in ids, non-ASCII, newlines, an empty string field.
CAPSULE = {
    "query": "max notional | order limit?",
    "answer": "MAX_ORDER_USD = 250000 | see limits.py, line 2",
    "confidence": "medium",
    "key_facts": [{"fact": "Orders above 250,000 USD are rejected — ✓"}],
    "context": [
        {"id": "limits.py_chunk_000", "content": "class RiskEngine:\n    MAX_ORDER_USD = 250000"},
        {"id": "a,b|c", "content": ""},
    ],
    "provenance": {
        "device": "vivo I2501 · Qualcomm SM8750 · Android 16",
        "key_security_level": "tee",
        "gating_path": "extractive_early_exit",
        "timestamp": 1773368291000,
        # SPKI DER of a fixed P-256 point — only its SHA-256 is signed, so
        # any byte string works as a vector; this one is a real key.
        "public_key": ("3059301306072a8648ce3d020106082a8648ce3d03010703420004"
                       "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296"
                       "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"),
    },
}

PAIRING_CODE = "7K3QX-M9RTV-2HJ8P-4WZNC"


def main() -> None:
    payload = cv.canonical_payload(CAPSULE)
    root = vp.root_from_pairing_code(PAIRING_CODE)
    keys = vp.LinkKeys.from_root(root)
    out = {
        "capsule_sig_v1": {
            "capsule": CAPSULE,
            "canonical_payload_hex": payload.hex(),
            "canonical_digest": hashlib.sha256(payload).hexdigest(),
        },
        "vaultlink_v2_keys": {
            "pairing_code": PAIRING_CODE,
            "root_hex": root.hex(),
            "request_key_hex": keys.request_key.hex(),
            "reply_key_hex": keys.reply_key.hex(),
            "kid": keys.kid,
        },
    }
    (HERE / "cross_language_vectors.json").write_text(
        json.dumps(out, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(out["capsule_sig_v1"]["canonical_digest"]))


if __name__ == "__main__":
    main()
