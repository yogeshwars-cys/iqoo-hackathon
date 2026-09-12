"""Desktop verification of signed Vault context capsules.

Mirrors vault_rag_test/lib/core/security/capsule_signing.dart byte for byte.
The shared test vector (bridge/tests/test_capsule_verify.py and
vault_rag_test/test/capsule_signing_test.dart) pins both to the same digest.

VERIFICATION ORDER — every step fails closed:

  1. provenance block present and well-typed           else MISSING_PROVENANCE / MALFORMED
  2. rebuild canonical payload from the capsule JSON    else MALFORMED
  3. SHA-256(payload) == provenance.canonical_digest    else DIGEST_MISMATCH
  4. signature is a real DER signature (not MOCK/null)  else UNSIGNED
  5. public_key parses as an EC P-256 SPKI              else BAD_PUBLIC_KEY
  6. ECDSA-P256-SHA256 verifies over the payload        else INVALID_SIGNATURE
  7. public_key equals the key pinned at enrollment     else NOT_ENROLLED / TRUSTED_KEY_MISMATCH

Only step 7 turns "mathematically valid" into "trusted". A public key that
arrives inside the capsule it verifies proves nothing about who made it —
anyone can generate a key pair and sign their own capsule. Trust comes from
the pin, which is set only by an explicit enrollment (normally
``vaultlink.py enroll`` over the paired, authenticated VAULTLINK/2 channel).

Uses ``cryptography`` for all primitives. No custom crypto.
"""

from __future__ import annotations

import enum
import hashlib
import hmac
import json
import os
import time
from dataclasses import dataclass, field
from pathlib import Path

try:
    from cryptography import x509
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    HAVE_CRYPTOGRAPHY = True
except ImportError:  # pragma: no cover - exercised only without the package
    HAVE_CRYPTOGRAPHY = False

CAPSULE_SIG_TAG = "vault-capsule-sig/v1"
SIGNATURE_ALGORITHM = "ECDSA-P256-SHA256"


def _require_cryptography() -> None:
    if not HAVE_CRYPTOGRAPHY:
        raise RuntimeError(
            "capsule verification needs the 'cryptography' package: "
            "pip install cryptography")


# ---------------------------------------------------------------------------
# Canonical encoding — keep in lockstep with capsule_signing.dart
# ---------------------------------------------------------------------------

class MalformedCapsule(ValueError):
    pass


def _lp(data: bytes) -> bytes:
    return str(len(data)).encode("ascii") + b":" + data


def _lp_str(s: str) -> bytes:
    try:
        return _lp(s.encode("utf-8"))
    except UnicodeEncodeError as e:  # lone surrogates cannot have been signed
        raise MalformedCapsule("field is not valid Unicode") from e


def _lp_list(items: list[str]) -> bytes:
    return _lp(b"".join(_lp_str(i) for i in items))


def _str(value, name: str) -> str:
    if not isinstance(value, str):
        raise MalformedCapsule(f"{name} must be a string")
    return value


