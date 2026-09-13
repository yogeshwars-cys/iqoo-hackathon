/// QNN HTP acceptance: coverage from the delegate's own report, semantic
/// equivalence against XNNPACK on a fixed corpus, and latency. Plus the
/// status/hardware mapping that decides what the UI may claim.
///
/// The vectors are synthetic stand-ins for MiniLM output: what is under test
/// is the decision logic, which must reject on each failure mode in
/// isolation. Real QNN-vs-XNNPACK numbers only exist on the device.

library;

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_rag_test/core/compute_ledger.dart';
import 'package:vault_rag_test/core/embedding_service.dart';
import 'package:vault_rag_test/core/qnn/qnn_acceptance.dart';
import 'package:vault_rag_test/core/qnn/qnn_htp_delegate.dart';
import 'package:tflite_flutter/tflite_flutter.dart' show Delegate;

Float32List unit(Random rng, [int dim = 384]) {
  final v = Float32List(dim);
  var n = 0.0;
  for (var i = 0; i < dim; i++) {
    v[i] = rng.nextDouble() * 2 - 1;
    n += v[i] * v[i];
  }
  for (var i = 0; i < dim; i++) {
    v[i] /= sqrt(n);
  }
  return v;
}

/// Reference corpus: 12 passages, 4 queries each built close to one passage.
List<Float32List> referenceVectors() {
  final rng = Random(7);
  final passages = [for (var i = 0; i < 12; i++) unit(rng)];
  final queries = [
    for (var q = 0; q < 4; q++)
      Float32List.fromList([
        for (var j = 0; j < 384; j++) passages[q * 3][j] * 0.9 + unit(rng)[j] * 0.1,
      ]),
  ];
  return [...passages, ...queries];
}

/// FP16-like perturbation: tiny relative noise.
List<Float32List> perturbed(List<Float32List> vs, double scale, [int seed = 3]) {
  final rng = Random(seed);
  return [
    for (final v in vs)
      Float32List.fromList([for (final x in v) x + (rng.nextDouble() - 0.5) * scale]),
  ];
}

const goodReport = QnnDelegationReport(
    found: true, nodesDelegated: 290, nodesTotal: 300, partitions: 1);

QnnValidationEvidence evidence({
  QnnDelegationReport delegation = goodReport,
  List<Float32List>? qnn,
  List<double> qnnMs = const [8, 8, 9, 8, 8, 9, 8],
  List<double> refMs = const [30, 31, 29, 30, 30, 32, 30],
}) {
  final ref = referenceVectors();
  return QnnValidationEvidence(
    delegation: delegation,
    qnnVectors: qnn ?? perturbed(ref, 1e-4),
    referenceVectors: ref,
    passageCount: 12,
    qnnLatencyMs: qnnMs,
    referenceLatencyMs: refMs,
  );
}

class _ThrowingPlatform implements QnnPlatform {
  @override
  Future<QnnEnvironment> environment() async =>
      throw const QnnUnavailableException('no HTP device on host');
  @override
  Future<QnnDelegationReport> delegationReport(DateTime since) async =>
      QnnDelegationReport.missing;
  @override
  Delegate createDelegate(QnnEnvironment env) => throw UnimplementedError();
}

