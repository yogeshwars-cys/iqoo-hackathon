/// reasoner_coordinator.dart
///
/// ONE REASONER, AS A HARD INVARIANT.
///
/// The app carries two generation runtimes — llama.cpp (GGUF: Qwen, Llama,
/// SmolLM, GGUF Gemma) and MediaPipe (Gemma .task) — and before this file
/// both could be loaded at once, with VaultEngine.ask quietly preferring
/// whichever was "ready". That had three real costs:
///
///  * two multi-gigabyte weight sets resident at the same time;
///  * a capsule's `generation.model` depended on load order, not on a choice;
///  * the Model page could show one runtime while ask() used the other.
///
/// The invariant now: at most one runtime is loaded, and it is the one named
/// by the persisted `activeReasoner` setting.
///
///  * A load goes through [ReasonerCoordinator.activate]. Only if it
///    SUCCEEDS is every other runtime unloaded and the new one recorded as
///    active. A failed load changes nothing — the working reasoner survives.
///  * Routing reads [activeSynthesizer]: the selected runtime if it is ready,
///    otherwise nothing (and ask() degrades to the extractive capsule). It
///    never falls through to "the other one".
///  * Activations are serialised, so two taps on two Load buttons cannot
///    interleave into both being loaded.

library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../vault_engine.dart';
import 'capsule_prompt.dart';
import 'llama_runtime.dart';
import 'llm_runtime.dart';

enum ReasonerKind {
  /// llama.cpp / GGUF.
  llama('llama', 'llama.cpp (GGUF)'),

  /// MediaPipe LLM Inference / Gemma .task.
  mediapipe('mediapipe', 'MediaPipe (Gemma .task)');

  final String settingsName;
  final String label;
  const ReasonerKind(this.settingsName, this.label);

  static ReasonerKind? parse(String? raw) {
    for (final k in values) {
      if (k.settingsName == raw) return k;
    }
    return null;
  }
}

/// One loadable runtime, as the coordinator sees it.
abstract interface class ReasonerSlot {
  ReasonerKind get kind;
  bool get isReady;

  /// True while a generation is in flight; the coordinator waits for this to
  /// clear before unloading, so a capsule is never cut off mid-decode.
  bool get isBusy;
  String get modelLabel;
  String get backendLabel;
  Future<void> unload();
  CapsuleSynthesizer get synthesizer;
}

class LlamaSlot implements ReasonerSlot {
  final LlamaRuntime runtime;
  LlamaSlot(this.runtime);

  @override
  ReasonerKind get kind => ReasonerKind.llama;
  @override
  bool get isReady => runtime.isReady;
  @override
  bool get isBusy => runtime.isGenerating || runtime.queueDepth > 0;
  @override
  String get modelLabel => runtime.modelLabel;
  @override
  String get backendLabel => 'llama.cpp/${runtime.backend?.label ?? "?"}';
  @override
  Future<void> unload() => runtime.unload();
  @override
  CapsuleSynthesizer get synthesizer => LlamaSynthesizer(runtime);
}

class MediaPipeSlot implements ReasonerSlot {
  final LlmRuntime runtime;
  MediaPipeSlot(this.runtime);

  @override
  ReasonerKind get kind => ReasonerKind.mediapipe;
  @override
  bool get isReady => runtime.isReady;
  @override
  bool get isBusy => runtime.isGenerating;
  @override
  String get modelLabel => runtime.modelLabel;
  @override
  String get backendLabel => 'mediapipe/${runtime.backendLabel}';
  @override
  Future<void> unload() => runtime.unload();
  @override
  CapsuleSynthesizer get synthesizer => MediaPipeSynthesizer(runtime);
}

/// llama.cpp: unwrapped content — the runtime applies the GGUF's own chat
/// template (see capsule_prompt.dart for why Gemma markers must not be sent).
class LlamaSynthesizer implements CapsuleSynthesizer {
  final LlamaRuntime runtime;
  LlamaSynthesizer(this.runtime);

  @override
  bool get isReady => runtime.isReady;
  @override
  String get modelLabel => runtime.modelLabel;
  @override
  String get backendLabel => 'llama.cpp/${runtime.backend?.label ?? "?"}';

  @override
  Future<SynthesisOutput> synthesize(SearchResult result) async {
    final g = await runtime.generate(buildCapsuleContent(result));
    return SynthesisOutput(
      text: g.text,
      elapsedMs: g.prefillMs + g.decodeMs,
      tokens: g.tokens,
      prefillMs: g.prefillMs,
      decodeMs: g.decodeMs,
    );
  }
}

