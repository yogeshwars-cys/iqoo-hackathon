"""
Line-for-line Python port of lib/tokenizer.dart.

Exists so we can test the Dart tokenizer's *actual logic* against the real
HuggingFace WordPiece tokenizer, instead of trusting the "simplified but
probably fine" comment in the Dart source. Keep this in sync with
tokenizer.dart if that file changes.
"""
import re

PUNCT_RE = re.compile(r"[!-\/:-@\[-`{-~]")
WS_RE = re.compile(r"\s+")


class DartTokenizer:
    def __init__(self, vocab_text: str, max_len: int = 256):
        self.vocab = {}
        for i, line in enumerate(vocab_text.split("\n")):
            tok = line.strip()
            if tok:
                self.vocab[tok] = i
        for t in ("[CLS]", "[SEP]", "[PAD]", "[UNK]"):
            if t not in self.vocab:
                raise ValueError(f'vocab.txt missing required special token "{t}"')
        self.cls_id = self.vocab["[CLS]"]
        self.sep_id = self.vocab["[SEP]"]
        self.pad_id = self.vocab["[PAD]"]
        self.unk_id = self.vocab["[UNK]"]
        self.max_len = max_len

    def _basic_tokenize(self, text):
        lower = text.lower()
        spaced = PUNCT_RE.sub(lambda m: f" {m.group(0)} ", lower)
        return [w for w in WS_RE.split(spaced) if w]

    def _word_piece(self, word):
        if len(word) > 100:
            return [self.unk_id]
        ids = []
        start = 0
        while start < len(word):
            end = len(word)
            matched = None
            while start < end:
                sub = word[start:end]
                if start > 0:
                    sub = "##" + sub
                if sub in self.vocab:
                    matched = sub
                    break
                end -= 1
            if matched is None:
                return [self.unk_id]
            ids.append(self.vocab[matched])
            start = end
        return ids

    def encode(self, text):
        words = self._basic_tokenize(text)
        ids = [self.cls_id]
        for w in words:
            ids.extend(self._word_piece(w))
            if len(ids) >= self.max_len - 1:
                break
        if len(ids) > self.max_len - 1:
            del ids[self.max_len - 1:]
        ids.append(self.sep_id)

        input_ids = [self.pad_id] * self.max_len
        attention_mask = [0] * self.max_len
        token_type_ids = [0] * self.max_len
        for i, v in enumerate(ids):
            input_ids[i] = v
            attention_mask[i] = 1
        return input_ids, attention_mask, token_type_ids
