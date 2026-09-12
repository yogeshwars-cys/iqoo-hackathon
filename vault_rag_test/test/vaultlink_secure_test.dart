/// VAULTLINK/2 framing and the service's refusal of unauthenticated input.
///
/// Sealing runs through KeystoreService's host double (same wire layout as
/// the Kotlin AES-GCM path); the key schedule is checked against the vector
/// the Python laptop side also asserts.

library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_rag_test/core/security/bytes.dart';
import 'package:vault_rag_test/core/vault_engine.dart';
import 'package:vault_rag_test/link/vault_link_service.dart';
import 'package:vault_rag_test/link/vaultlink_secure.dart';

import 'ephemeral_clipboard_test.dart' show FakeClipboard;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final vector = (jsonDecode(File('../bridge/tests/vectors/cross_language_vectors.json')
          .readAsStringSync()) as Map<String, dynamic>)['vaultlink_v2_keys']
      as Map<String, dynamic>;
  final code = vector['pairing_code'] as String;

  group('key schedule', () {
    test('matches the Python laptop implementation', () {
      final keys = VaultLinkKeys.fromPairingCode(code);
      expect(toHex(keys.requestKey), vector['request_key_hex']);
      expect(toHex(keys.replyKey), vector['reply_key_hex']);
      expect(keys.kid, vector['kid']);
    });

    test('generated codes are 20 Crockford symbols and normalise', () {
      final c = generatePairingCode();
      expect(c, matches(RegExp(r'^[0-9A-HJKMNP-TV-Z]{5}(-[0-9A-HJKMNP-TV-Z]{5}){3}$')));
      expect(normalisePairingCode(c.toLowerCase().replaceAll('-', ' ')),
          c.replaceAll('-', ''));
      expect(normalisePairingCode('short'), isNull);
    });
  });

  group('codec', () {
    DateTime clock = DateTime.now();
    late VaultLinkCodec laptop;
    late VaultLinkCodec phone;

    setUp(() {
      clock = DateTime.now();
      laptop = VaultLinkCodec(VaultLinkKeys.fromPairingCode(code), now: () => clock);
      phone = VaultLinkCodec(VaultLinkKeys.fromPairingCode(code), now: () => clock);
    });

    Map<String, dynamic> req([String id = 'q_1']) =>
        {'id': id, 'op': 'query', 'q': 'salary of 413', 'ts': clock.millisecondsSinceEpoch};

    test('round trip hides the question', () async {
      final frame = await laptop.sealRequest(req());
      expect(frame, startsWith(kVaultLinkV2Prefix));
      expect(frame.contains('salary'), isFalse);
      expect((await phone.openRequest(frame))['q'], 'salary of 413');
    });

    test('a replayed request id is refused', () async {
      final frame = await laptop.sealRequest(req());
      await phone.openRequest(frame);
      await expectLater(phone.openRequest(frame),
          throwsA(isA<VaultLinkRejected>().having((r) => r.reason, 'reason', FrameRejection.replay)));
    });

    test('a stale timestamp is refused', () async {
      final old = req()..['ts'] = clock.subtract(const Duration(minutes: 6)).millisecondsSinceEpoch;
      await expectLater(phone.openRequest(await laptop.sealRequest(old)),
          throwsA(isA<VaultLinkRejected>().having((r) => r.reason, 'reason', FrameRejection.stale)));
    });

    test('the wrong pairing and tampered frames are refused', () async {
      final other = VaultLinkCodec(VaultLinkKeys.fromPairingCode('00000-00000-00000-00000'));
      await expectLater(phone.openRequest(await other.sealRequest(req())),
          throwsA(isA<VaultLinkRejected>().having((r) => r.reason, 'reason', FrameRejection.wrongKey)));

      final frame = await laptop.sealRequest(req('q_2'));
      final outer = jsonDecode(frame.substring(kVaultLinkV2Prefix.length)) as Map<String, dynamic>;
      final ct = base64Decode(outer['ct'] as String)..[14] ^= 1;
      outer['ct'] = base64Encode(ct);
      await expectLater(phone.openRequest('$kVaultLinkV2Prefix${jsonEncode(outer)}'),
          throwsA(isA<VaultLinkRejected>().having((r) => r.reason, 'reason', FrameRejection.badSeal)));
    });

    test('a reply cannot be reflected as a request', () async {
      final reply = await phone.sealReply({'id': 'q_3', 'op': 'query', 'ts': clock.millisecondsSinceEpoch});
      await expectLater(phone.openRequest(reply),
          throwsA(isA<VaultLinkRejected>().having((r) => r.reason, 'reason', FrameRejection.wrongDirection)));
      final outer = jsonDecode(reply.substring(kVaultLinkV2Prefix.length)) as Map<String, dynamic>
        ..['dir'] = 'req';
      await expectLater(phone.openRequest('$kVaultLinkV2Prefix${jsonEncode(outer)}'),
          throwsA(isA<VaultLinkRejected>().having((r) => r.reason, 'reason', FrameRejection.badSeal)));
    });
  });

  group('VaultLinkService', () {
    late FakeClipboard clipboard;
    late VaultEngine engine;
    late VaultLinkService link;

    setUp(() async {
      clipboard = FakeClipboard();
      engine = VaultEngine();
      link = VaultLinkService(
        engine: engine,
        telemetrySnapshot: () => const {},
        port: clipboard,
        pairingStore: MemoryPairingStore(),
      );
    });
    tearDown(() {
      link.dispose();
      engine.dispose();
    });

    test('an unauthenticated v1 request is ignored by default', () async {
      const frame = '$kVaultLinkV1Prefix{"id":"q_9","op":"ping"}';
      clipboard.content = frame;
      await link.tick();
      expect(clipboard.content, frame, reason: 'no reply written');
      expect(link.log.first.message, contains('Ignored unauthenticated'));
    });

    test('legacy mode answers v1 only when explicitly enabled', () async {
      link.allowInsecureV1 = true;
      clipboard.content = '$kVaultLinkV1Prefix{"id":"q_9","op":"ping"}';
      await link.tick();
      final reply = jsonDecode(clipboard.content!.substring(kVaultLinkV1Prefix.length));
      expect(reply['id'], 'q_9');
      expect(reply['secure'], isFalse);
    });

    test('a paired phone answers a sealed ping with a sealed reply', () async {
      final pairing = await link.pair();
      final laptop = VaultLinkCodec(VaultLinkKeys.fromPairingCode(pairing));
      clipboard.content = await laptop.sealRequest(
          {'id': 'q_10', 'op': 'ping', 'ts': DateTime.now().millisecondsSinceEpoch});
      await link.tick();

      final replyFrame = clipboard.content!;
      expect(replyFrame, startsWith(kVaultLinkV2Prefix));
      expect(replyFrame.contains('vault-minilm'), isFalse, reason: 'reply is encrypted');
      final reply = await laptop.openReply(replyFrame);
      expect(reply['id'], 'q_10');
      expect(reply['ok'], isTrue);
      expect(reply['secure'], isTrue);

      // The phone's next poll sees its own reply and does nothing.
      await link.tick();
      expect(clipboard.content, replyFrame);
    });

    test('a sealed request from an unpaired or different laptop is ignored', () async {
      await link.pair();
      final stranger = VaultLinkCodec(VaultLinkKeys.fromPairingCode(generatePairingCode()));
      final frame = await stranger.sealRequest(
          {'id': 'q_11', 'op': 'ping', 'ts': DateTime.now().millisecondsSinceEpoch});
      clipboard.content = frame;
      await link.tick();
      expect(clipboard.content, frame);
      expect(link.log.first.message, contains('different pairing'));
    });

    test('enroll is refused over legacy v1', () async {
      link.allowInsecureV1 = true;
      clipboard.content = '$kVaultLinkV1Prefix{"id":"q_12","op":"enroll"}';
      await link.tick();
      final reply = jsonDecode(clipboard.content!.substring(kVaultLinkV1Prefix.length));
      expect(reply['ok'], isFalse);
      expect(reply['error'], contains('VAULTLINK/2'));
    });

    test('pairing survives a restart through the store', () async {
      final store = MemoryPairingStore();
      link.pairingStore = store;
      final pairing = await link.pair();
      final restarted = VaultLinkService(
          engine: engine, telemetrySnapshot: () => const {}, port: clipboard, pairingStore: store);
      await restarted.restorePairing();
      expect(restarted.isPaired, isTrue);
      expect(restarted.keyId, VaultLinkKeys.fromPairingCode(pairing).kid);
      restarted.dispose();
    });
  });
}
