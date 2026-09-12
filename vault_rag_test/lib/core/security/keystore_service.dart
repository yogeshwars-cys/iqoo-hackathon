/// keystore_service.dart
///
/// Dart face of AndroidKeyStore (KeystoreChannel.kt, channel `vault/keystore`).
///
/// WHAT LIVES WHERE
///
///   AES-256-GCM master key  `vault_tee_aes_master`   encrypts chunk content
///   ECDSA P-256 key         `vault_tee_attestation`  signs context capsules
///
/// Both are generated inside AndroidKeyStore (StrongBox attempted first,
/// TEE-backed KeyStore otherwise) and neither is ever exported: Dart sends
/// bytes in and gets ciphertext, plaintext or a signature back. Nothing in
/// this file holds key material.
///
/// FALLBACK POLICY — THE PART THAT MUST NOT BE GOT WRONG
///
/// `flutter test` runs on the desktop host, where no platform channel has a
/// handler, so every call raises [MissingPluginException]. Rather than make
/// the whole pipeline untestable, the service swaps in
/// [HostTestKeystoreBackend] — but ONLY when all of these hold:
///
///   * not running on Android (`Platform.isAndroid == false`), and
///   * not a release build (`kReleaseMode == false`), and
///   * the failure was a missing handler / platform exception.
///
/// On an Android device every failure propagates as
/// [KeystoreUnavailableException] or [CiphertextIntegrityException]. A phone
/// whose keystore is broken fails closed; it never silently drops to the
/// test double, and the test double never produces anything that could be
/// mistaken for real protection (its status says `host-test`, its signatures
/// are `MOCK_SIG_…` strings the desktop verifier rejects outright).

library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'bytes.dart';
import 'host_test_keystore.dart';
import 'security_constants.dart';

/// Where a key's material actually lives, as reported by KeyInfo on the
/// device — not as assumed from the SoC.
enum KeySecurityLevel {
  strongbox,
  tee,
  software,
  unknown,

  /// No keystore at all (host test double).
  none;

  static KeySecurityLevel parse(Object? raw) {
    for (final level in values) {
      if (level.name == raw) return level;
    }
    return KeySecurityLevel.unknown;
  }

  bool get isHardware =>
      this == KeySecurityLevel.strongbox || this == KeySecurityLevel.tee;
}

class KeystoreStatus {
  final bool keystoreAvailable;
  final KeySecurityLevel aesLevel;
  final KeySecurityLevel signingLevel;

  /// Whether the device advertises FEATURE_STRONGBOX_KEYSTORE at all.
  final bool strongBoxFeature;

  /// True only for [HostTestKeystoreBackend].
  final bool isHostTestFallback;

  const KeystoreStatus({
    required this.keystoreAvailable,
    required this.aesLevel,
    required this.signingLevel,
    required this.strongBoxFeature,
    required this.isHostTestFallback,
  });

  static const hostTest = KeystoreStatus(
    keystoreAvailable: false,
    aesLevel: KeySecurityLevel.none,
    signingLevel: KeySecurityLevel.none,
    strongBoxFeature: false,
    isHostTestFallback: true,
  );

  factory KeystoreStatus.fromMap(Map<Object?, Object?> map) => KeystoreStatus(
        keystoreAvailable: map['keystoreAvailable'] == true,
        aesLevel: KeySecurityLevel.parse(map['aesLevel']),
        signingLevel: KeySecurityLevel.parse(map['signingLevel']),
        strongBoxFeature: map['strongBoxFeature'] == true,
        isHostTestFallback: false,
      );

  /// Both keys are live in AndroidKeyStore AND KeyInfo reports secure
  /// hardware for both. AndroidKeyStore on its own is not enough: a device
  /// can back it with software.
  bool get hardwareBacked =>
      !isHostTestFallback &&
      keystoreAvailable &&
      aesLevel.isHardware &&
      signingLevel.isHardware;

  /// Human label that never claims more than was reported.
  String get enclaveLabel {
    if (isHostTestFallback) return 'host-test (no enclave)';
    if (!keystoreAvailable) return 'AndroidKeyStore unavailable';
    return switch (signingLevel) {
      KeySecurityLevel.strongbox => 'AndroidKeyStore (StrongBox)',
      KeySecurityLevel.tee => 'AndroidKeyStore (TEE)',
      KeySecurityLevel.software => 'AndroidKeyStore (software-backed)',
      _ => 'AndroidKeyStore (security level unknown)',
    };
  }

