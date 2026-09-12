/// vaultlink_secure.dart
///
/// VAULTLINK/2 — authenticated, encrypted framing for the clipboard link.
///
/// WHY v1 WAS NOT SAFE
///
/// VAULTLINK/1 frames are plaintext JSON on a shared clipboard. Anything that
/// can write the clipboard — any foreground app, any desktop process, anyone
/// else on the Office Kit sync — could send `{"op":"query"}` and read the
/// vault's answer back off the same clipboard. The question and the answer
/// also sat in clipboard history in the clear.
///
/// WHAT v2 ADDS
///
///   * Pairing. The phone generates a 20-character Crockford-base32 code
///     (100 bits) and shows it on screen. The user types it into
///     `vaultlink.py pair`. The code never crosses the clipboard, so a
///     clipboard observer cannot learn it — this is the out-of-band step
///     everything else rests on.
///   * Key schedule (HMAC-SHA256 as a PRF, mirrored in vaultlink.py):
///         root  = HMAC(key="vaultlink/2 pairing", msg=normalised code)
///         K_req = HMAC(root, "vaultlink/2 req")   laptop -> phone
///         K_rep = HMAC(root, "vaultlink/2 rep")   phone -> laptop
///         kid   = hex(HMAC(root, "vaultlink/2 kid"))[0:16]
///     Separate keys per direction mean the phone cannot be fed its own
///     reply as a request, and neither side accepts the other's frames.
///   * Every frame is AES-256-GCM sealed: `IV || ct || tag`, AAD =
///     `VAULTLINK/2|dir|kid`. Confidentiality for question and answer;
///     integrity and origin authentication for both.
///   * Freshness. Requests carry `ts` (ms) and a unique `id`; the phone
///     rejects anything outside ±[kMaxClockSkew] or an id it has already
///     served. Every op is read-only and every reply is sealed to the paired
///     laptop, so a replay that slipped through (e.g. across an app restart)
///     discloses nothing new to the replayer.
///
/// Capsules inside replies remain ECDSA-signed by the keystore key, so a
/// laptop can hold the phone to its hardware key independently of the
/// pairing secret — the `enroll` op delivers that key over this channel.
///
/// NOT ADDRESSED (see SECURITY.md): the pairing code is only as secret as
/// the screen showing it; the laptop keeps the derived root under Windows
/// DPAPI, which protects it from other users, not from malware running as
/// the same user.

library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../core/security/bytes.dart';
import '../core/security/keystore_service.dart';

const kVaultLinkV1Prefix = 'VAULTLINK/1\n';
const kVaultLinkV2Prefix = 'VAULTLINK/2\n';
const kMaxClockSkew = Duration(minutes: 5);
const kReplayWindow = Duration(minutes: 10);

/// Crockford base32: no I, L, O, U — nothing to misread off a screen.
const _crockford = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
const kPairingCodeLength = 20;

/// Generates a fresh 100-bit pairing code, formatted XXXXX-XXXXX-XXXXX-XXXXX.
String generatePairingCode([Random? random]) {
  final rng = random ?? Random.secure();
  final chars = List.generate(
      kPairingCodeLength, (_) => _crockford[rng.nextInt(_crockford.length)]);
  final grouped = StringBuffer();
  for (var i = 0; i < chars.length; i++) {
    if (i > 0 && i % 5 == 0) grouped.write('-');
    grouped.write(chars[i]);
  }
  return grouped.toString();
}

/// Uppercases, strips separators, maps the Crockford look-alikes. Returns
/// null for anything that is not exactly 20 valid symbols.
String? normalisePairingCode(String input) {
  final out = StringBuffer();
  for (final rune in input.toUpperCase().runes) {
    var ch = String.fromCharCode(rune);
    if (ch == '-' || ch == ' ') continue;
    if (ch == 'O') ch = '0';
    if (ch == 'I' || ch == 'L') ch = '1';
    if (!_crockford.contains(ch)) return null;
    out.write(ch);
  }
  final s = out.toString();
  return s.length == kPairingCodeLength ? s : null;
}

class VaultLinkKeys {
  final Uint8List requestKey;
  final Uint8List replyKey;
  final String kid;

  const VaultLinkKeys._(this.requestKey, this.replyKey, this.kid);

