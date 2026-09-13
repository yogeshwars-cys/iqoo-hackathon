/// llm_runtime.dart
///
/// Dart side of the `vault/llm` channel: loads Gemma through MediaPipe's LLM
/// Inference API and runs one generation at a time.
///
/// WHY A METHOD CHANNEL RATHER THAN A PLUGIN
///
/// The obvious choice is a pub package that wraps MediaPipe. This project
/// has a long, documented history of dependency resolution going wrong (see
/// BUILD_NOTES.md, most of it), pins an unusual Dart SDK floor, and already
/// owns a method channel for device facts. One Gradle coordinate plus about
/// a hundred lines of Kotlin is a smaller surface than a transitive
/// dependency tree, and it means the generation parameters are ours rather
/// than whatever a wrapper chose to expose.
///
/// SERIALISATION, AGAIN
///
/// Like the TFLite interpreter, a MediaPipe LlmInference session is not
/// safe to drive from two places at once — and here there genuinely are
/// two, because the bridge can ask for a capsule while someone taps Ask on
/// the phone. Generation is therefore queued the same way embedding is, but
/// with an important difference: generation takes seconds, not hundreds of
/// milliseconds, so a second request that arrives mid-generation waits a
/// visible amount of time. [isGenerating] exists so the UI can say so
/// rather than appearing to hang.

library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../compute_ledger.dart';
import 'model_probe.dart';

const _channel = MethodChannel('vault/llm');

/// Where MediaPipe should run the model.
///
/// GPU is worth trying first on Adreno — it is several times faster than
/// CPU for this workload — but it needs more contiguous memory, and on a
/// mid-range phone with 6–8 GB it can fail to initialise where CPU
/// succeeds. [LlmRuntime.load] falls back automatically and reports which
/// one it ended up on, the same pattern the embedding service uses for its
/// delegates.
enum LlmBackend { gpu, cpu }

enum LlmState { unloaded, probing, loading, ready, failed }

class LlmGeneration {
  final String text;
  final int elapsedMs;

  /// Reported by MediaPipe when available; null otherwise. Not estimated —
  /// a guessed token count in a provenance field is worse than none.
  final int? tokens;

  const LlmGeneration({
    required this.text,
    required this.elapsedMs,
    this.tokens,
  });

  double? get tokensPerSecond =>
      (tokens == null || elapsedMs <= 0) ? null : tokens! * 1000 / elapsedMs;
}

class LlmRuntime extends ChangeNotifier {
  /// Called with the wall-clock duration of each generation, so the
  /// telemetry screen's duty-cycle lane accounts for LLM work as well as
  /// embedding. A callback rather than an import, keeping core/ free of a
  /// dependency on telemetry/.
  void Function(int micros)? onGeneration;

  /// Receives a lease per generation on the backend MediaPipe actually
  /// loaded on (its `load` succeeded there; there is no silent fallback
  /// after load). MediaPipe has no NPU path, so this is only ever GPU or CPU.
  ComputeLedger ledger = const NullComputeLedger();

  LlmState _state = LlmState.unloaded;
  String? _error;
  String? _modelPath;
  ModelProbeResult? _probe;
  LlmBackend? _backend;
  int _loadMs = 0;
  bool _isGenerating = false;

  /// The token budget the *loaded* session was actually configured with.
  ///
  /// This is `setMaxTokens` on MediaPipe's `LlmInferenceOptions` — the total
  /// input+output capacity of the session's KV-cache, fixed at load time and
  /// never revisited per call. [generate]'s own `maxTokens` parameter cannot
  /// change it after the fact; it exists only to cap the *response*, and
  /// [LlmChannel.onGenerate] on the Kotlin side does not even read it. This
  /// field is what a pre-flight length check has to compare against.
  int _maxTokens = 0;

  /// Serialises generation, and lets a queued caller know it is queued.
  Future<void> _lock = Future<void>.value();
  int _queueDepth = 0;

  /// Set by [dispose]. Read by [_notify]; see it.
  bool _disposed = false;

  LlmState get state => _state;
  String? get error => _error;
  String? get modelPath => _modelPath;
  ModelProbeResult? get probe => _probe;
  LlmBackend? get backend => _backend;
  int get loadMs => _loadMs;
  int get maxTokens => _maxTokens;
  bool get isReady => _state == LlmState.ready;
  bool get isGenerating => _isGenerating;
  int get queueDepth => _queueDepth;

