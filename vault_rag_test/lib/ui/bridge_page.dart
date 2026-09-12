/// bridge_page.dart
///
/// The co-processor link: point the phone at a laptop running
/// bridge_server.py, and the desktop can push documents into the vault and
/// query it from an IDE or an MCP client.
///
/// The screen is built around one honest admission, stated at the top
/// rather than buried: turning this on is the only thing in the app that
/// uses the network. Everything else works with the radios off, and the
/// previous build's headline was that it requested no permissions at all.
/// That changed to add exactly one — INTERNET — and a user who is here for
/// the air-gap claim deserves to read that on the screen that does it, not
/// in a manifest.

library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/bridge_client.dart';
import '../bridge/bridge_settings.dart';
import 'theme.dart';
import 'widgets/common.dart';

class BridgePage extends StatefulWidget {
  final BridgeClient client;
  final String documentsPath;

  const BridgePage({
    super.key,
    required this.client,
    required this.documentsPath,
  });

  @override
  State<BridgePage> createState() => _BridgePageState();
}

class _BridgePageState extends State<BridgePage> {
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '8000');
  String? _localIp;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final saved = await BridgeSettings.load(widget.documentsPath);
    final ip = await localIpv4();
    if (!mounted) return;
    setState(() {
      if (saved.host.isNotEmpty) _hostController.text = saved.host;
      _portController.text = '${saved.port}';
      _localIp = ip;
    });
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final host = _hostController.text.trim();
    if (host.isEmpty) return;
    final port = int.tryParse(_portController.text.trim()) ?? 8000;

    await BridgeSettings(host: host, port: port).save(widget.documentsPath);
    if (!mounted) return;
    // Dismiss the keyboard: the log below is the thing to watch next, and on
    // a phone it is entirely hidden behind the IME.
    FocusScope.of(context).unfocus();
    await widget.client.connect(host, port: port);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.client,
      builder: (context, _) {
        final c = widget.client;
        return ListView(
          padding: const EdgeInsets.fromLTRB(
            VaultSpace.lg,
            VaultSpace.md,
            VaultSpace.lg,
            VaultSpace.xxl,
          ),
          children: [
            _linkCard(c),
            const SizedBox(height: VaultSpace.md),
            if (c.isConnected) ...[
              _servedCard(c),
              const SizedBox(height: VaultSpace.md),
            ],
            _logCard(c),
            const SizedBox(height: VaultSpace.md),
            _howToCard(),
          ],
        );
      },
    );
  }

  Widget _linkCard(BridgeClient c) {
    final (label, color, pulsing) = switch (c.state) {
      BridgeState.connected => ('LINKED', VaultColors.accent, true),
      BridgeState.connecting => ('DIALLING', VaultColors.warn, true),
      BridgeState.error => ('ERROR', VaultColors.danger, false),
      BridgeState.offline => ('OFFLINE', VaultColors.faint, false),
    };

    return SectionCard(
      title: 'Desktop bridge',
      subtitle: c.isConnected
          ? c.endpoint
          : 'Enter the laptop’s LAN address. The phone dials out; nothing '
              'can reach the vault unless it does.',
      trailing: StatusPill(label: label, color: color, pulsing: pulsing),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _hostController,
                  enabled: !c.isConnected,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  style: VaultText.mono.copyWith(
                    color: VaultColors.foreground,
                    fontSize: 14,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Laptop IP',
                    hintText: '10.60.26.221',
                  ),
                ),
              ),
              const SizedBox(width: VaultSpace.sm),
              Expanded(
                child: TextField(
                  controller: _portController,
                  enabled: !c.isConnected,
                  keyboardType: TextInputType.number,
                  style: VaultText.mono.copyWith(
                    color: VaultColors.foreground,
                    fontSize: 14,
                  ),
                  decoration: const InputDecoration(labelText: 'Port'),
                ),
              ),
            ],
          ),
          const SizedBox(height: VaultSpace.md),
          if (c.isConnected)
            OutlinedButton.icon(
              onPressed: c.disconnect,
              icon: const Icon(Icons.link_off_rounded, size: 19),
              label: const Text('Disconnect'),
            )
          else
            FilledButton.icon(
              onPressed: c.state == BridgeState.connecting ? null : _connect,
              icon: const Icon(Icons.link_rounded, size: 19),
              label: Text(
                c.state == BridgeState.connecting ? 'Connecting…' : 'Connect',
              ),
            ),
          if (c.statusDetail != null) ...[
            const SizedBox(height: VaultSpace.md),
            Text(
              c.statusDetail!,
              style: TextStyle(
                color: c.state == BridgeState.error
                    ? VaultColors.danger
                    : VaultColors.faint,
                fontSize: 11.5,
                height: 1.45,
              ),
            ),
          ],
          if (_localIp != null) ...[
            const SizedBox(height: VaultSpace.sm),
            Text(
              'This phone is $_localIp — the laptop must be on the same subnet.',
              style: const TextStyle(
                color: VaultColors.faint,
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: VaultSpace.md),
          _networkNotice(),
        ],
      ),
    );
  }

  Widget _networkNotice() {
    return Container(
      padding: const EdgeInsets.all(VaultSpace.md),
      decoration: BoxDecoration(
        color: VaultColors.warn.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(VaultSpace.radiusSm),
        border: Border.all(color: VaultColors.warn.withValues(alpha: 0.3)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.wifi_tethering_rounded,
              size: 15, color: VaultColors.warn),
          SizedBox(width: VaultSpace.sm),
          Expanded(
            child: Text(
              'This is the only feature that opens a socket. Chunks retrieved '
              'over the bridge leave the device — that is the point of it — '
              'so the air-gap claim holds only while this stays disconnected.',
              style: TextStyle(
                color: VaultColors.muted,
                fontSize: 11,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _servedCard(BridgeClient c) {
    return SectionCard(
      title: 'Served',
      child: Row(
        children: [
          Expanded(
            child: MetricTile(
              label: 'QUERIES',
              value: '${c.servedQueries}',
              accent: VaultColors.info,
            ),
          ),
          const SizedBox(width: VaultSpace.sm),
          Expanded(
            child: MetricTile(
              label: 'DOCUMENTS',
              value: '${c.servedIndexes}',
              accent: VaultColors.accent,
            ),
          ),
        ],
      ),
    );
  }

  Widget _logCard(BridgeClient c) {
    return SectionCard(
      title: 'Activity',
      child: c.log.isEmpty
          ? const EmptyState(
              icon: Icons.terminal_rounded,
              title: 'No traffic yet',
              message: 'Requests from the desktop appear here as they arrive.',
            )
          : Column(
              children: [
                for (final e in c.log.take(40))
                  Padding(
                    padding: const EdgeInsets.only(bottom: VaultSpace.sm),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Icon(
                            switch (e.kind) {
                              BridgeEventKind.success =>
                                Icons.check_circle_outline,
                              BridgeEventKind.failure => Icons.error_outline,
                              BridgeEventKind.request =>
                                Icons.south_west_rounded,
                              BridgeEventKind.info => Icons.circle_outlined,
                            },
                            size: 13,
                            color: switch (e.kind) {
                              BridgeEventKind.success => VaultColors.accent,
                              BridgeEventKind.failure => VaultColors.danger,
                              BridgeEventKind.request => VaultColors.info,
                              BridgeEventKind.info => VaultColors.faint,
                            },
                          ),
                        ),
                        const SizedBox(width: VaultSpace.sm),
                        Expanded(
                          child: Text(
                            e.message,
                            style: const TextStyle(
                              color: VaultColors.muted,
                              fontSize: 11.5,
                              height: 1.45,
                            ),
                          ),
                        ),
                        const SizedBox(width: VaultSpace.sm),
                        Text(
                          _clock(e.at),
                          style: VaultText.mono.copyWith(
                            color: VaultColors.faint,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  static String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}';

  Widget _howToCard() {
    const snippet = 'pip install fastapi uvicorn websockets\n'
        'python bridge_server.py\n'
        '# then: python query.py "your question"';

    return SectionCard(
      title: 'On the laptop',
      subtitle: 'From the bridge/ directory of this repo.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const CodeBlock(snippet),
          const SizedBox(height: VaultSpace.md),
          OutlinedButton.icon(
            onPressed: () async {
              await Clipboard.setData(const ClipboardData(text: snippet));
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Commands copied')),
              );
            },
            icon: const Icon(Icons.copy_rounded, size: 17),
            label: const Text('Copy commands'),
          ),
        ],
      ),
    );
  }
}
