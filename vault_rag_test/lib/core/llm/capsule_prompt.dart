/// capsule_prompt.dart
///
/// The fixed generator prompt that turns Gemma into a capsule emitter.
///
/// This file is the "output generator" — not a fine-tune, but a
/// pre-authored, versioned instruction template plus one worked example.
/// For a 2B instruct model that is the whole difference between usable
/// structured output and prose with braces in it.
///
/// WHAT EACH PART OF THE PROMPT IS DOING, AND WHY IT IS NOT DECORATION
///
///  1. Gemma's own turn markers (`<start_of_turn>` / `<end_of_turn>`). Gemma
///     2 instruct models are trained on these exactly. Omitting them costs
///     noticeably more drift and repetition than any wording change, and
///     Gemma has no system role — the instructions go inside the first user
///     turn, which is why everything below is one block.
///
///  2. Context is numbered and delimited before the question. Putting the
///     question last keeps it adjacent to the generation point, which on a
///     small model matters more than it should.
///
///  3. One complete worked example. A schema description alone gets roughly
///     the right keys with the wrong shapes (a string where a list belongs,
///     most often). An example fixes shape far more reliably than adjectives
///     about shape.
///
///  4. Field order is priority order. `answer` and `confidence` come first
///     so that when the model hits the token limit mid-object, what gets
///     truncated is `caveats` — and the parser's brace-closing recovery
///     yields a capsule that is still worth having.
///
///  5. The refusal instruction is explicit and has its own example value.
///     Given a corpus that does not contain the answer, an unprompted 2B
///     model will confabulate one with complete confidence. Telling it that
///     "the context does not say" is a *permitted, expected* answer is the
///     single highest-value line in this file.
///
/// The prompt is versioned. Changing it changes what the model emits, so a
/// capsule records [promptVersion] and a stored capsule can be traced back
/// to the instructions that produced it.

library;

import '../vault_engine.dart';

const String promptVersion = 'capsule-v1';

/// Characters of retrieved context to include.
///
/// Gemma 2B's window is 8192 tokens, but the practical limit here is lower:
/// generation slows roughly linearly with context on a mid-range phone, and
/// a 2B model's attention over long contexts degrades well before it runs
/// out of window. ~6000 characters is about 1500 tokens, which leaves ample
/// room for the instructions and the output while keeping a query
/// responsive.
const int maxContextChars = 6000;

/// Builds the full prompt for one query.
///
/// [chunks] should already be ranked; they are included best-first and
/// truncated at [maxContextChars], so a budget overrun drops the least
/// relevant material rather than an arbitrary tail.
String buildCapsulePrompt(SearchResult result) {
  final context = StringBuffer();
  var used = 0;
  var included = 0;

  for (final chunk in result.chunks) {
    final body = chunk.content.trim();
    if (body.isEmpty) continue;

    final remaining = maxContextChars - used;
    if (remaining < 200) break;

    final text =
        body.length > remaining ? '${body.substring(0, remaining)}…' : body;

    included++;
    context
      ..writeln('[$included] source: ${chunk.fileName} '
          '(similarity ${chunk.score.toStringAsFixed(3)})')
      ..writeln(text)
      ..writeln();
    used += text.length;
  }

  if (included == 0) {
    context.writeln('(no context was retrieved)');
  }

  return '''<start_of_turn>user
You convert retrieved document context into a single JSON object. You do not chat, explain, or add commentary.

RULES
1. Output exactly one JSON object. No prose before it, no prose after it, no markdown fences.
2. Use only what the CONTEXT below states. Never use outside knowledge.
3. If the context does not answer the question, set "answer" to "The retrieved context does not state this." and "confidence" to "none". This is a correct and expected outcome, not a failure.
4. Every entry in "key_facts" must carry a "verbatim" field quoting the exact span from the context that supports it. Copy it character for character. Do not paraphrase inside "verbatim".
5. "confidence" is one of: high, medium, low, none.
6. Keep "answer" under 60 words.

SCHEMA
{
  "answer": string,
  "confidence": "high" | "medium" | "low" | "none",
  "key_facts": [ { "fact": string, "source": string, "verbatim": string } ],
  "caveats": [ string ]
}

EXAMPLE
CONTEXT:
[1] source: limits.py (similarity 0.812)
class RiskEngine:
    MAX_ORDER_USD = 250000
    REVIEW_THRESHOLD_USD = 100000

QUESTION: What is the largest order the engine accepts?

OUTPUT:
{
  "answer": "The risk engine accepts orders up to 250,000 USD. Orders above 100,000 USD are flagged for review first.",
  "confidence": "high",
  "key_facts": [
    { "fact": "Maximum order size is 250,000 USD.", "source": "limits.py", "verbatim": "MAX_ORDER_USD = 250000" },
    { "fact": "Orders over 100,000 USD hit a review threshold.", "source": "limits.py", "verbatim": "REVIEW_THRESHOLD_USD = 100000" }
  ],
  "caveats": ["The context does not say what happens to a flagged order."]
}

NOW DO THE SAME FOR THIS INPUT.

CONTEXT:
${context.toString().trimRight()}

QUESTION: ${result.query}

OUTPUT:
<end_of_turn>
<start_of_turn>model
''';
}

/// Rough token estimate for the prompt, used to size the generation budget.
///
/// Deliberately crude — about 3.6 characters per token for English prose
/// with code mixed in. It only needs to be good enough to keep the request
/// inside the window, and the alternative is shipping a second tokenizer.
int estimateTokens(String text) => (text.length / 3.6).ceil();
