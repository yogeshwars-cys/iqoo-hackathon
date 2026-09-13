/// ONE REASONER: the coordinator's invariant, the persisted selection, and
/// VaultEngine routing that follows the selection rather than readiness.

library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_rag_test/core/llm/model_settings.dart';
import 'package:vault_rag_test/core/llm/reasoner_coordinator.dart';
import 'package:vault_rag_test/core/vault_engine.dart';

import 'gating_test.dart' show resultWithTopScore;

class FakeSynth implements CapsuleSynthesizer {
  final String name;
  int calls = 0;
  FakeSynth(this.name);
  @override
  bool get isReady => true;
  @override
  String get modelLabel => name;
  @override
  String get backendLabel => 'fake';
  @override
  Future<SynthesisOutput> synthesize(SearchResult result) async {
    calls++;
    return SynthesisOutput(
      text: '{"answer": "from $name", "confidence": "high", "key_facts": []}',
      elapsedMs: 10,
    );
  }
}

class FakeSlot implements ReasonerSlot {
  @override
  final ReasonerKind kind;
  final FakeSynth synth;
  @override
  bool isReady = false;
  @override
  bool isBusy = false;
  int unloads = 0;
  final List<String> events;

  FakeSlot(this.kind, this.events) : synth = FakeSynth(kind.settingsName);

  Future<bool> load({bool succeed = true, Duration delay = Duration.zero}) async {
    events.add('load ${kind.settingsName}');
    await Future<void>.delayed(delay);
    isReady = succeed;
    return succeed;
  }

  @override
  String get modelLabel => '${kind.settingsName}-model';
  @override
  String get backendLabel => 'fake/gpu';
  @override
  Future<void> unload() async {
    events.add('unload ${kind.settingsName}');
    unloads++;
    isReady = false;
  }

  @override
  CapsuleSynthesizer get synthesizer => synth;
}

void main() {
  late List<String> events;
  late FakeSlot llama;
  late FakeSlot mediapipe;
  late List<ReasonerKind> persisted;
  late ReasonerCoordinator c;

  setUp(() {
    events = [];
    persisted = [];
    llama = FakeSlot(ReasonerKind.llama, events);
    mediapipe = FakeSlot(ReasonerKind.mediapipe, events);
    c = ReasonerCoordinator(
      [llama, mediapipe],
      onSelected: (k) async => persisted.add(k),
      busyTimeout: const Duration(seconds: 2),
    );
  });
  tearDown(() => c.dispose());

  test('a successful GGUF load unloads MediaPipe and selects llama', () async {
    await c.activate(ReasonerKind.mediapipe, mediapipe.load);
    final a = await c.activate(ReasonerKind.llama, llama.load);
    expect(a.ok, isTrue);
    expect(a.unloaded, [ReasonerKind.mediapipe]);
    expect(mediapipe.isReady, isFalse);
    expect(c.active, ReasonerKind.llama);
    expect(c.loadedCount, 1);
    expect(persisted.last, ReasonerKind.llama);
    // Unload happens only AFTER the new load succeeded.
    expect(events, ['load mediapipe', 'load llama', 'unload mediapipe']);
  });

  test('a successful MediaPipe load unloads llama.cpp', () async {
    await c.activate(ReasonerKind.llama, llama.load);
    await c.activate(ReasonerKind.mediapipe, mediapipe.load);
    expect(llama.isReady, isFalse);
    expect(c.active, ReasonerKind.mediapipe);
    expect(c.loadedCount, 1);
  });

  test('a failed load leaves the working reasoner loaded and selected', () async {
    await c.activate(ReasonerKind.llama, llama.load);
    final a = await c.activate(
        ReasonerKind.mediapipe, () => mediapipe.load(succeed: false));
    expect(a.ok, isFalse);
    expect(llama.isReady, isTrue);
    expect(llama.unloads, 0);
    expect(c.active, ReasonerKind.llama);
    expect(persisted, [ReasonerKind.llama]);
  });

  test('overlapping activations are serialised: never two loaded', () async {
    final f1 = c.activate(ReasonerKind.llama,
        () => llama.load(delay: const Duration(milliseconds: 30)));
    final f2 = c.activate(ReasonerKind.mediapipe, mediapipe.load);
    await Future.wait([f1, f2]);
    expect(c.loadedCount, 1);
    expect(c.active, ReasonerKind.mediapipe);
  });

  test('waits for an in-flight generation before unloading', () async {
    await c.activate(ReasonerKind.llama, llama.load);
    llama.isBusy = true;
    Timer(const Duration(milliseconds: 250), () => llama.isBusy = false);
    final sw = Stopwatch()..start();
    await c.activate(ReasonerKind.mediapipe, mediapipe.load);
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(200));
    expect(llama.isReady, isFalse);
  });

  test('routing never falls through to the non-selected runtime', () async {
    c.restoreSelection(ReasonerKind.mediapipe);
    llama.isReady = true; // loaded outside the coordinator: must be ignored
    expect(c.activeSynthesizer, isNull);

    mediapipe.isReady = true;
    expect(c.activeSynthesizer, same(mediapipe.synth));
  });

  test('VaultEngine.ask routes to the persisted selection', () async {
    final engine = VaultEngine()..reasoner = c;
    addTearDown(engine.dispose);
    await c.activate(ReasonerKind.llama, llama.load);
    mediapipe.isReady = true; // simulate a stray loaded runtime

    final capsule = await engine.buildCapsule(resultWithTopScore(0.7));
    expect(capsule.answer, 'from llama');
    expect(llama.synth.calls, 1);
    expect(mediapipe.synth.calls, 0);

    // Selected but unloaded: extractive fallback, not the other runtime.
    await c.unloadActive();
    final fallback = await engine.buildCapsule(resultWithTopScore(0.7));
    expect(fallback.generation.ran, isFalse);
    expect(mediapipe.synth.calls, 0);
  });

  group('ModelSettings.activeReasoner', () {
    test('round-trips through the settings file', () async {
      final dir = Directory.systemTemp.createTempSync('model_settings_');
      addTearDown(() => dir.deleteSync(recursive: true));
      await const ModelSettings(llamaModelPath: '/m/qwen.gguf', activeReasoner: 'llama')
          .save(dir.path);
      final loaded = await ModelSettings.load(dir.path);
      expect(loaded.activeReasoner, 'llama');
      expect(loaded.resolvedActiveReasoner, 'llama');
    });

    test('pre-invariant files resolve to the runtime they would have loaded', () {
      expect(const ModelSettings(modelPath: '/g.task').resolvedActiveReasoner,
          'mediapipe');
      expect(const ModelSettings(llamaModelPath: '/q.gguf').resolvedActiveReasoner,
          'llama');
      expect(ModelSettings.empty.resolvedActiveReasoner, isNull);
      expect(
          const ModelSettings(modelPath: '/g.task', activeReasoner: 'llama')
              .resolvedActiveReasoner,
          'llama');
    });
  });
}
