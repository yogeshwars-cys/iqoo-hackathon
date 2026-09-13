/// link_page.dart
///
/// VaultLink: one switch. When it's on, the phone watches its own clipboard
/// for a VAULTLINK request, runs it, and writes the answer back — carried
/// across devices by Office Kit's clipboard mirror, not by this app.
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
          VaultSpace.sm,
          VaultSpace.lg,
          VaultSpace.xxl,
        ),
        children: [
          _sessionCard(context),
          const SizedBox(height: VaultSpace.lg),
          _PairingCard(link: link),
          const SizedBox(height: VaultSpace.lg),
          _logCard(context),
          const SizedBox(height: VaultSpace.lg),
          _howItWorksCard(),
        ],
      ),
    );
  }

  Widget _sessionCard(BuildContext context) {
    return SectionCard(
      icon: Icons.content_paste_rounded,
      title: 'VaultLink session',
      subtitle: 'Clipboard transport · no socket',
      trailing: StatusPill(
        label: link.isRunning ? 'Watching' : 'Off',
        color: link.isRunning ? VaultColors.accent : VaultColors.faint,
        pulsing: link.isRunning,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: MetricTile(
                  label: 'Served',
                  value: '${link.served}',
                  accent: link.served > 0 ? VaultColors.info : null,
                ),
              ),
              const SizedBox(width: VaultSpace.sm),
              Expanded(
                child: MetricTile(
                  label: 'Protocol',
                  value: link.allowInsecureV1 ? 'v1 + v2' : 'v2',
                  accent: link.allowInsecureV1
                      ? VaultColors.warn
                      : VaultColors.accent,
                  footnote: link.allowInsecureV1 ? 'legacy allowed' : 'sealed only',
                ),
              ),
            ],
          ),
          const SizedBox(height: VaultSpace.lg),
          if (link.isRunning)
            OutlinedButton.icon(
              onPressed: link.stop,
              icon: const Icon(Icons.stop_rounded, size: 18),
              label: const Text('Stop session'),
            )
          else
            FilledButton.icon(
              onPressed: link.start,
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: const Text('Start session'),
            ),
          const SizedBox(height: VaultSpace.md),
          const Notice(
            tone: NoticeTone.neutral,
            icon: Icons.phone_android_rounded,
            message: 'Keep this screen open. Android only lets the foreground '
                'app read the clipboard, which is exactly the protection a '
                'background clipboard reader would defeat.',
          ),
        ],
      ),
    );
  }

  Widget _logCard(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SectionCard(
      icon: Icons.receipt_long_outlined,
      title: 'Activity',
      trailing: link.log.isEmpty ? null : VaultTag('${link.log.length}'),
      child: link.log.isEmpty
          ? const EmptyState(
              icon: Icons.terminal_rounded,
              title: 'No requests yet',
              message: 'Start a session, then run vaultlink.py ask "…" on '
                  'the laptop.',
            )
          : Column(
              children: [
                for (final e in link.log.take(40))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Icon(
                            switch (e.kind) {
                              VaultLinkEventKind.success =>
                                Icons.check_circle_outline_rounded,
                              VaultLinkEventKind.failure =>
                                Icons.error_outline_rounded,
                              VaultLinkEventKind.request =>
                                Icons.south_west_rounded,
                              VaultLinkEventKind.info => Icons.circle_outlined,
                            },
                            size: 18,
                            color: switch (e.kind) {
                              VaultLinkEventKind.success => VaultColors.accent,
                              VaultLinkEventKind.failure => VaultColors.danger,
                              VaultLinkEventKind.request => VaultColors.info,
                              VaultLinkEventKind.info => VaultColors.faint,
                            },
                          ),
                        ),
                        const SizedBox(width: VaultSpace.md),
                        Expanded(
                          child: Text(e.message,
                              style: text.bodyMedium!
                                  .copyWith(color: VaultColors.muted)),
                        ),
                        const SizedBox(width: VaultSpace.sm),
                        Text(
                          _clock(e.at),
                          style: VaultText.mono.copyWith(
                            color: VaultColors.faint,
                            fontSize: 12,
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
    const snippet = 'python vaultlink.py pair XXXXX-XXXXX-XXXXX-XXXXX\n'
        'python vaultlink.py enroll\n'
        'python vaultlink.py ask "your question"';

    return const SectionCard(
      icon: Icons.laptop_rounded,
      title: 'On the laptop',
      subtitle: 'From bridge/testdata/ in this repo',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CodeBlock(snippet),
          SizedBox(height: VaultSpace.md),
          _Step('pair', 'stores the key under Windows DPAPI'),
          _Step('enroll', 'pins this phone\'s signing key'),
          _Step('ask', 'verifies every capsule against that key and scrubs '
              'the clipboard after 20 s'),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final String command;
  final String detail;
  const _Step(this.command, this.detail);

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: VaultSpace.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(command,
                style: VaultText.mono.copyWith(
                    color: VaultColors.accent, fontSize: 13, height: 20 / 13)),
          ),
          Expanded(
            child: Text(detail,
                style: text.bodyMedium!.copyWith(color: VaultColors.muted)),
          ),
        ],
      ),
    );
  }
}

