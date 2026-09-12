/// Tests for the JSON repair pass, specifically that it never damages
/// content inside string literals.
///
/// Kept in its own file rather than added to capsule_test.dart so it can be
/// read as one argument: the repairs exist to recover a capsule that is one
/// comma from valid, and a repair that corrupts the answer while doing so is
/// worse than no repair at all.

library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_rag_test/core/llm/capsule.dart';

void main() {
  group('repair does not corrupt string contents', () {
    test('a colon after a comma inside prose survives', () {
      // The failure this was written for. Unparseable for exactly one
      // reason — the trailing comma — but a global regex also rewrites
      // ", note:" inside the answer into ", \"note\":", closing the string
      // early and breaking it in a new way.
      final parsed = extractCapsuleJson(
        '{"answer": "see section 3, note: important", "caveats": [],}',
      );
      expect(parsed, isNotNull);
      expect(parsed!['answer'], 'see section 3, note: important');
    });

    test('the word None inside prose is not turned into null', () {
      final parsed = extractCapsuleJson(
        '{"answer": "None of the limits apply here", "caveats": [],}',
      );
      expect(parsed?['answer'], 'None of the limits apply here');
    });

    test('True and False inside prose survive', () {
      final parsed = extractCapsuleJson(
        '{"answer": "The flag reads True in the config", "caveats": [],}',
      );
      expect(parsed?['answer'], 'The flag reads True in the config');
    });

    test('a brace inside prose does not end the object early', () {
      final parsed = extractCapsuleJson(
        '{"answer": "the literal { and } characters", "n": 1,}',
      );
      expect(parsed?['answer'], 'the literal { and } characters');
      expect(parsed?['n'], 1);
    });

    test('an escaped quote inside prose is handled', () {
      final parsed = extractCapsuleJson(
        r'{"answer": "he said \"stop\" clearly", "caveats": [],}',
      );
      expect(parsed?['answer'], r'he said "stop" clearly');
    });

    test('a code-looking span inside a verbatim quote is preserved', () {
      // verbatim fields hold source lines, which are full of the exact
      // shapes the repair rules match.
      final parsed = extractCapsuleJson(
        '{"answer": "a", "key_facts": [{"fact": "f", '
        '"verbatim": "config = {debug: True, retries: None}"}],}',
      );
      final facts = parsed?['key_facts'] as List?;
      expect(facts, hasLength(1));
      expect(
        (facts!.first as Map)['verbatim'],
        'config = {debug: True, retries: None}',
      );
    });
  });

  group('repair still fixes what it is for', () {
    test('trailing commas outside strings', () {
      final parsed = extractCapsuleJson('{"a": [1, 2,], "b": 3,}');
      expect((parsed?['a'] as List).length, 2);
      expect(parsed?['b'], 3);
    });

    test('unquoted keys outside strings', () {
      final parsed = extractCapsuleJson('{answer: "x", confidence: "high"}');
      expect(parsed?['answer'], 'x');
      expect(parsed?['confidence'], 'high');
    });

    test('Python literals outside strings', () {
      final parsed = extractCapsuleJson(
        '{"verified": True, "extra": None, "off": False}',
      );
      expect(parsed?['verified'], true);
      expect(parsed?['extra'], isNull);
      expect(parsed?['off'], false);
    });

    test('smart quotes are normalised before anything else', () {
      // They have to be: while the delimiters are curly, the splitter cannot
      // tell a literal from code, so every other repair would run over the
      // whole text.
      final parsed = extractCapsuleJson('{“answer”: “curly”, “n”: 1,}');
      expect(parsed?['answer'], 'curly');
      expect(parsed?['n'], 1);
    });

    test('a mix of damage in one payload', () {
      final parsed = extractCapsuleJson(
        '{answer: "see note: below", verified: True, "caveats": ["a",],}',
      );
      expect(parsed?['answer'], 'see note: below');
      expect(parsed?['verified'], true);
      expect((parsed?['caveats'] as List).length, 1);
    });
  });

  group('valid JSON is never rewritten', () {
    test('clean input takes the fast path untouched', () {
      // _repair only runs after a plain decode fails, so anything already
      // valid must come back byte-identical in meaning.
      const clean = '{"answer": "a, b: c and None too", "n": 1}';
      final parsed = extractCapsuleJson(clean);
      expect(parsed?['answer'], 'a, b: c and None too');
      expect(parsed?['n'], 1);
    });
  });
}
