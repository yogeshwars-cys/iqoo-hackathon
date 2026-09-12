/// gating.dart
///
/// Speculative early exit: decide from the retrieval score alone whether the
/// language model needs to run at all.
///
///   score >= tier1            extractive_early_exit      no LLM, quoted line
///   tier2 <= score < tier1    llm_synthesized            LLM writes the answer
///   score < tier2             below_relevance_threshold  no LLM, fixed refusal
///
/// A fourth path exists because honesty beats a tidy enum: when the score
/// lands in tier 2 but no model is loaded, generation is switched off, or
/// generation fails, the capsule is extractive and says so —
/// `extractive_fallback` — rather than claiming `llm_synthesized` for text
/// no model wrote.
///
/// THE THRESHOLDS ARE DEFAULTS, NOT FACTS. 0.82 / 0.50 were chosen a priori.
/// MiniLM cosine scores for a correct passage commonly sit in 0.45–0.75, so
/// on a real corpus tier 1 will be rare and some genuinely relevant queries
/// will fall under 0.50. Calibrate with bridge/corpus/run_eval.py against a
/// labelled set before trusting the refusal tier; [GatingPolicy] is
/// injectable for exactly that reason.

library;

import 'security/security_constants.dart';

enum GatingPath {
  extractiveEarlyExit('extractive_early_exit', 1),
  llmSynthesized('llm_synthesized', 2),
  extractiveFallback('extractive_fallback', 2),
  belowRelevanceThreshold('below_relevance_threshold', 3);

  final String wireName;
  final int tier;
  const GatingPath(this.wireName, this.tier);
}

class GatingPolicy {
  final double tier1Threshold;
  final double tier2Threshold;

  const GatingPolicy({
    this.tier1Threshold = kTier1Threshold,
    this.tier2Threshold = kTier2Threshold,
  }) : assert(tier2Threshold <= tier1Threshold);

  static const standard = GatingPolicy();

  /// The tier the score alone selects. [topScore] is null when nothing was
  /// retrieved, which is below every threshold by definition.
  GatingPath decide(double? topScore) {
    if (topScore == null || topScore.isNaN) {
      return GatingPath.belowRelevanceThreshold;
    }
    if (topScore >= tier1Threshold) return GatingPath.extractiveEarlyExit;
    if (topScore >= tier2Threshold) return GatingPath.llmSynthesized;
    return GatingPath.belowRelevanceThreshold;
  }

  Map<String, dynamic> toJson() => {
        'tier1_threshold': tier1Threshold,
        'tier2_threshold': tier2Threshold,
      };
}
