/// Host-side tests for the extractive answer synthesizer.
///
/// No device, no model: the synthesizer takes already-retrieved chunks and
/// picks a line, so it is pure Dart and testable in milliseconds.
///
/// The cases below are the ones that actually broke during development. In
/// particular "identifier splitting" is not a nicety — without it the
/// synthesizer scores zero on exactly the queries it exists to answer,
/// because `MAX_NOTIONAL_PER_ORDER_USD` is one opaque token to a naive
/// tokenizer and shares no word with "maximum notional".

library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_rag_test/core/answer_synthesizer.dart';
import 'package:vault_rag_test/core/vector_store.dart';

RetrievedChunk chunk(String file, String content, double score) =>
    RetrievedChunk(id: '${file}_0', fileName: file, content: content, score: score);

void main() {
  group('synthesizeDirectAnswer', () {
    test('returns null when there is nothing to draw from', () {
      expect(synthesizeDirectAnswer('anything', const []), isNull);
    });

    test('returns null when the query is all stopwords', () {
      final chunks = [chunk('a.py', 'MAX_ORDERS = 12', 0.9)];
      expect(synthesizeDirectAnswer('what is the', chunks), isNull);
    });

    test('finds a value bound to a SCREAMING_SNAKE identifier', () {
      final chunks = [
        chunk(
          'risk.py',
          'class ExecutionRiskEngine:\n'
          '    """Matching engine limits."""\n'
          '    MAX_NOTIONAL_PER_ORDER_USD = 15000000.00\n'
          '    MAX_PORTFOLIO_DRAWDOWN_PCT = 0.045\n',
          0.82,
        ),
      ];

      final answer = synthesizeDirectAnswer(
        'What is the maximum notional per order?',
        chunks,
      );

      expect(answer, isNotNull);
      expect(answer!.text, contains('MAX_NOTIONAL_PER_ORDER_USD'));
      expect(answer.text, contains('15000000'));
      expect(answer.fileName, 'risk.py');
    });

    test('splits camelCase identifiers too', () {
      final chunks = [
        chunk('cfg.ts', 'const sessionRotationTtl = 900;\nconst other = 1;',
            0.8),
      ];
      final answer =
          synthesizeDirectAnswer('session rotation ttl', chunks);
      expect(answer, isNotNull);
      expect(answer!.text, contains('sessionRotationTtl'));
    });

    test('prefers a definition line over prose mentioning the same words', () {
      final chunks = [
        chunk(
          'doc.md',
          'The keepalive interval is discussed at length in this paragraph '
              'which mentions keepalive and interval repeatedly without ever '
              'stating the keepalive interval value itself.\n'
              'KEEP_ALIVE_INTERVAL_SEC = 25\n',
          0.8,
        ),
      ];
      final answer = synthesizeDirectAnswer('keep alive interval', chunks);
      expect(answer, isNotNull);
      expect(answer!.text, contains('25'));
    });

    test('weights the chunk score, not just the line', () {
      // Same answer line in both chunks; the better-retrieved chunk wins.
      final chunks = [
        chunk('weak.py', 'UDP_LISTEN_PORT = 51820', 0.20),
        chunk('strong.py', 'UDP_LISTEN_PORT = 51820', 0.95),
      ];
      final answer = synthesizeDirectAnswer('udp listen port', chunks);
      expect(answer, isNotNull);
      expect(answer!.fileName, 'strong.py');
    });

    test('refuses to answer when no line clears the floor', () {
      // Topically adjacent, but nothing in it answers the question. The box
      // this renders into looks authoritative, so silence beats a bad quote.
      final chunks = [
        chunk(
          'unrelated.md',
          'Deployment runs nightly. The pipeline builds artifacts and '
              'publishes them to the internal registry.',
          0.55,
        ),
      ];
      expect(
        synthesizeDirectAnswer('what is the satellite uplink frequency',
            chunks),
        isNull,
      );
    });

    test('reports a 1-based line number within the chunk', () {
      final chunks = [
        chunk('a.py', 'first = 1\nsecond = 2\nTARGET_VALUE = 3', 0.9),
      ];
      final answer = synthesizeDirectAnswer('target value', chunks);
      expect(answer, isNotNull);
      expect(answer!.lineInChunk, 3);
    });

    test('ignores lines too short to be an answer', () {
      final chunks = [chunk('a.py', 'x=1\ny=2', 0.9)];
      expect(synthesizeDirectAnswer('x value', chunks), isNull);
    });

    test('only reads from the top chunks', () {
      final chunks = [
        for (var i = 0; i < 6; i++) chunk('pad$i.md', 'padding text here', 0.5),
        chunk('deep.py', 'ORBITAL_EPHEMERIS_SEED = "abc"', 0.49),
      ];
      // The matching line is in the 7th chunk, past considerChunks.
      expect(
        synthesizeDirectAnswer('orbital ephemeris seed', chunks),
        isNull,
      );
      // Raising the window finds it.
      expect(
        synthesizeDirectAnswer('orbital ephemeris seed', chunks,
            considerChunks: 10),
        isNotNull,
      );
    });

    test('serialises with its provenance', () {
      final chunks = [chunk('a.py', 'RETENTION_YEARS = 7', 0.77)];
      final answer = synthesizeDirectAnswer('retention years', chunks)!;
      final json = answer.toJson();
      expect(json['file'], 'a.py');
      expect(json['method'], 'extractive');
      expect(json['chunk_score'], closeTo(0.77, 1e-6));
    });
  });
}
