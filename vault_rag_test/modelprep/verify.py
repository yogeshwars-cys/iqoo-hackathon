"""
Verify the converted TFLite model before it ever reaches the phone.

Three checks, in order of how badly a failure would hurt:
  1. Tokenizer  - does tokenizer.dart's simplified WordPiece agree with the
                  real HuggingFace tokenizer on prose AND code?
  2. Numerics   - do the TFLite variants reproduce the ONNX reference
                  embeddings? (cosine sim of mean-pooled, L2-normed vectors)
  3. Retrieval  - on a tiny corpus with known answers, does top-1 match?
"""
import json, os, sys
import numpy as np

sys.path.insert(0, "D:/modelprep")
from dart_tokenizer_port import DartTokenizer

SEQ = 256
OUT = "D:/modelprep/out2"
SRC = "D:/modelprep/src"

VOCAB = open(f"{SRC}/vocab.txt", encoding="utf-8").read()
dart_tok = DartTokenizer(VOCAB, max_len=SEQ)

SENTENCES = [
    "The vector store ranks chunks with brute-force cosine similarity.",
    "def mean_pool(x, mask): return (x * mask).sum(1) / mask.sum(1)",
    "Flutter builds the APK and installs it over USB with adb.",
    "class VectorStore { final Database _db; void insert(TextChunk c) {} }",
    "Encryption at rest is not implemented in this v0 test build.",
    "http://example.com/path?q=1&r=2#frag -- punctuation & symbols!",
]


def l2norm(v):
    n = np.linalg.norm(v)
    return v / n if n > 0 else v


def mean_pool(token_emb, mask):
    """token_emb [S,384], mask [S] -> [384]. Mirrors _meanPoolAndNormalize."""
    m = np.asarray(mask, dtype=np.float64)[:, None]
    valid = max(m.sum(), 1.0)
    return l2norm((token_emb.astype(np.float64) * m).sum(0) / valid)


# ---------------------------------------------------------------- 1. tokenizer
def check_tokenizer():
    print("=" * 70)
    print("1. TOKENIZER  (tokenizer.dart port  vs  real HuggingFace WordPiece)")
    print("=" * 70)
    try:
        from tokenizers import Tokenizer as HFTok
    except ImportError:
        print("  SKIPPED - `tokenizers` not installed")
        return None
    hf = HFTok.from_file(f"{SRC}/tokenizer.json")
    hf.enable_truncation(max_length=SEQ)
    hf.enable_padding(length=SEQ, pad_id=dart_tok.pad_id, pad_token="[PAD]")

    agree = 0
    for s in SENTENCES:
        d_ids, d_mask, _ = dart_tok.encode(s)
        enc = hf.encode(s)
        h_ids = list(enc.ids)
        same = d_ids == h_ids
        agree += same
        if not same:
            dn = sum(d_mask)
            hn = sum(enc.attention_mask)
            print(f"  MISMATCH ({dn} vs {hn} tokens): {s[:58]}")
            for i, (a, b) in enumerate(zip(d_ids, h_ids)):
                if a != b:
                    print(f"     first diff @{i}: dart={a} hf={b}")
                    break
    print(f"  {agree}/{len(SENTENCES)} sentences tokenize identically")
    return agree == len(SENTENCES)


# ------------------------------------------------------------------ 2. numerics
def onnx_reference():
    import onnxruntime as ort
    sess = ort.InferenceSession(f"{SRC}/model.onnx", providers=["CPUExecutionProvider"])
    embs = []
    for s in SENTENCES:
        ids, mask, tt = dart_tok.encode(s)
        out = sess.run(None, {
            "input_ids": np.array([ids], dtype=np.int64),
            "attention_mask": np.array([mask], dtype=np.int64),
            "token_type_ids": np.array([tt], dtype=np.int64),
        })[0][0]
        embs.append(mean_pool(out, mask))
    return np.stack(embs)


def load_interp(path):
    try:
        from ai_edge_litert.interpreter import Interpreter
    except ImportError:
        from tensorflow.lite import Interpreter
    it = Interpreter(model_path=path)
    it.allocate_tensors()
    return it


def map_inputs(inp):
    """Match TFLite input tensors to the three BERT inputs by name."""
    by_name = {}
    for d in inp:
        n = d["name"].split("/")[-1].split(":")[0].lower()
        for key in ("input_ids", "attention_mask", "token_type_ids"):
            if key in n:
                by_name[key] = d
    return by_name


