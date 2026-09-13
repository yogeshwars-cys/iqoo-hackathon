/// How VaultEngine.buildCapsule decides who writes the answer.
///
/// The rule, restored after the score-gated experiment: when a reasoner is
/// loaded and generation is on, it answers EVERY query that retrieved
/// context, whatever the similarity score. No model, generation off, nothing
/// retrieved, or a failed generation -> the extractive answer, labelled so.
///
/// No encoder, no database: each case hands the engine a SearchResult with a
/// chosen top score and a synthesizer that counts how often it is invoked.

library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_rag_test/core/answer_synthesizer.dart';
import 'package:vault_rag_test/core/gating.dart';
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

  group('a loaded reasoner answers every query with context', () {
    for (final score in [0.95, 0.82, 0.64, 0.50, 0.45, 0.30, 0.05]) {
      test('top score $score -> LLM invoked, llm_synthesized', () async {
        final c = await engine.buildCapsule(resultWithTopScore(score));
        expect(llm.calls, 1);
        expect(c.gatingPath, GatingPath.llmSynthesized);
        expect(c.answer, 'Synthesised from two chunks.');
        expect(c.generation.model, 'fake-gemma-2b-int4');
        expect(c.context, hasLength(2));
      });
    }

    test('the capsule records the top score, but nothing gates on it', () async {
      final c = await engine.buildCapsule(resultWithTopScore(0.31));
      expect(c.toJson()['gating'], {'path': 'llm_synthesized', 'top_score': 0.31});
    });
  });

  group('extractive fallback, and only when no model can answer', () {
    test('no model ready', () async {
      llm.ready = false;
      final c = await engine.buildCapsule(resultWithTopScore(0.7));
      expect(llm.calls, 0);
      expect(c.gatingPath, GatingPath.extractiveFallback);
      expect(c.generation.ran, isFalse);
    });

    test('generation switched off', () async {
      final c = await engine.buildCapsule(resultWithTopScore(0.7), generate: false);
      expect(llm.calls, 0);
      expect(c.gatingPath, GatingPath.extractiveFallback);
    });

    test('nothing retrieved', () async {
      const empty = SearchResult(
        query: 'anything',
        chunks: [],
        directAnswer: null,
        latencyMs: 1,
        embedMs: 1,
        totalIndexed: 0,
      );
      final c = await engine.buildCapsule(empty);
      expect(llm.calls, 0);
      expect(c.gatingPath, GatingPath.extractiveFallback);
    });

    test('generation failure keeps retrieval and records why', () async {
      llm.fail = true;
      final c = await engine.buildCapsule(resultWithTopScore(0.7));
      expect(llm.calls, 1);
      expect(c.gatingPath, GatingPath.extractiveFallback);
      expect(c.generation.ran, isTrue);
      expect(c.generation.parseError, contains('Generation failed'));
      expect(c.context, isNotEmpty);
    });
  });

  test('retrieval-only capsule names the real encoder backend', () async {
    llm.ready = false;
    final base = resultWithTopScore(0.9);
    final result = SearchResult(
      query: base.query,
      chunks: base.chunks,
      directAnswer: base.directAnswer,
      latencyMs: base.latencyMs,
      embedMs: base.embedMs,
      totalIndexed: base.totalIndexed,
      embeddingBackend: 'XNNPACK fallback',
      embeddingHardware: 'cpu',
    );
    final c = await engine.buildCapsule(result);
    expect(c.caveats.single, contains('XNNPACK fallback'));
    expect(c.toPrettyJson(), isNot(contains('Hexagon')));
    expect(c.retrieval['encoder_backend'], 'XNNPACK fallback');
    expect(c.retrieval['encoder_hardware'], 'cpu');
  });
}