  Map<String, dynamic> toJson() => {
        'keystore_available': keystoreAvailable,
        'aes_level': aesLevel.name,
        'signing_level': signingLevel.name,
        'strongbox_feature': strongBoxFeature,
        'host_test_fallback': isHostTestFallback,
      };
}

/// A capsule signature: DER bytes from the keystore, or a mock string from
/// the host test double. Never both.
class PayloadSignature {
  final Uint8List? der;
  final String? mock;

  const PayloadSignature.der(Uint8List this.der) : mock = null;
  const PayloadSignature.mock(String this.mock) : der = null;

  bool get isMock => der == null;
  String get algorithm => isMock ? 'MOCK-UNSIGNED' : 'ECDSA-P256-SHA256';
}

/// The keystore is missing or refused an operation on a real device.
class KeystoreUnavailableException implements Exception {
  final String message;
  const KeystoreUnavailableException(this.message);
  @override
  String toString() => 'KeystoreUnavailableException: $message';
}

/// A ciphertext failed GCM authentication or was malformed. Deliberately
/// carries no plaintext and no key detail.
class CiphertextIntegrityException implements Exception {
  final String message;
  const CiphertextIntegrityException(this.message);
  @override
  String toString() => 'CiphertextIntegrityException: $message';
}

/// Operations every keystore implementation provides.
abstract interface class KeystoreBackend {
  Future<Uint8List> encrypt(Uint8List plaintext);
  Future<Uint8List> decrypt(Uint8List payload);
  Future<List<Uint8List>> decryptBatch(List<Uint8List> payloads);

  /// ECDSA-P256 over SHA-256 of [payload] (the canonical capsule bytes —
  /// NOT a digest; see capsule_signing.dart for why).
  Future<PayloadSignature> signPayload(Uint8List payload);

  /// X.509 SubjectPublicKeyInfo DER, or null when there is no real key.
  Future<Uint8List?> publicKeyDer();

  /// Android Key Attestation chain for the signing key, leaf first.
  Future<List<Uint8List>> attestationChain();

  Future<KeystoreStatus> status();

  /// AES-256-GCM with a caller-supplied session key (VaultLink). The key is
  /// a shared secret, so by definition it cannot be a non-exportable
  /// keystore key; the platform JCA provider does the cipher work.
  Future<Uint8List> sessionSeal(Uint8List key, Uint8List plaintext, Uint8List aad);
  Future<Uint8List> sessionOpen(Uint8List key, Uint8List payload, Uint8List aad);
}

class PlatformKeystoreBackend implements KeystoreBackend {
  final MethodChannel _channel;

  const PlatformKeystoreBackend([
    this._channel = const MethodChannel(kKeystoreChannel),
  ]);

  Future<T> _invoke<T>(String method, [Object? args]) async {
    try {
      final result = await _channel.invokeMethod<T>(method, args);
      if (result == null) {
        throw KeystoreUnavailableException('$method returned nothing.');
      }
      return result;
    } on PlatformException catch (e) {
      // Kotlin reports GCM tag failures and malformed payloads with these
      // codes. They are integrity failures, not availability failures, and
      // callers must be able to tell the two apart.
      if (e.code == 'AUTH_FAILED' || e.code == 'MALFORMED') {
        throw CiphertextIntegrityException('$method: ${e.code}');
      }
      rethrow;
    }
  }

  @override
  Future<Uint8List> encrypt(Uint8List plaintext) =>
      _invoke<Uint8List>('encrypt', plaintext);

  @override
  Future<Uint8List> decrypt(Uint8List payload) {
    _checkPayloadShape(payload);
    return _invoke<Uint8List>('decrypt', payload);
  }

  @override
  Future<List<Uint8List>> decryptBatch(List<Uint8List> payloads) async {
    payloads.forEach(_checkPayloadShape);
    final raw = await _invoke<List<Object?>>('decryptBatch', payloads);
    return raw.cast<Uint8List>();
  }

  @override
  Future<PayloadSignature> signPayload(Uint8List payload) async =>
      PayloadSignature.der(await _invoke<Uint8List>('signPayload', payload));

  @override
  Future<Uint8List?> publicKeyDer() => _invoke<Uint8List>('getPublicKey');

  @override
  Future<List<Uint8List>> attestationChain() async =>
      (await _invoke<List<Object?>>('getAttestationChain')).cast<Uint8List>();

