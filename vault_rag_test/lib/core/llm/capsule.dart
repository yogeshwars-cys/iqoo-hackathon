/// capsule.dart
///
/// The context capsule: a fixed-schema JSON object the on-device LLM emits
/// from the retrieved chunks, and the tolerant parser that turns what the
/// model *actually* wrote into that schema.
///
/// WHY A CAPSULE RATHER THAN PROSE
///
/// The consumer of this is a program — an IDE agent, an MCP client, a
/// script — not a person reading a paragraph. A capsule is addressable:
/// a caller can take `answer` alone, or check `confidence` before acting,
/// or follow `key_facts[].verbatim` back to the source line without
/// re-parsing English. It also gives the model a shape to fill rather than
/// an open field to wander in, which measurably reduces drift on a 2B
/// model.
///
/// WHY THE PARSER IS SO FORGIVING
///
/// Because a 2B model at int4 is not a JSON API. In practice it emits, in
/// rough order of frequency:
///
///   * correct JSON (most of the time, with the prompt in capsule_prompt.dart)
///   * correct JSON wrapped in ```json fences
///   * JSON preceded by "Here is the capsule:" or similar
///   * JSON with a trailing comma before } or ]
///   * JSON with single quotes, or smart quotes from the tokenizer
///   * two capsules, the second a repetition of the first
///   * truncated JSON, when it hits the token limit mid-object
///
/// Treating any of those as failure would make the feature unusable, and
/// "just raise the token limit" does not fix the first five. So the parser
/// extracts the first balanced object, repairs the common damage, and
/// coerces types. What it will NOT do is invent content: every repair is
/// syntactic. If the object cannot be recovered, [CapsuleResult] carries
/// the raw text and the caller falls back to the deterministic capsule
/// built from retrieval alone — see [ContextCapsule.fromRetrievalOnly].
///
/// That fallback is the reason this whole path is safe to ship. Generation
/// is an enhancement layered on retrieval, never a dependency of it: if the
/// model is missing, slow, or talking nonsense, the caller still gets a
/// valid capsule containing the real chunks and the extractive answer.

library;

import 'dart:convert';

import '../vault_engine.dart';
import '../vector_store.dart';

/// How much the capsule's own answer should be trusted.
enum CapsuleConfidence { high, medium, low, none }

CapsuleConfidence _confidenceFrom(Object? raw) {
  final s = raw?.toString().toLowerCase().trim() ?? '';
  if (s.startsWith('high')) return CapsuleConfidence.high;
  if (s.startsWith('med')) return CapsuleConfidence.medium;
  if (s.startsWith('low')) return CapsuleConfidence.low;
  return CapsuleConfidence.none;
}

/// One claim, tied back to the chunk it came from.
class CapsuleFact {
  final String fact;
  final String? source;

  /// The span the model says it drew this from. Checked against the corpus
  /// by [ContextCapsule._verify] — a fact whose quote does not appear in any
  /// retrieved chunk is marked unverified rather than silently trusted.
  final String? verbatim;
  final bool verified;

  const CapsuleFact({
    required this.fact,
    this.source,
    this.verbatim,
    this.verified = false,
  });

  Map<String, dynamic> toJson() => {
        'fact': fact,
        if (source != null) 'source': source,
        if (verbatim != null) 'verbatim': verbatim,
        'verified': verified,
      };
}

class CapsuleSource {
  final String file;
  final double similarity;

  const CapsuleSource(this.file, this.similarity);

  Map<String, dynamic> toJson() => {
        'file': file,
        'similarity': double.parse(similarity.toStringAsFixed(4)),
      };
}

/// Provenance for the generation step. Present even when generation did not
/// run, so a consumer can always tell what produced the answer.
class CapsuleGeneration {
  final bool ran;
  final String? model;
  final String? backend;
  final int? tokens;
  final int? elapsedMs;

  /// Set when generation ran but its output could not be parsed.
  final String? parseError;

  const CapsuleGeneration({
    required this.ran,
    this.model,
    this.backend,
    this.tokens,
    this.elapsedMs,
    this.parseError,
  });

  static const notRun = CapsuleGeneration(ran: false);

  Map<String, dynamic> toJson() => {
        'ran': ran,
        if (model != null) 'model': model,
        if (backend != null) 'backend': backend,
        if (tokens != null) 'tokens': tokens,
        if (elapsedMs != null) 'elapsed_ms': elapsedMs,
        if (parseError != null) 'parse_error': parseError,
      };
}

