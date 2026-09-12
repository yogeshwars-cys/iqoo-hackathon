/// capsule_signing.dart
///
/// The ONE canonical encoding a context capsule is signed over. Mirrored
/// byte-for-byte by `bridge/vault_cli/capsule_verify.py`; the shared test
/// vector in test/capsule_signing_test.dart and
/// bridge/tests/test_capsule_verify.py pins both to the same digest.
///
/// PROTOCOL (`vault-capsule-sig/v1`)
///
///   payload   = LP(tag) LP(query) LP(answer) LP(timestamp) LP(gating_path)
///               LPL(chunk_ids) LP(confidence) LPL(key_fact_texts)
///               LPL(sha256_hex(context[i].content)) LP(device)
///               LP(key_security_level) LP(sha256_hex(public_key_der))
///   LP(s)     = utf8(decimal byte length of utf8(s)) ":" utf8(s)
///   LPL(xs)   = LP(concatenation of LP(x) for x in xs)
///
///   canonical_digest = lowercase hex SHA-256(payload)
///   signature        = ECDSA-P256 with SHA-256 over `payload` (DER)
///
/// The Android keystore signs `payload` with SHA256withECDSA — it hashes
/// once, internally. `canonical_digest` is published alongside so a reader
/// can detect a mismatched reconstruction before even parsing the signature,
/// but the signature is NOT computed over the digest; nothing is hashed twice.
/// A verifier checks: recompute payload → digest equals canonical_digest →
/// ECDSA verify(public_key, signature, payload) → public_key equals the
/// pinned device key.
///
/// WHY LENGTH-PREFIXED, NOT `query|answer|timestamp|gating|ids`
///
/// A pipe-joined string is not injective. `query="a|b", answer="c"` and
/// `query="a", answer="b|c"` produce identical bytes, so a signature over one
/// capsule verifies for a different capsule; the same holds for chunk ids
/// containing commas. Length prefixes make every field boundary unambiguous
/// with no escaping rules to get subtly wrong in two languages.
///
/// WHY MORE FIELDS THAN QUERY/ANSWER/IDS
///
/// A consumer acts on `context[].content` and `key_facts` too. If those were
/// unsigned, anyone relaying the capsule could rewrite the quoted source
/// text under a valid signature. Hashing each context chunk binds the exact
/// text; binding the public-key hash and security level stops a signature
/// being re-presented under a different claimed key or hardware tier.
/// Similarity scores and latency telemetry are deliberately left unsigned:
/// they are floats formatted differently by each language, and nothing
/// security-relevant is decided on them (the gating path they produced IS
/// signed).
///
/// Strings are signed exactly as stored — no trimming at verification time.
/// The capsule builder trims query and answer once, before signing, so the
/// JSON a verifier reads is exactly the bytes that were signed.

library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const kCapsuleSigTag = 'vault-capsule-sig/v1';

class CanonicalCapsule {
  final String query;
  final String answer;
  final int timestamp;
  final String gatingPath;
  final List<String> chunkIds;
  final String confidence;
  final List<String> keyFactTexts;
  final List<String> contextContents;
  final String device;
  final String keySecurityLevel;

  /// X.509 DER of the signing key, or null (host test double — hashed as
  /// the empty string, and such capsules never verify anyway).
  final Uint8List? publicKeyDer;

  const CanonicalCapsule({
    required this.query,
    required this.answer,
    required this.timestamp,
    required this.gatingPath,
    required this.chunkIds,
    required this.confidence,
    required this.keyFactTexts,
    required this.contextContents,
    required this.device,
    required this.keySecurityLevel,
    required this.publicKeyDer,
  });

  Uint8List encode() {
    final out = BytesBuilder(copy: false);
    void lp(List<int> bytes) {
      out
        ..add(ascii.encode('${bytes.length}:'))
        ..add(bytes);
    }

    void lpString(String s) => lp(utf8.encode(s));

    void lpList(Iterable<String> items) {
      final inner = BytesBuilder(copy: false);
      for (final item in items) {
        final b = utf8.encode(item);
        inner
          ..add(ascii.encode('${b.length}:'))
          ..add(b);
      }
      lp(inner.takeBytes());
    }

    lpString(kCapsuleSigTag);
    lpString(query);
    lpString(answer);
    lpString(timestamp.toString());
    lpString(gatingPath);
    lpList(chunkIds);
    lpString(confidence);
    lpList(keyFactTexts);
    lpList(contextContents.map((c) => sha256.convert(utf8.encode(c)).toString()));
    lpString(device);
    lpString(keySecurityLevel);
    lpString(publicKeyDer == null ? '' : sha256.convert(publicKeyDer!).toString());
    return out.takeBytes();
  }

  String digestHex() => sha256.convert(encode()).toString();
}
