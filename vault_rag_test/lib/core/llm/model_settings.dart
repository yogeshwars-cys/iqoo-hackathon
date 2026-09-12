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

  const ModelSettings({this.modelPath, this.autoLoad = false});

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
      );
    } catch (_) {
      return empty;
    }
  }

  Future<void> save(String documentsPath) async {
    try {
      await _file(documentsPath).writeAsString(
        jsonEncode({'model_path': modelPath, 'auto_load': autoLoad}),
      );
    } catch (_) {
      // Non-fatal: the choice just will not survive this session.
    }
  }

  ModelSettings copyWith({String? modelPath, bool? autoLoad}) =>
      ModelSettings(
        modelPath: modelPath ?? this.modelPath,
        autoLoad: autoLoad ?? this.autoLoad,
      );
}
