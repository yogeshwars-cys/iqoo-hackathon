/// Standalone on-device ranking benchmark. Not part of the app.
///
///   flutter run --release --flavor airgap -t lib/bench_rank_main.dart
///
/// Prints to logcat (`flutter logs`) and shows the result on screen. Target:
/// median under 3 ms for 1,000 x 384 on the iQOO 15.

library;

import 'package:flutter/material.dart';

import 'core/vector/rank_benchmark.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final lines = <String>[];
  for (final n in [1000, 5000]) {
    final r = runRankBenchmark(vectors: n);
    final line = 'VAULT_BENCH $r ${n == 1000 ? (r.medianMs < 3 ? 'PASS <3ms' : 'MISS >=3ms') : ''}';
    debugPrint(line);
    lines.add(line);
  }
  runApp(MaterialApp(
    home: Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SelectableText(lines.join('\n\n')),
        ),
      ),
    ),
  ));
}