class ContextCapsule {
  static const schemaVersion = '1.0';

  final String query;
  final String answer;
  final CapsuleConfidence confidence;
  final List<CapsuleFact> keyFacts;
  final List<String> caveats;
  final List<CapsuleSource> sources;

  /// The retrieved chunks themselves.
  ///
  /// A capsule carries its own context on purpose. The consumer is usually
  /// a program deciding whether to trust `answer`, and it cannot do that
  /// from a filename and a similarity score alone — it needs the text the
  /// answer was supposedly drawn from. Shipping them together also means a
  /// stored capsule stays auditable after the vault has moved on.
  final List<RetrievedChunk> context;

  /// The extractive answer, always present. Independent of the LLM, so a
  /// consumer that does not trust generated text has something to use.
  final String? extractedAnswer;
  final String? extractedFrom;

  final CapsuleGeneration generation;
  final Map<String, dynamic> retrieval;

  const ContextCapsule({
    required this.query,
    required this.answer,
    required this.confidence,
    required this.keyFacts,
    required this.caveats,
    required this.sources,
    required this.context,
    required this.extractedAnswer,
    required this.extractedFrom,
    required this.generation,
    required this.retrieval,
  });

  Map<String, dynamic> toJson() => {
        'capsule_version': schemaVersion,
        'query': query,
        'answer': answer,
        'confidence': confidence.name,
        'key_facts': keyFacts.map((f) => f.toJson()).toList(),
        'caveats': caveats,
        'sources': sources.map((s) => s.toJson()).toList(),
        'context': context
            .map((c) => {
                  'file': c.fileName,
                  'similarity': double.parse(c.score.toStringAsFixed(4)),
                  'content': c.content,
                })
            .toList(),
        'extracted_answer': extractedAnswer,
        'extracted_from': extractedFrom,
        'generation': generation.toJson(),
        'retrieval': retrieval,
      };

  String toPrettyJson() =>
      const JsonEncoder.withIndent('  ').convert(toJson());

  /// The capsule you get with no LLM: retrieval plus the extractive answer.
  ///
  /// This is the floor the feature never falls below. It is a complete,
  /// schema-valid capsule — `generation.ran` is false and `answer` is the
  /// quoted line rather than written prose, which is strictly less useful
  /// and never wrong in a way the quoted line is not.
  factory ContextCapsule.fromRetrievalOnly(
    SearchResult result, {
    String? parseError,
    CapsuleGeneration? generation,
  }) {
    final extracted = result.directAnswer;
    return ContextCapsule(
      query: result.query,
      answer: extracted?.text ??
          'No line in the retrieved context answers this directly.',
      confidence: extracted == null
          ? CapsuleConfidence.none
          : (extracted.lineScore > 0.6
              ? CapsuleConfidence.medium
              : CapsuleConfidence.low),
      keyFacts: [
        if (extracted != null)
          CapsuleFact(
            fact: extracted.text,
            source: extracted.fileName,
            verbatim: extracted.text,
            verified: true,
          ),
      ],
      caveats: [
        if (generation?.ran ?? false)
          'The language model ran but its output could not be parsed; this '
              'capsule was rebuilt from retrieval alone.'
        else
          'Generated with retrieval only — no language model was loaded. '
              'The answer is a line quoted verbatim from the corpus.',
      ],
      sources: result.chunks
          .map((c) => CapsuleSource(c.fileName, c.score))
          .toList(),
      context: result.chunks,
      extractedAnswer: extracted?.text,
      extractedFrom: extracted == null
          ? null
          : '${extracted.fileName}:${extracted.lineInChunk}',
      generation: generation ??
          (parseError == null
              ? CapsuleGeneration.notRun
              : CapsuleGeneration(ran: true, parseError: parseError)),
      retrieval: _retrievalBlock(result),
    );
  }