void main() {
  group('decideQnn', () {
    test('accepts full coverage, FP16-level drift and a faster NPU', () {
      final d = decideQnn(evidence());
      expect(d.accepted, isTrue, reason: d.rejections.join('; '));
      expect(d.minCosine, greaterThan(0.999));
      expect(d.top1Agreements, 4);
      expect(d.latencyRatio, lessThan(1));
    });

    test('rejects a negligible delegated fraction', () {
      final d = decideQnn(evidence(
          delegation: const QnnDelegationReport(
              found: true, nodesDelegated: 12, nodesTotal: 300, partitions: 9)));
      expect(d.accepted, isFalse);
      expect(d.rejections.single, contains('12/300 nodes delegated'));
    });

    test('rejects when coverage cannot be proven (no report)', () {
      final d = decideQnn(evidence(delegation: QnnDelegationReport.missing));
      expect(d.accepted, isFalse);
      expect(d.rejections.single, contains('coverage unproven'));
    });

    test('rejects embedding drift beyond FP16 noise', () {
      final d = decideQnn(evidence(qnn: perturbed(referenceVectors(), 0.05)));
      expect(d.accepted, isFalse);
      expect(d.rejections.any((r) => r.contains('embedding drift')), isTrue);
    });

    test('rejects a retrieval ranking change even when cosine is high', () {
      final ref = referenceVectors();
      // Swap two passages' vectors on the QNN side: per-text cosine of the
      // queries stays perfect, but query 0's best passage now differs.
      final qnn = [...ref];
      final tmp = qnn[0];
      qnn[0] = qnn[1];
      qnn[1] = tmp;
      final d = decideQnn(evidence(qnn: qnn));
      expect(d.accepted, isFalse);
      expect(d.rejections.any((r) => r.contains('ranking changed')), isTrue);
    });

    test('rejects invalid (non-finite) output', () {
      final bad = perturbed(referenceVectors(), 1e-4);
      bad[3][7] = double.nan;
      final d = decideQnn(evidence(qnn: bad));
      expect(d.accepted, isFalse);
    });

    test('rejects a material latency regression', () {
      final d = decideQnn(evidence(
          qnnMs: const [45, 44, 46, 45, 47, 45, 44],
          refMs: const [30, 31, 29, 30, 30, 32, 30]));
      expect(d.accepted, isFalse);
      expect(d.rejections.single, contains('latency regression'));
    });

    test('tolerates noise within the latency ratio', () {
      final d = decideQnn(evidence(
          qnnMs: const [31, 32, 31, 32, 31, 32, 31],
          refMs: const [30, 31, 29, 30, 30, 32, 30]));
      expect(d.accepted, isTrue, reason: d.rejections.join('; '));
    });
  });

  group('status and hardware attribution', () {
    test('NPU only when QNN HTP is verified', () {
      const verified = EmbeddingAcceleratorStatus(
          verdict: AcceleratorVerdict.qnnHtpVerified, activeBackend: 'QNN HTP');
      const rejected = EmbeddingAcceleratorStatus(
          verdict: AcceleratorVerdict.xnnpackFallback, activeBackend: 'XNNPACK');
      const unavailable = EmbeddingAcceleratorStatus(
          verdict: AcceleratorVerdict.qnnUnavailable, activeBackend: 'XNNPACK');
      expect(verified.hardware, ComputeHardware.npu);
      expect(verified.label, 'QNN HTP verified');
      expect(rejected.hardware, ComputeHardware.cpu);
      expect(rejected.label, 'XNNPACK fallback');
      expect(unavailable.hardware, ComputeHardware.cpu);
      expect(unavailable.label, 'QNN unavailable');
    });

    test('default backend order is qnnHtp -> xnnpack -> cpu', () {
      expect(MiniLMEmbeddingService().backendsToTry,
          [EmbeddingBackend.qnnHtp, EmbeddingBackend.xnnpack, EmbeddingBackend.cpu]);
    });

    test('QNN failure is reported as unavailable and loading continues', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final service = MiniLMEmbeddingService(qnnPlatform: _ThrowingPlatform());
      // On the host the XNNPACK/CPU fallbacks also cannot load (no LiteRT
      // native library), so load() throws — but only after QNN was recorded
      // as unavailable and the fallback chain was attempted.
      await expectLater(service.load(vocabText: '[PAD]\n[UNK]\n[CLS]\n[SEP]\n'),
          throwsA(anything));
      expect(service.acceleratorStatus.verdict, AcceleratorVerdict.qnnUnavailable);
      expect(service.acceleratorStatus.detail, 'no HTP device on host');
      expect(service.backendReport, isEmpty); // load threw before summarising
      service.close();
    });

    test('environment blocking reasons name the missing piece', () {
      const env = QnnEnvironment(
        nativeLibraryDir: '/data/app/lib/arm64',
        cacheDir: '/cache',
        qnnRuntimeVersion: '2.50.0',
        delegateLibraryPackaged: true,
        htpLibraryPackaged: true,
        shimPackaged: true,
        skels: ['libQnnHtpV81Skel.so'],
        fastRpcLibraryPresent: false,
        socModel: 'SM8850',
      );
      expect(env.blockingReason, contains('libcdsprpc.so'));
    });
  });
}
