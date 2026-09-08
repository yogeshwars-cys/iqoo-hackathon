/// chunking.dart
///
/// Splits raw text into overlapping windows suitable for embedding.
///
/// NOTE ON "TOKENS": this approximates tokens as whitespace-delimited words
/// rather than true WordPiece subword tokens. That is intentional for a
/// 30-hour build: chunk *boundaries* don't need to exactly match the
/// tokenizer's subword boundaries, because embedding_service.dart re-runs
/// the real WordPiece tokenizer over each chunk's raw text anyway. Worst
/// case a chunk is a little longer or shorter than 256 real subword tokens
/// (WordPiece can split one word into 2-3 subwords for code identifiers
/// and rare words) — encode() in tokenizer.dart truncates safely if that
/// happens, so nothing breaks. Don't spend hackathon hours making this
/// exact; it isn't the bottleneck.

class TextChunk {
  final String id;
  final String fileName;
  final String content;
  final int startWord;
  final int endWord;

  TextChunk({
    required this.id,
    required this.fileName,
    required this.content,
    required this.startWord,
    required this.endWord,
  });
}

class Chunker {
  final int windowSize;
  final int overlap;

  Chunker({this.windowSize = 256, this.overlap = 32})
      : assert(overlap >= 0 && overlap < windowSize,
            'overlap must be >= 0 and smaller than windowSize');

  /// Splits [text] (the full contents of one file) into overlapping chunks.
  /// Returns an empty list for blank/whitespace-only input.
  List<TextChunk> chunk(String fileName, String text) {
    final words =
        text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return [];

    final stride = windowSize - overlap;
    final chunks = <TextChunk>[];
    var start = 0;
    var index = 0;

    while (start < words.length) {
      final end = (start + windowSize).clamp(0, words.length);
      final content = words.sublist(start, end).join(' ');
      chunks.add(TextChunk(
        id: '${fileName}_chunk_${index.toString().padLeft(3, '0')}',
        fileName: fileName,
        content: content,
        startWord: start,
        endWord: end,
      ));
      index++;
      if (end == words.length) break;
      start += stride;
    }
    return chunks;
  }
}