  /// Builds a capsule from the model's raw output, falling back cleanly.
  factory ContextCapsule.fromModelOutput(
    String rawOutput,
    SearchResult result, {
    required String model,
    required String backend,
    required int elapsedMs,
    int? tokens,
  }) {
    final parsed = _extractJsonObject(rawOutput);
    if (parsed == null) {
      return ContextCapsule.fromRetrievalOnly(
        result,
        generation: CapsuleGeneration(
          ran: true,
          model: model,
          backend: backend,
          tokens: tokens,
          elapsedMs: elapsedMs,
          parseError: 'No recoverable JSON object in ${rawOutput.length} '
              'characters of output.',
        ),
      );
    }

    final extracted = result.directAnswer;
    final answer = (parsed['answer'] ?? parsed['summary'] ?? '')
        .toString()
        .trim();

    // An empty answer is a failed generation even when the JSON parsed.
    if (answer.isEmpty) {
      return ContextCapsule.fromRetrievalOnly(
        result,
        generation: CapsuleGeneration(
          ran: true,
          model: model,
          backend: backend,
          tokens: tokens,
          elapsedMs: elapsedMs,
          parseError: 'Parsed JSON contained no "answer" field.',
        ),
      );
    }

    final corpus = result.chunks.map((c) => c.content).join('\n');
    final facts = _factList(parsed['key_facts'] ?? parsed['facts'])
        .map((f) => _verify(f, corpus))
        .toList();

    return ContextCapsule(
      query: result.query,
      answer: answer,
      confidence: _confidenceFrom(parsed['confidence']),
      keyFacts: facts,
      caveats: _stringList(parsed['caveats'] ?? parsed['limitations']),
      sources: result.chunks
          .map((c) => CapsuleSource(c.fileName, c.score))
          .toList(),
      context: result.chunks,
      extractedAnswer: extracted?.text,
      extractedFrom: extracted == null
          ? null
          : '${extracted.fileName}:${extracted.lineInChunk}',
      generation: CapsuleGeneration(
        ran: true,
        model: model,
        backend: backend,
        tokens: tokens,
        elapsedMs: elapsedMs,
      ),
      retrieval: _retrievalBlock(result),
    );
  }

  static Map<String, dynamic> _retrievalBlock(SearchResult result) => {
        'encoder': 'all-MiniLM-L6-v2',
        'chunks_returned': result.chunks.length,
        'chunks_scanned': result.totalIndexed,
        'latency_ms': result.latencyMs,
        'embed_ms': result.embedMs,
      };

