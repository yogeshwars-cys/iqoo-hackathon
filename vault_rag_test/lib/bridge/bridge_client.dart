/// bridge_client.dart
///
/// The phone half of the iQOO co-processor link.
///
/// The desktop runs bridge_server.py; this connects *out* to it over the
/// LAN and then serves requests. That direction is deliberate and worth
/// understanding, because the intuitive design is the opposite one:
///
///   * A phone cannot reliably accept inbound connections. Android kills
///     background sockets, the IP changes with every DHCP lease, and most
///     office/hotel Wi-Fi has client isolation that blocks peer-to-peer
///     traffic outright. A laptop on the same network is a stable listener;
///     a phone is not.
///   * Connecting out means the phone is the only side that has to be
///     told an address, and the laptop needs no firewall exception for
///     inbound mobile traffic.
///   * It keeps the trust story straight: nothing can reach the vault
///     unless the phone chose to dial out first. There is no listening port
///     on the device to find.
///
/// WIRE PROTOCOL (matches bridge_server.py exactly):
///
///   desktop -> phone   {"id": "q_…", "action": "search"|"ask"|"index",
///                       "data": {…}}
///   phone -> desktop   {"id": "q_…", "action": "result", "data": {…}}
///   phone -> desktop   {"action": "telemetry", "data": {…}}   (unsolicited)
///
/// The server checks `action == "telemetry"` *before* it looks at `id`, so a
/// reply must never use that action name — hence "result". Getting this
/// wrong is silent: the reply is swallowed as a telemetry frame and the
/// desktop just times out.
///
/// Uses dart:io's built-in [WebSocket] rather than package:web_socket_channel.
/// This app is Android-only, dart:io covers it completely, and the previous
/// build's notes are emphatic about what adding a dependency costs here.

library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/vault_engine.dart';

enum BridgeState { offline, connecting, connected, error }

/// One line in the on-screen activity log.
class BridgeEvent {
  final DateTime at;
  final String message;
  final BridgeEventKind kind;

  BridgeEvent(this.message, this.kind) : at = DateTime.now();
}

enum BridgeEventKind { info, request, success, failure }

class BridgeClient extends ChangeNotifier {
  final VaultEngine engine;

  /// Snapshot of live compute telemetry, injected rather than imported so
  /// the bridge does not depend on the stats screen being built.
  final Map<String, dynamic> Function() telemetrySnapshot;

  BridgeClient({required this.engine, required this.telemetrySnapshot});

  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _telemetryTimer;
  Timer? _reconnectTimer;

  BridgeState _state = BridgeState.offline;
  String? _statusDetail;
  String _host = '';
  int _port = 8000;

  /// Set when the user explicitly disconnects, so the reconnect loop knows
  /// the difference between "the link dropped" and "we were told to stop".
  bool _stopRequested = false;

  int _reconnectAttempt = 0;
  int _servedQueries = 0;
  int _servedIndexes = 0;

  final List<BridgeEvent> _log = [];

  BridgeState get state => _state;
  String? get statusDetail => _statusDetail;
  String get host => _host;
  int get port => _port;
  bool get isConnected => _state == BridgeState.connected;
  int get servedQueries => _servedQueries;
  int get servedIndexes => _servedIndexes;

  /// Newest first, capped — this renders in a scroll view on a phone and
  /// nobody scrolls back 500 entries.
  List<BridgeEvent> get log => List.unmodifiable(_log);

  String get endpoint => 'ws://$_host:$_port/ws/phone';

  void _emit(String message, [BridgeEventKind kind = BridgeEventKind.info]) {
    _log.insert(0, BridgeEvent(message, kind));
    if (_log.length > 120) _log.removeLast();
  }

  Future<void> connect(String host, {int port = 8000}) async {
    _host = host.trim();
    _port = port;
    _stopRequested = false;
    _reconnectAttempt = 0;
    await _openSocket();
  }

