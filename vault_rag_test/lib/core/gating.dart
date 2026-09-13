/// gating.dart
///
/// Which path produced a capsule's answer. Recorded in the capsule and bound
/// into its signature (`provenance.gating_path`), so a consumer always knows
/// whether prose was written by the model or quoted by retrieval.
///
///   llm_synthesized      the selected reasoner wrote the answer from the
///                        retrieved chunks
///   extractive_fallback  no model wrote it: none loaded, generation switched
///                        off, nothing retrieved, or generation failed — the
///                        answer is a line quoted verbatim from the corpus
///
/// There is deliberately NO score-based gate. An earlier build skipped the
/// model above a similarity threshold and refused below another; on the
/// device that refused answerable questions (MiniLM scores for correct
/// passages sat at 0.30–0.45) and bypassed the reasoner the app exists to
/// run. When a model is loaded, it answers every query that retrieved
/// context.

library;

enum GatingPath {
  llmSynthesized('llm_synthesized'),
  extractiveFallback('extractive_fallback');

  final String wireName;
  const GatingPath(this.wireName);
}