def canonical_payload(capsule: dict) -> bytes:
    """Rebuilds the exact bytes the phone signed, from capsule JSON.

    Strings are used exactly as they appear — no trimming or normalisation —
    because the phone trims once before signing and stores the result.
    """
    if not isinstance(capsule, dict):
        raise MalformedCapsule("capsule must be a JSON object")
    prov = capsule.get("provenance")
    if not isinstance(prov, dict):
        raise MalformedCapsule("provenance missing")

    timestamp = prov.get("timestamp")
    # bool is an int subclass in Python; a JSON true must not pass as 1.
    if not isinstance(timestamp, int) or isinstance(timestamp, bool):
        raise MalformedCapsule("provenance.timestamp must be an integer")

    context = capsule.get("context")
    if not isinstance(context, list):
        raise MalformedCapsule("context must be a list")
    facts = capsule.get("key_facts")
    if not isinstance(facts, list):
        raise MalformedCapsule("key_facts must be a list")

    chunk_ids, contents = [], []
    for i, c in enumerate(context):
        if not isinstance(c, dict):
            raise MalformedCapsule(f"context[{i}] must be an object")
        chunk_ids.append(_str(c.get("id"), f"context[{i}].id"))
        contents.append(_str(c.get("content"), f"context[{i}].content"))
    fact_texts = []
    for i, f in enumerate(facts):
        if not isinstance(f, dict):
            raise MalformedCapsule(f"key_facts[{i}] must be an object")
        fact_texts.append(_str(f.get("fact"), f"key_facts[{i}].fact"))

    public_key_hex = prov.get("public_key")
    if public_key_hex is None:
        key_hash = ""
    else:
        key_hash = hashlib.sha256(_hex_bytes(public_key_hex, "public_key")).hexdigest()

    parts = [
        _lp_str(CAPSULE_SIG_TAG),
        _lp_str(_str(capsule.get("query"), "query")),
        _lp_str(_str(capsule.get("answer"), "answer")),
        _lp_str(str(timestamp)),
        _lp_str(_str(prov.get("gating_path"), "provenance.gating_path")),
        _lp_list(chunk_ids),
        _lp_str(_str(capsule.get("confidence"), "confidence")),
        _lp_list(fact_texts),
        _lp_list([hashlib.sha256(c.encode("utf-8")).hexdigest() for c in contents]),
        _lp_str(_str(prov.get("device"), "provenance.device")),
        _lp_str(_str(prov.get("key_security_level"), "provenance.key_security_level")),
        _lp_str(key_hash),
    ]
    return b"".join(parts)


def _hex_bytes(value, name: str) -> bytes:
    if not isinstance(value, str) or len(value) % 2:
        raise MalformedCapsule(f"{name} must be an even-length hex string")
    try:
        return bytes.fromhex(value)
    except ValueError as e:
        raise MalformedCapsule(f"{name} is not valid hex") from e


# ---------------------------------------------------------------------------
# Trust store — pinned device keys
# ---------------------------------------------------------------------------

def vaultlink_home() -> Path:
    return Path(os.environ.get("VAULTLINK_HOME", Path.home() / ".vaultlink"))


def key_fingerprint(public_key_der: bytes) -> str:
    """SHA-256 of the SPKI DER, grouped for reading aloud."""
    h = hashlib.sha256(public_key_der).hexdigest()
    return ":".join(h[i:i + 4] for i in range(0, 32, 4))


class TrustStore:
    """JSON file of pinned device public keys, keyed by device name.

    It holds public keys only, so it is not secret — but it is integrity-
    critical: whoever can edit it can pin their own key. It lives in the
    user's profile for that reason.
    """

    def __init__(self, path: Path | None = None):
        self.path = Path(path) if path else vaultlink_home() / "trusted_devices.json"

    def _load(self) -> dict:
        if not self.path.exists():
            return {}
        return json.loads(self.path.read_text(encoding="utf-8"))

    def get(self, device: str = "default") -> dict | None:
        return self._load().get(device)

    def pin(self, public_key_der: bytes, *, device: str = "default",
            meta: dict | None = None) -> dict:
        """Explicit enrollment. Refuses to overwrite a different key: rotating
        a device key must be a deliberate ``unpin`` first."""
        _require_cryptography()
        _load_p256(public_key_der)  # validates
        data = self._load()
        existing = data.get(device)
        if existing and existing["public_key"] != public_key_der.hex():
            raise ValueError(
                f"device {device!r} is already pinned to a different key "
                f"({existing['fingerprint']}); unpin it first to re-enroll")
        record = {
            "public_key": public_key_der.hex(),
            "fingerprint": key_fingerprint(public_key_der),
            "enrolled_at": int(time.time()),
            **(meta or {}),
        }
        data[device] = record
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, indent=2), encoding="utf-8")
        tmp.replace(self.path)
        return record

    def unpin(self, device: str = "default") -> bool:
        data = self._load()
        if device not in data:
            return False
        del data[device]
        self.path.write_text(json.dumps(data, indent=2), encoding="utf-8")
        return True