  Future<void> _openSocket() async {
    if (_stopRequested || _host.isEmpty) return;

    _reconnectTimer?.cancel();
    await _teardownSocket();

    _state = BridgeState.connecting;
    _statusDetail = 'Dialling $endpoint';
    notifyListeners();

    try {
      final socket = await WebSocket.connect(endpoint)
          .timeout(const Duration(seconds: 8));
      _socket = socket;
      // Without a ping interval a link that dies silently (phone sleeps,
      // laptop suspends, AP drops the session) looks connected forever.
      socket.pingInterval = const Duration(seconds: 15);

      _state = BridgeState.connected;
      _statusDetail = 'Linked to $_host:$_port';
      _reconnectAttempt = 0;
      _emit('Link established to $_host:$_port', BridgeEventKind.success);
      notifyListeners();

      _subscription = socket.listen(
        _onMessage,
        onDone: () => _onClosed('Desktop closed the link'),
        onError: (Object e) => _onClosed('Socket error: $e'),
        cancelOnError: true,
      );

      await _sendTelemetry();
      _telemetryTimer?.cancel();
      _telemetryTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _sendTelemetry(),
      );
    } catch (e) {
      _state = BridgeState.error;
      _statusDetail = _explain(e);
      _emit('Connect failed: ${_explain(e)}', BridgeEventKind.failure);
      notifyListeners();
      _scheduleReconnect();
    }
  }

  /// Turns the usual socket exceptions into something a person can act on.
  /// "SocketException: OS Error: Connection refused, errno = 111" is not a
  /// useful thing to show someone standing next to a working laptop.
  String _explain(Object e) {
    final s = e.toString();
    if (e is TimeoutException) {
      return 'Timed out. Check the phone and laptop are on the same Wi-Fi, '
          'and that the network is not using client isolation.';
    }
    if (s.contains('Connection refused')) {
      return 'Connection refused — bridge_server.py is not listening on '
          '$_host:$_port.';
    }
    if (s.contains('Network is unreachable') || s.contains('No route')) {
      return 'No route to $_host. Wrong IP, or a different network.';
    }
    if (s.contains('Failed host lookup')) {
      return 'Cannot resolve "$_host". Use the laptop IP address.';
    }
    return s;
  }

  void _onClosed(String why) {
    if (_stopRequested) return;
    _state = BridgeState.offline;
    _statusDetail = why;
    _emit(why, BridgeEventKind.failure);
    notifyListeners();
    _scheduleReconnect();
  }

  /// Exponential backoff, capped at 15 s.
  ///
  /// The demo case is a laptop that has not started the server yet, so the
  /// first few retries are fast; the sustained case is a phone in a pocket,
  /// where hammering a dead address is just battery.
  void _scheduleReconnect() {
    if (_stopRequested) return;
    _reconnectTimer?.cancel();
    _reconnectAttempt++;
    final seconds = [1, 2, 3, 5, 8, 15][
        _reconnectAttempt.clamp(1, 6) - 1];
    _statusDetail =
        '${_statusDetail ?? 'Disconnected'} · retrying in ${seconds}s';
    notifyListeners();
    _reconnectTimer = Timer(Duration(seconds: seconds), _openSocket);
  }

  Future<void> disconnect() async {
    _stopRequested = true;
    _reconnectTimer?.cancel();
    await _teardownSocket();
    _state = BridgeState.offline;
    _statusDetail = 'Disconnected';
    _emit('Link closed by user');
    notifyListeners();
  }

  Future<void> _teardownSocket() async {
    _telemetryTimer?.cancel();
    _telemetryTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _socket?.close();
    } catch (_) {
      // Already gone.
    }
    _socket = null;
  }

  Future<void> _send(Map<String, dynamic> message) async {
    final socket = _socket;
    if (socket == null || socket.readyState != WebSocket.open) return;
    try {
      socket.add(jsonEncode(message));
    } catch (e) {
      _onClosed('Send failed: $e');
    }
  }

  Future<void> _sendTelemetry() async {
    if (!isConnected) return;
    await _send({
      'action': 'telemetry',
      'data': {
        ...engine.describe(),
        'compute': telemetrySnapshot(),
        'served_queries': _servedQueries,
        'served_indexes': _servedIndexes,
        'link': {'host': _host, 'port': _port},
      },
    });
  }

  Future<void> _onMessage(dynamic raw) async {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (e) {
      _emit('Dropped unparseable frame: $e', BridgeEventKind.failure);
      return;
    }

    final id = msg['id'] as String?;
    final action = msg['action'] as String?;
    final data = (msg['data'] as Map?)?.cast<String, dynamic>() ?? const {};

    try {
      switch (action) {
        case 'search':
          await _handleSearch(id, data);
        case 'ask':
          await _handleAsk(id, data);
        case 'index':
          await _handleIndex(id, data);
        case 'ping':
          await _reply(id, {'pong': true, 'compute': telemetrySnapshot()});
        case 'telemetry':
          await _sendTelemetry();
        default:
          _emit('Unknown action "$action"', BridgeEventKind.failure);
          await _reply(id, {'error': 'Unsupported action: $action'});
      }
    } catch (e) {
      _emit('$action failed: $e', BridgeEventKind.failure);
      // Always answer. An unanswered id leaves the desktop's Future pending
      // until its timeout, which reads to the user as the phone hanging.
      await _reply(id, {'error': e.toString()});
    }
    notifyListeners();
  }

  Future<void> _reply(String? id, Map<String, dynamic> data) async {
    if (id == null) return;
    await _send({'id': id, 'action': 'result', 'data': data});
  }

  Future<void> _handleSearch(String? id, Map<String, dynamic> data) async {
    final query = (data['query'] as String?)?.trim() ?? '';
    final topK = (data['top_k'] as num?)?.toInt() ?? 3;
    if (query.isEmpty) {
      await _reply(id, {'error': 'Empty query'});
      return;
    }

    _emit('Query: "$query"', BridgeEventKind.request);
    notifyListeners();

    final result = await engine.search(query, topK: topK);
    _servedQueries++;
    _emit(
      'Answered in ${result.latencyMs} ms over ${result.totalIndexed} chunks',
      BridgeEventKind.success,
    );
    await _reply(id, {
      ...result.toBridgeJson(),
      'compute': telemetrySnapshot(),
    });
  }

  /// Retrieval plus a generated context capsule.
  ///
  /// Kept separate from `search` rather than added as a flag: generation
  /// takes seconds where retrieval takes a quarter of one, and the desktop
  /// needs a far longer timeout for it. Folding both into one action would
  /// mean either a fast path with a slow timeout or the reverse.
  Future<void> _handleAsk(String? id, Map<String, dynamic> data) async {
    final query = (data['query'] as String?)?.trim() ?? '';
    final topK = (data['top_k'] as num?)?.toInt() ?? 5;
    final generate = (data['generate'] as bool?) ?? true;
    if (query.isEmpty) {
      await _reply(id, {'error': 'Empty query'});
      return;
    }

    _emit('Capsule: "$query"', BridgeEventKind.request);
    notifyListeners();

    final capsule = await engine.ask(query, topK: topK, generate: generate);
    _servedQueries++;

    final generation = capsule.generation;
    _emit(
      generation.ran
          ? 'Capsule generated in ${generation.elapsedMs ?? 0} ms '
              '(${generation.backend ?? '?'})'
          : 'Capsule from retrieval only — no model loaded',
      generation.parseError == null
          ? BridgeEventKind.success
          : BridgeEventKind.failure,
    );

    await _reply(id, {
      ...capsule.toJson(),
      'compute': telemetrySnapshot(),
    });
  }

  Future<void> _handleIndex(String? id, Map<String, dynamic> data) async {
    final fileName = (data['filename'] as String?) ?? 'pushed.txt';
    final content = (data['content'] as String?) ?? '';
    if (content.trim().isEmpty) {
      await _reply(id, {'error': 'Empty content'});
      return;
    }

    _emit('Indexing $fileName (${content.length} bytes)',
        BridgeEventKind.request);
    notifyListeners();

    final result = await engine.indexDocument(fileName, content);
    _servedIndexes++;
    _emit(
      'Indexed $fileName: +${result.chunksAdded} chunks in '
      '${result.elapsedMs} ms',
      BridgeEventKind.success,
    );
    await _reply(id, {
      ...result.toJson(),
      'compute': telemetrySnapshot(),
    });
  }

  @override
  void dispose() {
    _stopRequested = true;
    _reconnectTimer?.cancel();
    _teardownSocket();
    super.dispose();
  }
}
