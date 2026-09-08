/// embedding_service.dart
///
/// Wraps a quantized TFLite export of all-MiniLM-L6-v2 for on-device
/// embedding generation.
///
/// WHY TFLite INSTEAD OF RAW ONNX RUNTIME MOBILE: tflite_flutter is a
/// mature, actively maintained plugin with prebuilt Android/iOS native
/// binaries and a direct NNAPI delegate path to the Snapdragon NPU/HTP.
/// Wiring raw ONNX Runtime Mobile into Flutter means writing your own
/// platform channel around the Android AAR — solvable, but not a
/// solve-it-before-lunch problem on hour 6 of a 30-hour build.
///
/// PRE-HACKATHON PREP (do this before the clock starts, not during):
/// 1. Export a quantized all-MiniLM-L6-v2 to .tflite (e.g. via onnx2tf from
///    the HuggingFace ONNX export, or TF/Keras -> TFLiteConverter with
///    int8/dynamic-range quantization).
/// 2. Bundle the resulting .tflite file and the model's vocab.txt as
///    Flutter assets, and register both paths in pubspec.yaml.
/// 3. Run the Android jniLibs install step tflite_flutter requires (see
///    the package README) — this downloads the native TFLite C binaries
///    into android/app/src/main/jniLibs/. Skipping this is the #1 cause
///    of "works on my machine, crashes on the loaner phone."
///
/// This file has NOT been run against a real model in this environment —
/// smoke-test it against your actual .tflite export in the first hour.

import 'dart:math' as math;
import 'dart:typed_data';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'tokenizer.dart';

abstract class EmbeddingService {
  Future<void> load({required String vocabText});
  Future<Float32List> embed(String text);
}

class MiniLMEmbeddingService implements EmbeddingService {
  final String modelAssetPath;
  final int embeddingDim;
  final int maxSeqLen;

  Interpreter? _interpreter;
  Tokenizer? _tokenizer;

  MiniLMEmbeddingService({
    this.modelAssetPath = 'assets/models/minilm_l6_v2_quant.tflite',
    this.embeddingDim = 384,
    this.maxSeqLen = 256,
  });

  /// [vocabText] is the raw contents of the model's vocab.txt. Load it in
  /// your UI/app layer with `await rootBundle.loadString('assets/models/vocab.txt')`
  /// and pass it in here — kept out of this file so the embedding service
  /// itself has no Flutter-widget-layer dependency and is easy to unit test.
  @override
  Future<void> load({required String vocabText}) async {
    final options = InterpreterOptions()..useNnApiForAndroid = true;
    _interpreter = await Interpreter.fromAsset(modelAssetPath, options: options);
    _tokenizer = Tokenizer.fromVocabText(vocabText, maxLen: maxSeqLen);
  }

  @override
  Future<Float32List> embed(String text) async {
    final interpreter = _interpreter;
    final tokenizer = _tokenizer;
    if (interpreter == null || tokenizer == null) {
      throw StateError('Call load() before embed().');
    }

    final enc = tokenizer.encode(text);
    final inputs = [
      [enc.inputIds],
      [enc.attentionMask],
      [enc.tokenTypeIds],
    ];

    // MiniLM's exported graph produces token-level embeddings:
    // shape [1, maxSeqLen, embeddingDim]. Confirm this against your actual
    // .tflite's output signature in hour 1 — export scripts occasionally
    // emit [1, embeddingDim] if pooling was baked in at export time, in
    // which case skip _meanPoolAndNormalize and normalize the raw output.
    final output = List.generate(
      1,
      (_) => List.generate(maxSeqLen, (_) => List<double>.filled(embeddingDim, 0.0)),
    );

    interpreter.runForMultipleInputs(inputs, {0: output});

    return _meanPoolAndNormalize(output[0], enc.attentionMask);
  }

  Float32List _meanPoolAndNormalize(
    List<List<double>> tokenEmbeddings,
    List<int> attentionMask,
  ) {
    final pooled = Float64List(embeddingDim);
    var validTokens = 0;

    for (var i = 0; i < attentionMask.length; i++) {
      if (attentionMask[i] == 0) continue;
      validTokens++;
      final row = tokenEmbeddings[i];
      for (var d = 0; d < embeddingDim; d++) {
        pooled[d] += row[d];
      }
    }
    if (validTokens == 0) validTokens = 1;

    var normSq = 0.0;
    for (var d = 0; d < embeddingDim; d++) {
      pooled[d] /= validTokens;
      normSq += pooled[d] * pooled[d];
    }
    final norm = normSq > 0 ? math.sqrt(normSq) : 1.0;

    final out = Float32List(embeddingDim);
    for (var d = 0; d < embeddingDim; d++) {
      out[d] = pooled[d] / norm;
    }
    return out;
  }

  void close() => _interpreter?.close();
}