def _load_p256(der: bytes):
    try:
        key = serialization.load_der_public_key(der)
    except (ValueError, TypeError) as e:
        raise MalformedCapsule("public key is not a valid SPKI DER") from e
    if not isinstance(key, ec.EllipticCurvePublicKey) or key.curve.name != "secp256r1":
        raise MalformedCapsule("public key is not EC P-256")
    return key


# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

class Status(enum.Enum):
    VERIFIED = "verified"
    NOT_ENROLLED = "cryptographically valid, but no trusted key is pinned"
    TRUSTED_KEY_MISMATCH = "signed by a key that is not the pinned device key"
    INVALID_SIGNATURE = "signature does not verify"
    DIGEST_MISMATCH = "canonical digest does not match the capsule contents"
    UNSIGNED = "capsule is unsigned or carries a mock signature"
    BAD_PUBLIC_KEY = "public key is malformed or not P-256"
    MALFORMED = "capsule is malformed"
    MISSING_PROVENANCE = "capsule has no provenance block"


@dataclass
class VerificationResult:
    status: Status
    detail: str = ""
    digest: str | None = None
    fingerprint: str | None = None
    security_level: str | None = None
    enclave: str | None = None
    extra: dict = field(default_factory=dict)

    @property
    def trusted(self) -> bool:
        return self.status is Status.VERIFIED

    @property
    def cryptographically_valid(self) -> bool:
        return self.status in (Status.VERIFIED, Status.NOT_ENROLLED,
                               Status.TRUSTED_KEY_MISMATCH)


def verify_capsule(capsule: dict, trust_store: TrustStore | None = None,
                   *, device: str = "default") -> VerificationResult:
    _require_cryptography()
    prov = capsule.get("provenance") if isinstance(capsule, dict) else None
    if not isinstance(prov, dict):
        return VerificationResult(Status.MISSING_PROVENANCE)

    try:
        payload = canonical_payload(capsule)
    except MalformedCapsule as e:
        return VerificationResult(Status.MALFORMED, str(e))

    digest = hashlib.sha256(payload).hexdigest()
    claimed = prov.get("canonical_digest")
    if not isinstance(claimed, str) or not hmac.compare_digest(digest, claimed.lower()):
        return VerificationResult(Status.DIGEST_MISMATCH, digest=digest)

    sig_hex = prov.get("signature")
    if (prov.get("signature_algorithm") != SIGNATURE_ALGORITHM
            or not isinstance(sig_hex, str) or sig_hex.startswith("MOCK_SIG_")):
        return VerificationResult(Status.UNSIGNED, prov.get("signature_error", ""),
                                  digest=digest)

    try:
        key_der = _hex_bytes(prov.get("public_key"), "public_key")
        key = _load_p256(key_der)
    except MalformedCapsule as e:
        return VerificationResult(Status.BAD_PUBLIC_KEY, str(e), digest=digest)

    try:
        signature = _hex_bytes(sig_hex, "signature")
        key.verify(signature, payload, ec.ECDSA(hashes.SHA256()))
    except (MalformedCapsule, InvalidSignature, ValueError) as e:
        # ValueError covers DER that does not parse as (r, s).
        return VerificationResult(Status.INVALID_SIGNATURE, type(e).__name__,
                                  digest=digest)

    fp = key_fingerprint(key_der)
    common = dict(digest=digest, fingerprint=fp,
                  security_level=prov.get("key_security_level"),
                  enclave=prov.get("enclave"))
    pinned = (trust_store or TrustStore()).get(device)
    if pinned is None:
        return VerificationResult(Status.NOT_ENROLLED, **common)
    if not hmac.compare_digest(pinned["public_key"], key_der.hex()):
        return VerificationResult(
            Status.TRUSTED_KEY_MISMATCH,
            f"pinned {pinned['fingerprint']}, capsule {fp}", **common)
    return VerificationResult(Status.VERIFIED, **common)