  @override
  Future<KeystoreStatus> status() async => KeystoreStatus.fromMap(
      await _invoke<Map<Object?, Object?>>('keyStatus'));

  @override
  Future<Uint8List> sessionSeal(
          Uint8List key, Uint8List plaintext, Uint8List aad) =>
      _invoke<Uint8List>(
          'sessionSeal', {'key': key, 'plaintext': plaintext, 'aad': aad});

  @override
  Future<Uint8List> sessionOpen(
      Uint8List key, Uint8List payload, Uint8List aad) {
    _checkPayloadShape(payload);
    return _invoke<Uint8List>(
        'sessionOpen', {'key': key, 'payload': payload, 'aad': aad});
  }
}

/// Rejects anything that cannot be `IV || ct || tag` before it crosses the
/// channel. Kotlin checks again; the duplication is intentional.
void _checkPayloadShape(Uint8List payload) {
  if (payload.length < kGcmMinPayloadLength) {
    throw CiphertextIntegrityException(
        'Payload of ${payload.length} bytes is shorter than IV + tag.');
  }
}

/// Static entry point used by the rest of the app.
class KeystoreService {
  KeystoreService._();

  static KeystoreBackend _platform = const PlatformKeystoreBackend();
  static KeystoreBackend? _override;
  static KeystoreBackend? _hostFallback;

  /// Forces a backend (tests). Pass null to restore normal resolution.
  @visibleForTesting
  static set backendForTesting(KeystoreBackend? backend) {
    _override = backend;
    _hostFallback = null;
  }

  /// Replaces the channel-backed implementation (tests that exercise the
  /// fallback policy itself).
  @visibleForTesting
  static set platformBackendForTesting(KeystoreBackend backend) {
    _platform = backend;
    _hostFallback = null;
  }

  /// Decides whether a platform failure may degrade to the test double.
  /// Overridable so the "never on Android" rule can itself be tested.
  @visibleForTesting
  static bool Function() hostFallbackAllowed =
      () => !kReleaseMode && !Platform.isAndroid;

  static Future<T> _run<T>(Future<T> Function(KeystoreBackend b) op) async {
    final forced = _override ?? _hostFallback;
    if (forced != null) return op(forced);
    try {
      return await op(_platform);
    } on MissingPluginException catch (e) {
      return _fallbackOr(op, e);
    } on PlatformException catch (e) {
      return _fallbackOr(op, e);
    }
  }

  static Future<T> _fallbackOr<T>(
    Future<T> Function(KeystoreBackend b) op,
    Object error,
  ) {
    if (!hostFallbackAllowed()) {
      // Fail closed. The message names the category, never the payload.
      throw KeystoreUnavailableException(
          'AndroidKeyStore operation failed (${error.runtimeType}).');
    }
    final fallback = _hostFallback ??= HostTestKeystoreBackend();
    return op(fallback);
  }

  static Future<Uint8List> encrypt(Uint8List data) =>
      _run((b) => b.encrypt(data));

  static Future<Uint8List> decrypt(Uint8List payload) =>
      _run((b) => b.decrypt(payload));

  static Future<List<Uint8List>> decryptBatch(List<Uint8List> payloads) =>
      payloads.isEmpty
          ? Future.value(const <Uint8List>[])
          : _run((b) => b.decryptBatch(payloads));

  static Future<PayloadSignature> signPayload(Uint8List payload) =>
      _run((b) => b.signPayload(payload));

  static Future<Uint8List?> getPublicKey() => _run((b) => b.publicKeyDer());

  static Future<String?> getPublicKeyHex() async {
    final der = await getPublicKey();
    return der == null ? null : toHex(der);
  }

  static Future<List<Uint8List>> getAttestationChain() =>
      _run((b) => b.attestationChain());

  static Future<KeystoreStatus> status() => _run((b) => b.status());

  /// True only when both keys are in AndroidKeyStore and KeyInfo reports
  /// TEE or StrongBox for both. Always false on the host.
  static Future<bool> isHardwareEnclaveActive() async {
    try {
      return (await status()).hardwareBacked;
    } on KeystoreUnavailableException {
      return false;
    }
  }

  static Future<Uint8List> sessionSeal(
          Uint8List key, Uint8List plaintext, Uint8List aad) =>
      _run((b) => b.sessionSeal(key, plaintext, aad));

  static Future<Uint8List> sessionOpen(
          Uint8List key, Uint8List payload, Uint8List aad) =>
      _run((b) => b.sessionOpen(key, payload, aad));
}
