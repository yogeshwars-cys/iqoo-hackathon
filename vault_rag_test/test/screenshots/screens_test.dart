/// Screenshot harness: renders every tab with deterministic fixture state at
/// a phone viewport, with real fonts, into build/ui_shots/*.png.
///
///   $env:VAULT_SCREENSHOTS=1; flutter test test/screenshots --update-goldens
///
/// Skipped in the normal suite. Nothing here is asserted — it produces images
/// for design review, because no phone is attached to the build machine.

library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_rag_test/bridge/bridge_client.dart';
import 'package:vault_rag_test/core/answer_synthesizer.dart';
import 'package:vault_rag_test/core/gating.dart';
import 'package:vault_rag_test/core/llm/capsule.dart';
import 'package:vault_rag_test/core/llm/llama_runtime.dart';
import 'package:vault_rag_test/core/llm/llm_runtime.dart';
import 'package:vault_rag_test/core/llm/reasoner_coordinator.dart';
import 'package:vault_rag_test/core/security/capsule_signing.dart';
import 'package:vault_rag_test/core/vault_engine.dart';
import 'package:vault_rag_test/core/vector_store.dart';
import 'package:vault_rag_test/link/vault_link_service.dart';
import 'package:vault_rag_test/telemetry/benchmark_runner.dart';
import 'package:vault_rag_test/telemetry/compute_telemetry.dart';
import 'package:vault_rag_test/telemetry/llm_benchmark_runner.dart';
import 'package:vault_rag_test/telemetry/pipeline_benchmark_runner.dart';
import 'package:vault_rag_test/telemetry/telemetry_sources.dart';
import 'package:vault_rag_test/ui/app_chrome.dart';
import 'package:vault_rag_test/ui/bridge_page.dart';
import 'package:vault_rag_test/ui/link_page.dart';
import 'package:vault_rag_test/ui/model_page.dart';
import 'package:vault_rag_test/ui/stats_page.dart';
import 'package:vault_rag_test/ui/system_screens.dart';
import 'package:vault_rag_test/ui/theme.dart';
import 'package:vault_rag_test/ui/vault_page.dart';

import '../ephemeral_clipboard_test.dart' show FakeClipboard;

final _enabled = Platform.environment['VAULT_SCREENSHOTS'] == '1';
const _fontsDir = 'D:/flutter/bin/cache/artifacts/material_fonts';

Future<void> _loadFont(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    loader.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
  }
  await loader.load();
}

