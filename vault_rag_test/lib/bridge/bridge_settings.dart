/// bridge_settings.dart
///
/// Remembers the last desktop address, and reports this phone's own LAN
/// address for diagnostics.
///
/// Stored as a small JSON file in the app's private documents directory
/// rather than pulling in shared_preferences. One setting does not justify a
/// plugin, and this project's build notes are largely a record of what
/// adding dependencies costs here.

library;

import 'dart:convert';
import 'dart:io';

class BridgeSettings {
  final String host;
  final int port;

  const BridgeSettings({required this.host, this.port = 8000});

  static const empty = BridgeSettings(host: '');

  static File _file(String documentsPath) =>
      File('$documentsPath/bridge_settings.json');

  static Future<BridgeSettings> load(String documentsPath) async {
    try {
      final f = _file(documentsPath);
      if (!await f.exists()) return empty;
      final map = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return BridgeSettings(
        host: (map['host'] as String?) ?? '',
        port: (map['port'] as num?)?.toInt() ?? 8000,
      );
    } catch (_) {
      // A corrupt settings file is not worth surfacing — the user just
      // re-types an IP address.
      return empty;
    }
  }

  Future<void> save(String documentsPath) async {
    try {
      await _file(documentsPath)
          .writeAsString(jsonEncode({'host': host, 'port': port}));
    } catch (_) {
      // Non-fatal: the link still works for this session.
    }
  }
}

/// This device's IPv4 address on the local network, or null when not on one.
///
/// Shown on the bridge screen purely as a debugging aid: when the link will
/// not come up, the first question is always whether the two machines are on
/// the same subnet, and this answers half of it without leaving the app.
Future<String?> localIpv4() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (!addr.isLoopback) return addr.address;
      }
    }
  } catch (_) {
    // Permission or platform issue — the field just stays blank.
  }
  return null;
}
