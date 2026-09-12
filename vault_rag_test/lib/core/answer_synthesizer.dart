/// answer_synthesizer.dart
///
/// Produces the `direct_answer` field the desktop client prints above the
/// retrieved chunks.
///
/// THIS IS EXTRACTIVE, NOT GENERATIVE, AND THE DISTINCTION IS THE POINT.
///
/// There is no language model on this device — the vault ships a 23 MB
/// embedding encoder, not a decoder. So rather than pretend, this picks the
/// single most query-relevant *line that already exists* in the retrieved
/// text and returns it verbatim, with its file and line number.
///
/// That is a worse answer than a 7B model would write and a better one for
/// this product: every character returned is quotable back to a source, so
/// an answer can be audited, and the failure mode is "picked a mediocre
/// line" rather than "fluently stated something the corpus never said".
/// The UI labels it "extracted", never "generated".
///
/// The scoring is tuned for the kind of corpus this vault actually holds —
/// configuration and source files, where the answer to "what is the maximum
/// notional order limit" is literally a line reading
/// `MAX_NOTIONAL_PER_ORDER_USD = 15_000_000.00`. Hence the definition boost:
/// a line that binds a name to a value outscores prose mentioning the same
/// words.

library;

import 'vector_store.dart';

class DirectAnswer {
  /// The extracted line, verbatim.
  final String text;
  final String fileName;

  /// 1-based line number within the chunk that produced it.
  final int lineInChunk;

  /// Retrieval score of the chunk this came from.
  final double chunkScore;

  /// Lexical overlap score of the line itself, 0..1-ish. Low values mean
  /// the retriever found a topically-related chunk but no line in it
  /// actually answers the question.
  final double lineScore;

  const DirectAnswer({
    required this.text,
    required this.fileName,
    required this.lineInChunk,
    required this.chunkScore,
    required this.lineScore,
  });

  Map<String, dynamic> toJson() => {
        'text': text,
        'file': fileName,
        'line_in_chunk': lineInChunk,
        'chunk_score': double.parse(chunkScore.toStringAsFixed(4)),
        'line_score': double.parse(lineScore.toStringAsFixed(4)),
        'method': 'extractive',
      };
}

/// Words carrying no retrieval signal. Kept deliberately short: an
/// aggressive stoplist strips domain words that matter in a code corpus
/// ("key", "value", "state" are all real identifiers here).
const _stopwords = {
  'a', 'an', 'the', 'is', 'are', 'was', 'were', 'be', 'been', 'being',
  'of', 'for', 'to', 'in', 'on', 'at', 'by', 'with', 'from', 'as',
  'and', 'or', 'but', 'if', 'then', 'than', 'that', 'this', 'these',
  'those', 'it', 'its', 'what', 'which', 'who', 'whom', 'how', 'when',
  'where', 'why', 'do', 'does', 'did', 'can', 'could', 'should', 'would',
  'will', 'shall', 'may', 'might', 'must', 'have', 'has', 'had', 'me',
  'my', 'our', 'your', 'their', 'there', 'here', 'about', 'into', 'over',
};

/// Splits text into lowercase content terms, also exploding identifiers so
/// a query for "max notional" matches `MAX_NOTIONAL_PER_ORDER_USD`.
///
/// Without this the whole thing fails on exactly the queries it exists to
/// answer: snake_case and camelCase identifiers are a single opaque token
/// to a naive tokenizer, so the one line that literally contains the answer
/// scores zero.
Set<String> _terms(String text) {
  final out = <String>{};
  for (final raw in text.split(RegExp(r'[^A-Za-z0-9_]+'))) {
    if (raw.isEmpty) continue;
    final lower = raw.toLowerCase();
    if (lower.length > 1 && !_stopwords.contains(lower)) out.add(lower);

    // snake_case / SCREAMING_SNAKE -> parts
    for (final part in lower.split('_')) {
      if (part.length > 1 && !_stopwords.contains(part)) out.add(part);
    }
    // camelCase / PascalCase -> parts
    for (final m
        in RegExp(r'[A-Z]+(?![a-z])|[A-Z][a-z]+|[a-z]+|\d+').allMatches(raw)) {
      final part = m.group(0)!.toLowerCase();
      if (part.length > 1 && !_stopwords.contains(part)) out.add(part);
    }
  }
  return out;
}

/// A line that binds a name to a value — the shape most answers take in a
/// config or source corpus.
final _definitionShape = RegExp(
  r'''^\s*[A-Za-z_][A-Za-z0-9_.\[\]'"]*\s*[:=]\s*\S''',
);

/// Picks the best answer line from [results], or null when nothing clears
/// the floor.
///
/// [minLineScore] is a real quality gate, not decoration. Returning a
/// confidently-formatted irrelevant line is worse than returning nothing:
/// the caller prints `direct_answer` in a highlighted box, so a bad one
/// reads as authoritative. Below the floor we return null and let the
/// retrieved chunks speak for themselves.
DirectAnswer? synthesizeDirectAnswer(
  String query,
  List<RetrievedChunk> results, {
  double minLineScore = 0.34,

  /// How many top chunks to read lines from. Beyond about three the
  /// retrieval score is low enough that a high lexical match is usually a
  /// coincidence.
  int considerChunks = 3,
}) {
  final queryTerms = _terms(query);
  if (queryTerms.isEmpty || results.isEmpty) return null;

  DirectAnswer? best;
  var bestCombined = 0.0;

  for (final chunk in results.take(considerChunks)) {
    final lines = chunk.content.split(RegExp(r'[\n\r]+|(?<=[.!?])\s{1,}'));

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      // Too short to be an answer; long enough to be a paragraph is fine.
      if (line.length < 8 || line.length > 400) continue;

      final lineTerms = _terms(line);
      if (lineTerms.isEmpty) continue;

      final overlap = queryTerms.intersection(lineTerms).length;
      if (overlap == 0) continue;

      // Coverage of the *question*, not of the line — a short line that hits
      // every query term beats a long one that happens to contain them all
      // among fifty others.
      var score = overlap / queryTerms.length;

      // Mild penalty for verbosity, so a whole paragraph does not win on
      // surface area alone.
      score *= 1.0 / (1.0 + (lineTerms.length / 60.0));

      if (_definitionShape.hasMatch(line)) score *= 1.6;

      // Weight by how well the chunk itself matched, so a great line in a
      // barely-relevant chunk does not outrank a good line in the right one.
      final combined = score * (0.5 + 0.5 * chunk.score.clamp(0.0, 1.0));

      if (combined > bestCombined) {
        bestCombined = combined;
        best = DirectAnswer(
          text: line,
          fileName: chunk.fileName,
          lineInChunk: i + 1,
          chunkScore: chunk.score,
          lineScore: score,
        );
      }
    }
  }

  if (best == null || best.lineScore < minLineScore) return null;
  return best;
}
