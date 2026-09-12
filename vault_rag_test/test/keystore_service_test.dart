/// Host tests for KeystoreService's fallback policy and the AES-GCM wire
/// format.
///
/// WHAT THESE DO NOT PROVE: nothing here touches AndroidKeyStore. The format
/// tests run against HostTestKeystoreBackend, which reproduces the
/// `IV(12) || ct || tag(16)` layout and fail-closed behaviour; whether the
/// device keys are really in StrongBox or the TEE can only be established on
/// the phone (KeystoreChannel.keyStatus / key attestation).

library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_rag_test/core/security/host_test_keystore.dart';
import 'package:vault_rag_test/core/security/keystore_service.dart';
import 'package:vault_rag_test/core/security/security_constants.dart';

/// A platform backend that fails every call the way a given environment does.
class _ThrowingBackend extends PlatformKeystoreBackend {
  final Object error;
  const _ThrowingBackend(this.error);

  @override
  Future<Uint8List> encrypt(Uint8List plaintext) => Future.error(error);
  @override
  Future<KeystoreStatus> status() => Future.error(error);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    KeystoreService.backendForTesting = null;
    KeystoreService.platformBackendForTesting = const PlatformKeystoreBackend();
    KeystoreService.hostFallbackAllowed = () => true;
  });

  group('fallback policy', () {
    test('MissingPluginException on the host selects the test double', () async {
      KeystoreService.platformBackendForTesting =
          _ThrowingBackend(MissingPluginException('no handler'));
      final ct = await KeystoreService.encrypt(Uint8List.fromList([1, 2, 3]));
      expect(ct.length, kGcmIvLength + 3 + kGcmTagLength);
    });

    test('PlatformException on the host selects the test double', () async {
      KeystoreService.platformBackendForTesting =
          _ThrowingBackend(PlatformException(code: 'KEYSTORE_ERROR'));
      final status = await KeystoreService.status();
      expect(status.isHostTestFallback, isTrue);
    });

    test('the real channel with no handler falls back on the host', () async {
      // No override at all: the genuine MethodChannel path, as flutter test
      // exercises it.
      expect(await KeystoreService.isHardwareEnclaveActive(), isFalse);
      final status = await KeystoreService.status();
      expect(status.isHostTestFallback, isTrue);
      expect(status.enclaveLabel, contains('host-test'));
      expect(await KeystoreService.getPublicKey(), isNull);
    });

    test('where fallback is not allowed (Android, release) it fails closed',
        () async {
      KeystoreService.hostFallbackAllowed = () => false;
      KeystoreService.platformBackendForTesting =
          _ThrowingBackend(MissingPluginException('no handler'));
      await expectLater(
        KeystoreService.encrypt(Uint8List.fromList(utf8.encode('secret'))),
        throwsA(isA<KeystoreUnavailableException>()),
      );
      // …and never reports an enclave it could not reach.
      expect(await KeystoreService.isHardwareEnclaveActive(), isFalse);
    });

    test('hardwareBacked requires hardware levels for both keys', () {
      const teeOnlyAes = KeystoreStatus(
        keystoreAvailable: true,
        aesLevel: KeySecurityLevel.tee,
        signingLevel: KeySecurityLevel.software,
        strongBoxFeature: true,
        isHostTestFallback: false,
      );
      expect(teeOnlyAes.hardwareBacked, isFalse);
      expect(teeOnlyAes.enclaveLabel, contains('software'));
      expect(teeOnlyAes.enclaveLabel, isNot(contains('StrongBox')));
    });
  });

  group('AES-GCM payload format (host double)', () {
    late HostTestKeystoreBackend backend;
    setUp(() => KeystoreService.backendForTesting =
        backend = HostTestKeystoreBackend());

    test('IV is 12 bytes, tag 16, payload larger than plaintext', () async {
      final plain = Uint8List.fromList(utf8.encode('MAX_ORDER_USD = 250000'));
      final ct = await KeystoreService.encrypt(plain);
      expect(ct.length, plain.length + kGcmIvLength + kGcmTagLength);
      expect(await KeystoreService.decrypt(ct), plain);
    });

    test('identical plaintexts never produce identical payloads', () async {
      final plain = Uint8List.fromList(utf8.encode('same text'));
      final a = await KeystoreService.encrypt(plain);
      final b = await KeystoreService.encrypt(plain);
      expect(a.sublist(0, kGcmIvLength), isNot(b.sublist(0, kGcmIvLength)));
      expect(a, isNot(b));
    });

    test('truncated payload is rejected before decryption', () async {
      await expectLater(
        KeystoreService.decrypt(Uint8List(kGcmMinPayloadLength - 1)),
        throwsA(isA<CiphertextIntegrityException>()),
      );
    });

    test('one flipped bit anywhere fails authentication', () async {
      final ct = await KeystoreService.encrypt(
          Uint8List.fromList(utf8.encode('salary: 184,000')));
      for (final index in [0, kGcmIvLength + 2, ct.length - 1]) {
        final tampered = Uint8List.fromList(ct)..[index] ^= 0x01;
        await expectLater(
          KeystoreService.decrypt(tampered),
          throwsA(isA<CiphertextIntegrityException>()),
          reason: 'byte $index',
        );
      }
    });

    test('mock signatures cannot be mistaken for DER', () async {
      final sig = await KeystoreService.signPayload(Uint8List.fromList([1]));
      expect(sig.isMock, isTrue);
      expect(sig.mock, startsWith('MOCK_SIG_'));
      expect(sig.algorithm, 'MOCK-UNSIGNED');
      expect(backend.encryptCalls, 0);
    });
  });
}
