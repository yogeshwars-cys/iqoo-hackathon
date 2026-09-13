"""Capsule signature verification and VAULTLINK/2 framing — desktop half.

No phone, no clipboard. Keys are generated per test with ``cryptography``;
the canonical encoding is pinned by tests/vectors/cross_language_vectors.json,
which the Dart suite asserts too.

Run either way:
    pytest tests/test_capsule_verify.py
    python tests/test_capsule_verify.py
"""

from __future__ import annotations

import copy
import hashlib
import json
import pathlib
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

from cryptography import x509  # noqa: E402
from cryptography.hazmat.primitives import hashes, serialization  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec  # noqa: E402

from vault_cli import capsule_verify as cv  # noqa: E402
from vault_cli import vaultlink_protocol as vp  # noqa: E402

VECTORS = json.loads((HERE / "vectors" / "cross_language_vectors.json").read_text("utf-8"))


def _spki(key) -> bytes:
    return key.public_key().public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)


def signed_capsule(key=None) -> tuple[dict, ec.EllipticCurvePrivateKey]:
    """A capsule signed exactly the way the phone signs one."""
    key = key or ec.generate_private_key(ec.SECP256R1())
    capsule = copy.deepcopy(VECTORS["capsule_sig_v1"]["capsule"])
    prov = capsule["provenance"]
    prov["public_key"] = _spki(key).hex()
    payload = cv.canonical_payload(capsule)
    prov["canonical_digest"] = hashlib.sha256(payload).hexdigest()
    prov["signature"] = key.sign(payload, ec.ECDSA(hashes.SHA256())).hex()
    prov["signature_algorithm"] = "ECDSA-P256-SHA256"
    prov["enclave"] = "AndroidKeyStore (TEE)"
    return capsule, key


def store_pinned(key=None) -> cv.TrustStore:
    store = cv.TrustStore(pathlib.Path(tempfile.mkdtemp()) / "trusted.json")
    if key is not None:
        store.pin(_spki(key))
    return store


def resign_digest_only(capsule: dict) -> None:
    """Attacker who edits content and recomputes the digest, but has no key."""
    capsule["provenance"]["canonical_digest"] = hashlib.sha256(
        cv.canonical_payload(capsule)).hexdigest()


# ---------------------------------------------------------------------------
# Canonical encoding
# ---------------------------------------------------------------------------

def test_cross_language_vector_digest():
    v = VECTORS["capsule_sig_v1"]
    payload = cv.canonical_payload(v["capsule"])
    assert payload.hex() == v["canonical_payload_hex"]
    assert hashlib.sha256(payload).hexdigest() == v["canonical_digest"]


def test_canonical_payload_is_deterministic():
    c = VECTORS["capsule_sig_v1"]["capsule"]
    assert cv.canonical_payload(c) == cv.canonical_payload(copy.deepcopy(c))


def test_pipe_injection_does_not_collide():
    # Under a naive "query|answer" join these two would be identical bytes.
    a = copy.deepcopy(VECTORS["capsule_sig_v1"]["capsule"])
    b = copy.deepcopy(a)
    a["query"], a["answer"] = "x|y", "z"
    b["query"], b["answer"] = "x", "y|z"
    assert cv.canonical_payload(a) != cv.canonical_payload(b)


def test_comma_in_chunk_ids_does_not_collide():
    a = copy.deepcopy(VECTORS["capsule_sig_v1"]["capsule"])
    b = copy.deepcopy(a)
    a["context"] = [{"id": "p,q", "content": "c"}]
    b["context"] = [{"id": "p", "content": "c"}, {"id": "q", "content": "c"}]
    assert cv.canonical_payload(a) != cv.canonical_payload(b)


def test_boolean_timestamp_is_malformed():
    c = copy.deepcopy(VECTORS["capsule_sig_v1"]["capsule"])
    c["provenance"]["timestamp"] = True
    try:
        cv.canonical_payload(c)
    except cv.MalformedCapsule:
        return
    raise AssertionError("bool accepted as timestamp")


