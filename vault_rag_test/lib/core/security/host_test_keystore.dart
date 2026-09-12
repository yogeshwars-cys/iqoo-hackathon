/// host_test_keystore.dart
///
/// TEST DOUBLE. NOT A PRODUCTION CIPHER. NOT SELECTABLE ON ANDROID.
///
/// [KeystoreService] reaches this only under `flutter test` on a desktop host
/// (see the fallback policy in keystore_service.dart). It exists so the
/// encrypted-storage pipeline — migration, lazy decryption, tamper
/// detection — runs end to end in host tests instead of being skipped.
///
/// It reproduces the production *wire format* exactly,
/// `IV(12) || ciphertext || tag(16)`, so length checks, truncation handling
/// and "one flipped bit is rejected" behave the same way they do against
/// AndroidKeyStore. The construction underneath is an HMAC-SHA256
/// counter-mode keystream with an HMAC-SHA256 tag (encrypt-then-MAC) under a
/// fixed, public, test-only key. It is built from `package:crypto` HMAC, not
/// hand-rolled primitives, but the key is a constant in this file: anything
/// it "encrypts" is readable by anyone with the source. That is fine for a
/// unit test and disqualifying everywhere else, which is why its status
/// reports `host-test` and its signatures are `MOCK_SIG_…` strings that the
/// desktop verifier refuses.

library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'bytes.dart';
import 'keystore_service.dart';
import 'security_constants.dart';

class HostTestKeystoreBackend implements KeystoreBackend {
  static final _masterKey =
      sha256.convert(utf8.encode('vault host-test key — not a secret')).bytes;

  final Random _random;

  /// Counts, so tests can assert that ranking never decrypts.
  int encryptCalls = 0;
  int decryptCalls = 0;

  HostTestKeystoreBackend({Random? random})
      : _random = random ?? Random.secure();

  @override
  Future<Uint8List> encrypt(Uint8List plaintext) async {
    encryptCalls++;
    return _seal(_masterKey, plaintext, const []);
  }

  @override
  Future<Uint8List> decrypt(Uint8List payload) async {
    decryptCalls++;
    return _open(_masterKey, payload, const []);
  }

  @override
  Future<List<Uint8List>> decryptBatch(List<Uint8List> payloads) async {
    decryptCalls += payloads.length;
    return [for (final p in payloads) _open(_masterKey, p, const [])];
  }

  @override
  Future<PayloadSignature> signPayload(Uint8List payload) async =>
      PayloadSignature.mock('MOCK_SIG_${sha256.convert(payload)}');

  @override
  Future<Uint8List?> publicKeyDer() async => null;

  @override
  Future<List<Uint8List>> attestationChain() async => const [];

  @override
  Future<KeystoreStatus> status() async => KeystoreStatus.hostTest;

  @override
  Future<Uint8List> sessionSeal(
          Uint8List key, Uint8List plaintext, Uint8List aad) async =>
      _seal(key, plaintext, aad);

  @override
  Future<Uint8List> sessionOpen(
          Uint8List key, Uint8List payload, Uint8List aad) async =>
      _open(key, payload, aad);

  Uint8List _seal(List<int> key, Uint8List plaintext, List<int> aad) {
    final iv = Uint8List(kGcmIvLength);
    for (var i = 0; i < iv.length; i++) {
      iv[i] = _random.nextInt(256);
    }
    final ct = _xorKeystream(key, iv, plaintext);
    final tag = _tag(key, iv, ct, aad);
    return Uint8List.fromList([...iv, ...ct, ...tag]);
  }

  Uint8List _open(List<int> key, Uint8List payload, List<int> aad) {
    if (payload.length < kGcmMinPayloadLength) {
      throw const CiphertextIntegrityException('Payload too short.');
    }
    final iv = payload.sublist(0, kGcmIvLength);
    final ct = payload.sublist(kGcmIvLength, payload.length - kGcmTagLength);
    final tag = payload.sublist(payload.length - kGcmTagLength);
    if (!constantTimeEquals(tag, _tag(key, iv, ct, aad))) {
      // Fail closed: nothing derived from an unauthenticated ciphertext is
      // ever returned.
      throw const CiphertextIntegrityException('Authentication failed.');
    }
    return _xorKeystream(key, iv, ct);
  }

  static Uint8List _xorKeystream(List<int> key, List<int> iv, List<int> input) {
    final encKey = Hmac(sha256, key).convert(utf8.encode('enc')).bytes;
    final out = Uint8List(input.length);
    var block = const <int>[];
    for (var i = 0; i < input.length; i++) {
      if (i % 32 == 0) {
        final counter = ByteData(4)..setUint32(0, i ~/ 32);
        block = Hmac(sha256, encKey)
            .convert([...iv, ...counter.buffer.asUint8List()]).bytes;
      }
      out[i] = input[i] ^ block[i % 32];
    }
    return out;
  }

  static List<int> _tag(
      List<int> key, List<int> iv, List<int> ct, List<int> aad) {
    final macKey = Hmac(sha256, key).convert(utf8.encode('mac')).bytes;
    final lengths = ByteData(16)
      ..setUint64(0, aad.length)
      ..setUint64(8, ct.length);
    return Hmac(sha256, macKey)
        .convert([...iv, ...aad, ...ct, ...lengths.buffer.asUint8List()])
        .bytes
        .sublist(0, kGcmTagLength);
  }
}