/// MediaPipe/Gemma: hand-wrapped Gemma turn markers.
class MediaPipeSynthesizer implements CapsuleSynthesizer {
  final LlmRuntime runtime;
  MediaPipeSynthesizer(this.runtime);

  @override
  bool get isReady => runtime.isReady;
  @override
  String get modelLabel => runtime.modelLabel;
  @override
  String get backendLabel => runtime.backendLabel;

  @override
  Future<SynthesisOutput> synthesize(SearchResult result) async {
    final g = await runtime.generate(buildCapsulePrompt(result));
    return SynthesisOutput(text: g.text, elapsedMs: g.elapsedMs, tokens: g.tokens);
  }
}

class ReasonerActivation {
  final bool ok;
  final ReasonerKind kind;

  /// Runtimes that were unloaded to uphold the invariant.
  final List<ReasonerKind> unloaded;

  const ReasonerActivation(this.ok, this.kind, this.unloaded);
}

class ReasonerCoordinator extends ChangeNotifier {
  final Map<ReasonerKind, ReasonerSlot> _slots;

  /// Persists a change of selection (main.dart writes model_settings.json).
  final Future<void> Function(ReasonerKind kind)? onSelected;

  /// How long to wait for an in-flight generation before unloading anyway.
  final Duration busyTimeout;

  ReasonerKind? _active;
  Future<void> _lock = Future<void>.value();
  bool _disposed = false;

  ReasonerCoordinator(
    List<ReasonerSlot> slots, {
    this.onSelected,
    this.busyTimeout = const Duration(seconds: 90),
  }) : _slots = {for (final s in slots) s.kind: s} {
    assert(_slots.length == slots.length, 'one slot per ReasonerKind');
  }

  /// The selected reasoner, loaded or not.
  ReasonerKind? get active => _active;
  ReasonerSlot? get activeSlot => _active == null ? null : _slots[_active];
  ReasonerSlot? slot(ReasonerKind kind) => _slots[kind];

  /// What VaultEngine.ask routes to: the selected runtime when it is ready,
  /// otherwise null. Deliberately never the non-selected runtime.
  CapsuleSynthesizer? get activeSynthesizer {
    final s = activeSlot;
    return (s != null && s.isReady) ? s.synthesizer : null;
  }

  /// Number of runtimes currently holding weights. The invariant is `<= 1`.
  int get loadedCount => _slots.values.where((s) => s.isReady).length;

  /// Restores the persisted selection at startup without loading anything.
  void restoreSelection(ReasonerKind? kind) {
    _active = kind;
    _notify();
  }

  /// Loads [kind] via [load]; on success unloads every other runtime and
  /// makes [kind] the persisted selection. On failure nothing else changes.
  Future<ReasonerActivation> activate(
    ReasonerKind kind,
    Future<bool> Function() load,
  ) {
    final completer = Completer<ReasonerActivation>();
    _lock = _lock.then((_) async {
      try {
        final ok = await load();
        if (!ok) {
          completer.complete(ReasonerActivation(false, kind, const []));
          return;
        }
        final unloaded = <ReasonerKind>[];
        for (final other in _slots.values) {
          if (other.kind == kind || !other.isReady) continue;
          await _waitIdle(other);
          await other.unload();
          unloaded.add(other.kind);
        }
        _active = kind;
        _notify();
        await onSelected?.call(kind);
        completer.complete(ReasonerActivation(true, kind, unloaded));
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// Unloads the selected runtime, keeping the selection (so the next
  /// startup still knows which one to auto-load).
  Future<void> unloadActive() {
    final done = Completer<void>();
    _lock = _lock.then((_) async {
      try {
        final s = activeSlot;
        if (s != null && s.isReady) {
          await _waitIdle(s);
          await s.unload();
        }
        _notify();
        done.complete();
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  Future<void> _waitIdle(ReasonerSlot slot) async {
    final deadline = DateTime.now().add(busyTimeout);
    while (slot.isBusy && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Map<String, dynamic> describe() => {
        'active_reasoner': _active?.settingsName,
        'loaded_count': loadedCount,
        for (final s in _slots.values)
          s.kind.settingsName: {
            'ready': s.isReady,
            'model': s.isReady ? s.modelLabel : null,
            'backend': s.isReady ? s.backendLabel : null,
          },
      };

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
