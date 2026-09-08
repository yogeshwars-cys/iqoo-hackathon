/// embedding_service.dart
///
/// Wraps a TFLite export of all-MiniLM-L6-v2 for on-device embedding
/// generation.
///
/// WHY TFLite INSTEAD OF RAW ONNX RUNTIME MOBILE: tflite_flutter is a
/// mature, actively maintained plugin with prebuilt Android/iOS native
/// binaries and a direct NNAPI delegate path to the Snapdragon NPU/HTP.
/// Wiring raw ONNX Runtime Mobile into Flutter means writing your own
/// platform channel around the Android AAR — solvable, but not a
/// solve-it-before-lunch problem on hour 6 of a 30-hour build.
///
/// THREE THINGS THIS FILE REFUSES TO ASSUME, each because assuming it
/// produced a silent wrong answer during model prep:
///
///  1. Input ORDER. `runForMultipleInputs` feeds `inputs[i]` to input
///     tensor `i`, and the exporter does not promise that order matches
///     the ONNX signature — our own export lists the signature as
///     (attention_mask, input_ids, token_type_ids) while the tensor
///     indices are (input_ids, attention_mask, token_type_ids). Getting
///     this backwards embeds the attention mask as if it were token ids
///     and still returns a perfectly plausible-looking vector. So we map
///     tensors to roles by NAME at load time.
///
///  2. Input DTYPE. tflite_flutter's ByteConversionUtils writes int32
///     with Endian.little but int64 with Endian.big. On ARM that means an
///     int64 model receives byte-swapped tokens and embeds garbage, with
///     no error anywhere. We therefore require int32 inputs and fail loudly
///     if the bundled model has any other integer type.
///
///  3. That the model works at all. A delegate can load fine and then
///     emit NaN (the dynamic-range-quantized export of this very model
///     does exactly that). `load()` runs a smoke test and falls back from
///     NNAPI to CPU if the accelerated path misbehaves.
///
/// See modelprep/ for the export and verification scripts that produced
/// the bundled .tflite.

library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'tokenizer.dart';

abstract class EmbeddingService {
  Future<void> load({required String vocabText});
  Future<Float32List> embed(String text);

  /// Dimensionality of the vectors [embed] returns, read from the model.
  int get embeddingDim;

  /// Which execution path actually ended up running ("NNAPI" or "CPU"),
  /// for display in the UI — knowing this matters when timing the demo.
  String get backend;

  void close();
}

/// The three tensors a BERT-family encoder expects, as role indices.
const int _roleIds = 0;
const int _roleMask = 1;
const int _roleTypes = 2;

/// Execution paths [MiniLMEmbeddingService] knows how to try.
///
/// Measured on a realme RMX3660 (Snapdragon 695, Android 14), 256 tokens:
///   xnnpack   224 ms
///   cpu      2782 ms
///   gpu      unavailable — the interpreter refuses to build with the
///            delegate attached (throws, so it degrades cleanly)
///   nnapi    unavailable (LiteRT 1.4.0 has largely moved past NNAPI)
///
/// XNNPACK is worth more than an order of magnitude here, so plain [cpu]
/// exists only as a fallback.
///
/// [xnnpack] must never be combined with [XNNPackDelegateOptions]: that class
/// calloc's a zeroed TfLiteXNNPackDelegateOptions instead of calling TFLite's
/// TfLiteXNNPackDelegateOptionsDefault(), so required fields are left invalid
/// and TfLiteXNNPackDelegateCreateWithThreadpool dereferences a null pointer.
/// That is a SIGSEGV in native code, which Dart cannot catch — it kills the
/// app at startup. Passing no options uses TFLite's own defaults and is safe.
///
/// This is why backends are an explicit opt-in list rather than something the
/// service probes on its own: a native crash in a probe is unrecoverable, so
/// an untested delegate must never be on the default path.
enum EmbeddingBackend { cpu, xnnpack, gpu, nnapi }

class MiniLMEmbeddingService implements EmbeddingService {
  final String modelAssetPath;

  /// Backends [load] will try, in order of preference. Read
  /// [EmbeddingBackend] before adding to this list: an untested delegate can
  /// take the whole app down with a native crash.
  final List<EmbeddingBackend> backendsToTry;

