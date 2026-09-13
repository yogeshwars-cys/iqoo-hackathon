/// app_chrome.dart
///
/// The app bar, link-state pill and bottom navigation shared by every tab.
/// Extracted from main.dart so the running app and the screenshot harness
/// (test/screenshots/) render exactly the same chrome.

library;

import 'package:flutter/material.dart';

import 'theme.dart';
import 'widgets/common.dart';

class VaultDestination {
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  const VaultDestination(this.label, this.icon, this.selectedIcon);
}

const vaultDestinations = [
  VaultDestination('Vault', Icons.folder_outlined, Icons.folder_rounded),
  VaultDestination('Model', Icons.memory_outlined, Icons.memory_rounded),
  VaultDestination('Bridge', Icons.hub_outlined, Icons.hub_rounded),
  VaultDestination('Link', Icons.content_paste_outlined, Icons.content_paste_rounded),
  VaultDestination('Stats', Icons.insights_outlined, Icons.insights_rounded),
];

class VaultAppChrome extends StatelessWidget {
  final int index;
  final ValueChanged<int> onSelect;
  final List<Widget> pages;

  /// Global link-state pill, visible from every tab.
  final String statusLabel;
  final Color statusColor;
  final bool statusPulsing;

  const VaultAppChrome({
    super.key,
    required this.index,
    required this.onSelect,
    required this.pages,
    required this.statusLabel,
    required this.statusColor,
    this.statusPulsing = false,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vault Co-Processor'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: VaultSpace.lg),
            child: StatusPill(
              label: statusLabel,
              color: statusColor,
              pulsing: statusPulsing,
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: IndexedStack(index: index, children: pages),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: onSelect,
        destinations: [
          for (final d in vaultDestinations)
            NavigationDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.selectedIcon),
              label: d.label,
            ),
        ],
      ),
    );
  }
}
