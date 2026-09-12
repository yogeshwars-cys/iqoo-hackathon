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

  LlmState _state = LlmState.unloaded;
  String? _error;
  String? _modelPath;
  ModelProbeResult? _probe;
  LlmBackend? _backend;
  int _loadMs = 0;
  bool _isGenerating = false;

  /// Serialises generation, and lets a queued caller know it is queued.
  Future<void> _lock = Future<void>.value();
  int _queueDepth = 0;

  LlmState get state => _state;
  String? get error => _error;
  String? get modelPath => _modelPath;
  ModelProbeResult? get probe => _probe;
  LlmBackend? get backend => _backend;
  int get loadMs => _loadMs;
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

  /// Reads the file header and reports what it is, without loading it.
  Future<ModelProbeResult> inspect(String path) async {
    _state = LlmState.probing;
    notifyListeners();

    final result = await probeModel(path);
    _probe = result;
    _state = _state == LlmState.probing ? LlmState.unloaded : _state;
    notifyListeners();
    return result;
  }

  /// Loads [path], trying GPU then CPU.
  ///
  /// Refuses outright when [inspect] says the file is not a MediaPipe
  /// container. That check is cheap and the alternative is expensive: a
  /// wrong format reaches native code and aborts the process, which no Dart
  /// try/catch can intercept.
  Future<bool> load(
    String path, {
    int maxTokens = 1024,
    double temperature = 0.2,
    int topK = 40,
  }) async {
    final probe = await inspect(path);
    if (!probe.isUsable) {
      _state = LlmState.failed;
      _error = probe.format.remedy ??
          'Cannot load a ${probe.format.label} file.';
      notifyListeners();
      return false;
    }

    _state = LlmState.loading;
    _error = null;
    notifyListeners();

    final stopwatch = Stopwatch()..start();
    for (final backend in [LlmBackend.gpu, LlmBackend.cpu]) {
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
        _state = LlmState.ready;
        notifyListeners();
        return true;
      } catch (e) {
        debugPrint('[vault] LLM backend ${backend.name} failed: $e');
        _error = _explain(e, backend);
        // Try CPU next; if that was CPU, fall through to failure.
      }
    }

    stopwatch.stop();
    _state = LlmState.failed;
    notifyListeners();
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
    notifyListeners();
  }

  /// Runs one generation. Queues behind any in flight.
  Future<LlmGeneration> generate(String prompt, {int? maxTokens}) {
    if (!isReady) {
      return Future.error(StateError('No model loaded.'));
    }

    _queueDepth++;
    notifyListeners();

    final completer = Completer<LlmGeneration>();
    _lock = _lock.then((_) async {
      _queueDepth--;
      _isGenerating = true;
      notifyListeners();

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
        _isGenerating = false;
        notifyListeners();
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
        'format': _probe?.format.name,
        'size_bytes': _probe?.sizeBytes,
        if (_error != null) 'error': _error,
      };

  @override
  void dispose() {
    unload();
    super.dispose();
  }
}