def tflite_embed(interp, sentences):
    inp = interp.get_input_details()
    out = interp.get_output_details()
    by_name = map_inputs(inp)
    if len(by_name) != 3:
        raise RuntimeError(f"could not map inputs by name: {[d['name'] for d in inp]}")
    embs = []
    for s in sentences:
        ids, mask, tt = dart_tok.encode(s)
        vals = {"input_ids": ids, "attention_mask": mask, "token_type_ids": tt}
        for key, d in by_name.items():
            interp.set_tensor(d["index"], np.array([vals[key]], dtype=d["dtype"]))
        interp.invoke()
        o = interp.get_tensor(out[0]["index"])[0]
        embs.append(mean_pool(o, mask))
    return np.stack(embs), inp, out


def check_numerics():
    print()
    print("=" * 70)
    print("2. NUMERICS  (TFLite  vs  ONNX reference)")
    print("=" * 70)
    ref = onnx_reference()
    results = {}
    cands = [f for f in sorted(os.listdir(OUT)) if f.endswith(".tflite")]
    for f in cands:
        path = os.path.join(OUT, f)
        try:
            it = load_interp(path)
            embs, inp, out = tflite_embed(it, SENTENCES)
        except Exception as e:
            print(f"  {f:42s} FAILED: {type(e).__name__}: {e}")
            continue
        cos = [float(np.dot(a, b)) for a, b in zip(ref, embs)]
        mb = os.path.getsize(path) / 1e6
        print(f"  {f:42s} {mb:7.2f} MB  cos min={min(cos):.5f} mean={np.mean(cos):.5f}")
        results[f] = dict(path=path, size=mb, cos_min=min(cos),
                          cos_mean=float(np.mean(cos)),
                          inputs=[(d["name"], list(map(int, d["shape"])), str(d["dtype"])) for d in inp],
                          outputs=[(d["name"], list(map(int, d["shape"])), str(d["dtype"])) for d in out])
    return results


# ----------------------------------------------------------------- 3. retrieval
CORPUS = [
    ("vector_store.dart", "Brute-force cosine similarity ranks every stored chunk. Fine up to a few thousand rows on phone hardware."),
    ("chunking.dart", "Splits raw text into overlapping 256-word windows with 32 words of overlap between neighbours."),
    ("embedding_service.dart", "Wraps a quantized TFLite export of MiniLM and runs it with the NNAPI delegate on Android."),
    ("main.dart", "The upload button opens a file picker restricted to text and source-code extensions."),
    ("implementation.md", "No encryption at rest yet. Add it before the real demo, not before this retrieval test."),
]
QUERIES = [
    ("How are chunks ranked against the query?", "vector_store.dart"),
    ("What is the overlap between windows?", "chunking.dart"),
    ("Is the data encrypted on disk?", "implementation.md"),
    ("Which hardware accelerator runs the model?", "embedding_service.dart"),
]


def check_retrieval(path):
    print()
    print("=" * 70)
    print(f"3. RETRIEVAL  ({os.path.basename(path)})")
    print("=" * 70)
    it = load_interp(path)
    docs, _, _ = tflite_embed(it, [c[1] for c in CORPUS])
    qs, _, _ = tflite_embed(it, [q[0] for q in QUERIES])
    hits = 0
    for (q, expect), qe in zip(QUERIES, qs):
        scores = docs @ qe
        order = np.argsort(-scores)
        top = CORPUS[order[0]][0]
        ok = top == expect
        hits += ok
        print(f"  [{'PASS' if ok else 'FAIL'}] {q}")
        print(f"         top1={top} ({scores[order[0]]:.3f})  expected={expect}")
    print(f"  {hits}/{len(QUERIES)} queries retrieved the right chunk")
    return hits == len(QUERIES)


if __name__ == "__main__":
    tok_ok = check_tokenizer()
    res = check_numerics()
    if not res:
        print("\nNo usable TFLite model produced.")
        sys.exit(1)
    # Prefer a model that is numerically faithful; among those, the smallest.
    best = max(res.items(), key=lambda kv: (kv[1]["cos_min"] > 0.999, -kv[1]["size"]))
    print(f"\n=== signature of {best[0]} ===")
    for n, s, d in best[1]["inputs"]:
        print(f"  IN   {n:34s} {s} {d}")
    for n, s, d in best[1]["outputs"]:
        print(f"  OUT  {n:34s} {s} {d}")
    ret_ok = check_retrieval(best[1]["path"])
    json.dump(res, open("D:/modelprep/verify_report.json", "w"), indent=2)
    print(f"\ntokenizer_ok={tok_ok}  retrieval_ok={ret_ok}  chosen={best[0]}")
