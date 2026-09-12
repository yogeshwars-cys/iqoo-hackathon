/// main.dart
///
/// Composition root for the iQOO co-processor vault.
///
/// WHAT CHANGED FROM THE PREVIOUS BUILD, AND WHY
///
/// v0 was a single screen whose State object *was* the application: it held
/// the interpreter, the chunker, the database handle and the UI, and every
/// step of the pipeline was a method on a widget. That is the right shape
/// for a test harness with one caller.
///
/// It stops being the right shape the moment a second caller exists. The
/// desktop bridge has to ingest and query with no widget mounted, possibly
/// while the user is on another tab, and possibly at the same time as a
/// local search — and a TFLite interpreter is not reentrant, so "at the
/// same time" is a native crash rather than a race you can debug.
///
/// So the pipeline moved into [VaultEngine], which serialises every call
/// that touches the interpreter, and this file became what wires the six
/// long-lived objects together and hands them to four screens:
///
///   VaultEngine        the encoder, the chunker, the vector store
///   LlmRuntime         Gemma, for reasoning - optional, loaded on demand
///   ComputeTelemetry   1 Hz sysfs sampling for the charts
///   BenchmarkRunner    repeatable embedding load, driven by the engine
///   LlmBenchmarkRunner repeatable generation load on whichever backend
///                      LlmRuntime already has loaded - see its file header
///                      for why it never switches backends itself
///   BridgeClient       the outbound WebSocket to bridge_server.py
///
/// The two models divide the work strictly: MiniLM encodes (every ingest,
/// every query, always loaded, ~230 ms) and Gemma reasons over what
/// retrieval already found (once per query, only when loaded, seconds). The
/// engine works with the second one absent, which is why [LlmRuntime] is
/// attached to it rather than owned by it.
///
/// They are constructed here and only here. Nothing in ui/ owns state that
/// outlives its screen, which is what makes it safe for the bridge to keep
/// working while the user is looking at the benchmark.

library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'bridge/bridge_client.dart';
import 'core/llm/llama_runtime.dart';
import 'core/llm/llm_runtime.dart';
import 'core/llm/model_settings.dart';
import 'core/security/capsule_signer.dart';
import 'core/vault_engine.dart';
import 'link/vault_link_service.dart';
import 'telemetry/benchmark_runner.dart';
import 'telemetry/compute_telemetry.dart';
import 'telemetry/device_info.dart';
import 'telemetry/llm_benchmark_runner.dart';
import 'ui/bridge_page.dart';
import 'ui/link_page.dart';
import 'ui/model_page.dart';
import 'ui/stats_page.dart';
import 'ui/theme.dart';
import 'ui/vault_page.dart';
import 'ui/widgets/common.dart';

/// True for every build except the `lan` flavor — including builds with no
/// flavor at all, so the safe answer is the default. The Android manifest is
/// the real enforcement (no INTERNET permission in airgap release); this
/// only keeps the UI from offering what the OS would refuse.
const bool kAirGapped = appFlavor != 'lan';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: VaultColors.surface,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const CoProcessorApp());
}

class CoProcessorApp extends StatelessWidget {
  const CoProcessorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'iQOO Vault Co-Processor',
      debugShowCheckedModeBanner: false,
      theme: buildVaultTheme(),
      home: const AppShell(),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _meter = InferenceMeter();

  late final VaultEngine _engine;
  late final LlmRuntime _llm;
  late final LlamaRuntime _llama;
  late final ComputeTelemetry _telemetry;
  late final BenchmarkRunner _benchmark;
  late final LlmBenchmarkRunner _llmBenchmark;
  late final BridgeClient _bridge;
  late final VaultLinkService _link;
  AppLifecycleListener? _lifecycle;

  int _tab = 0;
  bool _bootstrapped = false;
  String? _bootstrapError;
  String _vocabText = '';
  String _documentsPath = '';
  ModelSettings _modelSettings = ModelSettings.empty;