# ---------------------------------------------------------------------------
# Verification — accept
# ---------------------------------------------------------------------------

def test_valid_capsule_with_pinned_key_is_verified():
    capsule, key = signed_capsule()
    r = cv.verify_capsule(capsule, store_pinned(key))
    assert r.status is cv.Status.VERIFIED, r
    assert r.trusted and r.security_level == "tee"


def test_valid_signature_without_enrollment_is_not_trusted():
    capsule, _ = signed_capsule()
    r = cv.verify_capsule(capsule, store_pinned())
    assert r.status is cv.Status.NOT_ENROLLED
    assert r.cryptographically_valid and not r.trusted


def test_der_signature_parses_as_r_s():
    from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
    capsule, _ = signed_capsule()
    r, s = decode_dss_signature(bytes.fromhex(capsule["provenance"]["signature"]))
    assert r > 0 and s > 0


# ---------------------------------------------------------------------------
# Verification — reject (the security test matrix)
# ---------------------------------------------------------------------------

def _tampered(mutate, *, fix_digest=True) -> cv.VerificationResult:
    capsule, key = signed_capsule()
    mutate(capsule)
    if fix_digest:
        resign_digest_only(capsule)
    return cv.verify_capsule(capsule, store_pinned(key))


def test_modified_answer_one_character_is_rejected():
    r = _tampered(lambda c: c.__setitem__("answer", c["answer"][:-1] + "3"))
    assert r.status is cv.Status.INVALID_SIGNATURE


def test_modified_answer_without_digest_fix_is_digest_mismatch():
    r = _tampered(lambda c: c.__setitem__("answer", c["answer"] + "!"), fix_digest=False)
    assert r.status is cv.Status.DIGEST_MISMATCH


def test_modified_query_is_rejected():
    assert _tampered(lambda c: c.__setitem__("query", "other")).status is cv.Status.INVALID_SIGNATURE


def test_modified_timestamp_is_rejected():
    def m(c):
        c["provenance"]["timestamp"] += 1
    assert _tampered(m).status is cv.Status.INVALID_SIGNATURE


def test_modified_gating_path_is_rejected():
    def m(c):
        c["provenance"]["gating_path"] = "extractive_fallback"
    assert _tampered(m).status is cv.Status.INVALID_SIGNATURE


def test_modified_chunk_id_is_rejected():
    def m(c):
        c["context"][0]["id"] = "limits.py_chunk_001"
    assert _tampered(m).status is cv.Status.INVALID_SIGNATURE


def test_modified_context_content_is_rejected():
    def m(c):
        c["context"][0]["content"] = c["context"][0]["content"].replace("250000", "950000")
    assert _tampered(m).status is cv.Status.INVALID_SIGNATURE


def test_modified_key_fact_is_rejected():
    def m(c):
        c["key_facts"][0]["fact"] = "Orders are unlimited"
    assert _tampered(m).status is cv.Status.INVALID_SIGNATURE


def test_upgraded_security_level_claim_is_rejected():
    def m(c):
        c["provenance"]["key_security_level"] = "strongbox"
    assert _tampered(m).status is cv.Status.INVALID_SIGNATURE


def test_modified_digest_is_rejected():
    def m(c):
        d = c["provenance"]["canonical_digest"]
        c["provenance"]["canonical_digest"] = ("0" if d[0] != "0" else "1") + d[1:]
    assert _tampered(m, fix_digest=False).status is cv.Status.DIGEST_MISMATCH


def test_modified_signature_is_rejected():
    def m(c):
        sig = bytearray(bytes.fromhex(c["provenance"]["signature"]))
        sig[-1] ^= 0x01
        c["provenance"]["signature"] = sig.hex()
    assert _tampered(m, fix_digest=False).status is cv.Status.INVALID_SIGNATURE


def test_malformed_signature_is_rejected():
    def m(c):
        c["provenance"]["signature"] = "3006020101"  # truncated DER
    assert _tampered(m, fix_digest=False).status is cv.Status.INVALID_SIGNATURE


