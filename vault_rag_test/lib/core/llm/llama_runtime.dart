/// llama_runtime.dart
///
/// Dart side of the `vault/llama` channel: loads a GGUF model through
/// llama.cpp (vendored as a pinned submodule, built from source by Gradle —
/// see android/app/src/main/cpp/CMakeLists.txt) and runs one generation at a
/// time.
///
/// ALONGSIDE [LlmRuntime], NOT INSTEAD OF IT
///
/// `vault/llm` (MediaPipe/Gemma) stays the proven fallback throughout this
/// build-out — confirmed working end to end on the iQOO 15 before this file
/// existed. This is the GGUF/Qwen3/SmolLM2/multi-backend path the PocketRAG
/// plan asks for, developed next to it, not over it.
///
/// WHY THIS HAS NO GPU/CPU FALLBACK ORDERING, UNLIKE [LlmRuntime.load]
///
/// [LlmRuntime.load] spends a long comment on why an ambiguous MediaPipe
/// model file must try CPU before GPU: handing CPU-quantised weights to the
/// GPU backend there is a silent, uncatchable native crash, so the *order*
/// of the fallback list is a safety property. GGUF does not split that way —
/// one file, one set of weights, and [LlamaBackend] selects a specific
/// `ggml_backend_dev_t` by name on the native side (vault_llama_jni.cpp's
/// `select_device`) rather than guessing a quantisation target from a
/// filename. Asking for a device this build doesn't have is a clean,
/// catchable `LOAD_FAILED` — never a process death — so there is nothing here
/// for an ordered fallback to protect against.

library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('vault/llama');

enum LlamaBackend { cpu, gpu, npu }

extension LlamaBackendLabel on LlamaBackend {
  String get label => switch (this) {
        LlamaBackend.cpu => 'CPU',
        LlamaBackend.gpu => 'GPU',
        LlamaBackend.npu => 'NPU',
      };
}

enum LlamaState { unloaded, loading, ready, failed }

class LlamaGeneration {
  final String text;
  final int tokens;

  /// Prompt-processing time, from the native `ggml_time_us()` clock —
  /// directly comparable across backends since it excludes JNI/method-channel
  /// marshalling overhead.
  final int prefillMs;

  /// Decode-loop time, same clock.
  final int decodeMs;

  const LlamaGeneration({
    required this.text,
    required this.tokens,
    required this.prefillMs,
    required this.decodeMs,
  });

  double? get tokensPerSecond =>
      (tokens <= 0 || decodeMs <= 0) ? null : tokens * 1000 / decodeMs;

  Map<String, dynamic> toJson() => {
        'text': text,
        'tokens': tokens,
        'prefill_ms': prefillMs,
        'decode_ms': decodeMs,
        if (tokensPerSecond != null)
          'tokens_per_second': double.parse(tokensPerSecond!.toStringAsFixed(2)),
      };
}

class LlamaRuntime extends ChangeNotifier {
  /// Same purpose as [LlmRuntime.onGeneration]: feeds the telemetry screen's
  /// duty-cycle lane. A callback rather than an import, for the same reason
  /// documented there — core/ stays free of a dependency on telemetry/.
  void Function(int micros)? onGeneration;

  LlamaState _state = LlamaState.unloaded;
  String? _error;
  String? _modelPath;
  LlamaBackend? _backend;
  int _loadMs = 0;
  int _maxTokens = 0;
  bool _isGenerating = false;
  Map<String, dynamic>? _backendStatus;

  Future<void> _lock = Future<void>.value();
  int _queueDepth = 0;

  bool _disposed = false;

  LlamaState get state => _state;
  String? get error => _error;
  String? get modelPath => _modelPath;
  LlamaBackend? get backend => _backend;
  int get loadMs => _loadMs;
  int get maxTokens => _maxTokens;
  bool get isReady => _state == LlamaState.ready;
  bool get isGenerating => _isGenerating;
  int get queueDepth => _queueDepth;

  /// Populated after [load] or [backendStatus] — the runtime's own answer to
  /// "what devices does this build actually see", straight from
  /// `ggml_backend_dev_*`. This is the evidence the PocketRAG plan asks for
  /// ("record proof from the runtime... never report GPU/NPU usage unless
  /// the runtime confirms execution"), not a label chosen ahead of time.
  Map<String, dynamic>? get backendStatusSnapshot => _backendStatus;

