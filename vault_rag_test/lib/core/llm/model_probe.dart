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

/// Which MediaPipe backend a model file was built for.
///
/// This is inferred from the filename, not from the binary format — the file
/// magic only tells you the container (task/bin), not the quantisation target.
/// MediaPipe CPU and GPU int4 weights are the same container format but
/// incompatible tensor layouts. Loading a CPU model on the GPU backend causes
/// a native SIGSEGV that no Kotlin or Dart try/catch can intercept.
enum SuggestedBackend {
  /// Filename contains "-cpu-" or "_cpu_" — load on CPU, never GPU.
  cpu,

  /// Filename contains "-gpu-" or "_gpu_" — try GPU first.
  gpu,

  /// Filename carries no backend token, so we do not know.
  ///
  /// This case is loaded CPU-first, not GPU-first. See the ordering argument
  /// in [LlmRuntime.load]: the fallback loop only rescues *catchable* load
  /// failures, and guessing GPU wrong is not one of them — it is a process
  /// kill with no second attempt. The load page also says out loud that the
  /// backend was guessed, and offers an explicit override.
  unknown,
}

extension SuggestedBackendInfo on SuggestedBackend {
  String get label => switch (this) {
        SuggestedBackend.cpu => 'CPU',
        SuggestedBackend.gpu => 'GPU',
        SuggestedBackend.unknown => '?',
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

  /// Backend inferred from the filename.
  ///
  /// MediaPipe publishes CPU and GPU variants of the same model with the
  /// backend in the filename: `gemma2-2b-it-cpu-int4.task` vs
  /// `gemma-2b-it-gpu-int4.bin`. This field drives backend selection in
  /// [LlmRuntime.load] so a CPU model is never sent through the GPU path.
  final SuggestedBackend suggestedBackend;

  /// [suggestedBackend] is `required` rather than defaulted on purpose.
  ///
  /// It used to default to [SuggestedBackend.unknown], and three of the four
  /// return sites in [probeModel] silently took that default — which is
  /// exactly the value that means "we have no idea, be careful". A safety
  /// field whose default is the uncertain case is a field that gets
  /// forgotten. Making it required turns the next forgotten call site into a
  /// compile error instead of a quietly wrong backend guess.
  const ModelProbeResult({
    required this.path,
    required this.format,
    required this.sizeBytes,
    required this.suggestedBackend,
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

  /// Said before the Load button, not after a crash.
  ///
  /// When the filename carries no backend token there is nothing to infer
  /// from, and the consequence of inferring wrong is a process kill rather
  /// than an error message. The user is the only one here who might actually
  /// know where the file came from, so ask them instead of guessing quietly.
  String? get backendWarning {
    if (!format.isSupported) return null;
    if (suggestedBackend != SuggestedBackend.unknown) return null;
    return 'This filename says nothing about which backend the weights were '
        'built for. MediaPipe ships CPU and GPU builds in the same container, '
        'and handing GPU-quantised weights to the CPU path — or the reverse — '
        'kills the process outright rather than raising an error. CPU is '
        'tried first because it is the recoverable guess. If you know which '
        'build this is, say so below, or rename the file to include -cpu- '
        'or -gpu-.';
  }

  Map<String, dynamic> toJson() => {
        'path': path,
        'format': format.name,
        'label': format.label,
        'size_bytes': sizeBytes,
        'supported': format.isSupported,
        'suggested_backend': suggestedBackend.name,
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

  // Inferred once, up front, and attached to every result below.
  //
  // The backend guess is a pure function of the path string, so it is
  // available even on the paths where the file could not be opened at all.
  // Reporting it there is not academic: "unreadable, and by the way it was a
  // CPU build" is what lets someone fix a permissions problem and load the
  // file without a second round of guessing.
  final backend = _inferBackend(path);

  int size;
  Uint8List head;
  try {
    if (!await file.exists()) {
      return ModelProbeResult(
        path: path,
        format: ModelFormat.unreadable,
        sizeBytes: 0,
        suggestedBackend: backend,
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
      suggestedBackend: backend,
      error: '$e',
    );
  }

  if (head.length < 8) {
    return ModelProbeResult(
      path: path,
      format: ModelFormat.unknown,
      sizeBytes: size,
      magicHex: _hex(head),
      suggestedBackend: backend,
      error: 'File is only ${head.length} bytes.',
    );
  }

  final format = _identify(head);
  return ModelProbeResult(
    path: path,
    format: format,
    sizeBytes: size,
    magicHex: format == ModelFormat.unknown ? _hex(head) : null,
    suggestedBackend: backend,
  );
}

/// Extracts the intended backend from the filename.
///
/// MediaPipe's official Gemma releases embed the backend in the filename:
///   gemma2-2b-it-cpu-int4.task  →  CPU
///   gemma-2b-it-gpu-int4.bin   →  GPU
///
/// The match is against the lowercased basename only, using a word-boundary
/// pattern so an incidental "gpu" inside "gpuinfo" does not trigger a false
/// positive.
///
/// BASENAME ONLY, DELIBERATELY. A directory called `cpu/` says where someone
/// filed the download, not what the converter targeted, and people do keep
/// both builds under one `models/gpu/` tree. Directory names are evidence
/// about the human, not about the tensor layout, so they are ignored.
///
/// CPU WINS WHEN BOTH TOKENS APPEAR. That ordering is a safety property, not
/// an accident of which `if` came first: a name like `gemma-cpu-gpu-int4` is
/// genuinely ambiguous, and the ambiguous case should resolve to the guess
/// whose failure mode is recoverable. Do not reorder these two checks.
SuggestedBackend _inferBackend(String path) {
  final name = path.split(RegExp(r'[\\/]')).last.toLowerCase();

  // Delimiters are symmetric on both sides — `-`, `_` and `.` all separate
  // fields in the names these files actually ship under, so `gemma.cpu.int4`
  // must read the same as `gemma-cpu-int4`. The leading class used to omit
  // `.`, which silently demoted dot-separated names to `unknown`.
  final cpuPat = RegExp(r'(?:^|[-_.])cpu(?:[-_.]|$)');
  final gpuPat = RegExp(r'(?:^|[-_.])gpu(?:[-_.]|$)');
  if (cpuPat.hasMatch(name)) return SuggestedBackend.cpu;
  if (gpuPat.hasMatch(name)) return SuggestedBackend.gpu;
  return SuggestedBackend.unknown;
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