  /// When false (the default), [load] stops at the first backend that works,
  /// which keeps startup to roughly two inferences. Set true to build and
  /// time every entry in [backendsToTry] and keep the fastest — that is how
  /// the numbers in [EmbeddingBackend] were obtained, but it costs two
  /// inferences per candidate, and a CPU-path measurement alone is ~6 s.
  final bool benchmarkAllBackends;

  /// CPU threads, used only on the plain CPU path.
  final int threads;

  Interpreter? _interpreter;
  Tokenizer? _tokenizer;
  List<Delegate> _ownedDelegates = const [];

  int _seqLen = 0;
  int _dim = 0;
  bool _outputIsPooled = false;
  List<int> _roleOfInput = const [];
  String _backend = 'not loaded';
  String _backendReport = '';

  MiniLMEmbeddingService({
    this.modelAssetPath = 'assets/models/minilm_l6_v2.tflite',
    this.backendsToTry = const [
      EmbeddingBackend.xnnpack,
      EmbeddingBackend.cpu,
    ],
    this.benchmarkAllBackends = false,
    this.threads = 4,
  });

  @override
  int get embeddingDim => _dim;

  @override
  String get backend => _backend;

  /// Token window the model was exported with. The tokenizer pads to this.
  int get sequenceLength => _seqLen;

  /// Per-backend timings measured at [load], e.g.
  /// "XNNPACK 640 ms · CPU 2936 ms · GPU unavailable · NNAPI unavailable".
  String get backendReport => _backendReport;

  /// Microseconds the native interpreter spent inside the last [embed] call.
  /// Worth surfacing next to wall-clock time: the gap between the two is
  /// Dart-side overhead, and comparing them is how the output-marshalling
  /// cost in [_embedSync] was found.
  int get lastInferenceMicros =>
      _interpreter?.lastNativeInferenceDurationMicroSeconds ?? 0;

  /// [vocabText] is the raw contents of the model's vocab.txt. Load it in
  /// your UI/app layer with `await rootBundle.loadString('assets/models/vocab.txt')`
  /// and pass it in here — kept out of this file so the embedding service
  /// itself has no Flutter-widget-layer dependency and is easy to unit test.
  @override
  Future<void> load({required String vocabText}) async {
    final candidates =
        <String, InterpreterOptions Function(List<Delegate> owned)>{
      for (final backend in backendsToTry)
        switch (backend) {
          EmbeddingBackend.cpu => 'CPU',
          EmbeddingBackend.xnnpack => 'XNNPACK',
          EmbeddingBackend.gpu => 'GPU',
          EmbeddingBackend.nnapi => 'NNAPI',
        }: switch (backend) {
            EmbeddingBackend.cpu => (_) =>
                InterpreterOptions()..threads = threads,
            // Deliberately no XNNPackDelegateOptions — see EmbeddingBackend.
            EmbeddingBackend.xnnpack => (owned) {
                final d = XNNPackDelegate();
                owned.add(d);
                return InterpreterOptions()..addDelegate(d);
              },
            EmbeddingBackend.gpu => (owned) {
                final d = GpuDelegateV2();
                owned.add(d);
                return InterpreterOptions()..addDelegate(d);
              },
            EmbeddingBackend.nnapi => (_) =>
                InterpreterOptions()..useNnApiForAndroid = true,
          },
    };

    final report = <String, String>{};
    Interpreter? best;
    var bestOwned = <Delegate>[];
    var bestMicros = 1 << 62;

    for (final entry in candidates.entries) {
      final owned = <Delegate>[];
      Interpreter? candidate;
      try {
        candidate = await Interpreter.fromAsset(modelAssetPath,
            options: entry.value(owned));
        _adopt(candidate, vocabText);
        final micros = _benchmark();
        report[entry.key] = '${(micros / 1000).round()} ms';
        // Logged per candidate so a later one crashing the process still
        // leaves the earlier measurements in logcat.
        // ignore: avoid_print
        print('[vault] backend ${entry.key}: ${(micros / 1000).round()} ms');

        if (micros < bestMicros) {
          _release(best, bestOwned);
          bestMicros = micros;
          best = candidate;
          bestOwned = owned;
          _backend = entry.key;
        } else {
          _release(candidate, owned);
        }
      } catch (e) {
        report[entry.key] = 'unavailable';
        // ignore: avoid_print
        print('[vault] backend ${entry.key}: unavailable ($e)');
        _release(candidate, owned);
      }
      _interpreter = null;
      if (best != null && !benchmarkAllBackends) break;
    }

    if (best == null) {
      throw StateError('Could not initialise the embedding model on any '
          'backend.\n${report.entries.map((e) => '${e.key}: ${e.value}').join('\n')}');
    }

    _interpreter = best;
    _ownedDelegates = bestOwned;
    _backendReport =
        report.entries.map((e) => '${e.key} ${e.value}').join(' · ');
  }

