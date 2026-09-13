/// qnn_acceptance.dart
///
/// Whether a QNN HTP interpreter may replace XNNPACK for MiniLM.
///
/// A delegate that builds is not evidence of anything. Three independent
/// failure modes each make "running on the NPU" a false claim or a bad trade,
/// and each gets its own gate:
///
///  1. COVERAGE — the delegate may accept a handful of ops and leave the
///     transformer on the CPU, paying two copies per partition for nothing.
///     Gate: the delegate's own "N nodes delegated out of M" report. No
///     report means coverage is unproven, which is a rejection, not a pass.
///  2. CORRECTNESS — FP16 on HTP must not change what retrieval returns.
///     Gate: per-text cosine between QNN and XNNPACK embeddings over a fixed
///     corpus, AND identical top-1 / near-identical top-3 rankings for fixed
///     queries. Cosine alone can pass while rankings flip on close calls.
///  3. LATENCY — an NPU path slower than XNNPACK is a regression dressed up
///     as acceleration. Gate: median native inference time ratio.
///
/// Pure Dart, no platform calls: the embedding service collects the numbers,
/// this decides.

library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'qnn_htp_delegate.dart';

class QnnAcceptanceCriteria {
  /// Minimum fraction of graph nodes the delegate must own.
  final double minDelegatedFraction;

  /// Every corpus text must embed to within this cosine of XNNPACK.
  final double minCosine;

  /// QNN median latency may be at most this multiple of XNNPACK's.
  final double maxLatencyRatio;

  /// Minimum average top-3 set overlap across queries (0..1).
  final double minTop3Overlap;

  const QnnAcceptanceCriteria({
    this.minDelegatedFraction = 0.75,
    this.minCosine = 0.995,
    this.maxLatencyRatio = 1.10,
    this.minTop3Overlap = 0.9,
  });

  Map<String, dynamic> toJson() => {
        'min_delegated_fraction': minDelegatedFraction,
        'min_cosine': minCosine,
        'max_latency_ratio': maxLatencyRatio,
        'min_top3_overlap': minTop3Overlap,
      };
}

class QnnValidationEvidence {
  final QnnDelegationReport delegation;

  /// Embeddings of [qnnValidationPassages] then [qnnValidationQueries], same
  /// order on both backends.
  final List<Float32List> qnnVectors;
  final List<Float32List> referenceVectors;
  final int passageCount;
  final List<double> qnnLatencyMs;
  final List<double> referenceLatencyMs;

  const QnnValidationEvidence({
    required this.delegation,
    required this.qnnVectors,
    required this.referenceVectors,
    required this.passageCount,
    required this.qnnLatencyMs,
    required this.referenceLatencyMs,
  });
}

class QnnDecision {
  final bool accepted;
  final List<String> rejections;
  final double? delegatedFraction;
  final double minCosine;
  final double meanCosine;
  final int top1Agreements;
  final int queries;
  final double top3Overlap;
  final double qnnMedianMs;
  final double referenceMedianMs;

  const QnnDecision({
    required this.accepted,
    required this.rejections,
    required this.delegatedFraction,
    required this.minCosine,
    required this.meanCosine,
    required this.top1Agreements,
    required this.queries,
    required this.top3Overlap,
    required this.qnnMedianMs,
    required this.referenceMedianMs,
  });

  double get latencyRatio =>
      referenceMedianMs <= 0 ? double.infinity : qnnMedianMs / referenceMedianMs;

  Map<String, dynamic> toJson() => {
        'accepted': accepted,
        'rejections': rejections,
        'delegated_fraction': delegatedFraction,
        'min_cosine': _r(minCosine, 5),
        'mean_cosine': _r(meanCosine, 5),
        'top1_agreement': '$top1Agreements/$queries',
        'top3_overlap': _r(top3Overlap, 3),
        'qnn_median_ms': _r(qnnMedianMs, 2),
        'xnnpack_median_ms': _r(referenceMedianMs, 2),
        'latency_ratio': latencyRatio.isFinite ? _r(latencyRatio, 3) : null,
      };

  static double _r(double v, int digits) =>
      v.isFinite ? double.parse(v.toStringAsFixed(digits)) : v;
}

