"""Emit Dart test goldens from the tokenizer that verify.py proved matches HF."""
import sys, json
sys.path.insert(0, "D:/modelprep")
from dart_tokenizer_port import DartTokenizer

vocab = open("D:/modelprep/src/vocab.txt", encoding="utf-8").read()
tok = DartTokenizer(vocab, max_len=32)

CASES = [
    "Hello world!",
    "def mean_pool(x, mask):",
    "VectorStore ranks chunks by cosine similarity.",
]
print("special:", tok.cls_id, tok.sep_id, tok.pad_id, tok.unk_id)
out = []
for c in CASES:
    ids, mask, _ = tok.encode(c)
    n = sum(mask)
    out.append({"text": c, "ids": ids[:n], "len": n})
print(json.dumps(out, indent=2))
