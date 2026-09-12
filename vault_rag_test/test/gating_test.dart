/// Three-tier speculative gating in VaultEngine.buildCapsule.
///
/// No encoder, no database: each case hands the gate a SearchResult with a
/// chosen top score and a synthesizer that counts how often it is invoked.

library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_rag_test/core/answer_synthesizer.dart';
import 'package:vault_rag_test/core/gating.dart';
import 'package:vault_rag_test/core/llm/capsule.dart';
import 'package:vault_rag_test/core/security/security_constants.dart';
import 'package:vault_rag_test/core/vault_engine.dart';
import 'package:vault_rag_test/core/vector_store.dart';

class CountingSynthesizer implements CapsuleSynthesizer {
  int calls = 0;
  bool ready = true;
  bool fail = false;

  @override
  bool get isReady => ready;
  @override
  String get modelLabel => 'fake-gemma-2b-int4';
  @override
  String get backendLabel => 'llama.cpp/fake';

  @override
  Future<SynthesisOutput> synthesize(SearchResult result) async {
    calls++;
    if (fail) throw StateError('model crashed');
    return const SynthesisOutput(
      text: '{"answer": "Synthesised from two chunks.", "confidence": "medium", '
          '"key_facts": [], "caveats": []}',
      elapsedMs: 1200,
      tokens: 40,
    );
  }
}

SearchResult resultWithTopScore(double score) {
  final chunks = [
    RetrievedChunk(
      id: 'limits.py_chunk_000',
      fileName: 'limits.py',
      content: 'class RiskEngine:\n    MAX_ORDER_USD = 250000',
      score: score,
    ),
    RetrievedChunk(
      id: 'limits.py_chunk_001',
      fileName: 'limits.py',
      content: 'REVIEW_THRESHOLD_USD = 100000',
      score: score - 0.05,
    ),
  ];
  const query = 'what is the max order usd';
  return SearchResult(
    query: query,
    chunks: chunks,
    directAnswer: synthesizeDirectAnswer(query, chunks),
    latencyMs: 30,
    embedMs: 20,
    totalIndexed: 2,
  );
}

void main() {
  late VaultEngine engine;
  late CountingSynthesizer llm;

  setUp(() {
    engine = VaultEngine();
    llm = CountingSynthesizer();
    engine.synthesizerOverride = llm;
  });
  tearDown(() => engine.dispose());

  group('GatingPolicy boundaries', () {
    const p = GatingPolicy.standard;
    test('exactly 0.82 is tier 1', () => expect(p.decide(0.82), GatingPath.extractiveEarlyExit));
    test('above 0.82 is tier 1', () => expect(p.decide(0.9), GatingPath.extractiveEarlyExit));
    test('just below 0.82 is tier 2', () {
      expect(p.decide(0.8199999999), GatingPath.llmSynthesized);
      expect(p.decide(0.82 - 1e-12), GatingPath.llmSynthesized);
    });
    test('exactly 0.50 is tier 2', () => expect(p.decide(0.50), GatingPath.llmSynthesized));
    test('below 0.50 is tier 3', () {
      expect(p.decide(0.4999999), GatingPath.belowRelevanceThreshold);
      expect(p.decide(-1), GatingPath.belowRelevanceThreshold);
    });
    test('nothing retrieved or NaN is tier 3', () {
      expect(p.decide(null), GatingPath.belowRelevanceThreshold);
      expect(p.decide(double.nan), GatingPath.belowRelevanceThreshold);
    });
    test('constants are the specified thresholds', () {
      expect(kTier1Threshold, 0.82);
      expect(kTier2Threshold, 0.50);
    });
  });

  group('tier 1 — deterministic hit', () {
    test('never invokes the LLM, even when one is ready', () async {
      final c = await engine.buildCapsule(resultWithTopScore(0.82));
      expect(llm.calls, 0);
      expect(c.gatingPath, GatingPath.extractiveEarlyExit);
      expect(c.generation.ran, isFalse);
      expect(c.toJson()['gating']['path'], 'extractive_early_exit');
      expect(c.context, hasLength(2));
    });
  });

  group('tier 2 — ambiguous synthesis', () {
    test('invokes the LLM once at 0.50 and marks llm_synthesized', () async {
      final c = await engine.buildCapsule(resultWithTopScore(0.50));
      expect(llm.calls, 1);
      expect(c.gatingPath, GatingPath.llmSynthesized);
      expect(c.answer, 'Synthesised from two chunks.');
      expect(c.generation.model, 'fake-gemma-2b-int4');
    });

    test('invokes the LLM just below 0.82', () async {
      await engine.buildCapsule(resultWithTopScore(0.8199));
      expect(llm.calls, 1);
    });

    test('no model ready: extractive_fallback, honestly labelled', () async {
      llm.ready = false;
      final c = await engine.buildCapsule(resultWithTopScore(0.7));
      expect(llm.calls, 0);
      expect(c.gatingPath, GatingPath.extractiveFallback);
    });

    test('generate=false: extractive_fallback without touching the LLM', () async {
      final c = await engine.buildCapsule(resultWithTopScore(0.7), generate: false);
      expect(llm.calls, 0);
      expect(c.gatingPath, GatingPath.extractiveFallback);
    });

    test('generation failure keeps retrieval and records it', () async {
      llm.fail = true;
      final c = await engine.buildCapsule(resultWithTopScore(0.7));
      expect(llm.calls, 1);
      expect(c.gatingPath, GatingPath.extractiveFallback);
      expect(c.generation.ran, isTrue);
      expect(c.generation.parseError, contains('Generation failed'));
      expect(c.context, isNotEmpty);
    });
  });

  group('tier 3 — low relevance', () {
    test('never invokes the LLM and returns the fixed refusal', () async {
      final c = await engine.buildCapsule(resultWithTopScore(0.49));
      expect(llm.calls, 0);
      expect(c.gatingPath, GatingPath.belowRelevanceThreshold);
      expect(c.answer, 'No relevant facts found in vault.');
      expect(c.keyFacts, isEmpty);
      expect(c.confidence, CapsuleConfidence.none);
      // Low-scoring chunk text is not shipped in the capsule.
      expect(c.context, isEmpty);
      expect(c.sources, hasLength(2));
    });

    test('is deterministic apart from the timestamp', () async {
      final a = (await engine.buildCapsule(resultWithTopScore(0.2))).toJson();
      final b = (await engine.buildCapsule(resultWithTopScore(0.2))).toJson();
      a.remove('retrieval');
      b.remove('retrieval');
      expect(a, b);
    });

    test('an empty retrieval is tier 3', () async {
      const empty = SearchResult(
        query: 'anything',
        chunks: [],
        directAnswer: null,
        latencyMs: 1,
        embedMs: 1,
        totalIndexed: 0,
      );
      final c = await engine.buildCapsule(empty);
      expect(c.gatingPath, GatingPath.belowRelevanceThreshold);
      expect(llm.calls, 0);
    });
  });

  test('a custom policy is honoured', () async {
    engine.gatingPolicy =
        const GatingPolicy(tier1Threshold: 0.6, tier2Threshold: 0.3);
    final c = await engine.buildCapsule(resultWithTopScore(0.65));
    expect(c.gatingPath, GatingPath.extractiveEarlyExit);
    expect(c.gating['tier1_threshold'], 0.6);
  });
}