  /// Marks a fact verified when its quoted span really occurs in the
  /// retrieved text.
  ///
  /// Whitespace is normalised before comparing — the model reflows quotes
  /// constantly, and a fact should not be called unverified over a line
  /// break. Everything else must match exactly; this is a substring check,
  /// not a similarity score, precisely so that "verified" means one thing.
  static CapsuleFact _verify(CapsuleFact fact, String corpus) {
    final quote = fact.verbatim;
    if (quote == null || quote.trim().length < 8) return fact;

    String squash(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
    final verified = squash(corpus).contains(squash(quote));

    return CapsuleFact(
      fact: fact.fact,
      source: fact.source,
      verbatim: quote,
      verified: verified,
    );
  }

  static List<CapsuleFact> _factList(Object? raw) {
    if (raw is! List) return const [];
    final out = <CapsuleFact>[];
    for (final item in raw) {
      if (item is String) {
        if (item.trim().isNotEmpty) out.add(CapsuleFact(fact: item.trim()));
      } else if (item is Map) {
        final fact = (item['fact'] ?? item['claim'] ?? item['text'] ?? '')
            .toString()
            .trim();
        if (fact.isEmpty) continue;
        out.add(CapsuleFact(
          fact: fact,
          source: item['source']?.toString(),
          verbatim: (item['verbatim'] ?? item['quote'])?.toString(),
        ));
      }
      // Cap the list. A looping model will happily emit two hundred
      // near-identical facts, and none after the first handful are useful.
      if (out.length >= 8) break;
    }
    return out;
  }

  static List<String> _stringList(Object? raw) {
    if (raw is String) {
      return raw.trim().isEmpty ? const [] : [raw.trim()];
    }
    if (raw is! List) return const [];
    return raw
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .take(5)
        .toList();
  }
}

// ---------------------------------------------------------------------------
// Recovering JSON from model output
// ---------------------------------------------------------------------------

/// Pulls the first balanced JSON object out of [raw] and parses it,
/// repairing the damage small models commonly produce.
///
/// Returns null when nothing recoverable is there. Exposed for testing.
Map<String, dynamic>? extractCapsuleJson(String raw) => _extractJsonObject(raw);

Map<String, dynamic>? _extractJsonObject(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return null;

  // Strip a ``` or ```json fence if the model added one.
  final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```', multiLine: true)
      .firstMatch(text);
  if (fence != null) text = fence.group(1)!.trim();

  final slice = _firstBalancedObject(text);
  if (slice == null) return null;

  for (final candidate in [slice, _repair(slice)]) {
    try {
      final decoded = jsonDecode(candidate);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (_) {
      // Try the next candidate.
    }
  }
  return null;
}

/// Finds the first complete `{ … }` span, ignoring braces inside strings.
///
/// When the model truncates mid-object nothing ever balances; rather than
/// give up, this closes what is still open. A capsule missing its last field
/// is far more useful than no capsule, and the prompt emits fields in
/// priority order precisely so that a truncation loses the least important
/// ones.
///
/// Tracks a stack of `{` and `[` rather than a brace counter. An array is
/// the most likely thing to be open when the limit is hit — `key_facts` is
/// the longest field — and closing it with `}` produces something that is
/// still unparseable, which was the whole point of trying.
String? _firstBalancedObject(String text) {
  final start = text.indexOf('{');
  if (start < 0) return null;

  final open = <String>[];
  var inString = false;
  var escaped = false;

  for (var i = start; i < text.length; i++) {
    final ch = text[i];

    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }

    if (ch == '"') {
      inString = true;
    } else if (ch == '{' || ch == '[') {
      open.add(ch);
    } else if (ch == '}' || ch == ']') {
      if (open.isNotEmpty) open.removeLast();
      if (open.isEmpty) return text.substring(start, i + 1);
    }
  }

  // Truncated. Close the string if we are inside one, drop whatever partial
  // element trails, then close the containers in reverse order.
  var tail = text.substring(start);
  if (inString) tail += '"';
  tail = _dropDanglingTail(tail);
  for (var i = open.length - 1; i >= 0; i--) {
    tail += open[i] == '{' ? '}' : ']';
  }
  return tail;
}

/// Index of the opening quote of the string [s] ends with, or -1.
int _startOfTrailingString(String s) {
  var i = s.length - 2;
  while (i >= 0) {
    if (s[i] == '"') {
      // An escaped quote is not the opening one. Count the backslashes
      // before it: an even number means this quote is real.
      var backslashes = 0;
      var j = i - 1;
      while (j >= 0 && s[j] == r'\') {
        backslashes++;
        j--;
      }
      if (backslashes.isEven) return i;
    }
    i--;
  }
  return -1;
}

/// Removes a half-written trailing element so the remainder can be closed.
///
/// Three shapes show up when generation is cut off mid-object: a trailing
/// comma, a key with a colon and no value, and a bare key with neither. All
/// three are unparseable however they are closed, and all three are one
/// element the caller was never going to get anyway.
String _dropDanglingTail(String input) {
  var s = input.trimRight();

  // Bounded: each pass removes at least one character, but a guard keeps a
  // pathological input from spinning.
  for (var guard = 0; guard < 32 && s.isNotEmpty; guard++) {
    final last = s[s.length - 1];

    if (last == ',') {
      s = s.substring(0, s.length - 1).trimRight();
      continue;
    }

    if (last == ':') {
      s = s.substring(0, s.length - 1).trimRight();
      if (s.endsWith('"')) {
        final open = _startOfTrailingString(s);
        if (open >= 0) s = s.substring(0, open).trimRight();
      }
      continue;
    }

    if (last == '"') {
      final open = _startOfTrailingString(s);
      if (open < 0) break;
      final before = s.substring(0, open).trimRight();
      // A string straight after '{' or ',' is a key with no value yet.
      // Anything else is a value, and values are worth keeping.
      if (before.endsWith('{') || before.endsWith(',')) {
        s = before;
        continue;
      }
      break;
    }

    break;
  }
  return s;
}

/// Syntactic repairs only. Nothing here changes meaning.
String _repair(String json) {
  var out = json;

  // Smart quotes, which some tokenizers emit for ASCII quotes.
  out = out
      .replaceAll('“', '"')
      .replaceAll('”', '"')
      .replaceAll('‘', "'")
      .replaceAll('’', "'");

  // Trailing commas before a closer. replaceAllMapped, not replaceAll:
  // String.replaceAll does not expand $1, so the plain version silently
  // substitutes the literal text "$1" and produces worse JSON than it got.
  out = out.replaceAllMapped(RegExp(r',(\s*[}\]])'), (m) => m[1]!);

  // Unquoted keys: {key: -> {"key":
  out = out.replaceAllMapped(
    RegExp(r'([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*:)'),
    (m) => '${m[1]}"${m[2]}"${m[3]}',
  );

  // Python-isms.
  out = out
      .replaceAll(RegExp(r'\bNone\b'), 'null')
      .replaceAll(RegExp(r'\bTrue\b'), 'true')
      .replaceAll(RegExp(r'\bFalse\b'), 'false');

  return out;
}