  @override
  void initState() {
    super.initState();

    _engine = VaultEngine(
      // Capsules are signed with the platform-reported device label rather
      // than a hardcoded marketing name.
      signer: CapsuleSigner(
        deviceLabel: () async => (await DeviceFacts.load()).summary,
      ),
    );
    // The engine reports native inference time to the meter, which the
    // telemetry service turns into the "inference duty" lane. A callback
    // rather than an import, so core/ has no dependency on telemetry/.
    _engine.embeddings.onInference = _meter.record;

    _llm = LlmRuntime();
    // Generation feeds the same duty-cycle lane as embedding, so a capsule
    // being written shows up on the chart as the multi-second block of work
    // it actually is.
    _llm.onGeneration = _meter.record;
    _engine.llm = _llm;

    // The llama.cpp/GGUF path, alongside _llm rather than replacing it — see
    // llama_runtime.dart's file header. VaultEngine.ask() prefers this one
    // when it is ready, so loading a GGUF model here also makes it the
    // engine "Ask on device" actually reasons with.
    _llama = LlamaRuntime();
    _llama.onGeneration = _meter.record;
    _engine.llama = _llama;

    _telemetry = ComputeTelemetry(meter: _meter);
    _benchmark = BenchmarkRunner(engine: _engine, telemetry: _telemetry);
    _llmBenchmark = LlmBenchmarkRunner(llm: _llm, telemetry: _telemetry);
    _bridge = BridgeClient(
      engine: _engine,
      telemetrySnapshot: _telemetry.snapshot,
      networkAllowed: !kAirGapped,
    );
    // Clipboard-carried alternative to the WebSocket bridge above — same
    // engine, same telemetry snapshot, no socket. See vault_link_service.dart.
    _link = VaultLinkService(
      engine: _engine,
      telemetrySnapshot: _telemetry.snapshot,
    );

    // Stop sampling in the background. A 1 Hz timer reading eight sysfs
    // files is not free, and samples taken while the app is not foreground
    // would pollute the chart with a flat stretch that looks like idle
    // hardware rather than a paused recorder.
    _lifecycle = AppLifecycleListener(
      onPause: _telemetry.stop,
      onResume: _telemetry.start,
    );

    _bootstrap();
  }

  /// Resolves the persisted backend name back to [LlamaBackend], or null if
  /// nothing was ever remembered — a plain loop rather than
  /// package:collection's firstOrNull, which this project does not
  /// otherwise depend on.
  LlamaBackend? _rememberedLlamaBackend() {
    for (final backend in LlamaBackend.values) {
      if (backend.name == _modelSettings.llamaBackend) return backend;
    }
    return null;
  }