def test_mock_signature_is_unsigned():
    def m(c):
        c["provenance"]["signature"] = "MOCK_SIG_" + "0" * 64
        c["provenance"]["signature_algorithm"] = "MOCK-UNSIGNED"
    assert _tampered(m, fix_digest=False).status is cv.Status.UNSIGNED


def test_malformed_public_key_is_rejected():
    def m(c):
        c["provenance"]["public_key"] = "3059deadbeef"
    assert _tampered(m).status in (cv.Status.BAD_PUBLIC_KEY, cv.Status.INVALID_SIGNATURE)


def test_non_p256_public_key_is_rejected():
    capsule, key = signed_capsule()
    other = ec.generate_private_key(ec.SECP384R1())
    capsule["provenance"]["public_key"] = _spki(other).hex()
    resign_digest_only(capsule)
    assert cv.verify_capsule(capsule, store_pinned(key)).status is cv.Status.BAD_PUBLIC_KEY


def test_attacker_key_is_rejected_when_device_key_is_pinned():
    _, device_key = signed_capsule()
    attacker_capsule, _ = signed_capsule()  # fresh attacker key, self-consistent
    r = cv.verify_capsule(attacker_capsule, store_pinned(device_key))
    assert r.status is cv.Status.TRUSTED_KEY_MISMATCH
    assert r.cryptographically_valid and not r.trusted


def test_wrong_public_key_for_signature_is_rejected():
    capsule, key = signed_capsule()
    other = ec.generate_private_key(ec.SECP256R1())
    capsule["provenance"]["public_key"] = _spki(other).hex()
    resign_digest_only(capsule)
    assert cv.verify_capsule(capsule, store_pinned(key)).status is cv.Status.INVALID_SIGNATURE


def test_missing_provenance_is_rejected():
    capsule, key = signed_capsule()
    del capsule["provenance"]
    assert cv.verify_capsule(capsule, store_pinned(key)).status is cv.Status.MISSING_PROVENANCE


def test_enrollment_refuses_silent_key_rotation():
    _, k1 = signed_capsule()
    _, k2 = signed_capsule()
    store = store_pinned(k1)
    try:
        store.pin(_spki(k2))
    except ValueError:
        pass
    else:
        raise AssertionError("pin() silently replaced a trusted key")
    assert store.unpin()
    store.pin(_spki(k2))  # explicit re-enrollment path
    assert store.get()["public_key"] == _spki(k2).hex()


# ---------------------------------------------------------------------------
# Attestation evidence parsing (synthetic chain — not a hardware proof)
# ---------------------------------------------------------------------------

def _der(tag: int, value: bytes) -> bytes:
    n = len(value)
    length = bytes([n]) if n < 0x80 else bytes([0x81, n])
    return bytes([tag]) + length + value


def _cert(subject_key, issuer_key, cn: str, ext: bytes | None = None,
          issuer_cn: str = "root"):
    import datetime
    name = lambda n: x509.Name([x509.NameAttribute(x509.NameOID.COMMON_NAME, n)])  # noqa: E731
    b = (x509.CertificateBuilder().subject_name(name(cn)).issuer_name(name(issuer_cn))
         .public_key(subject_key.public_key()).serial_number(x509.random_serial_number())
         .not_valid_before(datetime.datetime(2025, 1, 1))
         .not_valid_after(datetime.datetime(2035, 1, 1)))
    if ext is not None:
        b = b.add_extension(x509.UnrecognizedExtension(
            x509.ObjectIdentifier(cv.KEY_ATTESTATION_OID), ext), critical=False)
    return b.sign(issuer_key, hashes.SHA256())


