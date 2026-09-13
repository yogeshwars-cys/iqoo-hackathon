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

import 'compute_ledger.dart';
import 'qnn/qnn_acceptance.dart';
import 'qnn/qnn_htp_delegate.dart';
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
///
/// [qnnHtp] is Qualcomm's QNN HTP delegate on the Hexagon NPU (V81 on the
/// iQOO 15's SM8850). It is on the default path only because it is never
/// trusted on creation: [MiniLMEmbeddingService.load] accepts it solely after
/// the coverage / equivalence / latency checks in qnn_acceptance.dart, and
/// otherwise releases it and continues down the list.
enum EmbeddingBackend { cpu, xnnpack, gpu, nnapi, qnnHtp }

/// The three outcomes the UI and capsules may report for the encoder's
/// accelerator. Derived from what the delegate did, never from branding.
enum AcceleratorVerdict {
  /// QNN delegate created AND passed coverage, equivalence and latency.
  qnnHtpVerified('QNN HTP verified'),

  /// QNN could not be created or failed its smoke test on this device/build.
  qnnUnavailable('QNN unavailable'),

  /// QNN ran but was rejected by validation; XNNPACK serves instead.
  xnnpackFallback('XNNPACK fallback'),

  /// qnnHtp was not in the backend list (e.g. a benchmark probe).
  notAttempted('QNN not attempted');

  final String label;
  const AcceleratorVerdict(this.label);
}

class EmbeddingAcceleratorStatus {
  final AcceleratorVerdict verdict;

  /// The backend actually serving embeddings ("QNN HTP", "XNNPACK", "CPU").
  final String activeBackend;
  final String? detail;
  final QnnDecision? decision;
  final QnnDelegationReport? delegation;
  final QnnEnvironment? environment;

  const EmbeddingAcceleratorStatus({
    required this.verdict,
    required this.activeBackend,
    this.detail,
    this.decision,
    this.delegation,
    this.environment,
  });

  static const initial = EmbeddingAcceleratorStatus(
    verdict: AcceleratorVerdict.notAttempted,
    activeBackend: 'not loaded',
  );

  /// Hardware the encoder may be attributed to. NPU only when verified.
  ComputeHardware get hardware => switch (activeBackend) {
        'QNN HTP' when verdict == AcceleratorVerdict.qnnHtpVerified =>
          ComputeHardware.npu,
        'GPU' => ComputeHardware.gpu,
        _ => ComputeHardware.cpu,
      };

  String get label => verdict == AcceleratorVerdict.notAttempted
      ? activeBackend
      : verdict.label;

  EmbeddingAcceleratorStatus withActiveBackend(String backend) =>
      EmbeddingAcceleratorStatus(
        verdict: verdict,
        activeBackend: backend,
        detail: detail,
        decision: decision,
        delegation: delegation,
        environment: environment,
      );

