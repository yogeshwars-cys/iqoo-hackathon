/// Tests for the similarity scoring.
///
/// [VectorStore] itself cannot be opened on the host — it needs the sqlite3
/// native library, which the Flutter test runner does not load — so the
/// scoring function is top-level and tested directly. That is where the
/// arithmetic lives, and it is the part that runs once per stored chunk on
/// every single query.

library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_rag_test/core/vector_store.dart';

Float32List vec(List<double> values) => Float32List.fromList(values);

Float32List unit(List<double> values) {
  var norm = 0.0;
  for (final v in values) {
    norm += v * v;
  }
  norm = math.sqrt(norm);
  return Float32List.fromList(values.map((v) => v / norm).toList());
}

void main() {
  group('cosineSimilarity', () {
    test('identical unit vectors score 1', () {
      final a = unit([1, 2, 3, 4]);
      expect(cosineSimilarity(a, a), closeTo(1.0, 1e-6));
    });

    test('orthogonal vectors score 0', () {
      expect(cosineSimilarity(vec([1, 0]), vec([0, 1])), closeTo(0.0, 1e-9));
    });

    test('opposed vectors score -1', () {
      expect(cosineSimilarity(vec([1, 0]), vec([-1, 0])), closeTo(-1.0, 1e-9));
    });

    test('magnitude does not affect the score', () {
      final small = vec([1, 2, 3]);
      final large = vec([100, 200, 300]);
      expect(cosineSimilarity(small, large), closeTo(1.0, 1e-6));
    });

    test('a dimension mismatch returns 0 instead of throwing', () {
      // The bug this was written for: the loop ran to a.length while
      // indexing b, so a shorter b threw RangeError — and because scoring
      // happens inside the loop over the whole corpus, one bad row failed
      // every search against the vault rather than just itself.
      expect(
        () => cosineSimilarity(vec([1, 2, 3, 4]), vec([1, 2])),
        returnsNormally,
      );
      expect(cosineSimilarity(vec([1, 2, 3, 4]), vec([1, 2])), 0.0);
      // And the other way round, which the original loop happened to
      // survive — asymmetry in a scoring function is its own bug.
      expect(cosineSimilarity(vec([1, 2]), vec([1, 2, 3, 4])), 0.0);
    });

    test('empty vectors score 0', () {
      expect(cosineSimilarity(vec([]), vec([])), 0.0);
    });

    test('a zero vector scores 0 rather than producing NaN', () {
      // Dividing by a zero norm yields NaN, which then sorts
      // unpredictably and lands in a JSON capsule as `null`.
      final score = cosineSimilarity(vec([0, 0, 0]), vec([1, 2, 3]));
      expect(score.isNaN, isFalse);
      expect(score, 0.0);
    });

    test('the result is clamped to [-1, 1]', () {
      // Float error on near-identical unit vectors can produce 1.0000001,
      // which reads as a bug in a capsule.
      final a = unit(List<double>.filled(384, 1.0));
      final score = cosineSimilarity(a, a);
      expect(score, lessThanOrEqualTo(1.0));
      expect(score, greaterThanOrEqualTo(-1.0));
    });

    test('non-finite input does not propagate NaN into the ranking', () {
      final withNan = vec([double.nan, 1, 2]);
      expect(cosineSimilarity(withNan, vec([1, 1, 1])).isNaN, isFalse);

      final withInf = vec([double.infinity, 1, 2]);
      expect(cosineSimilarity(withInf, vec([1, 1, 1])).isFinite, isTrue);
    });

    test('ranks a realistic 384-dim set in the expected order', () {
      final query = unit(List<double>.generate(384, (i) => i.toDouble()));
      final near = unit(List<double>.generate(384, (i) => i + 0.5));
      final far = unit(List<double>.generate(384, (i) => (383 - i).toDouble()));

      final nearScore = cosineSimilarity(query, near);
      final farScore = cosineSimilarity(query, far);

      expect(nearScore, greaterThan(farScore));
      expect(nearScore, closeTo(1.0, 0.01));
    });
  });
}
