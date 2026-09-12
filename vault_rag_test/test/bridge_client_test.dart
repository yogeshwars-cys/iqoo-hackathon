/// Tests for the outbound bridge link.
///
/// These run against a real loopback WebSocket server rather than a mock.
/// The behaviour under test is entirely about *timing* — what happens when
/// the user acts while a handshake is in flight — and a mock that resolves
/// instantly cannot express the window where the bug lives.

library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_rag_test/bridge/bridge_client.dart';
import 'package:vault_rag_test/core/vault_engine.dart';

/// Counts what actually reached the desktop end of the link.
class _ServerTally {
  int upgraded = 0;
  int closed = 0;

  /// Sockets the phone opened and never closed. This is the number that
  /// matters: a live socket the client has lost its handle to is one the
  /// user cannot disconnect.
  int get leaked => upgraded - closed;
}

/// A server that takes its time completing the upgrade, standing in for a
/// laptop that is slow to answer — which on real Wi-Fi is the normal case,
/// not the exotic one. [BridgeClient] allows eight seconds for it.
Future<HttpServer> _slowServer(Duration delay, [_ServerTally? tally]) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(server.forEach((request) async {
    await Future<void>.delayed(delay);
    try {
      final socket = await WebSocketTransformer.upgrade(request);
      tally?.upgraded++;
      // Drain it, otherwise a close frame from the phone is never processed
      // and every socket looks permanently open.
      socket.listen(
        (_) {},
        onDone: () => tally?.closed++,
        onError: (_) => tally?.closed++,
      );
    } catch (_) {
      // The client gave up first; nothing to do.
    }
  }));
  return server;
}

void main() {
  group('BridgeClient disconnect during the dial', () {
    test('a link closed by the user does not come up behind them', () async {
      final server = await _slowServer(const Duration(milliseconds: 400));
      final engine = VaultEngine();
      final client = BridgeClient(engine: engine, telemetrySnapshot: () => {});

      // Deliberately not awaited: this is the in-flight handshake.
      final dialing = client.connect('127.0.0.1', port: server.port);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(client.state, BridgeState.connecting);

      await client.disconnect();
      await dialing;

      // Long enough for the server's upgrade to land.
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // Before the fix the socket arrived after disconnect() had already
      // run its teardown against a null socket, and was adopted: the app
      // showed LOCAL while the desktop stayed linked and could go on
      // querying the vault.
      expect(client.isConnected, isFalse);
      expect(client.state, BridgeState.offline);

      client.dispose();
      engine.dispose();
      await server.close(force: true);
    });

    test('disposing mid-dial does not notify a disposed notifier', () async {
      final server = await _slowServer(const Duration(milliseconds: 400));
      final engine = VaultEngine();
      final client = BridgeClient(engine: engine, telemetrySnapshot: () => {});

      final dialing = client.connect('127.0.0.1', port: server.port);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      client.dispose();
      await dialing;

      // As with the telemetry test, the assertion is the absence of an
      // uncaught async error from ChangeNotifier.
      await Future<void>.delayed(const Duration(milliseconds: 500));

      engine.dispose();
      await server.close(force: true);
    });

    test('an ordinary connect still succeeds', () async {
      // Guards against "fixing" the above by never connecting at all.
      final server = await _slowServer(Duration.zero);
      final engine = VaultEngine();
      final client = BridgeClient(engine: engine, telemetrySnapshot: () => {});

      await client.connect('127.0.0.1', port: server.port);
      expect(client.isConnected, isTrue);
      expect(client.state, BridgeState.connected);

      await client.disconnect();
      expect(client.isConnected, isFalse);

      client.dispose();
      engine.dispose();
      await server.close(force: true);
    });
  });

  group('BridgeClient overlapping dials', () {
    test('a second dial does not orphan the first socket', () async {
      // Two taps of Connect. The button is only disabled once the state
      // turns `connecting`, and _connect() awaits a settings file write
      // before it gets that far, so the second tap lands inside the gap and
      // starts a second dial.
      final tally = _ServerTally();
      final server = await _slowServer(const Duration(milliseconds: 250), tally);
      final engine = VaultEngine();
      final client = BridgeClient(engine: engine, telemetrySnapshot: () => {});

      await Future.wait([
        client.connect('127.0.0.1', port: server.port),
        client.connect('127.0.0.1', port: server.port),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // Both TCP dials were already in flight, so the server sees two — the
      // question is whether the client keeps both. Before the fix the loser
      // overwrote `_socket` and `_subscription`, leaving a fully live socket
      // that was still serving the desktop's search/ask/index requests and
      // that nothing held a handle to.
      expect(tally.leaked, 1, reason: 'exactly one link should survive');
      expect(client.isConnected, isTrue);

      await client.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 400));

      // And the survivor goes down when the user says so.
      expect(tally.leaked, 0, reason: 'disconnect must close every socket');

      client.dispose();
      engine.dispose();
      await server.close(force: true);
    });
  });

  group('BridgeClient reconnect backoff', () {
    test('the backoff table is indexed in range however many attempts run',
        () async {
      // _scheduleReconnect indexes a six-entry table with a clamped attempt
      // counter. Nothing resets that counter on a link that never comes up,
      // so it keeps climbing; a RangeError here would kill the reconnect
      // loop permanently on the seventh try.
      final engine = VaultEngine();
      final client = BridgeClient(engine: engine, telemetrySnapshot: () => {});

      // Port 1 on loopback refuses immediately, so each attempt fails fast.
      await client.connect('127.0.0.1', port: 1);
      expect(client.state, BridgeState.error);
      expect(client.statusDetail, contains('retrying in 1s'));

      await client.disconnect();
      client.dispose();
      engine.dispose();
    });
  });
}