  Map<String, dynamic> toJson() => {
        'verdict': verdict.name,
        'label': label,
        'active_backend': activeBackend,
        'hardware': hardware.name,
        if (detail != null) 'detail': detail,
        if (decision != null) 'decision': decision!.toJson(),
        if (delegation != null) 'delegation': delegation!.toJson(),
        if (environment != null) 'environment': environment!.toJson(),
      };
}

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

  /// Called after every inference with the time the native interpreter
  /// actually spent, in microseconds.
  ///
  /// A callback rather than a direct dependency on the telemetry layer, so
  /// core/ stays importable on its own and unit-testable without a running
  /// sampler. The app wires this to `InferenceMeter.record`.
  ///
  /// Deliberately fed from `lastNativeInferenceDurationMicroSeconds` and not
  /// a Dart-side Stopwatch: the gap between the two is marshalling overhead,
  /// and attributing that to the accelerator would inflate the duty-cycle
  /// lane on the stats screen with time the model never ran for.
  void Function(int micros)? onInference;

  /// Receives a lease per inference on [acceleratorStatus]'s hardware — NPU
  /// only after QNN HTP was verified. See compute_ledger.dart.
  ComputeLedger ledger = const NullComputeLedger();

  /// Device hooks for QNN; injectable so the accept/reject flow is testable.
  final QnnPlatform qnnPlatform;
  final QnnAcceptanceCriteria qnnCriteria;

  EmbeddingAcceleratorStatus _status = EmbeddingAcceleratorStatus.initial;

  /// What the encoder is running on and why — "QNN HTP verified",
  /// "QNN unavailable" or "XNNPACK fallback", with the evidence.
  EmbeddingAcceleratorStatus get acceleratorStatus => _status;

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
      EmbeddingBackend.qnnHtp,
      EmbeddingBackend.xnnpack,
      EmbeddingBackend.cpu,
    ],
    this.benchmarkAllBackends = false,
    this.threads = 4,
    this.qnnPlatform = const AndroidQnnPlatform(),
    this.qnnCriteria = const QnnAcceptanceCriteria(),
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
    final report = <String, String>{};
    Interpreter? best;
    var bestOwned = <Delegate>[];
    var bestMicros = 1 << 62;
    _status = EmbeddingAcceleratorStatus.initial;

    // QNN first, when listed: accepted only through [_tryQnn]'s validation.
    final wantsQnn = backendsToTry.contains(EmbeddingBackend.qnnHtp);
    if (wantsQnn) {
      final qnn = await _tryQnn(vocabText, report);
      if (qnn != null) {
        best = qnn.interpreter;
        bestOwned = qnn.owned;
        bestMicros = qnn.micros;
        _backend = 'QNN HTP';
      }
      _interpreter = null;
    }

    final candidates =
        <String, InterpreterOptions Function(List<Delegate> owned)>{
      for (final backend
          in backendsToTry.where((b) => b != EmbeddingBackend.qnnHtp))
        switch (backend) {
          EmbeddingBackend.cpu => 'CPU',
          EmbeddingBackend.xnnpack => 'XNNPACK',
          EmbeddingBackend.gpu => 'GPU',
          EmbeddingBackend.nnapi => 'NNAPI',
          EmbeddingBackend.qnnHtp => 'QNN HTP',
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
            // Filtered out above; handled by _tryQnn.
            EmbeddingBackend.qnnHtp => (_) => InterpreterOptions(),
          },
    };

    for (final entry in candidates.entries) {
      if (best != null && !benchmarkAllBackends) break;
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
    _status = _status.withActiveBackend(_backend);
    _backendReport =
        report.entries.map((e) => '${e.key} ${e.value}').join(' · ');
  }

  /// Builds a QNN HTP interpreter and keeps it only if it passes validation
  /// against an XNNPACK reference. Returns null (with [_status] explaining
  /// why) when QNN is unavailable or rejected; the caller then continues
  /// down [backendsToTry], so a QNN failure always lands on XNNPACK/CPU.
  Future<({Interpreter interpreter, List<Delegate> owned, int micros})?>
      _tryQnn(String vocabText, Map<String, String> report) async {
    QnnEnvironment? env;
    final owned = <Delegate>[];
    Interpreter? qnn;
    final since = DateTime.now();
    try {
      env = await qnnPlatform.environment();
      owned.add(qnnPlatform.createDelegate(env));
      qnn = await Interpreter.fromAsset(modelAssetPath,
          options: InterpreterOptions()..addDelegate(owned.single));
      _adopt(qnn, vocabText);
      _benchmark(); // finite / unit-vector smoke test; throws if invalid
    } catch (e) {
      _release(qnn, owned);
      _interpreter = null;
      final reason = e is QnnUnavailableException ? e.reason : '$e'.split('\n').first;
      report['QNN HTP'] = 'unavailable';
      // tflite_flutter only says "Unable to create interpreter"; the actual
      // cause is in the delegate's own log, captured for remote diagnosis.
      QnnDelegationReport? log;
      if (env != null) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        log = await qnnPlatform.delegationReport(since);
      }
      _status = EmbeddingAcceleratorStatus(
        verdict: AcceleratorVerdict.qnnUnavailable,
        activeBackend: 'not loaded',
        detail: reason,
        delegation: log,
        environment: env,
      );
      // ignore: avoid_print
      print('[vault] QNN HTP unavailable: $reason');
      return null;
    }

    // Reference: XNNPACK, independent of backendsToTry, so even a QNN-only
    // probe is validated rather than trusted.
    final refOwned = <Delegate>[];
    Interpreter? reference;
    QnnDecision decision;
    QnnDelegationReport delegation = QnnDelegationReport.missing;
    try {
      final x = XNNPackDelegate();
      refOwned.add(x);
      reference = await Interpreter.fromAsset(modelAssetPath,
          options: InterpreterOptions()..addDelegate(x));

      // The delegate logs its partition report while the interpreter is
      // built; give logd a moment to flush before reading it back.
      for (var attempt = 0; attempt < 3 && !delegation.found; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        delegation = await qnnPlatform.delegationReport(since);
      }

      final texts = [...qnnValidationPassages, ...qnnValidationQueries];
      final qnnVectors = [for (final t in texts) _embedWith(qnn, t)];
      final refVectors = [for (final t in texts) _embedWith(reference, t)];

      final qnnMs = <double>[], refMs = <double>[];
      for (var i = 0; i < 7; i++) {
        // Interleaved so both see the same thermal / governor state.
        _embedWith(qnn, qnnValidationPassages.first);
        qnnMs.add(qnn.lastNativeInferenceDurationMicroSeconds / 1000);
        _embedWith(reference, qnnValidationPassages.first);
        refMs.add(reference.lastNativeInferenceDurationMicroSeconds / 1000);
      }

      decision = decideQnn(
        QnnValidationEvidence(
          delegation: delegation,
          qnnVectors: qnnVectors,
          referenceVectors: refVectors,
          passageCount: qnnValidationPassages.length,
          qnnLatencyMs: qnnMs,
          referenceLatencyMs: refMs,
        ),
        criteria: qnnCriteria,
      );
    } catch (e) {
      _release(reference, refOwned);
      _release(qnn, owned);
      _interpreter = null;
      report['QNN HTP'] = 'unvalidated';
      _status = EmbeddingAcceleratorStatus(
        verdict: AcceleratorVerdict.xnnpackFallback,
        activeBackend: 'not loaded',
        detail: 'validation could not run: ${'$e'.split('\n').first}',
        delegation: delegation,
        environment: env,
      );
      return null;
    }
    _release(reference, refOwned);

    if (!decision.accepted) {
      _release(qnn, owned);
      _interpreter = null;
      report['QNN HTP'] = 'rejected';
      _status = EmbeddingAcceleratorStatus(
        verdict: AcceleratorVerdict.xnnpackFallback,
        activeBackend: 'not loaded',
        detail: decision.rejections.join('; '),
        decision: decision,
        delegation: delegation,
        environment: env,
      );
      // ignore: avoid_print
      print('[vault] QNN HTP rejected: ${decision.rejections.join('; ')}');
      return null;
    }

    report['QNN HTP'] = '${decision.qnnMedianMs.toStringAsFixed(1)} ms verified';
    _status = EmbeddingAcceleratorStatus(
      verdict: AcceleratorVerdict.qnnHtpVerified,
      activeBackend: 'QNN HTP',
      detail: '${delegation.nodesDelegated}/${delegation.nodesTotal} nodes on HTP, '
          '${delegation.partitions} partition(s); '
          'min cosine ${decision.minCosine.toStringAsFixed(4)} vs XNNPACK',
      decision: decision,
      delegation: delegation,
      environment: env,
    );
    _interpreter = qnn;
    return (
      interpreter: qnn,
      owned: owned,
      micros: (decision.qnnMedianMs * 1000).round(),
    );
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
  /// Doubles as the smoke test (kept for QNN too): it catches the failure mode where a delegate
  /// loads happily and then returns NaN for every token, which is exactly
  /// what the dynamic-range-quantized export of this model does.
  ///
  /// Returns the native inference time in microseconds, measured on a second
  /// run so lazy allocation on the first does not skew the comparison.
  int _benchmark() {
    // _embedWith, not _embedSync: backend selection must not show up in the
    // telemetry leases as real work on a hardware not yet decided.
    final it = _interpreter!;
    _embedWith(it, 'vault retrieval smoke test');
    final v = _embedWith(it, 'vault retrieval smoke test');

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
    if (interpreter == null || _tokenizer == null) {
      throw StateError('Call load() before embed().');
    }
    final lease = ledger.begin(
      _status.hardware,
      'minilm',
      evidence: _status.label,
    );
    try {
      final v = _embedWith(interpreter, text);
      // Report to the telemetry meter, if one is attached. Reads the native
      // counter rather than timing the call, for the reason in [onInference].
      onInference?.call(interpreter.lastNativeInferenceDurationMicroSeconds);
      return v;
    } finally {
      lease.end();
    }
  }

  /// One embedding on a specific interpreter — the live one, or the QNN /
  /// XNNPACK pair during validation (which must not feed telemetry).
  Float32List _embedWith(Interpreter interpreter, String text) {
    final tokenizer = _tokenizer;
    if (tokenizer == null) throw StateError('Call load() before embed().');

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
