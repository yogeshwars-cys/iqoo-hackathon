/// Host-side tests for the capsule parser and the model-format probe.
///
/// Every string in the parser group is a shape a 2B instruct model actually
/// produces. They are not hypotheses about what could go wrong — a fenced
/// block, a chatty preamble, a trailing comma and a mid-object truncation
/// are the four most common outputs after clean JSON, and a parser that
/// only handles clean JSON makes the whole generation path unusable.

library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_rag_test/core/answer_synthesizer.dart';
import 'package:vault_rag_test/core/llm/capsule.dart';
import 'package:vault_rag_test/core/llm/capsule_prompt.dart';
import 'package:vault_rag_test/core/llm/model_probe.dart';
import 'package:vault_rag_test/core/vault_engine.dart';
import 'package:vault_rag_test/core/vector_store.dart';

SearchResult fakeResult({
  String query = 'what is the order limit',
  List<RetrievedChunk>? chunks,
}) {
  final list = chunks ??
      [
        RetrievedChunk(
          id: 'limits.py_chunk_000',
          fileName: 'limits.py',
          content: 'class RiskEngine:\n'
              '    MAX_ORDER_USD = 250000\n'
              '    REVIEW_THRESHOLD_USD = 100000',
          score: 0.81,
        ),
      ];
  return SearchResult(
    query: query,
    chunks: list,
    directAnswer: list.isEmpty
        ? null
        : synthesizeDirectAnswer(query, list),
    latencyMs: 244,
    embedMs: 233,
    totalIndexed: 12,
  );
}

