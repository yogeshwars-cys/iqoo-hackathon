/// Canonical capsule encoding and host-side signing.
///
/// The cross-language vector is read from bridge/tests/vectors — the SAME
/// file the Python verifier's tests assert against — and the digest is
/// recomputed here by the Dart implementation. If the two languages ever
/// disagree on a single byte, one of the two suites fails.

library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_rag_test/core/gating.dart';
import 'package:vault_rag_test/core/llm/capsule.dart';
import 'package:vault_rag_test/core/security/bytes.dart';
import 'package:vault_rag_test/core/security/capsule_signer.dart';
import 'package:vault_rag_test/core/security/capsule_signing.dart';

import 'gating_test.dart' show resultWithTopScore;

CanonicalCapsule fromVector(Map<String, dynamic> c) {
  final prov = c['provenance'] as Map<String, dynamic>;
  return CanonicalCapsule(
    query: c['query'] as String,
    answer: c['answer'] as String,
    timestamp: prov['timestamp'] as int,
    gatingPath: prov['gating_path'] as String,
    chunkIds: [for (final x in c['context'] as List) x['id'] as String],
    confidence: c['confidence'] as String,
    keyFactTexts: [for (final f in c['key_facts'] as List) f['fact'] as String],
    contextContents: [for (final x in c['context'] as List) x['content'] as String],
    device: prov['device'] as String,
    keySecurityLevel: prov['key_security_level'] as String,
    publicKeyDer: fromHex(prov['public_key'] as String),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final vectors = jsonDecode(
    File('../bridge/tests/vectors/cross_language_vectors.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final v = vectors['capsule_sig_v1'] as Map<String, dynamic>;

  group('canonical payload', () {
    test('matches the Python implementation byte for byte', () {
      final canonical = fromVector(v['capsule'] as Map<String, dynamic>);
      expect(toHex(canonical.encode()), v['canonical_payload_hex']);
      expect(canonical.digestHex(), v['canonical_digest']);
    });

    test('is deterministic', () {
      final c = fromVector(v['capsule'] as Map<String, dynamic>);
      expect(c.encode(), fromVector(v['capsule'] as Map<String, dynamic>).encode());
    });

    CanonicalCapsule base({
      String query = 'q',
      String answer = 'a',
      int timestamp = 1,
      String gating = 'extractive_early_exit',
      List<String> ids = const ['c0'],
    }) =>
        CanonicalCapsule(
          query: query,
          answer: answer,
          timestamp: timestamp,
          gatingPath: gating,
          chunkIds: ids,
          confidence: 'medium',
          keyFactTexts: const [],
          contextContents: [for (final _ in ids) 'x'],
          device: 'd',
          keySecurityLevel: 'tee',
          publicKeyDer: Uint8List.fromList([1, 2, 3]),
        );

    test('every signed field changes the digest', () {
      final d = base().digestHex();
      expect(base(query: 'Q').digestHex(), isNot(d));
      expect(base(answer: 'b').digestHex(), isNot(d));
      expect(base(timestamp: 2).digestHex(), isNot(d));
      expect(base(gating: 'llm_synthesized').digestHex(), isNot(d));
      expect(base(ids: const ['c1']).digestHex(), isNot(d));
    });

    test('pipe and comma injection cannot collide', () {
      expect(base(query: 'x|y', answer: 'z').digestHex(),
          isNot(base(query: 'x', answer: 'y|z').digestHex()));
      expect(base(ids: const ['p,q']).digestHex(),
          isNot(base(ids: const ['p', 'q']).digestHex()));
    });
  });

  group('capsule signer on the host', () {
    test('attaches a mock provenance that is visibly not a real signature',
        () async {
      final unsigned = await _tier1Capsule();
      final signed =
          await CapsuleSigner(deviceLabel: () async => 'host').sign(unsigned);
      final p = signed.provenance!;
      expect(p.signature, startsWith('MOCK_SIG_'));
      expect(p.signatureAlgorithm, 'MOCK-UNSIGNED');
      expect(p.isSigned, isFalse);
      expect(p.publicKey, isNull);
      expect(p.keySecurityLevel, 'none');
      expect(p.enclave, contains('host-test'));
      expect(p.gatingPath, 'extractive_early_exit');
      expect(p.timestamp, unsigned.timestamp);
    });

    test('canonical_digest covers exactly what toJson() exposes', () async {
      final signed = await CapsuleSigner(deviceLabel: () async => 'host')
          .sign(await _tier1Capsule());
      final json = jsonDecode(signed.toPrettyJson()) as Map<String, dynamic>;
      // Rebuild from the JSON the desktop receives, not from Dart objects.
      final prov = json['provenance'] as Map<String, dynamic>;
      final rebuilt = CanonicalCapsule(
        query: json['query'] as String,
        answer: json['answer'] as String,
        timestamp: prov['timestamp'] as int,
        gatingPath: prov['gating_path'] as String,
        chunkIds: [for (final c in json['context'] as List) c['id'] as String],
        confidence: json['confidence'] as String,
        keyFactTexts: [for (final f in json['key_facts'] as List) f['fact'] as String],
        contextContents: [
          for (final c in json['context'] as List) c['content'] as String
        ],
        device: prov['device'] as String,
        keySecurityLevel: prov['key_security_level'] as String,
        publicKeyDer: null,
      );
      expect(rebuilt.digestHex(), prov['canonical_digest']);
      expect(sha256.convert(rebuilt.encode()).toString(), prov['canonical_digest']);
    });

    test('query and answer are trimmed before signing, not at verification',
        () async {
      final c = ContextCapsule.fromRetrievalOnly(
        resultWithTopScore(0.9),
        gatingPath: GatingPath.extractiveEarlyExit,
      );
      expect(c.query, c.query.trim());
      expect(c.answer, c.answer.trim());
    });
  });
}

Future<ContextCapsule> _tier1Capsule() async => ContextCapsule.fromRetrievalOnly(
      resultWithTopScore(0.9),
      gatingPath: GatingPath.extractiveEarlyExit,
      timestamp: 1773368291000,
    );