  /// Short model identity for capsule provenance.
  String get modelLabel {
    final path = _modelPath;
    if (path == null) return 'none';
    return path.split(RegExp(r'[/\\]')).last;
  }

  String get backendLabel => _backend?.name ?? 'none';

  /// [notifyListeners] that tolerates being called after disposal.
  ///
  /// Loading, generation and teardown all cross an `await` on a method
  /// channel, and can finish after the widget tree that started them is
  /// gone — most concretely, [unload]'s `close` call resolving after
  /// [dispose] has already run [ChangeNotifier.dispose]. ChangeNotifier
  /// throws if notified after dispose, so every notification in this class
  /// goes through here. Same idiom, and same reason, as
  /// `VaultEngine._notify`.
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// Reads the file header and reports what it is, without loading it.
  Future<ModelProbeResult> inspect(String path) async {
    _state = LlmState.probing;
    _notify();

    final result = await probeModel(path);
    _probe = result;
    _state = _state == LlmState.probing ? LlmState.unloaded : _state;
    _notify();
    return result;
  }

  /// Loads [path], using the backend order inferred from the filename.
  ///
  /// Refuses outright when [inspect] says the file is not a MediaPipe
  /// container. That check is cheap and the alternative is expensive: a
  /// wrong format reaches native code and aborts the process, which no Dart
  /// try/catch can intercept.
  ///
  /// BACKEND ORDERING — THIS IS THE CRASH FIX:
  ///
  /// MediaPipe CPU and GPU int4 weights use the same container format (.task /
  /// .bin) but completely different tensor layouts. When a CPU-quantised model
  /// is handed to the GPU shader backend, MediaPipe dereferences an invalid
  /// tensor pointer inside libllm_inference_engine_jni.so and raises
  /// SIGSEGV / SIGABRT. Android kills the process instantly — no Kotlin
  /// try/catch, no Dart catch, no fallback, just a hard crash.
  ///
  /// The fix: [probeModel] reads the filename and returns [SuggestedBackend].
  /// A file named *-cpu-* gets [LlmBackend.cpu] only; *-gpu-* gets the
  /// original [gpu, cpu] fallback order.
  ///
  /// WHY AN UNKNOWN FILENAME GOES TO CPU FIRST, NOT GPU
  ///
  /// The loop below reads like "try the fast backend, fall back to the safe
  /// one". It is only that for one failure mode: GPU *initialisation*
  /// failing — no delegate, not enough contiguous memory — which throws a
  /// Java exception, arrives here as a channel error, and lets the next
  /// iteration run.
  ///
  /// The failure this fix exists to prevent is not that one. A CPU-quantised
  /// model handed to the GPU backend does not throw. It dereferences a bad
  /// tensor pointer and the kernel kills the process. There is no exception,
  /// no next iteration, no error message, no second attempt. So for a file
  /// we cannot identify, `[gpu, cpu]` is not a fallback strategy — it stakes
  /// the whole process on a coin flip and has no recovery on the losing side.
  ///
  /// Order should therefore be chosen by the cost of being wrong:
  ///
  ///   wrong about GPU  →  process death. In-memory vault state gone, no
  ///                       diagnostic, and to the user the app simply
  ///                       vanished. Unrecoverable inside the run.
  ///   wrong about CPU  →  at worst a catchable load failure, after which
  ///                       the GPU pass below runs and succeeds; at best a
  ///                       successful load that is merely slower.
  ///
  /// CPU-first is the guess that keeps a second attempt possible, so it is
  /// the one an ambiguous name gets. The prior points the same way: a file
  /// with no backend token is more likely to be renamed, repackaged or
  /// self-converted than an official release, and the AI Edge Torch
  /// converter targets CPU by default.
  ///
  /// [backendOverride] skips the inference entirely — the load page offers
  /// it when the guess is `unknown`, because the user is the only party who
  /// might actually know where the file came from. An override is honoured
  /// exactly, with no fallback to the other backend: the point of asking is
  /// that the answer is better than our guess, and silently trying the other
  /// one afterwards would reintroduce the coin flip we just avoided.
  Future<bool> load(
    String path, {
    int maxTokens = 1024,
    double temperature = 0.2,
    int topK = 40,
    LlmBackend? backendOverride,
  }) async {
    final probe = await inspect(path);
    if (!probe.isUsable) {
      _state = LlmState.failed;
      _error = probe.format.remedy ??
          'Cannot load a ${probe.format.label} file.';
      _notify();
      return false;
    }

    _state = LlmState.loading;
    _error = null;
    _notify();

    // Derive backend order from the filename, unless the caller overrode it.
    final List<LlmBackend> order = switch (backendOverride) {
      // Explicit means explicit: one backend, no fallback. See the doc above.
      final LlmBackend forced => [forced],
      null => switch (probe.suggestedBackend) {
          SuggestedBackend.cpu => [LlmBackend.cpu],
          SuggestedBackend.gpu => [LlmBackend.gpu, LlmBackend.cpu],
          SuggestedBackend.unknown => () {
              debugPrint(
                '[vault] No backend token in filename — trying CPU first, '
                'because a wrong GPU guess kills the process outright while '
                'a wrong CPU guess is recoverable. Rename the file to '
                'include -cpu- or -gpu- to skip the guess.',
              );
              return [LlmBackend.cpu, LlmBackend.gpu];
            }(),
        },
    };

    debugPrint('[vault] Loading with backend order: ${order.map((b) => b.name).join(", ")}');

    final stopwatch = Stopwatch()..start();
    for (final backend in order) {
      try {
        await _channel.invokeMethod<void>('load', {
          'path': path,
          'backend': backend.name,
          'maxTokens': maxTokens,
          // Low but not zero. The capsule is a structured extraction task,
          // where creativity is a defect; a little above greedy avoids the
          // degenerate repetition loops small models fall into at 0.
          'temperature': temperature,
          'topK': topK,
        });
        stopwatch.stop();

        _modelPath = path;
        _backend = backend;
        _loadMs = stopwatch.elapsedMilliseconds;
        _maxTokens = maxTokens;
        _state = LlmState.ready;
        // Clear the first backend's failure once a later one works. Without
        // this, a successful CPU load after a failed GPU attempt leaves the
        // GPU error sitting in [error], and the status card renders it next
        // to a LOADED pill — a contradiction the user has to decide about.
        _error = null;
        _notify();
        return true;
      } catch (e) {
        debugPrint('[vault] LLM backend ${backend.name} failed: $e');
        _error = _explain(e, backend);
        // Try the next backend; if this was the last one, fall through to failure.
      }
    }

    stopwatch.stop();
    _state = LlmState.failed;
    _notify();
    return false;
  }