/// Pairing code, key id and the legacy-mode switch.
///
/// The code is hidden until tapped: it is the one secret VaultLink's
/// security rests on, and it should not sit on screen for anyone nearby.
class _PairingCard extends StatefulWidget {
  final VaultLinkService link;
  const _PairingCard({required this.link});

  @override
  State<_PairingCard> createState() => _PairingCardState();
}

class _PairingCardState extends State<_PairingCard> {
  bool _revealed = false;
  bool _working = false;

  Future<void> _pair() async {
    if (widget.link.isPaired) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.key_rounded),
          title: const Text('Replace the pairing?'),
          content: const Text(
            'The laptop paired now will stop working until it is paired '
            'again with the new code.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _working = true);
    try {
      await widget.link.pair();
      if (mounted) setState(() => _revealed = true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final link = widget.link;
    final code = link.pairingCode;

    return SectionCard(
      icon: Icons.key_rounded,
      title: 'Pairing',
      subtitle: link.isPaired
          ? 'VAULTLINK/2 · AES-256-GCM'
          : 'Sealed requests are ignored until paired',
      trailing: StatusPill(
        label: link.isPaired ? 'Paired' : 'Unpaired',
        color: link.isPaired ? VaultColors.accent : VaultColors.warn,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (code != null) ...[
            Semantics(
              button: true,
              label: _revealed ? 'Pairing code $code' : 'Reveal pairing code',
              child: Material(
                color: VaultColors.surfaceHigh,
                borderRadius: BorderRadius.circular(VaultSpace.radiusMd),
                child: InkWell(
                  onTap: () => setState(() => _revealed = !_revealed),
                  borderRadius: BorderRadius.circular(VaultSpace.radiusMd),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 72),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(
                        horizontal: VaultSpace.md, vertical: VaultSpace.lg),
                    child: _revealed
                        ? Column(
                            children: [
                              SelectableText(
                                code,
                                textAlign: TextAlign.center,
                                style: VaultText.mono.copyWith(
                                  color: VaultColors.foreground,
                                  fontSize: 20,
                                  letterSpacing: 1.5,
                                ),
                              ),
                              const SizedBox(height: VaultSpace.xs),
                              Text('Tap to hide', style: text.bodySmall),
                            ],
                          )
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.visibility_outlined,
                                  size: 20, color: VaultColors.muted),
                              const SizedBox(width: VaultSpace.sm),
                              Text('Tap to show the pairing code',
                                  style: text.labelLarge!
                                      .copyWith(color: VaultColors.muted)),
                            ],
                          ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: VaultSpace.md),
            if (link.keyId != null)
              InfoRow('Key id', '${link.keyId}', mono: true),
            const SizedBox(height: VaultSpace.xs),
            const Notice(
              tone: NoticeTone.info,
              icon: Icons.keyboard_rounded,
              message: 'Type the code into the laptop, never paste it: it '
                  'must not travel over the clipboard it protects.',
            ),
            const SizedBox(height: VaultSpace.lg),
          ],
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _working ? null : _pair,
                  icon: const Icon(Icons.key_rounded, size: 18),
                  label: Text(link.isPaired ? 'New code' : 'Pair a laptop'),
                ),
              ),
              if (link.isPaired) ...[
                const SizedBox(width: VaultSpace.sm),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _working ? null : link.unpair,
                    icon: const Icon(Icons.link_off_rounded, size: 18),
                    label: const Text('Unpair'),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: VaultSpace.md),
          const Divider(),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: link.allowInsecureV1,
            onChanged: (v) => link.allowInsecureV1 = v,
            title: const Text('Allow legacy VAULTLINK/1'),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'Unauthenticated and unencrypted: any app that can write the '
                'clipboard could query the vault. For older laptop scripts only.',
                style: text.bodySmall!.copyWith(
                  color: link.allowInsecureV1
                      ? VaultColors.warn
                      : VaultColors.muted,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
