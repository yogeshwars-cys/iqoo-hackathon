/// vault_link_service.dart
///
/// VaultLink: a laptop-to-vault request/response loop carried entirely over
/// the system clipboard, mirrored between devices by Office Kit. No socket,
/// no IP address, no Android permission.
///
///   laptop      writes a sealed request to its clipboard
///   Office Kit  mirrors it to the phone's clipboard
///   VaultLink   (this file) opens it, runs the query, seals the answer back
///   Office Kit  mirrors it back
///   laptop      opens the reply, verifies the capsule signature, scrubs
///
/// PROTOCOL: VAULTLINK/2 (vaultlink_secure.dart) — AES-256-GCM frames under
/// keys derived from an on-screen pairing code, with direction-separated
/// keys, a clock-skew window and a replay cache. The plaintext VAULTLINK/1
/// format is still understood, but only when [allowInsecureV1] is switched
/// on by the user, because a v1 request is by construction unauthenticated:
/// anything able to write the clipboard could query the vault with it.
///
/// Ops: `ping`, `query`, and `enroll` (v2 only) — which returns the device's
/// capsule-signing public key and its attestation chain so the laptop can
/// pin it over the already-authenticated channel rather than trusting the
/// first key it happens to see.
///
/// WHY POLLING, NOT AN EVENT: Android exposes no reliable clipboard-changed
/// callback in the background and has refused background clipboard reads
/// since Android 10. A foreground `Timer.periodic` while a session is
/// switched on is the only shape this can take, which is also why the
/// session is opt-in and visible on screen.
///
/// Anything on the clipboard that isn't a VaultLink frame is left alone, and
/// completed replies are scrubbed after [kClipboardTtl] if still unchanged.

library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../core/security/bytes.dart';
import '../core/security/ephemeral_clipboard.dart';
import '../core/security/keystore_service.dart';
import '../core/vault_engine.dart';
import 'vaultlink_secure.dart';

enum VaultLinkEventKind { info, request, success, failure }

class VaultLinkEvent {
  final DateTime at;
  final String message;
  final VaultLinkEventKind kind;

  VaultLinkEvent(this.message, this.kind) : at = DateTime.now();
}

/// Where the pairing code is kept between launches.
abstract interface class PairingStore {
  Future<String?> load();
  Future<void> save(String code);
  Future<void> clear();
}

/// Stores the pairing code AES-GCM-encrypted under the AndroidKeyStore
/// master key, in app-private storage. Plaintext never touches disk.
class KeystorePairingStore implements PairingStore {
  final String directory;
  const KeystorePairingStore(this.directory);

  File get _file => File('$directory/vaultlink_pairing.bin');

  @override
  Future<String?> load() async {
    if (!await _file.exists()) return null;
    final plain = await KeystoreService.decrypt(await _file.readAsBytes());
    return utf8.decode(plain);
  }

  @override
  Future<void> save(String code) async {
    final sealed = await KeystoreService.encrypt(utf8.encode(code));
    await _file.writeAsBytes(sealed, flush: true);
  }

  @override
  Future<void> clear() async {
    if (await _file.exists()) await _file.delete();
  }
}

class MemoryPairingStore implements PairingStore {
  String? code;
  @override
  Future<String?> load() async => code;
  @override
  Future<void> save(String code) async => this.code = code;
  @override
  Future<void> clear() async => code = null;
}

class VaultLinkService extends ChangeNotifier {
  final VaultEngine engine;
  final Map<String, dynamic> Function() telemetrySnapshot;
  final ClipboardPort port;

  /// Set once the documents directory is known (see main.dart bootstrap).
  PairingStore? pairingStore;
  final EphemeralClipboard _ephemeral;

  VaultLinkService({
    required this.engine,
    required this.telemetrySnapshot,
    this.port = const SystemClipboardPort(),
    this.pairingStore,
  }) : _ephemeral = EphemeralClipboard(port: port);

  Timer? _poll;
  bool _running = false;
  bool _busy = false;

  VaultLinkCodec? _codec;
  String? _pairingCode;

  /// Legacy plaintext frames. Off unless the user turns it on.
  bool _allowInsecureV1 = false;

  /// v1 dedupe: the most recent request id already handled.
  String? _lastV1RequestId;

  /// Digest of the last rejected frame, so one bad frame sitting on the
  /// clipboard is logged once rather than every 700 ms.
  String? _lastRejectedDigest;

  int _served = 0;
  final List<VaultLinkEvent> _log = [];