void main() {
  group('extractCapsuleJson', () {
    test('plain object', () {
      final parsed = extractCapsuleJson('{"answer": "yes"}');
      expect(parsed?['answer'], 'yes');
    });

    test('fenced block', () {
      final parsed = extractCapsuleJson(
        'Here you go:\n```json\n{"answer": "fenced"}\n```\n',
      );
      expect(parsed?['answer'], 'fenced');
    });

    test('chatty preamble and trailing chatter', () {
      final parsed = extractCapsuleJson(
        'Sure! Here is the capsule you asked for:\n'
        '{"answer": "amid prose"}\n'
        'Let me know if you need anything else.',
      );
      expect(parsed?['answer'], 'amid prose');
    });

    test('trailing commas', () {
      final parsed = extractCapsuleJson(
        '{"answer": "trailing", "caveats": ["a", "b",],}',
      );
      expect(parsed?['answer'], 'trailing');
      expect((parsed?['caveats'] as List).length, 2);
    });

    test('smart quotes from the tokenizer', () {
      final parsed = extractCapsuleJson(
        '{“answer”: “curly”}',
      );
      expect(parsed?['answer'], 'curly');
    });

    test('unquoted keys', () {
      final parsed = extractCapsuleJson('{answer: "bare key"}');
      expect(parsed?['answer'], 'bare key');
    });

    test('Python literals', () {
      final parsed = extractCapsuleJson(
        '{"answer": "py", "verified": True, "extra": None}',
      );
      expect(parsed?['verified'], true);
      expect(parsed?['extra'], isNull);
    });

    test('truncated mid-object recovers what arrived', () {
      // Hitting the token limit part-way through. Field order in the prompt
      // is priority order precisely so that this loses caveats, not answer.
      final parsed = extractCapsuleJson(
        '{"answer": "cut off here", "confidence": "high", "key_facts": [',
      );
      expect(parsed, isNotNull);
      expect(parsed?['answer'], 'cut off here');
    });

    test('truncated mid-string still recovers the fields before it', () {
      final parsed = extractCapsuleJson(
        '{"answer": "complete", "confidence": "hig',
      );
      expect(parsed?['answer'], 'complete');
    });

    test('braces inside strings do not confuse the scanner', () {
      final parsed = extractCapsuleJson(
        r'{"answer": "the literal { and } characters", "n": 1}',
      );
      expect(parsed?['answer'], 'the literal { and } characters');
      expect(parsed?['n'], 1);
    });

    test('takes the first object when the model repeats itself', () {
      final parsed = extractCapsuleJson(
        '{"answer": "first"}\n{"answer": "second"}',
      );
      expect(parsed?['answer'], 'first');
    });

    test('no JSON at all returns null', () {
      expect(extractCapsuleJson('I am sorry, I cannot help with that.'),
          isNull);
      expect(extractCapsuleJson(''), isNull);
    });
  });

  group('ContextCapsule.fromModelOutput', () {
    test('builds a full capsule from clean output', () {
      final capsule = ContextCapsule.fromModelOutput(
        '{"answer": "Orders cap at 250,000 USD.", "confidence": "high", '
        '"key_facts": [{"fact": "Cap is 250000.", "source": "limits.py", '
        '"verbatim": "MAX_ORDER_USD = 250000"}], '
        '"caveats": ["Nothing about rejections."]}',
        fakeResult(),
        model: 'gemma.task',
        backend: 'cpu',
        elapsedMs: 9000,
        tokens: 120,
      );

      expect(capsule.answer, contains('250,000'));
      expect(capsule.confidence, CapsuleConfidence.high);
      expect(capsule.keyFacts, hasLength(1));
      expect(capsule.caveats, hasLength(1));
      expect(capsule.generation.ran, isTrue);
      expect(capsule.generation.parseError, isNull);
      expect(capsule.context, hasLength(1));
    });

    test('verifies a quote that really occurs in the context', () {
      final capsule = ContextCapsule.fromModelOutput(
        '{"answer": "a", "key_facts": [{"fact": "f", '
        '"verbatim": "MAX_ORDER_USD = 250000"}]}',
        fakeResult(),
        model: 'm',
        backend: 'cpu',
        elapsedMs: 1,
      );
      expect(capsule.keyFacts.single.verified, isTrue);
    });

    test('marks an invented quote unverified rather than trusting it', () {
      // The single most valuable check in the file: a small model will
      // confidently attribute a quote the corpus never contained.
      final capsule = ContextCapsule.fromModelOutput(
        '{"answer": "a", "key_facts": [{"fact": "f", '
        '"verbatim": "MAX_ORDER_USD = 999999999"}]}',
        fakeResult(),
        model: 'm',
        backend: 'cpu',
        elapsedMs: 1,
      );
      expect(capsule.keyFacts.single.verified, isFalse);
    });

    test('reflowed whitespace in a quote still verifies', () {
      final capsule = ContextCapsule.fromModelOutput(
        '{"answer": "a", "key_facts": [{"fact": "f", '
        '"verbatim": "MAX_ORDER_USD   =    250000"}]}',
        fakeResult(),
        model: 'm',
        backend: 'cpu',
        elapsedMs: 1,
      );
      expect(capsule.keyFacts.single.verified, isTrue);
    });

    test('unparseable output falls back to the retrieval capsule', () {
      final capsule = ContextCapsule.fromModelOutput(
        'I think the answer is probably around 250 thousand dollars.',
        fakeResult(),
        model: 'gemma.task',
        backend: 'gpu',
        elapsedMs: 8000,
      );

      expect(capsule.generation.ran, isTrue);
      expect(capsule.generation.parseError, isNotNull);
      // The retrieval is never lost: the extractive answer survives.
      expect(capsule.extractedAnswer, isNotNull);
      expect(capsule.sources, hasLength(1));
      expect(capsule.context, hasLength(1));
    });

    test('parsed JSON with an empty answer counts as a failure', () {
      final capsule = ContextCapsule.fromModelOutput(
        '{"answer": "   ", "confidence": "high"}',
        fakeResult(),
        model: 'm',
        backend: 'cpu',
        elapsedMs: 1,
      );
      expect(capsule.generation.parseError, contains('answer'));
    });

    test('caps a looping model at eight facts', () {
      final facts = List.generate(
        40,
        (i) => '{"fact": "repeated $i", "verbatim": "x"}',
      ).join(',');
      final capsule = ContextCapsule.fromModelOutput(
        '{"answer": "a", "key_facts": [$facts]}',
        fakeResult(),
        model: 'm',
        backend: 'cpu',
        elapsedMs: 1,
      );
      expect(capsule.keyFacts.length, lessThanOrEqualTo(8));
    });

    test('accepts key_facts given as plain strings', () {
      final capsule = ContextCapsule.fromModelOutput(
        '{"answer": "a", "key_facts": ["just a sentence"]}',
        fakeResult(),
        model: 'm',
        backend: 'cpu',
        elapsedMs: 1,
      );
      expect(capsule.keyFacts.single.fact, 'just a sentence');
      expect(capsule.keyFacts.single.verified, isFalse);
    });
  });

  group('ContextCapsule.fromRetrievalOnly', () {
    test('is a complete, schema-valid capsule with no model', () {
      final capsule = ContextCapsule.fromRetrievalOnly(fakeResult());
      final json = capsule.toJson();

      expect(json['capsule_version'], ContextCapsule.schemaVersion);
      expect(json['answer'], isNotEmpty);
      expect((json['generation'] as Map)['ran'], isFalse);
      expect(json['caveats'], isNotEmpty);
      expect(json['context'], hasLength(1));
    });

    test('says so plainly when nothing was retrieved', () {
      final capsule =
          ContextCapsule.fromRetrievalOnly(fakeResult(chunks: []));
      expect(capsule.confidence, CapsuleConfidence.none);
      expect(capsule.sources, isEmpty);
      expect(capsule.answer, contains('No line in the retrieved context'));
    });
  });

  group('buildCapsulePrompt', () {
    test('includes the query, the context and the turn markers', () {
      final prompt = buildCapsulePrompt(fakeResult());
      expect(prompt, contains('<start_of_turn>user'));
      expect(prompt, contains('<end_of_turn>'));
      expect(prompt, contains('what is the order limit'));
      expect(prompt, contains('MAX_ORDER_USD = 250000'));
      expect(prompt, contains('limits.py'));
    });

    test('stays within the context budget on a large corpus', () {
      final chunks = List.generate(
        20,
        (i) => RetrievedChunk(
          id: 'big_$i',
          fileName: 'big$i.md',
          content: 'x' * 2000,
          score: 0.9 - i * 0.01,
        ),
      );
      final prompt = buildCapsulePrompt(fakeResult(chunks: chunks));
      // Prompt scaffolding is ~2 KB; the context itself must be capped.
      expect(prompt.length, lessThan(maxContextChars + 4000));
      // Best-first: the top-ranked chunk is the one that survives.
      expect(prompt, contains('big0.md'));
    });

    test('handles an empty corpus without producing a misleading prompt', () {
      final prompt = buildCapsulePrompt(fakeResult(chunks: []));
      expect(prompt, contains('no context was retrieved'));
    });
  });

  group('probeModel', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('vault_probe');
    });

    tearDown(() async => dir.delete(recursive: true));

    Future<String> write(String name, List<int> bytes) async {
      final f = File('${dir.path}/$name');
      await f.writeAsBytes(bytes);
      return f.path;
    }

    List<int> pad(List<int> head) =>
        [...head, ...List.filled(64 - head.length, 0)];

    test('identifies GGUF and explains why it cannot be used', () async {
      final path = await write('m.gguf', pad('GGUF'.codeUnits));
      final probe = await probeModel(path);
      expect(probe.format, ModelFormat.gguf);
      expect(probe.isUsable, isFalse);
      expect(probe.format.remedy, contains('MediaPipe'));
    });

    test('identifies a MediaPipe .task bundle by its zip header', () async {
      final path = await write('m.task', pad([0x50, 0x4B, 0x03, 0x04]));
      final probe = await probeModel(path);
      expect(probe.format, ModelFormat.mediaPipeTask);
      expect(probe.format.isSupported, isTrue);
    });

    test('identifies MediaPipe .bin by the TFL3 identifier at offset 4',
        () async {
      final path = await write(
        'm.bin',
        pad([0x18, 0, 0, 0, ...'TFL3'.codeUnits]),
      );
      final probe = await probeModel(path);
      expect(probe.format, ModelFormat.mediaPipeBin);
      expect(probe.format.isSupported, isTrue);
    });

    test('an extension cannot override the magic number', () async {
      // A GGUF file renamed to .task must still be refused — trusting the
      // extension here means a native abort rather than an error message.
      final path = await write('lying.task', pad('GGUF'.codeUnits));
      final probe = await probeModel(path);
      expect(probe.format, ModelFormat.gguf);
      expect(probe.isUsable, isFalse);
    });

    test('flags a plausible container that is far too small', () async {
      final path = await write('tiny.task', pad([0x50, 0x4B, 0x03, 0x04]));
      final probe = await probeModel(path);
      expect(probe.sizeWarning, contains('incomplete'));
    });

    test('unrecognised content reports its first bytes', () async {
      final path = await write('junk.bin', pad('<!DOCTYPE html'.codeUnits));
      final probe = await probeModel(path);
      expect(probe.format, ModelFormat.unknown);
      expect(probe.magicHex, isNotNull);
      expect(probe.format.remedy, contains('download'));
    });

    test('a missing file is unreadable, not unknown', () async {
      final probe = await probeModel('${dir.path}/nope.task');
      expect(probe.format, ModelFormat.unreadable);
      expect(probe.isUsable, isFalse);
    });
  });
}
