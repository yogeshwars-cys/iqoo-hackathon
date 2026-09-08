/// Host-side tests for the two pure-Dart stages of the pipeline.
///
/// These need no device, no model and no plugins, so they catch chunking and
/// tokenization regressions in a second instead of during a phone build.
///
/// The tokenizer goldens come from a Python port of tokenizer.dart that was
/// checked against the real HuggingFace WordPiece tokenizer for this exact
/// vocab (see modelprep/verify.py, check 1). So "matches these ids" really
/// does mean "matches what MiniLM was trained to expect", not just "matches
/// whatever this code did last time".

library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_rag_test/chunking.dart';
import 'package:vault_rag_test/tokenizer.dart';

void main() {
  group('Chunker', () {
    test('returns nothing for blank input', () {
      final c = Chunker();
      expect(c.chunk('empty.txt', ''), isEmpty);
      expect(c.chunk('empty.txt', '   \n\t  '), isEmpty);
    });

    test('short text becomes a single chunk', () {
      final chunks = Chunker().chunk('a.txt', 'one two three');
      expect(chunks, hasLength(1));
      expect(chunks.single.content, 'one two three');
      expect(chunks.single.startWord, 0);
      expect(chunks.single.endWord, 3);
      expect(chunks.single.fileName, 'a.txt');
    });

    test('windows overlap by exactly `overlap` words', () {
      final words = List.generate(25, (i) => 'w$i').join(' ');
      final chunks = Chunker(windowSize: 10, overlap: 3).chunk('a.txt', words);

      // stride = 7, so starts are 0, 7, 14, 21.
      expect(chunks.map((c) => c.startWord), [0, 7, 14, 21]);
      expect(chunks.last.endWord, 25);

      // The tail of one chunk is the head of the next.
      for (var i = 0; i + 1 < chunks.length; i++) {
        final tail = chunks[i].content.split(' ').sublist(7);
        final head = chunks[i + 1].content.split(' ').take(3).toList();
        expect(tail, head, reason: 'chunk $i/${i + 1} overlap');
      }
    });

    test('does not emit a trailing chunk when the text ends on a boundary', () {
      final words = List.generate(10, (i) => 'w$i').join(' ');
      final chunks = Chunker(windowSize: 10, overlap: 3).chunk('a.txt', words);
      expect(chunks, hasLength(1));
    });

    test('collapses arbitrary whitespace between words', () {
      final chunks = Chunker().chunk('a.txt', 'one\n\n  two\t\tthree\r\nfour');
      expect(chunks.single.content, 'one two three four');
    });

    test('chunk ids are unique and sort in document order', () {
      final words = List.generate(300, (i) => 'w$i').join(' ');
      final chunks = Chunker(windowSize: 10, overlap: 2).chunk('a.txt', words);
      final ids = chunks.map((c) => c.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
      expect(ids, orderedEquals(List.of(ids)..sort()));
    });

    test('rejects an overlap it cannot make progress with', () {
      expect(() => Chunker(windowSize: 10, overlap: 10), throwsA(anything));
    });
  });

  group('Tokenizer', () {
    late Tokenizer tok;

    setUpAll(() {
      // flutter_test runs with the package root as cwd.
      final vocab = File('assets/models/vocab.txt').readAsStringSync();
      tok = Tokenizer.fromVocabText(vocab, maxLen: 32);
    });

    test('special tokens resolve to the standard BERT ids', () {
      expect(tok.clsId, 101);
      expect(tok.sepId, 102);
      expect(tok.padId, 0);
      expect(tok.unkId, 100);
    });

    test('reproduces HuggingFace ids for prose, code and punctuation', () {
      const goldens = <String, List<int>>{
        'Hello world!': [101, 7592, 2088, 999, 102],
        'def mean_pool(x, mask):': [
          101, 13366, 2812, 1035, 4770, 1006, 1060, 1010, 7308, 1007, 1024, 102
        ],
        'VectorStore ranks chunks by cosine similarity.': [
          101, 19019, 19277, 6938, 24839, 2011, 2522, 11493, 2063, 14402, 1012,
          102
        ],
      };
      goldens.forEach((text, expected) {
        final enc = tok.encode(text);
        final n = enc.attentionMask.reduce((a, b) => a + b);
        expect(enc.inputIds.take(n), expected, reason: text);
      });
    });

    test('pads to maxLen and masks only the real tokens', () {
      final enc = tok.encode('Hello world!');
      expect(enc.inputIds, hasLength(32));
      expect(enc.attentionMask, hasLength(32));
      expect(enc.tokenTypeIds, hasLength(32));
      expect(enc.attentionMask.take(5), everyElement(1));
      expect(enc.attentionMask.skip(5), everyElement(0));
      expect(enc.inputIds.skip(5), everyElement(tok.padId));
      expect(enc.tokenTypeIds, everyElement(0));
    });

    test('truncates long input and still terminates with [SEP]', () {
      final long = List.filled(200, 'similarity').join(' ');
      final enc = tok.encode(long);
      expect(enc.inputIds, hasLength(32));
      expect(enc.inputIds.first, tok.clsId);
      expect(enc.inputIds[31], tok.sepId);
      expect(enc.attentionMask, everyElement(1));
    });

    test('unrepresentable characters fall back to [UNK], not a crash', () {
      final enc = tok.encode('你好 ☃');
      final n = enc.attentionMask.reduce((a, b) => a + b);
      expect(n, greaterThanOrEqualTo(2));
      expect(enc.inputIds.first, tok.clsId);
      expect(enc.inputIds[n - 1], tok.sepId);
    });

    test('a vocab without the special tokens is rejected loudly', () {
      expect(() => Tokenizer.fromVocabText('foo\nbar\n'), throwsStateError);
    });
  });
}