  factory VaultLinkKeys.fromPairingCode(String code) {
    final normalised = normalisePairingCode(code);
    if (normalised == null) {
      throw const FormatException('Not a valid VaultLink pairing code.');
    }
    final root = Uint8List.fromList(Hmac(sha256, utf8.encode('vaultlink/2 pairing'))
        .convert(utf8.encode(normalised))
        .bytes);
    List<int> derive(String label) =>
        Hmac(sha256, root).convert(utf8.encode(label)).bytes;
    final keys = VaultLinkKeys._(
      Uint8List.fromList(derive('vaultlink/2 req')),
      Uint8List.fromList(derive('vaultlink/2 rep')),
      toHex(derive('vaultlink/2 kid')).substring(0, 16),
    );
    wipe(root);
    return keys;
  }
}

enum FrameRejection { notV2, malformed, wrongKey, wrongDirection, badSeal, stale, replay }

class VaultLinkRejected implements Exception {
  final FrameRejection reason;
  const VaultLinkRejected(this.reason);
  @override
  String toString() => 'VaultLinkRejected(${reason.name})';
}

/// Seal/open for VAULTLINK/2 frames. Stateless apart from the replay cache.
class VaultLinkCodec {
  final VaultLinkKeys keys;
  final DateTime Function() now;
  final Map<String, DateTime> _seen = {};

  VaultLinkCodec(this.keys, {DateTime Function()? now})
      : now = now ?? DateTime.now;

  static Uint8List _aad(String dir, String kid) =>
      Uint8List.fromList(utf8.encode('VAULTLINK/2|$dir|$kid'));

  Future<String> _seal(String dir, Uint8List key, Map<String, dynamic> body) async {
    final sealed = await KeystoreService.sessionSeal(
        key, Uint8List.fromList(utf8.encode(jsonEncode(body))), _aad(dir, keys.kid));
    return '$kVaultLinkV2Prefix${jsonEncode({
          'kid': keys.kid,
          'dir': dir,
          'ct': base64Encode(sealed),
        })}';
  }

  Future<Map<String, dynamic>> _open(String frame, String dir, Uint8List key) async {
    if (!frame.startsWith(kVaultLinkV2Prefix)) {
      throw const VaultLinkRejected(FrameRejection.notV2);
    }
    final Map<String, dynamic> outer;
    final Uint8List ct;
    try {
      outer = jsonDecode(frame.substring(kVaultLinkV2Prefix.length))
          as Map<String, dynamic>;
      ct = base64Decode(outer['ct'] as String);
    } catch (_) {
      throw const VaultLinkRejected(FrameRejection.malformed);
    }
    if (outer['kid'] != keys.kid) throw const VaultLinkRejected(FrameRejection.wrongKey);
    if (outer['dir'] != dir) throw const VaultLinkRejected(FrameRejection.wrongDirection);
    final Uint8List plain;
    try {
      plain = await KeystoreService.sessionOpen(key, ct, _aad(dir, keys.kid));
    } on CiphertextIntegrityException {
      throw const VaultLinkRejected(FrameRejection.badSeal);
    }
    try {
      return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
    } catch (_) {
      throw const VaultLinkRejected(FrameRejection.malformed);
    }
  }

  /// Laptop side (and tests): seal a request.
  Future<String> sealRequest(Map<String, dynamic> request) =>
      _seal('req', keys.requestKey, request);

  /// Phone side: seal a reply.
  Future<String> sealReply(Map<String, dynamic> reply) =>
      _seal('rep', keys.replyKey, reply);

  /// Laptop side (and tests): open a reply.
  Future<Map<String, dynamic>> openReply(String frame) =>
      _open(frame, 'rep', keys.replyKey);

  /// Phone side: open, authenticate and freshness-check a request. The id is
  /// recorded as seen only after every check passes.
  Future<Map<String, dynamic>> openRequest(String frame) async {
    final req = await _open(frame, 'req', keys.requestKey);
    final id = req['id'];
    final ts = req['ts'];
    if (id is! String || id.isEmpty || ts is! int || req['op'] is! String) {
      throw const VaultLinkRejected(FrameRejection.malformed);
    }
    final t = now();
    final sent = DateTime.fromMillisecondsSinceEpoch(ts);
    if (sent.difference(t).abs() > kMaxClockSkew) {
      throw const VaultLinkRejected(FrameRejection.stale);
    }
    _seen.removeWhere((_, at) => t.difference(at) > kReplayWindow);
    if (_seen.containsKey(id)) throw const VaultLinkRejected(FrameRejection.replay);
    _seen[id] = t;
    return req;
  }
}