ContextCapsule _sampleCapsule() {
  final chunks = [
    RetrievedChunk(
      id: 'hr_finance.md_chunk_000',
      fileName: 'confidential_hr_finance.md',
      content: 'Compensation. The annual base salary of Jun Quispe is USD 98,500, '
          'reviewed each April. Target bonus is 12 percent of base.',
      score: 0.6384,
    ),
    RetrievedChunk(
      id: 'hr_finance.md_chunk_001',
      fileName: 'confidential_hr_finance.md',
      content: 'Payroll is deposited to the IBAN on file within five business '
          'days of month end.',
      score: 0.3576,
    ),
  ];
  const q = 'What is the annual base salary of Jun Quispe?';
  final result = SearchResult(
    query: q,
    chunks: chunks,
    directAnswer: synthesizeDirectAnswer(q, chunks),
    latencyMs: 2216,
    embedMs: 137,
    totalIndexed: 3,
    embeddingBackend: 'XNNPACK fallback',
    embeddingHardware: 'cpu',
  );
  final capsule = ContextCapsule.fromModelOutput(
    '{"answer": "The annual base salary of Jun Quispe is USD 98,500.", '
    '"confidence": "high", "key_facts": [{"fact": "Base salary USD 98,500", '
    '"source": "confidential_hr_finance.md", "verbatim": "The annual base '
    'salary of Jun Quispe is USD 98,500"}], "caveats": ["Figure is '
    'reviewed each April."]}',
    result,
    model: 'smollm2-1.7b-instruct-q4_k_m.gguf',
    backend: 'llama.cpp/GPU',
    elapsedMs: 15685,
    tokens: 163,
    timestamp: 1789265124000,
    gating: {'top_score': 0.6384},
  );
  expect(capsule.gatingPath, GatingPath.llmSynthesized);
  return capsule.withProvenance(const CapsuleProvenance(
    device: 'vivo I2501 · QTI SM8850 · Android 16',
    enclave: 'AndroidKeyStore (StrongBox)',
    keySecurityLevel: 'strongbox',
    strongBoxFeature: true,
    gatingPath: 'llm_synthesized',
    timestamp: 1789265124000,
    canonicalVersion: kCapsuleSigTag,
    canonicalDigest: '976a97ef6b717516df1c691ac32c102ef1b3a041ac5c56262dc2cec6ed3f83ee',
    signature: '3045022100fixture',
    signatureAlgorithm: 'ECDSA-P256-SHA256',
    publicKey: '3059301306fixture',
  ));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    if (!_enabled) return;
    await _loadFont('Roboto', [
      '$_fontsDir/roboto-regular.ttf',
      '$_fontsDir/roboto-medium.ttf',
      '$_fontsDir/roboto-bold.ttf',
      '$_fontsDir/roboto-light.ttf',
    ]);
    await _loadFont('MaterialIcons', ['$_fontsDir/materialicons-regular.otf']);
    await _loadFont('monospace', ['C:/Windows/Fonts/consola.ttf']);
  });

  Future<void> shoot(
    WidgetTester tester,
    String name,
    int tab, {
    double height = 915,
    Future<void> Function(WidgetTester t)? before,
    bool lan = false,
  }) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = Size(412 * 3.0, height * 3.0);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final meter = InferenceMeter();
    final engine = VaultEngine()
      ..debugSetState(EngineState.ready,
          statusLine: 'XNNPACK · 384-dim · 256 tokens · 176 ms to load');
    final llm = LlmRuntime();
    final llama = LlamaRuntime();
    final reasoner = ReasonerCoordinator([LlamaSlot(llama), MediaPipeSlot(llm)])
      ..restoreSelection(ReasonerKind.llama);
    final telemetry = ComputeTelemetry(meter: meter);
    final t0 = DateTime(2026, 9, 13, 12);
    for (var i = 0; i < 90; i++) {
      final wave = (i % 20) / 20;
      telemetry.debugAddSample(TelemetrySample(
        at: t0.add(Duration(seconds: i)),
        cpu: Probe(18 + 40 * wave, ProbeKind.measured),
        gpu: Probe(i > 30 && i < 70 ? 92 + 6 * wave : 4, ProbeKind.measured),
        npu: const Probe(null, ProbeKind.unavailable),
        duty: Probe(i > 30 && i < 70 ? 64.0 : 3.0, ProbeKind.derived),
        inferences: i % 3,
      ));
    }
    final link = VaultLinkService(
      engine: engine,
      telemetrySnapshot: () => const {},
      port: FakeClipboard(),
      pairingStore: MemoryPairingStore(),
    );
    await link.pair();
    link.start(interval: const Duration(days: 1));
    final bridge = BridgeClient(engine: engine, telemetrySnapshot: () => const {});
    final pages = [
      VaultPage(engine: engine, reasoner: reasoner, initialCapsule: _sampleCapsule()),
      ModelPage(
        llm: llm,
        llama: llama,
        reasoner: reasoner,
        embeddingStatus: () => engine.embeddings.acceleratorStatus,
        rememberedPath: null,
        onRemember: (_) async {},
        rememberedLlamaPath: '/storage/emulated/0/Download/smollm2-1.7b-instruct-q4_k_m.gguf',
        rememberedLlamaBackend: LlamaBackend.gpu,
        onRememberLlama: (_, _) async {},
      ),
      lan
          ? BridgePage(client: bridge, documentsPath: Directory.systemTemp.path)
          : AirGapPage(onOpenLink: () {}),
      LinkPage(link: link),
      StatsPage(
        telemetry: telemetry,
        benchmark: BenchmarkRunner(engine: engine, telemetry: telemetry),
        llmBenchmark: LlmBenchmarkRunner(llm: llm, telemetry: telemetry),
        llm: llm,
        engine: engine,
        vocabText: '',
        pipeline: PipelineBenchmarkRunner(
            engine: engine, telemetry: telemetry, meter: meter,
            reasoner: reasoner, llama: llama),
      ),
    ];

    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildVaultTheme(),
      home: RepaintBoundary(
        key: const ValueKey('shot'),
        child: VaultAppChrome(
          index: tab,
          onSelect: (_) {},
          pages: pages,
          statusLabel: lan ? 'Local' : 'Air-gap',
          statusColor: VaultColors.faint,
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 400));
    if (before != null) await before(tester);
    await expectLater(find.byKey(const ValueKey('shot')),
        matchesGoldenFile('../../build/ui_shots/$name.png'));
    link.stop();
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  }

  final names = ['vault', 'model', 'bridge', 'link', 'stats'];
  for (var i = 0; i < names.length; i++) {
    testWidgets('screen ${names[i]}', skip: !_enabled, (t) => shoot(t, names[i], i));
    testWidgets('screen ${names[i]} (full length)', skip: !_enabled,
        (t) => shoot(t, '${names[i]}_full', i, height: 3200));
  }
  testWidgets('screen bridge (lan flavor)', skip: !_enabled,
      (t) => shoot(t, 'bridge_lan', 2, lan: true, height: 1400));
}