  Future<void> _bootstrap() async {
    try {
      _vocabText = await rootBundle.loadString('assets/models/vocab.txt');
      final dir = await getApplicationDocumentsDirectory();
      _documentsPath = dir.path;

      await _engine.initialize(
        vocabText: _vocabText,
        databasePath: '${dir.path}/vault.db',
      );

      // Pairing code, AES-GCM-encrypted under the keystore master key.
      _link.pairingStore = KeystorePairingStore(dir.path);
      await _link.restorePairing();

      _modelSettings = await ModelSettings.load(dir.path);
      _telemetry.start();

      // Deliberately not auto-loading Gemma unless asked. A cold start that
      // spends 30 s on weights most sessions never use is the wrong default;
      // retrieval is the fast path and stays fast.
      final remembered = _modelSettings.modelPath;
      if (_modelSettings.autoLoad && remembered != null) {
        unawaited(_llm.load(remembered));
      }
      if (!mounted) return;
      setState(() => _bootstrapped = true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _bootstrapped = true;
        _bootstrapError = '$e';
      });
    }
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _bridge.dispose();
    _link.dispose();
    _llm.dispose();
    _llama.dispose();
    _telemetry.dispose();
    _benchmark.dispose();
    _llmBenchmark.dispose();
    _engine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_bootstrapped) return const _BootScreen();
    if (_bootstrapError != null || _engine.state == EngineState.failed) {
      return _FailureScreen(
        message: _bootstrapError ?? '${_engine.error}',
        onRetry: () {
          setState(() {
            _bootstrapped = false;
            _bootstrapError = null;
          });
          _bootstrap();
        },
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Vault Co-Processor'),
        actions: [
          // Link state is visible from every screen, not just the bridge
          // tab — it is the one piece of status that changes what the app
          // is doing while you are looking somewhere else.
          ListenableBuilder(
            listenable: _bridge,
            builder: (context, _) => Padding(
              padding: const EdgeInsets.only(right: VaultSpace.lg),
              child: StatusPill(
                label: _bridge.isConnected
                    ? 'LINKED'
                    : (kAirGapped ? 'AIR-GAP' : 'LOCAL'),
                color: _bridge.isConnected
                    ? VaultColors.accent
                    : VaultColors.faint,
                pulsing: _bridge.isConnected,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: IndexedStack(
          index: _tab,
          children: [
            VaultPage(engine: _engine, llm: _llm),
            ModelPage(
              llm: _llm,
              llama: _llama,
              rememberedPath: _modelSettings.modelPath,
              onRemember: (path) async {
                _modelSettings = _modelSettings.copyWith(modelPath: path);
                await _modelSettings.save(_documentsPath);
              },
              rememberedLlamaPath: _modelSettings.llamaModelPath,
              rememberedLlamaBackend: _rememberedLlamaBackend(),
              onRememberLlama: (path, backend) async {
                _modelSettings = _modelSettings.copyWith(
                  llamaModelPath: path,
                  llamaBackend: backend.name,
                );
                await _modelSettings.save(_documentsPath);
              },
            ),
            if (kAirGapped)
              const _AirGapNotice()
            else
              BridgePage(client: _bridge, documentsPath: _documentsPath),
            LinkPage(link: _link),
            StatsPage(
              telemetry: _telemetry,
              benchmark: _benchmark,
              llmBenchmark: _llmBenchmark,
              llm: _llm,
              engine: _engine,
              vocabText: _vocabText,
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder_rounded),
            label: 'Vault',
          ),
          NavigationDestination(
            icon: Icon(Icons.memory_outlined),
            selectedIcon: Icon(Icons.memory_rounded),
            label: 'Model',
          ),
          NavigationDestination(
            icon: Icon(Icons.hub_outlined),
            selectedIcon: Icon(Icons.hub_rounded),
            label: 'Bridge',
          ),
          NavigationDestination(
            icon: Icon(Icons.content_paste_outlined),
            selectedIcon: Icon(Icons.content_paste_rounded),
            label: 'Link',
          ),
          NavigationDestination(
            icon: Icon(Icons.insights_outlined),
            selectedIcon: Icon(Icons.insights_rounded),
            label: 'Stats',
          ),
        ],
      ),
    );
  }
}

/// Shown in place of the Bridge tab in the air-gapped build.
class _AirGapNotice extends StatelessWidget {
  const _AirGapNotice();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(VaultSpace.lg),
      children: const [
        SectionCard(
          title: 'Air-gapped build',
          subtitle: 'This APK requests no network permission, so the LAN '
              'bridge is not available. Use VaultLink on the Link tab, or '
              'install the lan flavor for the WebSocket bridge.',
          child: CodeBlock(
              'flutter build apk --release --flavor lan'),
        ),
      ],
    );
  }
}

/// Model load takes about half a second and is the only unavoidable wait.
/// It says what it is doing, because a blank screen with a spinner on a
/// cold start reads as a hang.
class _BootScreen extends StatelessWidget {
  const _BootScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: VaultColors.accent,
              ),
            ),
            SizedBox(height: VaultSpace.lg),
            Text(
              'Loading the encoder',
              style: TextStyle(
                color: VaultColors.foreground,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: VaultSpace.xs),
            Text(
              'Selecting the fastest available delegate',
              style: TextStyle(color: VaultColors.faint, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _FailureScreen extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _FailureScreen({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(VaultSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.error_outline,
                  color: VaultColors.danger, size: 34),
              const SizedBox(height: VaultSpace.lg),
              const Text(
                'The encoder did not load',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: VaultColors.foreground,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: VaultSpace.md),
              // The full error, verbatim. Every realistic cause here is a
              // build or export problem (missing asset, wrong input dtype,
              // no working delegate) and the exact text is what identifies
              // which — a friendly paraphrase would throw that away.
              CodeBlock(message),
              const SizedBox(height: VaultSpace.lg),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 19),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
