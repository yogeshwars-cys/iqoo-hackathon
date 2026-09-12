/// vault_link_service.dart
///
/// VaultLink: a laptop-to-vault request/response loop carried entirely over
/// the system clipboard, mirrored between devices by Office Kit. No socket,
/// no IP address, no new Android permission — this reuses exactly the
/// `Clipboard` API `vault_page.dart`'s Copy button already calls.
///
///   laptop           writes a request to its clipboard
///   Office Kit        mirrors it to the phone's clipboard
///   VaultLink         (this file) notices it, runs the query, writes the
///                     answer back to the phone's clipboard
///   Office Kit        mirrors it back
///   laptop            reads its clipboard, done
///
/// WIRE FORMAT — one line prefix, then one line of JSON:
///
///   VAULTLINK/1
///   {"id":"q_7f3a","op":"query","q":"...","k":5,"generate":true}
///
/// A request always carries `op`; VaultLink's replies never do — they carry
/// `status` instead (`"processing"` while a slow generation runs, then
/// `"complete"`). That asymmetry is what tells a poll loop a frame is its
/// own echo rather than a new incoming request, without needing to compare
/// clipboard text byte-for-byte. `id` alone still gets deduplicated too, in
/// case a request is somehow seen twice before its answer overwrites it.
///
/// WHY POLLING, NOT AN EVENT: Flutter/Android expose no clipboard-changed
/// callback that fires reliably in the background, and Android has refused
/// background clipboard reads outright since Android 10 — only the
/// foreground app may read it. A short `Timer.periodic` while a VaultLink
/// session is switched on is therefore not a workaround, it is the only
/// shape this can take, which is also why the session is opt-in and visible
/// on screen rather than started automatically at app launch.
///
/// Anything on the clipboard that isn't `VAULTLINK/1\n{...}` is left alone.
/// A person copying a phone number mid-session never sees it touched.

library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/vault_engine.dart';

const _prefix = 'VAULTLINK/1\n';

enum VaultLinkEventKind { info, request, success, failure }

class VaultLinkEvent {
  final DateTime at;
  final String message;
  final VaultLinkEventKind kind;

  VaultLinkEvent(this.message, this.kind) : at = DateTime.now();
}

class VaultLinkService extends ChangeNotifier {
  final VaultEngine engine;
  final Map<String, dynamic> Function() telemetrySnapshot;

  VaultLinkService({required this.engine, required this.telemetrySnapshot});

  Timer? _poll;
  bool _running = false;
  bool _busy = false;

  /// The most recent request id already handled (or currently being
  /// handled). A poll tick that sees this id again — which is exactly what
  /// happens on the tick right after this service writes its own reply — is
  /// dropped before it can be mistaken for a second incoming request.
  String? _lastRequestId;

  int _served = 0;
  final List<VaultLinkEvent> _log = [];

  bool get isRunning => _running;
  int get served => _served;
  List<VaultLinkEvent> get log => List.unmodifiable(_log);

  void _emit(String message, [VaultLinkEventKind kind = VaultLinkEventKind.info]) {
    _log.insert(0, VaultLinkEvent(message, kind));
    if (_log.length > 120) _log.removeLast();
    notifyListeners();
  }

  void start({Duration interval = const Duration(milliseconds: 700)}) {
    if (_running) return;
    _running = true;
    _emit('VaultLink session started — watching the clipboard');
    _poll = Timer.periodic(interval, (_) => _tick());
  }

  void stop() {
    if (!_running) return;
    _running = false;
    _poll?.cancel();
    _poll = null;
    _emit('VaultLink session stopped');
  }

  Future<void> _tick() async {
    if (_busy) return; // a generation is running; the next tick will see it
    ClipboardData? data;
    try {
      data = await Clipboard.getData(Clipboard.kTextPlain);
    } catch (_) {
      return; // transient platform-channel hiccup; try again next tick
    }
    final text = data?.text;
    if (text == null || !text.startsWith(_prefix)) return;

    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(text.substring(_prefix.length)) as Map<String, dynamic>;
    } catch (_) {
      return; // VAULTLINK-shaped but not valid JSON; not ours to touch
    }

    final id = msg['id'] as String?;
    final op = msg['op'] as String?;
    // Only a request carries `op`. Our own replies (`status` instead) are
    // read back by this same poll and dropped right here, harmlessly.
    if (id == null || op == null) return;
    if (id == _lastRequestId) return;

    _lastRequestId = id;
    _busy = true;
    _emit('Request $id: $op', VaultLinkEventKind.request);

    try {
      switch (op) {
        case 'ping':
          await _writeReply(id, {
            'ok': true,
            'status': 'complete',
            ...engine.describe(),
            'compute': telemetrySnapshot(),
          });
          _emit('Answered ping', VaultLinkEventKind.success);
        case 'query':
          await _handleQuery(id, msg);
        default:
          await _writeReply(id, {
            'ok': false,
            'status': 'complete',
            'error': 'Unsupported op: $op',
          });
          _emit('Unsupported op "$op"', VaultLinkEventKind.failure);
      }
    } catch (e) {
      await _writeReply(id, {'ok': false, 'status': 'complete', 'error': '$e'});
      _emit('Request $id failed: $e', VaultLinkEventKind.failure);
    } finally {
      _busy = false;
    }
  }

  Future<void> _handleQuery(String id, Map<String, dynamic> msg) async {
    final q = (msg['q'] as String?)?.trim() ?? '';
    final topK = (msg['k'] as num?)?.toInt() ?? 5;
    final generate = (msg['generate'] as bool?) ?? true;
    if (q.isEmpty) {
      await _writeReply(id, {'ok': false, 'status': 'complete', 'error': 'Empty query'});
      return;
    }

    // Generation can run to tens of seconds. Without this interim frame the
    // laptop side cannot tell "the phone has it and is thinking" from "the
    // phone never saw the request" — both look identical from outside.
    await _writeReply(id, {'status': 'processing'});

    final capsule = await engine.ask(q, topK: topK, generate: generate);
    _served++;
    await _writeReply(id, {
      'ok': true,
      'status': 'complete',
      ...capsule.toJson(),
      'compute': telemetrySnapshot(),
    });
    _emit(
      capsule.generation.ran
          ? 'Answered "$q" (${capsule.generation.elapsedMs ?? 0} ms generation)'
          : 'Answered "$q" (retrieval only — no model loaded)',
      VaultLinkEventKind.success,
    );
  }

  Future<void> _writeReply(String id, Map<String, dynamic> data) async {
    final payload = jsonEncode({'id': id, ...data});
    await Clipboard.setData(ClipboardData(text: '$_prefix$payload'));
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