  bool get isRunning => _running;
  bool get isPaired => _codec != null;
  String? get pairingCode => _pairingCode;
  String? get keyId => _codec?.keys.kid;
  bool get allowInsecureV1 => _allowInsecureV1;
  int get served => _served;
  List<VaultLinkEvent> get log => List.unmodifiable(_log);

  void _emit(String message, [VaultLinkEventKind kind = VaultLinkEventKind.info]) {
    _log.insert(0, VaultLinkEvent(message, kind));
    if (_log.length > 120) _log.removeLast();
    notifyListeners();
  }

  /// Restores a saved pairing. Failure (e.g. keystore key gone) leaves the
  /// link unpaired rather than half-configured.
  Future<void> restorePairing() async {
    final store = pairingStore;
    if (store == null) return;
    try {
      final code = await store.load();
      if (code != null) _applyCode(code);
    } catch (e) {
      _emit('Saved pairing could not be restored (${e.runtimeType}); pair again',
          VaultLinkEventKind.failure);
    }
    notifyListeners();
  }

  /// Generates and persists a new pairing code. Any previously paired laptop
  /// stops working immediately.
  Future<String> pair() async {
    final code = generatePairingCode();
    await pairingStore?.save(code);
    _applyCode(code);
    _emit('New pairing code generated — previous laptop unpaired');
    return code;
  }

  Future<void> unpair() async {
    await pairingStore?.clear();
    _codec = null;
    _pairingCode = null;
    _emit('Unpaired — sealed requests are now ignored');
  }

  void _applyCode(String code) {
    _codec = VaultLinkCodec(VaultLinkKeys.fromPairingCode(code));
    _pairingCode = code;
  }

  set allowInsecureV1(bool value) {
    if (value == _allowInsecureV1) return;
    _allowInsecureV1 = value;
    _emit(value
        ? 'Legacy VAULTLINK/1 enabled — unauthenticated, plaintext'
        : 'Legacy VAULTLINK/1 disabled');
  }

  void start({Duration interval = const Duration(milliseconds: 700)}) {
    if (_running) return;
    _running = true;
    _emit(isPaired
        ? 'VaultLink session started — watching for sealed requests'
        : 'VaultLink session started — not paired, only legacy frames can be served');
    _poll = Timer.periodic(interval, (_) => tick());
  }

  void stop() {
    if (!_running) return;
    _running = false;
    _poll?.cancel();
    _poll = null;
    _emit('VaultLink session stopped');
  }

  /// One poll. Public for tests; the timer calls it in production.
  @visibleForTesting
  Future<void> tick() async {
    if (_busy) return; // a generation is running; the next tick will see it
    final String? text;
    try {
      text = await port.read();
    } catch (_) {
      return; // transient platform-channel hiccup; try again next tick
    }
    if (text == null) return;

    if (text.startsWith(kVaultLinkV2Prefix)) {
      await _tickV2(text);
    } else if (text.startsWith(kVaultLinkV1Prefix)) {
      await _tickV1(text);
    }
  }

  Future<void> _tickV2(String frame) async {
    final codec = _codec;
    if (codec == null) {
      _rejectOnce(frame, 'Sealed request ignored — this phone is not paired');
      return;
    }
    final Map<String, dynamic> request;
    try {
      request = await codec.openRequest(frame);
    } on VaultLinkRejected catch (r) {
      // Our own replies are dir=rep: silently not requests.
      if (r.reason == FrameRejection.wrongDirection) return;
      final why = switch (r.reason) {
        FrameRejection.wrongKey => 'sealed for a different pairing',
        FrameRejection.badSeal => 'failed authentication',
        FrameRejection.stale => 'timestamp outside the ±5 min window',
        FrameRejection.replay => 'replayed request id',
        _ => 'malformed',
      };
      _rejectOnce(frame, 'Rejected request: $why');
      return;
    }
    await _handle(request['id'] as String, request, secure: true);
  }