  void _release(Interpreter? interpreter, List<Delegate> delegates) {
    // Order matters: the interpreter still references its delegates.
    try {
      interpreter?.close();
    } catch (_) {
      // Already gone; nothing useful left to do.
    }
    for (final d in delegates) {
      try {
        d.delete();
      } catch (_) {
        // Same.
      }
    }
  }

  /// Introspects [it], wires up role mapping, and builds the tokenizer to
  /// match the model's own sequence length.
  void _adopt(Interpreter it, String vocabText) {
    final inputs = it.getInputTensors();
    final outputs = it.getOutputTensors();
    if (outputs.isEmpty) {
      throw StateError('Model exposes no output tensors.');
    }

    // --- 1. inputs: role by name, never by position -----------------------
    final roles = List<int>.filled(inputs.length, -1);
    for (var i = 0; i < inputs.length; i++) {
      final name = inputs[i].name.toLowerCase();
      // Order matters: "token_type_ids" also contains "ids".
      if (name.contains('token_type')) {
        roles[i] = _roleTypes;
      } else if (name.contains('attention') || name.contains('mask')) {
        roles[i] = _roleMask;
      } else if (name.contains('ids') || name.contains('input')) {
        roles[i] = _roleIds;
      }
    }
    final resolved = roles.toSet();
    if (inputs.length != 3 ||
        !resolved.containsAll({_roleIds, _roleMask, _roleTypes})) {
      if (inputs.length != 3) {
        throw StateError('Expected 3 input tensors, found ${inputs.length}: '
            '${inputs.map((t) => t.name).join(', ')}');
      }
      // Names were unhelpful but the arity is right — fall back to the
      // conventional ONNX order and say so, rather than failing outright.
      for (var i = 0; i < 3; i++) {
        roles[i] = i;
      }
    }
    _roleOfInput = roles;

    // --- 2. dtype: int32 only (see file header, point 2) ------------------
    for (final t in inputs) {
      if (t.type != TensorType.int32) {
        throw StateError(
            'Input "${t.name}" has type ${t.type}, but this app requires '
            'int32 inputs: tflite_flutter writes int64 tensors big-endian '
            'while int32 goes out little-endian, so an int64 model receives '
            'byte-swapped tokens on ARM and embeds garbage silently. '
            'Re-export with int32 inputs (modelprep/fix_onnx.py does this).');
      }
    }

    final idsShape = inputs[roles.indexOf(_roleIds)].shape;
    _seqLen = idsShape.last;
    if (_seqLen < 8) {
      throw StateError('Input sequence length is $_seqLen (shape $idsShape). '
          'The model was probably exported with a dynamic sequence axis that '
          'collapsed to 1 — re-export with a static shape.');
    }

    // --- 3. output: token-level or already pooled -------------------------
    final outShape = outputs.first.shape;
    if (outShape.length == 3) {
      _outputIsPooled = false;
      _dim = outShape[2];
    } else if (outShape.length == 2) {
      // Some export paths bake mean pooling in; then there is nothing to
      // pool and we only L2-normalize. implementation.md flags this case.
      _outputIsPooled = true;
      _dim = outShape[1];
    } else {
      throw StateError('Unexpected output rank ${outShape.length} '
          '(shape $outShape); expected [1, seq, dim] or [1, dim].');
    }

    _tokenizer = Tokenizer.fromVocabText(vocabText, maxLen: _seqLen);
    _interpreter = it;
  }

