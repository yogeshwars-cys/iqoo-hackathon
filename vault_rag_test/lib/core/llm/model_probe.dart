/// model_probe.dart
///
/// Identifies what a model file on disk actually is, before anything tries
/// to load it.
///
/// WHY SNIFF AT ALL, RATHER THAN TRUST THE EXTENSION
///
/// "Gemma 2B int4" names a set of weights, not a file format, and the same
/// weights ship in at least four containers that are mutually unloadable:
///
///   gemma-2b-it-gpu-int4.bin        MediaPipe, a TFLite flatbuffer
///   gemma2-2b-it-cpu-int4.task      MediaPipe, a zip bundle
///   gemma-2-2b-it-Q4_K_M.gguf       llama.cpp
///   model.safetensors               HuggingFace, needs a full runtime
///
/// Extensions lie — `.bin` is used by three different ecosystems — and the
/// failure mode of guessing wrong is a native crash inside MediaPipe rather
/// than a Dart exception. So the file is read, four magic numbers are
/// checked, and the app tells you what it found and whether it can run it.
///
/// This is all pure Dart on purpose: no platform channel, no MediaPipe, no
/// 1.3 GB load attempt. It answers "is this the right file" in a few
/// milliseconds and a few bytes, which is what you want on a screen where
/// the alternative is a minute of loading and then a crash.

library;

import 'dart:io';
import 'dart:typed_data';

enum ModelFormat {
  /// MediaPipe LLM Inference bundle (`.task`), a zip container.
  mediaPipeTask,

  /// MediaPipe LLM Inference weights (`.bin`), a raw TFLite flatbuffer.
  mediaPipeBin,

  /// llama.cpp quantised weights.
  gguf,

  /// HuggingFace tensor dump — weights only, no runtime graph.
  safetensors,

  /// Read the file, recognised nothing.
  unknown,

  /// Could not read the file at all.
  unreadable,
}

extension ModelFormatInfo on ModelFormat {
  String get label => switch (this) {
        ModelFormat.mediaPipeTask => 'MediaPipe bundle (.task)',
        ModelFormat.mediaPipeBin => 'MediaPipe weights (.bin)',
        ModelFormat.gguf => 'GGUF (llama.cpp)',
        ModelFormat.safetensors => 'safetensors (HuggingFace)',
        ModelFormat.unknown => 'Unrecognised',
        ModelFormat.unreadable => 'Unreadable',
      };

  /// Whether this build can actually run it.
  ///
  /// Only the two MediaPipe containers are supported. That is a deliberate
  /// scope decision, not an oversight: MediaPipe's LLM Inference API ships
  /// a prebuilt Android runtime with a working Adreno GPU path, whereas
  /// GGUF would mean building llama.cpp with the NDK and driving it over
  /// FFI — a project in itself, and CPU-only on this SoC.
  bool get isSupported =>
      this == ModelFormat.mediaPipeTask || this == ModelFormat.mediaPipeBin;

  /// What to do about it, when it is not supported.
  String? get remedy => switch (this) {
        ModelFormat.gguf =>
          'This build runs MediaPipe models only. Convert with the AI Edge '
              'Torch generative converter, or download the .task build of '
              'Gemma from Kaggle / LiteRT Community on HuggingFace.',
        ModelFormat.safetensors =>
          'These are raw weights with no inference graph. Download the '
              'MediaPipe .task build of Gemma instead.',
        ModelFormat.unknown =>
          'No known model magic number at the start of this file. Check it '
              'downloaded completely — a truncated or HTML error-page '
              'download is the usual cause.',
        ModelFormat.unreadable =>
          'The file could not be opened. If it lives under '
              '/data/local/tmp, an app cannot read it on most ROMs; copy it '
              'somewhere in your own storage and pick it again.',
        _ => null,
      };
}

class ModelProbeResult {
  final String path;
  final ModelFormat format;
  final int sizeBytes;

  /// First bytes, hex, for the "unrecognised" case — so a bad download can
  /// be diagnosed from a screenshot.
  final String? magicHex;

