/// model_settings.dart
///
/// Remembers which model file was chosen, so it survives a relaunch.
///
/// Stored as JSON in app-private storage rather than via a preferences
/// plugin — same reasoning as bridge_settings.dart: two fields do not
/// justify a dependency in a project whose build notes are mostly about
/// dependency resolution.
///
/// The path is remembered, never the file. Copying a 1.3 GB model into app
/// storage would be the more robust option and is not worth the wait or the
/// duplicated gigabyte; if the file moves, [autoLoad] simply finds nothing
/// and the user picks it again.

library;

import 'dart:convert';
import 'dart:io';

class ModelSettings {
  final String? modelPath;

  /// Whether to load the model at startup.
  ///
  /// Defaults to false and has to be turned on deliberately. Loading tens of
  /// seconds of weights on every cold start, when most sessions never ask a
  /// generative question, is the wrong default — retrieval is the fast path
  /// and should stay fast.
  final bool autoLoad;

  /// Same idea as [modelPath], for the llama.cpp/GGUF path — remembered
  /// independently since the two engines are loaded independently (see
  /// llama_runtime.dart's file header for why both exist).
  final String? llamaModelPath;

  /// Stored as the enum name ("cpu" | "gpu" | "npu"); resolved back to
  /// [LlamaBackend] by the caller, which already owns that import — this
  /// file stays free of a dependency on llama_runtime.dart for one string.
  final String? llamaBackend;

  /// Which reasoner is THE reasoner: "llama" (llama.cpp / GGUF) or
  /// "mediapipe" (MediaPipe / Gemma .task). Exactly one runtime is ever
  /// loaded — see reasoner_coordinator.dart — and this is the persisted half
  /// of that invariant: routing in VaultEngine.ask and auto-load at startup
  /// both read it, instead of "whichever happens to be ready".
  ///
  /// Null only in settings files written before the field existed; see
  /// [resolvedActiveReasoner] for how those are interpreted.
  final String? activeReasoner;

  const ModelSettings({
    this.modelPath,
    this.autoLoad = false,
    this.llamaModelPath,
    this.llamaBackend,
    this.activeReasoner,
  });

  /// [activeReasoner], or for a pre-invariant settings file the runtime the
  /// old bootstrap would have auto-loaded (MediaPipe, if a path was saved),
  /// falling back to llama.cpp if only a GGUF path exists. Never guesses a
  /// runtime that has no remembered model.
  String? get resolvedActiveReasoner {
    if (activeReasoner == 'llama' || activeReasoner == 'mediapipe') {
      return activeReasoner;
    }
    if (modelPath != null) return 'mediapipe';
    if (llamaModelPath != null) return 'llama';
    return null;
  }

  static const empty = ModelSettings();

  static File _file(String documentsPath) =>
      File('$documentsPath/model_settings.json');

  static Future<ModelSettings> load(String documentsPath) async {
    try {
      final f = _file(documentsPath);
      if (!await f.exists()) return empty;
      final map = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return ModelSettings(
        modelPath: map['model_path'] as String?,
        autoLoad: (map['auto_load'] as bool?) ?? false,
        llamaModelPath: map['llama_model_path'] as String?,
        llamaBackend: map['llama_backend'] as String?,
        activeReasoner: map['active_reasoner'] as String?,
      );
    } catch (_) {
      return empty;
    }
  }

  Future<void> save(String documentsPath) async {
    try {
      await _file(documentsPath).writeAsString(
        jsonEncode({
          'model_path': modelPath,
          'auto_load': autoLoad,
          'llama_model_path': llamaModelPath,
          'llama_backend': llamaBackend,
          'active_reasoner': activeReasoner,
        }),
      );
    } catch (_) {
      // Non-fatal: the choice just will not survive this session.
    }
  }

  ModelSettings copyWith({
    String? modelPath,
    bool? autoLoad,
    String? llamaModelPath,
    String? llamaBackend,
    String? activeReasoner,
  }) =>
      ModelSettings(
        modelPath: modelPath ?? this.modelPath,
        autoLoad: autoLoad ?? this.autoLoad,
        llamaModelPath: llamaModelPath ?? this.llamaModelPath,
        llamaBackend: llamaBackend ?? this.llamaBackend,
        activeReasoner: activeReasoner ?? this.activeReasoner,
      );
}