  /// Times one inference and checks the result is a finite unit vector.
  ///
  /// Doubles as the smoke test: it catches the failure mode where a delegate
  /// loads happily and then returns NaN for every token, which is exactly
  /// what the dynamic-range-quantized export of this model does.
  ///
  /// Returns the native inference time in microseconds, measured on a second
  /// run so lazy allocation on the first does not skew the comparison.
  int _benchmark() {
    _embedSync('vault retrieval smoke test');
    final v = _embedSync('vault retrieval smoke test');

    var normSq = 0.0;
    for (final x in v) {
      if (!x.isFinite) {
        throw StateError('Model returned non-finite values '
            '(NaN/Inf) — this backend is unusable.');
      }
      normSq += x * x;
    }
    if ((math.sqrt(normSq) - 1.0).abs() > 1e-3) {
      throw StateError('Embedding is not unit length '
          '(norm=${math.sqrt(normSq).toStringAsFixed(4)}).');
    }
    return _interpreter!.lastNativeInferenceDurationMicroSeconds;
  }

  @override
  Future<Float32List> embed(String text) async => _embedSync(text);

  Float32List _embedSync(String text) {
    final interpreter = _interpreter;
    final tokenizer = _tokenizer;
    if (interpreter == null || tokenizer == null) {
      throw StateError('Call load() before embed().');
    }

    final enc = tokenizer.encode(text);
    final byRole = [enc.inputIds, enc.attentionMask, enc.tokenTypeIds];
    final inputs = List<Object>.generate(
      _roleOfInput.length,
      (i) => [byRole[_roleOfInput[i]]],
    );

    interpreter.runInference(inputs);

    // Read the output tensor's native buffer directly instead of going
    // through runForMultipleInputs.
    //
    // That convenience method calls Tensor.copyTo, which materialises the
    // [1, 256, 384] output as a nested Dart List of ~98,000 *boxed* doubles
    // and then deep-copies it into a second, equally boxed structure — every
    // single call. On a mid-range phone that marshalling cost several times
    // more than the inference itself: a single query embedding took ~2.8 s,
    // of which the model was a small fraction.
    //
    // Tensor.data is a zero-copy view of the native buffer, so viewing it as
    // Float32List and pooling over that touches no boxed doubles at all.
    final raw = interpreter.getOutputTensors().first.data;
    final values =
        raw.buffer.asFloat32List(raw.offsetInBytes, raw.lengthInBytes ~/ 4);

    if (_outputIsPooled) return _normalize(values);
    return _meanPoolAndNormalize(values, enc.attentionMask);
  }

  /// [tokenEmbeddings] is the flat [seq * dim] output buffer, row-major:
  /// token `i`'s vector occupies `[i * dim, (i + 1) * dim)`.
  Float32List _meanPoolAndNormalize(
    Float32List tokenEmbeddings,
    List<int> attentionMask,
  ) {
    final pooled = Float64List(_dim);
    var validTokens = 0;

    for (var i = 0; i < attentionMask.length; i++) {
      if (attentionMask[i] == 0) continue;
      validTokens++;
      final base = i * _dim;
      for (var d = 0; d < _dim; d++) {
        pooled[d] += tokenEmbeddings[base + d];
      }
    }
    if (validTokens == 0) validTokens = 1;
    for (var d = 0; d < _dim; d++) {
      pooled[d] /= validTokens;
    }
    return _normalize(pooled);
  }

  Float32List _normalize(List<double> v) {
    var normSq = 0.0;
    for (var d = 0; d < _dim; d++) {
      normSq += v[d] * v[d];
    }
    final norm = normSq > 0 ? math.sqrt(normSq) : 1.0;

    final out = Float32List(_dim);
    for (var d = 0; d < _dim; d++) {
      out[d] = v[d] / norm;
    }
    return out;
  }

  @override
  void close() {
    _release(_interpreter, _ownedDelegates);
    _interpreter = null;
    _ownedDelegates = const [];
  }
}
