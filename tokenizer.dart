/// tokenizer.dart
///
/// Minimal WordPiece tokenizer compatible with BERT-family vocabularies,
/// which is what all-MiniLM-L6-v2 uses. Load the model's vocab.txt as a
/// Flutter asset and pass its text content to Tokenizer.fromVocabText.
///
/// This is a simplified BasicTokenizer + WordPiece pass — correct for
/// standard English source code and prose (this project's stated scope:
/// .py, .js, .json, .txt, .md). It does not replicate every edge case of
/// the original HuggingFace tokenizer (e.g. some Unicode normalization),
/// which does not matter for chunking your own codebase.

class EncodedInput {
  final List<int> inputIds;
  final List<int> attentionMask;
  final List<int> tokenTypeIds;

  EncodedInput(this.inputIds, this.attentionMask, this.tokenTypeIds);
}

class Tokenizer {
  final Map<String, int> vocab;
  final int clsId;
  final int sepId;
  final int padId;
  final int unkId;
  final int maxLen;

  Tokenizer._(
    this.vocab,
    this.clsId,
    this.sepId,
    this.padId,
    this.unkId,
    this.maxLen,
  );

  factory Tokenizer.fromVocabText(String vocabText, {int maxLen = 256}) {
    final lines = vocabText.split('\n');
    final vocab = <String, int>{};
    for (var i = 0; i < lines.length; i++) {
      final tok = lines[i].trim();
      if (tok.isNotEmpty) vocab[tok] = i;
    }
    int required(String t) {
      final id = vocab[t];
      if (id == null) {
        throw StateError('vocab.txt is missing required special token "$t"');
      }
      return id;
    }

    return Tokenizer._(
      vocab,
      required('[CLS]'),
      required('[SEP]'),
      required('[PAD]'),
      required('[UNK]'),
      maxLen,
    );
  }

  List<String> _basicTokenize(String text) {
    final lower = text.toLowerCase();
    // Pad ASCII punctuation with spaces so it splits into its own token,
    // then collapse whitespace and split.
    final spaced = lower.replaceAllMapped(
      RegExp(r'[!-\/:-@\[-`{-~]'),
      (m) => ' ${m[0]} ',
    );
    return spaced.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  }

  List<int> _wordPiece(String word) {
    if (word.length > 100) return [unkId];
    final ids = <int>[];
    var start = 0;
    while (start < word.length) {
      var end = word.length;
      String? matched;
      while (start < end) {
        var sub = word.substring(start, end);
        if (start > 0) sub = '##$sub';
        if (vocab.containsKey(sub)) {
          matched = sub;
          break;
        }
        end--;
      }
      if (matched == null) return [unkId];
      ids.add(vocab[matched]!);
      start = end;
    }
    return ids;
  }

  /// Encodes [text] into fixed-length input_ids / attention_mask /
  /// token_type_ids arrays, each of length [maxLen], ready to feed
  /// straight into the TFLite interpreter.
  EncodedInput encode(String text) {
    final words = _basicTokenize(text);
    final ids = <int>[clsId];
    for (final w in words) {
      ids.addAll(_wordPiece(w));
      if (ids.length >= maxLen - 1) break;
    }
    if (ids.length > maxLen - 1) {
      ids.removeRange(maxLen - 1, ids.length);
    }
    ids.add(sepId);

    final inputIds = List<int>.filled(maxLen, padId);
    final attentionMask = List<int>.filled(maxLen, 0);
    final tokenTypeIds = List<int>.filled(maxLen, 0);
    for (var i = 0; i < ids.length; i++) {
      inputIds[i] = ids[i];
      attentionMask[i] = 1;
    }
    return EncodedInput(inputIds, attentionMask, tokenTypeIds);
  }
}