# ---------------------------------------------------------------------------
# Android Key Attestation (enrollment evidence)
# ---------------------------------------------------------------------------

KEY_ATTESTATION_OID = "1.3.6.1.4.1.11129.2.1.17"
_SECURITY_LEVELS = {0: "software", 1: "tee", 2: "strongbox"}


def _der_read(buf: bytes, pos: int) -> tuple[int, bytes, int]:
    """One DER TLV: (tag, value, next_pos). Short and long lengths only."""
    if pos + 2 > len(buf):
        raise ValueError("truncated DER")
    tag = buf[pos]
    length = buf[pos + 1]
    pos += 2
    if length & 0x80:
        n = length & 0x7F
        if n == 0 or n > 4 or pos + n > len(buf):
            raise ValueError("bad DER length")
        length = int.from_bytes(buf[pos:pos + n], "big")
        pos += n
    if pos + length > len(buf):
        raise ValueError("truncated DER value")
    return tag, buf[pos:pos + length], pos + length


def parse_key_description(ext_value: bytes) -> dict:
    """The first five KeyDescription fields — enough to read where the key
    was generated. Parsing only; the certificate signatures are checked by
    ``cryptography`` in :func:`check_attestation_chain`."""
    tag, seq, _ = _der_read(ext_value, 0)
    if tag != 0x30:
        raise ValueError("KeyDescription is not a SEQUENCE")
    pos = 0
    fields = []
    for expected in (0x02, 0x0A, 0x02, 0x0A, 0x04):
        tag, value, pos = _der_read(seq, pos)
        if tag != expected:
            raise ValueError("unexpected KeyDescription layout")
        fields.append(value)
    level = int.from_bytes(fields[1], "big")
    km_level = int.from_bytes(fields[3], "big")
    return {
        "attestation_version": int.from_bytes(fields[0], "big"),
        "attestation_security_level": _SECURITY_LEVELS.get(level, f"unknown({level})"),
        "keymint_version": int.from_bytes(fields[2], "big"),
        "keymint_security_level": _SECURITY_LEVELS.get(km_level, f"unknown({km_level})"),
        "attestation_challenge": fields[4].decode("utf-8", "replace"),
    }


def check_attestation_chain(chain_hex: list[str], public_key_der: bytes,
                            trusted_root_der: bytes | None = None) -> dict:
    """Evidence about the signing key, stated without overclaiming.

    ``chain_valid`` means each certificate is signed by the next one. That is
    NOT proof of hardware on its own: without ``trusted_root_der`` (Google's
    hardware attestation root, obtained out of band) an emulator could forge a
    self-consistent chain, and ``root_trusted`` stays False.
    """
    _require_cryptography()
    out = {"present": bool(chain_hex), "chain_valid": False, "leaf_matches_key": False,
           "root_trusted": False, "root_fingerprint": None, "key_description": None,
           "error": None}
    if not chain_hex:
        return out
    try:
        certs = [x509.load_der_x509_certificate(bytes.fromhex(h)) for h in chain_hex]
        for child, parent in zip(certs, certs[1:]):
            child.verify_directly_issued_by(parent)
        out["chain_valid"] = True
        leaf_spki = certs[0].public_key().public_bytes(
            serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
        out["leaf_matches_key"] = hmac.compare_digest(leaf_spki, public_key_der)
        root_der = certs[-1].public_bytes(serialization.Encoding.DER)
        out["root_fingerprint"] = hashlib.sha256(root_der).hexdigest()
        if trusted_root_der is not None:
            out["root_trusted"] = hmac.compare_digest(
                hashlib.sha256(root_der).digest(),
                hashlib.sha256(trusted_root_der).digest())
        for cert in certs:
            for ext in cert.extensions:
                if ext.oid.dotted_string == KEY_ATTESTATION_OID:
                    out["key_description"] = parse_key_description(ext.value.value)
                    break
            if out["key_description"]:
                break
    except Exception as e:  # any parse/verify failure is reported, not trusted
        out["chain_valid"] = False
        out["error"] = type(e).__name__
    return out
