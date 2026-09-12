/// capsule_signer.dart
///
/// Attaches [CapsuleProvenance] to a capsule: canonical digest, ECDSA-P256
/// signature from AndroidKeyStore, and the device public key.
///
/// FAILURE POLICY: a capsule whose signing failed is still returned — the
/// person asking their own vault on their own phone should still see the
/// answer — but with `signature: null` and a `signature_error` category.
/// Every verifier treats that as unsigned and rejects it, so the failure is
/// never converted into a trusted result; it just does not also destroy the
/// local answer.

library;

import 'package:crypto/crypto.dart';

import '../llm/capsule.dart';
import 'bytes.dart';
import 'capsule_signing.dart';
import 'keystore_service.dart';

class CapsuleSigner {
  /// Supplies the platform-reported device label; injected so core/ does not
  /// import telemetry/.
  final Future<String> Function() deviceLabel;

  String? _device;

  CapsuleSigner({Future<String> Function()? deviceLabel})
      : deviceLabel = deviceLabel ?? (() async => 'unknown device');

  Future<ContextCapsule> sign(ContextCapsule capsule) async {
    final device = _device ??= await _safeDeviceLabel();

    KeystoreStatus? status;
    try {
      status = await KeystoreService.status();
      final publicKey = await KeystoreService.getPublicKey();
      final canonical = capsule.canonical(
        device: device,
        keySecurityLevel: status.signingLevel.name,
        publicKeyDer: publicKey,
      );
      final payload = canonical.encode();
      final digest = sha256.convert(payload).toString();
      final signature = await KeystoreService.signPayload(payload);

      return capsule.withProvenance(CapsuleProvenance(
        device: device,
        enclave: status.enclaveLabel,
        keySecurityLevel: status.signingLevel.name,
        strongBoxFeature: status.strongBoxFeature,
        gatingPath: capsule.gatingPath.wireName,
        timestamp: capsule.timestamp,
        canonicalVersion: kCapsuleSigTag,
        canonicalDigest: digest,
        signature: signature.isMock ? signature.mock : toHex(signature.der!),
        signatureAlgorithm: signature.algorithm,
        publicKey: publicKey == null ? null : toHex(publicKey),
      ));
    } catch (e) {
      // Category only — never the payload or the exception text, which
      // could echo capsule content.
      return capsule.withProvenance(CapsuleProvenance(
        device: device,
        enclave: status?.enclaveLabel ?? 'AndroidKeyStore unavailable',
        keySecurityLevel: status?.signingLevel.name ?? 'unknown',
        strongBoxFeature: status?.strongBoxFeature ?? false,
        gatingPath: capsule.gatingPath.wireName,
        timestamp: capsule.timestamp,
        canonicalVersion: kCapsuleSigTag,
        canonicalDigest: '',
        signature: null,
        signatureAlgorithm: 'NONE',
        publicKey: null,
        signatureError: e.runtimeType.toString(),
      ));
    }
  }

  Future<String> _safeDeviceLabel() async {
    try {
      final label = (await deviceLabel()).trim();
      return label.isEmpty ? 'unknown device' : label;
    } catch (_) {
      return 'unknown device';
    }
  }
}