QnnDecision decideQnn(
  QnnValidationEvidence e, {
  QnnAcceptanceCriteria criteria = const QnnAcceptanceCriteria(),
}) {
  final rejections = <String>[];

  // 1. coverage — from the runtime, never assumed.
  final fraction = e.delegation.delegatedFraction;
  if (fraction == null) {
    rejections.add('coverage unproven: no delegation report from the QNN delegate');
  } else if (fraction < criteria.minDelegatedFraction) {
    rejections.add('only ${e.delegation.nodesDelegated}/${e.delegation.nodesTotal} '
        'nodes delegated (${(fraction * 100).toStringAsFixed(0)}% < '
        '${(criteria.minDelegatedFraction * 100).toStringAsFixed(0)}%)');
  }

  // 2. correctness.
  var minCos = 1.0, sumCos = 0.0;
  var invalid = false;
  final n = math.min(e.qnnVectors.length, e.referenceVectors.length);
  if (n == 0 || e.qnnVectors.length != e.referenceVectors.length) {
    rejections.add('validation corpus incomplete');
    invalid = true;
  }
  for (var i = 0; i < n; i++) {
    final c = _cosine(e.qnnVectors[i], e.referenceVectors[i]);
    if (!c.isFinite) invalid = true;
    minCos = math.min(minCos, c.isFinite ? c : -1);
    sumCos += c.isFinite ? c : -1;
  }
  if (invalid && !rejections.contains('validation corpus incomplete')) {
    rejections.add('QNN produced non-finite or mismatched output');
  }
  final meanCos = n == 0 ? 0.0 : sumCos / n;
  if (n > 0 && minCos < criteria.minCosine) {
    rejections.add('embedding drift: min cosine vs XNNPACK '
        '${minCos.toStringAsFixed(4)} < ${criteria.minCosine}');
  }

  final p = e.passageCount;
  final queries = n - p;
  var top1 = 0;
  var overlapSum = 0.0;
  for (var q = 0; q < queries; q++) {
    final qa = _rank(e.qnnVectors[p + q], e.qnnVectors.sublist(0, p));
    final qb = _rank(e.referenceVectors[p + q], e.referenceVectors.sublist(0, p));
    if (qa.first == qb.first) top1++;
    final k = math.min(3, p);
    final overlap = qa.take(k).toSet().intersection(qb.take(k).toSet()).length;
    overlapSum += overlap / k;
  }
  final top3 = queries <= 0 ? 0.0 : overlapSum / queries;
  if (queries > 0 && top1 < queries) {
    rejections.add('retrieval ranking changed: top-1 agrees on $top1/$queries queries');
  }
  if (queries > 0 && top3 < criteria.minTop3Overlap) {
    rejections.add('retrieval ranking changed: top-3 overlap '
        '${top3.toStringAsFixed(2)} < ${criteria.minTop3Overlap}');
  }

  // 3. latency.
  final qnnMed = _median(e.qnnLatencyMs);
  final refMed = _median(e.referenceLatencyMs);
  if (!qnnMed.isFinite || !refMed.isFinite) {
    rejections.add('latency not measured');
  } else if (qnnMed > refMed * criteria.maxLatencyRatio) {
    rejections.add('latency regression: QNN ${qnnMed.toStringAsFixed(1)} ms vs '
        'XNNPACK ${refMed.toStringAsFixed(1)} ms '
        '(> ${criteria.maxLatencyRatio}x)');
  }

  return QnnDecision(
    accepted: rejections.isEmpty,
    rejections: rejections,
    delegatedFraction: fraction,
    minCosine: minCos,
    meanCosine: meanCos,
    top1Agreements: top1,
    queries: queries < 0 ? 0 : queries,
    top3Overlap: top3,
    qnnMedianMs: qnnMed,
    referenceMedianMs: refMed,
  );
}

double _cosine(Float32List a, Float32List b) {
  if (a.length != b.length || a.isEmpty) return double.nan;
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na == 0 || nb == 0) return double.nan;
  return dot / (math.sqrt(na) * math.sqrt(nb));
}

List<int> _rank(Float32List query, List<Float32List> passages) {
  final idx = List<int>.generate(passages.length, (i) => i);
  final scores = [for (final p in passages) _cosine(query, p)];
  idx.sort((x, y) {
    final c = scores[y].compareTo(scores[x]);
    return c != 0 ? c : x.compareTo(y);
  });
  return idx;
}

double _median(List<double> xs) {
  if (xs.isEmpty) return double.nan;
  final s = [...xs]..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
}

/// Fixed validation corpus. Deliberately mixed: prose, code, config and
/// near-duplicates, so a precision problem shows up as a ranking flip
/// between close passages rather than hiding in easy separations.
const qnnValidationPassages = [
  'The risk engine rejects any order whose notional exceeds 250,000 USD.',
  'Orders above 100,000 USD are queued for manual review before execution.',
  'MAX_ORDER_USD = 250000\nREVIEW_THRESHOLD_USD = 100000',
  'The primary ledger database runs on db-1.internal port 6432.',
  'Retry with exponential backoff starting at 200 ms, capped at 30 seconds.',
  'def mean_pool(x, mask): return (x * mask).sum(1) / mask.sum(1)',
  'Employees accrue 1.75 days of paid leave per month of service.',
  'The mobile release train ships every second Tuesday after QA sign-off.',
  'Security incident: an exposed backup leaked 21,342 customer records.',
  'Wire transfers above 100,000 USD require a verbal authorisation code.',
  'Paris is the capital of France and sits on the Seine.',
  'Thermal throttling reduces CPU frequency when the SoC exceeds its limit.',
];

const qnnValidationQueries = [
  'what is the maximum notional order limit',
  'how many customer records were exposed',
  'which host and port does the ledger use',
  'how does the retry backoff work',
];
