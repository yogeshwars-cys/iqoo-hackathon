/// system_screens.dart
///
/// Full-screen states outside the tab content: cold boot, encoder failure,
/// and the air-gapped build's stand-in for the Bridge tab. Public so the
/// screenshot harness renders the same widgets the app does.

library;

import 'package:flutter/material.dart';

import 'theme.dart';
import 'widgets/common.dart';

/// Shown in place of the Bridge tab in the air-gapped build.
class AirGapPage extends StatelessWidget {
  /// Jumps to the Link tab; null hides the button.
  final VoidCallback? onOpenLink;

  const AirGapPage({super.key, this.onOpenLink});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
          VaultSpace.lg, VaultSpace.sm, VaultSpace.lg, VaultSpace.xxl),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                VaultSpace.xl, VaultSpace.xxl, VaultSpace.xl, VaultSpace.xl),
            child: Column(
              children: [
                const IconBadge(
                  icon: Icons.wifi_off_rounded,
                  size: 64,
                ),
                const SizedBox(height: VaultSpace.lg),
                Semantics(
                  header: true,
                  child: Text('Air-gapped build',
                      textAlign: TextAlign.center, style: text.headlineSmall),
                ),
                const SizedBox(height: VaultSpace.sm),
                Text(
                  'This APK requests no network permission, so the LAN '
                  'bridge is not available. Nothing in the app can open a '
                  'socket.',
                  textAlign: TextAlign.center,
                  style: text.bodyMedium!.copyWith(color: VaultColors.muted),
                ),
                if (onOpenLink != null) ...[
                  const SizedBox(height: VaultSpace.xl),
                  FilledButton.icon(
                    onPressed: onOpenLink,
                    icon: const Icon(Icons.content_paste_rounded, size: 18),
                    label: const Text('Use VaultLink instead'),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: VaultSpace.lg),
        const SectionCard(
          icon: Icons.checklist_rounded,
          title: 'What still works offline',
          child: Column(
            children: [
              _Check('Ingest, encrypt and search documents'),
              _Check('On-device reasoning with the loaded model'),
              _Check('Signed capsules over the clipboard (VaultLink)'),
              _Check('Telemetry and benchmarks'),
            ],
          ),
        ),
        const SizedBox(height: VaultSpace.lg),
        const SectionCard(
          icon: Icons.lan_outlined,
          title: 'Need the WebSocket bridge?',
          subtitle: 'Build the lan flavor, which adds INTERNET',
          child: CodeBlock('flutter build apk --release --flavor lan'),
        ),
      ],
    );
  }
}

class _Check extends StatelessWidget {
  final String label;
  const _Check(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.check_circle_rounded,
              size: 20, color: VaultColors.accent),
          const SizedBox(width: VaultSpace.md),
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}

/// Model load takes about half a second and is the only unavoidable wait.
/// It says what it is doing, because a blank screen with a spinner on a
/// cold start reads as a hang.
class BootScreen extends StatelessWidget {
  const BootScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const IconBadge(icon: Icons.lock_rounded, size: 64),
            const SizedBox(height: VaultSpace.xl),
            Text('Vault', style: text.headlineSmall),
            const SizedBox(height: VaultSpace.lg),
            const SizedBox(
              width: 160,
              child: LinearProgressIndicator(),
            ),
            const SizedBox(height: VaultSpace.lg),
            Text('Loading the encoder', style: text.titleSmall),
            const SizedBox(height: VaultSpace.xs),
            Text('Selecting the fastest available delegate',
                style: text.bodyMedium!.copyWith(color: VaultColors.muted)),
          ],
        ),
      ),
    );
  }
}

class FailureScreen extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const FailureScreen({super.key, required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(VaultSpace.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(
                  child: IconBadge(
                    icon: Icons.error_outline_rounded,
                    size: 64,
                    background: VaultColors.dangerContainer,
                    color: VaultColors.onDangerContainer,
                  ),
                ),
                const SizedBox(height: VaultSpace.xl),
                Text('The encoder did not load',
                    textAlign: TextAlign.center, style: text.headlineSmall),
                const SizedBox(height: VaultSpace.sm),
                Text(
                  'Retrieval needs it, so the vault cannot open. The error '
                  'below is verbatim.',
                  textAlign: TextAlign.center,
                  style: text.bodyMedium!.copyWith(color: VaultColors.muted),
                ),
                const SizedBox(height: VaultSpace.lg),
                // The full error, verbatim. Every realistic cause here is a
                // build or export problem (missing asset, wrong input dtype,
                // no working delegate) and the exact text is what identifies
                // which — a friendly paraphrase would throw that away.
                CodeBlock(message),
                const SizedBox(height: VaultSpace.xl),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