  String _explain(Object e, LlmBackend backend) {
    final s = e.toString();
    if (s.contains('OutOfMemory') || s.contains('out of memory')) {
      return 'Not enough memory to load on the ${backend.name.toUpperCase()} '
          'backend. Close other apps, or use a smaller quantisation.';
    }
    if (s.contains('MissingPluginException')) {
      return 'The vault/llm channel is not registered. A hot restart does '
          'not re-register channels — do a full stop and relaunch.';
    }
    if (s.contains('Permission') || s.contains('EACCES')) {
      return 'The file exists but cannot be read. Files under '
          '/data/local/tmp are not readable by an app on most ROMs; move it '
          'into your own storage.';
    }
    return s;
  }

  Future<void> unload() async {
    try {
      await _channel.invokeMethod<void>('close');
    } catch (_) {
      // Nothing useful to do if teardown fails; the state is reset anyway.
    }
    _state = LlmState.unloaded;
    _modelPath = null;
    _backend = null;
    _error = null;
    _maxTokens = 0;
    _notify();
  }

  /// Runs one generation. Queues behind any in flight.
  ///
  /// PRE-FLIGHT LENGTH CHECK — WHY THIS EXISTS
  ///
  /// [_maxTokens] is the session's *entire* input+output budget, fixed at
  /// load. A prompt that alone exceeds it does not get truncated or queued
  /// for later — `generateResponse` runs prefill straight into a KV-cache
  /// that is not big enough to hold it. That is an out-of-bounds write inside
  /// MediaPipe's native code, not a Dart exception, and it has the same
  /// "no catch, no fallback, process gone" shape as the backend-mismatch
  /// crash [load] already guards against.
  ///
  /// The capsule prompt is the concrete case this exists for: its own budget
  /// comment assumes "ample room for the instructions and the output" after
  /// up to 6000 characters (~1650 tokens) of context, but nothing before this
  /// check ever compared that assumption against what the loaded session was
  /// actually configured with. Measured worst case is ~2180 tokens of prompt
  /// alone — comfortably over a 1024-token session — and the mismatch is
  /// silent until the native call underneath it.
  ///
  /// So this is measured, not guessed, using the same crude chars-per-token
  /// estimate `capsule_prompt.dart` already uses for the same purpose. Firm
  /// rejection here — a `StateError` the caller's existing generation-failure
  /// handling already treats as "fall back to retrieval alone" — is strictly
  /// better than a coin flip on whether this particular prompt happens to be
  /// short enough not to matter.
  Future<LlmGeneration> generate(String prompt, {int? maxTokens}) {
    if (!isReady) {
      return Future.error(StateError('No model loaded.'));
    }

    // Reserve a little headroom for the response itself, not just the
    // prompt — a prompt that exactly fills the budget still crashes once
    // decoding tries to emit a first output token.
    const responseReserve = 64;
    final estimatedPromptTokens = (prompt.length / 3.6).ceil();
    if (estimatedPromptTokens + responseReserve > _maxTokens) {
      return Future.error(StateError(
        'Prompt is too long for this session\'s budget: ~$estimatedPromptTokens '
        'tokens against a $_maxTokens-token limit set at load. Reload with a '
        'higher maxTokens, or shorten the prompt (fewer/shorter retrieved '
        'chunks) — sending it as-is would crash the process rather than '
        'fail cleanly.',
      ));
    }

    _queueDepth++;
    _notify();

    final completer = Completer<LlmGeneration>();
    _lock = _lock.then((_) async {
      _queueDepth--;
      _isGenerating = true;
      _notify();

      final lease = ledger.begin(
        _backend == LlmBackend.gpu ? ComputeHardware.gpu : ComputeHardware.cpu,
        'mediapipe',
        evidence: 'mediapipe load succeeded on ${_backend?.name}',
      );
      final stopwatch = Stopwatch()..start();
      try {
        final result = await _channel.invokeMapMethod<String, dynamic>(
          'generate',
          {'prompt': prompt, 'maxTokens': ?maxTokens},
        );
        stopwatch.stop();

        final generation = LlmGeneration(
          text: (result?['text'] as String?) ?? '',
          elapsedMs: stopwatch.elapsedMilliseconds,
          tokens: (result?['tokens'] as num?)?.toInt(),
        );
        onGeneration?.call(stopwatch.elapsedMicroseconds);
        completer.complete(generation);
      } catch (e, st) {
        stopwatch.stop();
        completer.completeError(e, st);
      } finally {
        lease.end();
        _isGenerating = false;
        _notify();
      }
    });
    return completer.future;
  }

  Map<String, dynamic> describe() => {
        'state': _state.name,
        'model': _modelPath == null ? null : modelLabel,
        'path': _modelPath,
        'backend': _backend?.name,
        // Both the guess and the outcome, because they can disagree and the
        // disagreement is the interesting part: "we inferred cpu, it is
        // running on cpu" and "we inferred nothing, it happened to land on
        // cpu" are different amounts of confidence in the same field.
        'suggested_backend': _probe?.suggestedBackend.name,
        'load_ms': _loadMs,
        'max_tokens': _maxTokens,
        'format': _probe?.format.name,
        'size_bytes': _probe?.sizeBytes,
        if (_error != null) 'error': _error,
      };

  @override
  void dispose() {
    // Not unload(): that method awaits the channel's `close` before calling
    // _notify(), and dispose() cannot await. Without the flag, that
    // notification would still fire once the round-trip completes — after
    // super.dispose() below has already run — and ChangeNotifier throws on a
    // disposed instance. Setting _disposed first makes _notify() a no-op by
    // the time that happens, so the teardown below is fire-and-forget.
    _disposed = true;
    unawaited(_channel.invokeMethod<void>('close').catchError((_) {}));
    super.dispose();
  }
}