def test_attestation_chain_parsing_and_linkage():
    device = ec.generate_private_key(ec.SECP256R1())
    root = ec.generate_private_key(ec.SECP256R1())
    key_desc = _der(0x30, _der(0x02, b"\x64") + _der(0x0A, b"\x01") + _der(0x02, b"\x64")
                    + _der(0x0A, b"\x01") + _der(0x04, b"vault-capsule-signing-key/v1"))
    leaf = _cert(device, root, "leaf", key_desc)
    root_cert = _cert(root, root, "root")
    chain = [c.public_bytes(serialization.Encoding.DER).hex() for c in (leaf, root_cert)]

    out = cv.check_attestation_chain(chain, _spki(device))
    assert out["chain_valid"] and out["leaf_matches_key"]
    assert out["root_trusted"] is False  # no trusted root supplied
    assert out["key_description"]["attestation_security_level"] == "tee"
    assert out["key_description"]["attestation_challenge"] == "vault-capsule-signing-key/v1"

    trusted = cv.check_attestation_chain(
        chain, _spki(device), root_cert.public_bytes(serialization.Encoding.DER))
    assert trusted["root_trusted"] is True

    other = ec.generate_private_key(ec.SECP256R1())
    assert cv.check_attestation_chain(chain, _spki(other))["leaf_matches_key"] is False


# ---------------------------------------------------------------------------
# VAULTLINK/2
# ---------------------------------------------------------------------------

def test_vaultlink_key_schedule_vector():
    v = VECTORS["vaultlink_v2_keys"]
    root = vp.root_from_pairing_code(v["pairing_code"])
    keys = vp.LinkKeys.from_root(root)
    assert root.hex() == v["root_hex"]
    assert keys.request_key.hex() == v["request_key_hex"]
    assert keys.reply_key.hex() == v["reply_key_hex"]
    assert keys.kid == v["kid"]


def test_pairing_code_normalisation():
    code = VECTORS["vaultlink_v2_keys"]["pairing_code"]
    assert vp.root_from_pairing_code(code.lower().replace("-", " ")) == \
        vp.root_from_pairing_code(code)
    assert vp.normalise_pairing_code("TOO-SHORT") is None
    assert vp.normalise_pairing_code("U" * 20) is None  # U is not Crockford


def _keys():
    return vp.LinkKeys.from_root(vp.root_from_pairing_code(
        VECTORS["vaultlink_v2_keys"]["pairing_code"]))


def test_vaultlink_round_trip_and_ciphertext_hides_content():
    keys = _keys()
    frame = vp.seal(keys, "req", vp.new_request("query", q="salary of employee 413"))
    assert "salary" not in frame
    body = vp.open_frame(keys, "req", frame)
    assert body["q"] == "salary of employee 413"


def _expect_reject(fn, reason):
    try:
        fn()
    except vp.FrameRejected as e:
        assert e.reason == reason, e.reason
        return
    raise AssertionError(f"expected {reason}")


def test_vaultlink_rejects_tamper_wrong_key_and_reflection():
    keys = _keys()
    frame = vp.seal(keys, "rep", {"id": "q_1", "status": "complete"})

    outer = json.loads(frame[len(vp.V2_PREFIX):])
    import base64
    blob = bytearray(base64.b64decode(outer["ct"]))
    blob[20] ^= 1
    outer["ct"] = base64.b64encode(bytes(blob)).decode()
    _expect_reject(lambda: vp.open_frame(keys, "rep", vp.V2_PREFIX + json.dumps(outer)),
                   "bad_seal")

    other = vp.LinkKeys.from_root(vp.root_from_pairing_code("00000-00000-00000-00000"))
    _expect_reject(lambda: vp.open_frame(other, "rep", frame), "wrong_key")

    # A reply cannot be reflected back as a request, even with dir rewritten:
    # the direction is bound into both the key and the AAD.
    outer = json.loads(frame[len(vp.V2_PREFIX):])
    _expect_reject(lambda: vp.open_frame(keys, "req", frame), "wrong_direction")
    outer["dir"] = "req"
    _expect_reject(lambda: vp.open_frame(keys, "req", vp.V2_PREFIX + json.dumps(outer)),
                   "bad_seal")


if __name__ == "__main__":
    failures = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"PASS {name}")
            except Exception as e:  # noqa: BLE001
                failures += 1
                print(f"FAIL {name}: {e!r}")
    sys.exit(1 if failures else 0)