  final String? error;

  const ModelProbeResult({
    required this.path,
    required this.format,
    required this.sizeBytes,
    this.magicHex,
    this.error,
  });

  bool get isUsable => format.isSupported && sizeBytes > 0;

  String get sizeLabel {
    if (sizeBytes <= 0) return '—';
    const gb = 1024 * 1024 * 1024;
    const mb = 1024 * 1024;
    if (sizeBytes >= gb) return '${(sizeBytes / gb).toStringAsFixed(2)} GB';
    return '${(sizeBytes / mb).toStringAsFixed(0)} MB';
  }

  /// A plausible-size check. Gemma 2B at int4 lands around 1.3 GB; anything
  /// under a few hundred MB is not a 2B model whatever its magic says, and
  /// is most likely a partial download.
  String? get sizeWarning {
    if (!format.isSupported) return null;
    if (sizeBytes < 300 * 1024 * 1024) {
      return 'Only $sizeLabel — a 2B int4 model is normally 1.2–1.5 GB. '
          'This looks like an incomplete download.';
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'path': path,
        'format': format.name,
        'label': format.label,
        'size_bytes': sizeBytes,
        'supported': format.isSupported,
        if (magicHex != null) 'magic': magicHex,
        if (error != null) 'error': error,
      };
}

/// Reads the first bytes of [path] and identifies the container.
///
/// Synchronous file access is fine here — it opens, reads 16 bytes and
/// closes, and the caller is a button press, not a frame.
Future<ModelProbeResult> probeModel(String path) async {
  final file = File(path);

  int size;
  Uint8List head;
  try {
    if (!await file.exists()) {
      return ModelProbeResult(
        path: path,
        format: ModelFormat.unreadable,
        sizeBytes: 0,
        error: 'No file at this path.',
      );
    }
    size = await file.length();
    final handle = await file.open();
    try {
      head = await handle.read(16);
    } finally {
      await handle.close();
    }
  } catch (e) {
    return ModelProbeResult(
      path: path,
      format: ModelFormat.unreadable,
      sizeBytes: 0,
      error: '$e',
    );
  }

  if (head.length < 8) {
    return ModelProbeResult(
      path: path,
      format: ModelFormat.unknown,
      sizeBytes: size,
      magicHex: _hex(head),
      error: 'File is only ${head.length} bytes.',
    );
  }

  final format = _identify(head);
  return ModelProbeResult(
    path: path,
    format: format,
    sizeBytes: size,
    magicHex: format == ModelFormat.unknown ? _hex(head) : null,
  );
}

ModelFormat _identify(Uint8List head) {
  // GGUF: magic at offset 0.
  if (_matches(head, 0, 'GGUF')) return ModelFormat.gguf;

  // Zip local file header — MediaPipe .task bundles are zips. "PK\x03\x04".
  if (head[0] == 0x50 && head[1] == 0x4B && head[2] == 0x03 && head[3] == 0x04) {
    return ModelFormat.mediaPipeTask;
  }

  // TFLite flatbuffer: the file identifier sits at offset 4, after the root
  // table offset. MediaPipe's .bin LLM weights are exactly this.
  if (_matches(head, 4, 'TFL3')) return ModelFormat.mediaPipeBin;

  // safetensors: an 8-byte little-endian header length, then JSON. The
  // length is always small relative to the file and the next byte is '{'.
  final headerLength = ByteData.sublistView(head).getUint64(0, Endian.little);
  if (headerLength > 0 && headerLength < 100 * 1024 * 1024 && head[8] == 0x7B) {
    return ModelFormat.safetensors;
  }

  return ModelFormat.unknown;
}

bool _matches(Uint8List bytes, int offset, String ascii) {
  if (bytes.length < offset + ascii.length) return false;
  for (var i = 0; i < ascii.length; i++) {
    if (bytes[offset + i] != ascii.codeUnitAt(i)) return false;
  }
  return true;
}

String _hex(Uint8List bytes) => bytes
    .take(12)
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join(' ');
