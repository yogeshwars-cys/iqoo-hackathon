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
import 'core/llm/reasoner_coordinator.dart';
import 'core/security/capsule_signer.dart';
import 'core/vault_engine.dart';
import 'link/vault_link_service.dart';
import 'telemetry/benchmark_runner.dart';
import 'telemetry/compute_telemetry.dart';
import 'telemetry/device_info.dart';
import 'telemetry/llm_benchmark_runner.dart';
import 'telemetry/pipeline_benchmark_runner.dart';
import 'ui/app_chrome.dart';
import 'ui/bridge_page.dart';
import 'ui/link_page.dart';
import 'ui/model_page.dart';
import 'ui/stats_page.dart';
import 'ui/system_screens.dart';
import 'ui/theme.dart';
import 'ui/vault_page.dart';

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
    systemNavigationBarColor: VaultColors.surfaceContainer,
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
  late final ReasonerCoordinator _reasoner;
  late final ComputeTelemetry _telemetry;
  late final BenchmarkRunner _benchmark;
  late final LlmBenchmarkRunner _llmBenchmark;
  late final PipelineBenchmarkRunner _pipelineBenchmark;
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
    // Per-hardware leases: MiniLM on the NPU only once QNN HTP is verified,
    // generation on whatever device its runtime confirms. GPU and NPU are
    // tracked independently, so genuine overlap is visible.
    _engine.embeddings.ledger = _meter;

    _llm = LlmRuntime()
      ..onGeneration = _meter.record
      ..ledger = _meter;
    _llama = LlamaRuntime()
      ..onGeneration = _meter.record
      ..ledger = _meter;

    // ONE reasoner. Both runtimes exist, but only through the coordinator:
    // a successful load of either unloads the other, and ask() routes to the
    // persisted selection — never "whichever is ready".
    _reasoner = ReasonerCoordinator(
      [LlamaSlot(_llama), MediaPipeSlot(_llm)],
      onSelected: (kind) async {
        _modelSettings =
            _modelSettings.copyWith(activeReasoner: kind.settingsName);
        await _modelSettings.save(_documentsPath);
      },
    );
    _engine.reasoner = _reasoner;

    _telemetry = ComputeTelemetry(meter: _meter);
    _benchmark = BenchmarkRunner(engine: _engine, telemetry: _telemetry);
    _llmBenchmark = LlmBenchmarkRunner(llm: _llm, telemetry: _telemetry);
    _pipelineBenchmark = PipelineBenchmarkRunner(
      engine: _engine,
      telemetry: _telemetry,
      meter: _meter,
      reasoner: _reasoner,
      llama: _llama,
    );
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

      // Restore the selected reasoner, then auto-load ONLY that runtime,
      // and only when auto-load was switched on. A cold start that spends
      // 30 s on weights most sessions never use is the wrong default.
      final selected =
          ReasonerKind.parse(_modelSettings.resolvedActiveReasoner);
      _reasoner.restoreSelection(selected);
      if (_modelSettings.autoLoad) {
        switch (selected) {
          case ReasonerKind.llama:
            final path = _modelSettings.llamaModelPath;
            final backend = _rememberedLlamaBackend();
            if (path != null && backend != null) {
              unawaited(_reasoner.activate(ReasonerKind.llama,
                  () => _llama.load(path, backend: backend)));
            }
          case ReasonerKind.mediapipe:
            final path = _modelSettings.modelPath;
            if (path != null) {
              unawaited(_reasoner.activate(
                  ReasonerKind.mediapipe, () => _llm.load(path)));
            }
          case null:
            break;
        }
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
    _reasoner.dispose();
    _llm.dispose();
    _llama.dispose();
    _telemetry.dispose();
    _benchmark.dispose();
    _llmBenchmark.dispose();
    _pipelineBenchmark.dispose();
    _engine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_bootstrapped) return const BootScreen();
    if (_bootstrapError != null || _engine.state == EngineState.failed) {
      return FailureScreen(
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

    return ListenableBuilder(
      listenable: _bridge,
      // Link state is visible from every screen, not just the bridge tab —
      // it is the one piece of status that changes what the app is doing
      // while you are looking somewhere else.
      builder: (context, _) => VaultAppChrome(
        index: _tab,
        onSelect: (i) => setState(() => _tab = i),
        statusLabel: _bridge.isConnected
            ? 'Linked'
            : (kAirGapped ? 'Air-gap' : 'Local'),
        statusColor:
            _bridge.isConnected ? VaultColors.accent : VaultColors.faint,
        statusPulsing: _bridge.isConnected,
        pages: [
            VaultPage(engine: _engine, reasoner: _reasoner),
            ModelPage(
              llm: _llm,
              llama: _llama,
              reasoner: _reasoner,
              embeddingStatus: () => _engine.embeddings.acceleratorStatus,
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
              AirGapPage(onOpenLink: () => setState(() => _tab = 3))
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
              pipeline: _pipelineBenchmark,
            ),
        ],
      ),
    );
  }
}