  Future<void> _tickV1(String text) async {
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(text.substring(kVaultLinkV1Prefix.length))
          as Map<String, dynamic>;
    } catch (_) {
      return; // VAULTLINK-shaped but not valid JSON; not ours to touch
    }
    final id = msg['id'] as String?;
    // Only a request carries `op`; our own replies carry `status`.
    if (id == null || msg['op'] is! String || id == _lastV1RequestId) return;
    if (!_allowInsecureV1) {
      _rejectOnce(text,
          'Ignored unauthenticated VAULTLINK/1 request — pair the laptop '
          '(vaultlink.py pair) or enable legacy mode');
      return;
    }
    _lastV1RequestId = id;
    await _handle(id, msg, secure: false);
  }

  void _rejectOnce(String frame, String message) {
    final digest = sha256.convert(utf8.encode(frame)).toString();
    if (digest == _lastRejectedDigest) return;
    _lastRejectedDigest = digest;
    _emit(message, VaultLinkEventKind.failure);
  }

  Future<void> _handle(String id, Map<String, dynamic> msg,
      {required bool secure}) async {
    final op = msg['op'] as String;
    _busy = true;
    _emit('Request $id: $op${secure ? ' (sealed)' : ' (UNAUTHENTICATED)'}',
        VaultLinkEventKind.request);
    try {
      switch (op) {
        case 'ping':
          await _reply(id, {
            'ok': true,
            'status': 'complete',
            'secure': secure,
            ...engine.describe(),
            'compute': telemetrySnapshot(),
          }, secure: secure);
          _emit('Answered ping', VaultLinkEventKind.success);
        case 'query':
          await _handleQuery(id, msg, secure: secure);
        case 'enroll' when secure:
          await _handleEnroll(id);
        default:
          await _reply(id, {
            'ok': false,
            'status': 'complete',
            'error': op == 'enroll'
                ? 'enroll requires a paired VAULTLINK/2 session'
                : 'Unsupported op: $op',
          }, secure: secure);
          _emit('Unsupported op "$op"', VaultLinkEventKind.failure);
      }
    } catch (e) {
      // Category only: exception text can quote vault content.
      await _reply(id, {'ok': false, 'status': 'complete', 'error': '${e.runtimeType}'},
          secure: secure);
      _emit('Request $id failed: ${e.runtimeType}', VaultLinkEventKind.failure);
    } finally {
      _busy = false;
    }
  }

  Future<void> _handleQuery(String id, Map<String, dynamic> msg,
      {required bool secure}) async {
    final q = (msg['q'] as String?)?.trim() ?? '';
    final topK = ((msg['k'] as num?)?.toInt() ?? 5).clamp(1, 20);
    final generate = (msg['generate'] as bool?) ?? true;
    if (q.isEmpty) {
      await _reply(id, {'ok': false, 'status': 'complete', 'error': 'Empty query'},
          secure: secure);
      return;
    }

    // Generation can run to tens of seconds. Without this interim frame the
    // laptop cannot tell "the phone has it" from "never arrived".
    await _reply(id, {'status': 'processing'}, secure: secure, interim: true);

    final capsule = await engine.ask(q, topK: topK, generate: generate);
    _served++;
    await _reply(id, {
      'ok': true,
      'status': 'complete',
      ...capsule.toJson(),
      'compute': telemetrySnapshot(),
    }, secure: secure);
    _emit(
      'Answered (${capsule.gatingPath.wireName}'
      '${capsule.generation.ran ? ', ${capsule.generation.elapsedMs ?? 0} ms generation' : ''}'
      '${capsule.provenance?.isSigned ?? false ? ', signed' : ', UNSIGNED'})',
      VaultLinkEventKind.success,
    );
  }

  Future<void> _handleEnroll(String id) async {
    final status = await KeystoreService.status();
    final publicKey = await KeystoreService.getPublicKey();
    final chain = await KeystoreService.getAttestationChain();
    await _reply(id, {
      'ok': publicKey != null,
      'status': 'complete',
      if (publicKey == null) 'error': 'No hardware signing key on this device',
      'public_key': publicKey == null ? null : toHex(publicKey),
      'key_status': status.toJson(),
      'enclave': status.enclaveLabel,
      'attestation_chain': [for (final c in chain) toHex(c)],
    }, secure: true);
    _emit('Enrollment: signing key sent to the paired laptop',
        VaultLinkEventKind.success);
  }

  Future<void> _reply(String id, Map<String, dynamic> data,
      {required bool secure, bool interim = false}) async {
    final body = {'id': id, ...data};
    final codec = _codec;
    // Unpaired mid-request: the laptop that asked is no longer trusted, so
    // it gets nothing rather than a reply sealed to a discarded key.
    if (secure && codec == null) return;
    final text = secure
        ? await codec!.sealReply(body)
        : '$kVaultLinkV1Prefix${jsonEncode(body)}';
    if (interim) {
      await port.write(text);
    } else {
      // Final answers get the TTL: scrubbed after 20 s if still unchanged.
      await _ephemeral.copy(text);
    }
  }

  @override
  void dispose() {
    stop();
    _ephemeral.dispose();
    super.dispose();
  }
}