  String get modelLabel {
    final path = _modelPath;
    if (path == null) return 'none';
    return path.split(RegExp(r'[/\\]')).last;
  }

  /// [notifyListeners] that tolerates being called after disposal. Same
  /// idiom, same reason, as `VaultEngine._notify` / `LlmRuntime._notify`.
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// Queries the native backend registry without loading a model — lets the
  /// UI show which of CPU/GPU/NPU this exact build actually has before the
  /// user picks one, rather than discovering it only at load time.
  Future<Map<String, dynamic>> backendStatus() async {
    final result =
        await _channel.invokeMapMethod<String, dynamic>('backendStatus');
    _backendStatus = result;
    _notify();
    return result ?? const {};
  }

  Future<bool> load(
    String path, {
    required LlamaBackend backend,
    int nCtx = 4096,
    double temperature = 0.2,
    int topK = 40,
  }) async {
    _state = LlamaState.loading;
    _error = null;
    _notify();

    final stopwatch = Stopwatch()..start();
    try {
      final status = await _channel.invokeMapMethod<String, dynamic>('load', {
        'path': path,
        'device': backend.name,
        'nCtx': nCtx,
        'temperature': temperature,
        'topK': topK,
      });
      stopwatch.stop();

      _modelPath = path;
      _backend = backend;
      _loadMs = stopwatch.elapsedMilliseconds;
      _maxTokens = nCtx;
      _backendStatus = status;
      _state = LlamaState.ready;
      _error = null;
      _notify();
      return true;
    } catch (e) {
      stopwatch.stop();
      _state = LlamaState.failed;
      _error = _explain(e);
      _notify();
      return false;
    }
  }

  String _explain(Object e) {
    final s = e.toString();
    if (s.contains('No "npu" device') || s.contains('No "gpu" device')) {
      return s;
    }
    if (s.contains('not enough memory') || s.contains('OOM')) {
      return 'Not enough memory to create a context this size. Try a '
          'smaller nCtx or a smaller model.';
    }
    return s;
  }

  Future<void> unload() async {
    try {
      await _channel.invokeMethod<void>('close');
    } catch (_) {
      // Nothing useful to do if teardown fails; the state is reset anyway.
    }
    _state = LlamaState.unloaded;
    _modelPath = null;
    _backend = null;
    _maxTokens = 0;
    _error = null;
    _notify();
  }

  /// Runs one generation. Queues behind any in flight — same reasoning as
  /// [LlmRuntime.generate]: the underlying session is not safe to drive
  /// concurrently, and a second caller waiting a visible amount of time is
  /// better than a silently corrupted generation.
  Future<LlamaGeneration> generate(String prompt, {int maxTokens = 512}) {
    if (!isReady) {
      return Future.error(StateError('No model loaded.'));
    }

    _queueDepth++;
    _notify();

    final completer = Completer<LlamaGeneration>();
    _lock = _lock.then((_) async {
      _queueDepth--;
      _isGenerating = true;
      _notify();

      try {
        final result = await _channel.invokeMapMethod<String, dynamic>(
          'generate',
          {'prompt': prompt, 'maxTokens': maxTokens},
        );
        final generation = LlamaGeneration(
          text: (result?['text'] as String?) ?? '',
          tokens: (result?['tokens'] as num?)?.toInt() ?? 0,
          prefillMs: (result?['prefill_ms'] as num?)?.toInt() ?? 0,
          decodeMs: (result?['decode_ms'] as num?)?.toInt() ?? 0,
        );
        onGeneration?.call((generation.prefillMs + generation.decodeMs) * 1000);
        completer.complete(generation);
      } catch (e, st) {
        completer.completeError(e, st);
      } finally {
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
        'load_ms': _loadMs,
        'max_tokens': _maxTokens,
        if (_backendStatus != null) 'backend_status': _backendStatus,
        if (_error != null) 'error': _error,
      };

  @override
  void dispose() {
    // Not the full unload(): see LlmRuntime.dispose for why calling
    // through to a method that awaits a channel round-trip and then
    // notifies would race a disposed ChangeNotifier. Fire-and-forget the
    // native teardown instead.
    _disposed = true;
    unawaited(_channel.invokeMethod<void>('close').catchError((_) {}));
    super.dispose();
  }
}
