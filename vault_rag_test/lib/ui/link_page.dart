/// link_page.dart
///
/// VaultLink: one switch. When it's on, the phone watches its own clipboard
/// for a `VAULTLINK/1` request, runs it, and writes the answer back —
/// carried across devices by Office Kit's clipboard mirror, not by this app.
///
/// No IP field on this screen, unlike Bridge — there is nothing to dial.
/// That absence is the point: this path opens no socket at all.

library;

import 'package:flutter/material.dart';

import '../link/vault_link_service.dart';
import 'theme.dart';
import 'widgets/common.dart';

class LinkPage extends StatelessWidget {
  final VaultLinkService link;

  const LinkPage({super.key, required this.link});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: link,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(
          VaultSpace.lg,
          VaultSpace.md,
          VaultSpace.lg,
          VaultSpace.xxl,
        ),
        children: [
          _sessionCard(context),
          const SizedBox(height: VaultSpace.md),
          if (link.served > 0) ...[
            _servedCard(),
            const SizedBox(height: VaultSpace.md),
          ],
          _logCard(),
          const SizedBox(height: VaultSpace.md),
          _howItWorksCard(),
        ],
      ),
    );
  }

  Widget _sessionCard(BuildContext context) {
    return SectionCard(
      title: 'VaultLink session',
      subtitle: 'Query and answer travel over the clipboard, mirrored by '
          'Office Kit. No socket, no address to type in.',
      trailing: StatusPill(
        label: link.isRunning ? 'WATCHING' : 'OFF',
        color: link.isRunning ? VaultColors.accent : VaultColors.faint,
        pulsing: link.isRunning,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (link.isRunning)
            OutlinedButton.icon(
              onPressed: link.stop,
              icon: const Icon(Icons.pause_circle_outline_rounded, size: 19),
              label: const Text('Stop session'),
            )
          else
            FilledButton.icon(
              onPressed: link.start,
              icon: const Icon(Icons.play_circle_outline_rounded, size: 19),
              label: const Text('Start session'),
            ),
          const SizedBox(height: VaultSpace.md),
          _foregroundNotice(),
        ],
      ),
    );
  }

  Widget _foregroundNotice() {
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
          Icon(Icons.info_outline_rounded, size: 15, color: VaultColors.warn),
          SizedBox(width: VaultSpace.sm),
          Expanded(
            child: Text(
              'Android only lets the foreground app read the clipboard, so '
              'this screen has to stay open (screen on) for the session to '
              'see anything. That is deliberate, not a bug to route around — '
              'an app that could read your clipboard from the background is '
              'exactly the thing this restriction exists to stop.',
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

  Widget _servedCard() {
    return SectionCard(
      title: 'Served',
      child: MetricTile(
        label: 'QUERIES',
        value: '${link.served}',
        accent: VaultColors.info,
      ),
    );
  }

  Widget _logCard() {
    return SectionCard(
      title: 'Activity',
      child: link.log.isEmpty
          ? const EmptyState(
              icon: Icons.terminal_rounded,
              title: 'No requests yet',
              message: 'Start a session, then send a query from the laptop '
                  '(vaultlink.py ask "...") and it appears here.',
            )
          : Column(
              children: [
                for (final e in link.log.take(40))
                  Padding(
                    padding: const EdgeInsets.only(bottom: VaultSpace.sm),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Icon(
                            switch (e.kind) {
                              VaultLinkEventKind.success =>
                                Icons.check_circle_outline,
                              VaultLinkEventKind.failure =>
                                Icons.error_outline,
                              VaultLinkEventKind.request =>
                                Icons.south_west_rounded,
                              VaultLinkEventKind.info => Icons.circle_outlined,
                            },
                            size: 13,
                            color: switch (e.kind) {
                              VaultLinkEventKind.success => VaultColors.accent,
                              VaultLinkEventKind.failure => VaultColors.danger,
                              VaultLinkEventKind.request => VaultColors.info,
                              VaultLinkEventKind.info => VaultColors.faint,
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

  Widget _howItWorksCard() {
    const snippet = 'python vaultlink.py ping\n'
        'python vaultlink.py ask "your question"';

    return SectionCard(
      title: 'On the laptop',
      subtitle: 'From bridge/testdata/ in this repo. No bridge_server.py, '
          'no IP address, no adb.',
      child: CodeBlock(snippet),
    );
  }
}
