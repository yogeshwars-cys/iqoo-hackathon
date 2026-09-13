"""
Re-export all-MiniLM-L6-v2 as an accelerator-friendly TFLite graph for the
Qualcomm QNN HTP (Hexagon NPU) delegate.

WHY THE EXISTING EXPORT CANNOT RUN ON HTP

The model shipped from convert.py is numerically right but structurally
hostile to an NPU: onnx2tf carried ONNX's runtime shape computation through
verbatim, so a 6-layer encoder is 664 nodes, of which ~300 are SHAPE / SLICE /
STRIDED_SLICE / CONCATENATION / GATHER-on-shape plumbing, plus SELECT/EQUAL
mask logic on bool tensors and 4 int64 tensors. HTP has no int64, and every
runtime-shape op either stays on the CPU (fragmenting the graph into many
partitions) or makes graph finalisation fail — which is exactly the device
result "QNN unavailable: Unable to create interpreter".

WHAT THIS DOES

  1. onnxsim with the static 1x256 shapes: constant-folds every Shape ->
     Gather -> Concat -> Reshape chain into literal shapes.
  2. Removes the Cast(int32 -> int64) edge nodes fix_onnx.py inserted: the
     Gather lookups accept int32 indices directly, so no int64 survives.
  3. onnx2tf with optimization_for_gpu_delegate, which rewrites remaining ops
     into forms accelerator delegates accept.
  4. VERIFIES before writing anything the app will use:
       - op census of the result (no SHAPE, no int64 tensors)
       - mean-pooled embeddings vs the ONNX reference (onnxruntime) and vs
         the currently shipped TFLite: cosine >= 0.9999 on prose and code
       - top-1 retrieval agreement on a small labelled corpus
     and exits non-zero if any check fails.

Usage (model-prep venv):
    D:/modelprep/.venv/Scripts/python.exe modelprep/export_htp.py
Output:
    D:/modelprep/out_htp/minilm_l6_v2_htp.tflite  (+ report JSON)
Copy it over assets/models/minilm_l6_v2.tflite only if verification passed.
"""
import collections
import json
import os
import shutil
import sys

import numpy as np

SRC_ONNX = "D:/modelprep/src/model_int32_1x256.onnx"
REF_ONNX = "D:/modelprep/src/model.onnx"
SHIPPED = os.path.join(os.path.dirname(__file__), "..", "assets", "models", "minilm_l6_v2.tflite")
OUT = "D:/modelprep/out_htp"
SEQ = 256
# onnx2tf GPU-delegate rewrite injects LESS/SELECT index normalisation around
# GATHER that stock TFLite cannot even prepare; off by default.
GPU_OPT = os.environ.get("VAULT_GPU_OPT") == "1"

sys.path.insert(0, os.path.dirname(__file__))
from dart_tokenizer_port import DartTokenizer  # noqa: E402

SENTENCES = [
    "The risk engine rejects any order whose notional exceeds 250,000 USD.",
    "def mean_pool(x, mask): return (x * mask).sum(1) / mask.sum(1)",
    "Employee Jun Quispe has an annual base salary of USD 98,500.",
    "The corporate card 4809 0798 9117 9197 is issued to Dmitri Novak.",
    "Retry with exponential backoff starting at 200 ms, capped at 30 seconds.",
    "class VectorStore { final Database _db; void insert(TextChunk c) {} }",
]
CORPUS = [
    "MAX_ORDER_USD = 250000 and REVIEW_THRESHOLD_USD = 100000",
    "The primary ledger database runs on db-1.internal port 6432.",
    "Security incident: an exposed backup leaked 21,342 customer records.",
    "Employees accrue 1.75 days of paid leave per month of service.",
]
QUERIES = [
    ("what is the maximum order size in usd", 0),
    ("which port does the ledger database use", 1),
    ("how many customer records leaked", 2),
    ("how much paid leave do employees get", 3),
]


def step(msg):
    print(f"\n=== {msg} ===", flush=True)


def simplify():
    import onnx
    from onnxsim import simplify as onnx_simplify

    step("1. onnxsim constant folding (static 1x256)")
    model = onnx.load(SRC_ONNX)
    before = collections.Counter(n.op_type for n in model.graph.node)
    model, ok = onnx_simplify(model, overwrite_input_shapes={
        "input_ids": [1, SEQ], "attention_mask": [1, SEQ], "token_type_ids": [1, SEQ]})
    if not ok:
        sys.exit("onnxsim could not validate the simplified model")

    step("2. drop int32->int64 edge casts feeding lookups")
    graph = model.graph
    inputs = {i.name for i in graph.input}
    removed = 0
    for node in list(graph.node):
        if node.op_type != "Cast" or node.input[0] not in inputs:
            continue
        consumers = [n for n in graph.node if node.output[0] in n.input]
        # Only safe when every consumer is an index-taking lookup.
        if consumers and all(c.op_type == "Gather" and c.input[1] == node.output[0]
                             for c in consumers):
            for c in consumers:
                c.input[1] = node.input[0]
            graph.node.remove(node)
            removed += 1
    print(f"removed {removed} Cast node(s)")

    step("2b. NPU-safe attention mask")
    rewired = _rewrite_attention_mask(model)
    print(f"attention-mask Where replaced for {rewired} consumer(s)")
    model, ok = onnx_simplify(model, overwrite_input_shapes={
        "input_ids": [1, SEQ], "attention_mask": [1, SEQ], "token_type_ids": [1, SEQ]})
    if not ok:
        sys.exit("onnxsim could not validate the mask-rewritten model")
    graph = model.graph
    after = collections.Counter(n.op_type for n in graph.node)
    print(f"ONNX nodes {sum(before.values())} -> {sum(after.values())}")
    for op in ("Shape", "Gather", "Concat", "Slice", "Where", "Equal", "Cast"):
        print(f"  {op:8s} {before.get(op, 0):4d} -> {after.get(op, 0):4d}")
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, "model_htp_prepared.onnx")
    onnx.save(model, path)
    return path


def _rewrite_attention_mask(model):
    """Replace HF BERT's extended attention mask
         Where(bool(1 - mask), -3.4e38, 1 - mask)      (via int64 Cast + Expand)
    with
         (1 - float(mask)) * -1e4, shaped [1, 1, 1, SEQ]
    -3.4e38 overflows FP16 (HTP's precision) to -inf and poisons softmax with
    NaN; Where on bool plus the int64 Expand are not NPU-friendly either.
    exp(-1e4) underflows to exactly 0 in float32, so masked attention weights
    are unchanged — verified numerically in step 4.
    """
    import numpy as np
    from onnx import helper, numpy_helper

    g = model.graph
    wheres = [n for n in g.node if n.op_type == "Where"
              and any(i for i in n.input if "Constant" in i or i.startswith("/Constant"))]
    target = None
    for n in wheres:
        consumers = [c for c in g.node if n.output[0] in c.input]
        if consumers and all(c.op_type == "Add" and "attention" in c.name for c in consumers):
            target = (n, consumers)
            break
    if target is None:
        sys.exit("attention-mask Where not found; the ONNX graph layout changed")
    where, consumers = target

    g.initializer.extend([
        numpy_helper.from_array(np.array([1, 1, 1, SEQ], dtype=np.int64), "vault_mask_shape"),
        numpy_helper.from_array(np.array(1.0, dtype=np.float32), "vault_one"),
        numpy_helper.from_array(np.array(-1e4, dtype=np.float32), "vault_mask_neg"),
    ])
    g.node.extend([
        helper.make_node("Cast", ["attention_mask"], ["vault_mask_f"], to=1, name="vault_mask_cast"),
        helper.make_node("Reshape", ["vault_mask_f", "vault_mask_shape"], ["vault_mask_4d"],
                         name="vault_mask_reshape"),
        helper.make_node("Sub", ["vault_one", "vault_mask_4d"], ["vault_mask_inv"], name="vault_mask_inv"),
        helper.make_node("Mul", ["vault_mask_inv", "vault_mask_neg"], ["vault_mask_bias"],
                         name="vault_mask_bias"),
    ])
    for c in consumers:
        for i, name in enumerate(c.input):
            if name == where.output[0]:
                c.input[i] = "vault_mask_bias"
    # Old chain is now dead; onnxsim removes it. Topologically re-sort.
    import onnx
    nodes = list(g.node)
    produced = {i.name for i in g.input} | {i.name for i in g.initializer}
    ordered, pending = [], nodes
    while pending:
        progress = [n for n in pending if all((not i) or i in produced for i in n.input)]
        if not progress:
            sys.exit("graph rewrite produced a cycle / dangling input")
        for n in progress:
            ordered.append(n)
            produced.update(n.output)
        pending = [n for n in pending if n not in progress]
    del g.node[:]
    g.node.extend(ordered)
    onnx.checker.check_model(model)
    return len(consumers)


def convert(onnx_path):
    import onnx2tf

    step(f"3. onnx2tf (optimization_for_gpu_delegate={GPU_OPT})")
    tf_dir = os.path.join(OUT, "tf")
    shutil.rmtree(tf_dir, ignore_errors=True)
    onnx2tf.convert(
        input_onnx_file_path=onnx_path,
        output_folder_path=tf_dir,
        overwrite_input_shape=[f"input_ids:1,{SEQ}", f"attention_mask:1,{SEQ}",
                               f"token_type_ids:1,{SEQ}"],
        output_signaturedefs=True,
        copy_onnx_input_output_names_to_tflite=True,
        optimization_for_gpu_delegate=GPU_OPT,
        non_verbose=True,
    )
    produced = [f for f in os.listdir(tf_dir) if f.endswith("float32.tflite")]
    if not produced:
        sys.exit("onnx2tf produced no float32 tflite")
    dst = os.path.join(OUT, "minilm_l6_v2_htp.tflite")
    shutil.copy(os.path.join(tf_dir, produced[0]), dst)
    return dst


def census(path):
    import tensorflow as tf

    it = tf.lite.Interpreter(model_path=path)
    ops = collections.Counter(op["op_name"] for op in it._get_ops_details())
    dtypes = collections.Counter(t["dtype"].__name__ for t in it.get_tensor_details())
    dynamic = sum(1 for t in it.get_tensor_details() if -1 in list(t.get("shape_signature", [])))
    return ops, dtypes, dynamic, it


def run_tflite(it, text, tok):
    ids, mask, types = tok.encode(text)
    feed = {"input_ids": ids, "attention_mask": mask, "token_type_ids": types}
    it.allocate_tensors()
    for d in it.get_input_details():
        key = next(k for k in feed if k in d["name"])
        it.set_tensor(d["index"], np.array([feed[key]], dtype=np.int32))
    it.invoke()
    out = it.get_tensor(it.get_output_details()[0]["index"])[0]
    m = np.array(mask, dtype=np.float64)[:, None]
    v = (out.astype(np.float64) * m).sum(0) / max(m.sum(), 1)
    return v / np.linalg.norm(v)


def run_onnx(sess, text, tok):
    ids, mask, types = tok.encode(text)
    feed = {"input_ids": np.array([ids], dtype=np.int64),
            "attention_mask": np.array([mask], dtype=np.int64),
            "token_type_ids": np.array([types], dtype=np.int64)}
    names = {i.name for i in sess.get_inputs()}
    out = sess.run(None, {k: v for k, v in feed.items() if k in names})[0][0]
    m = np.array(mask, dtype=np.float64)[:, None]
    v = (out.astype(np.float64) * m).sum(0) / max(m.sum(), 1)
    return v / np.linalg.norm(v)


def main():
    tok = DartTokenizer(open("D:/modelprep/src/vocab.txt", encoding="utf-8").read(), max_len=SEQ)
    new_path = convert(simplify())

    step("4. verification")
    import onnxruntime as ort

    ops_new, dt_new, dyn_new, it_new = census(new_path)
    ops_old, dt_old, _, it_old = census(SHIPPED)
    print(f"TFLite nodes: shipped {sum(ops_old.values())} -> HTP export {sum(ops_new.values())}")
    print("HTP export ops:", dict(sorted(ops_new.items(), key=lambda x: -x[1])))
    print("HTP export tensor dtypes:", dict(dt_new), "dynamic tensors:", dyn_new)

    sess = ort.InferenceSession(REF_ONNX, providers=["CPUExecutionProvider"])
    failures = []
    report = {"nodes_shipped": sum(ops_old.values()), "nodes_htp": sum(ops_new.values()),
              "ops_htp": dict(ops_new), "dtypes_htp": dict(dt_new), "cosines": []}
    for s in SENTENCES:
        ref = run_onnx(sess, s, tok)
        new = run_tflite(it_new, s, tok)
        old = run_tflite(it_old, s, tok)
        c_ref, c_old = float(ref @ new), float(old @ new)
        report["cosines"].append({"text": s[:40], "vs_onnx": c_ref, "vs_shipped": c_old})
        print(f"  cos vs ONNX {c_ref:.6f}  vs shipped {c_old:.6f}  | {s[:50]}")
        if c_ref < 0.9999 or c_old < 0.9999:
            failures.append(f"cosine below 0.9999 for: {s[:40]}")

    corpus_vecs = [run_tflite(it_new, c, tok) for c in CORPUS]
    for q, want in QUERIES:
        qv = run_tflite(it_new, q, tok)
        got = int(np.argmax([qv @ c for c in corpus_vecs]))
        print(f"  top-1 {'OK ' if got == want else 'BAD'} {q}")
        if got != want:
            failures.append(f"retrieval top-1 wrong for: {q}")

    if ops_new.get("SHAPE", 0):
        failures.append(f"{ops_new['SHAPE']} SHAPE ops remain")
    if dt_new.get("int64", 0):
        failures.append(f"{dt_new['int64']} int64 tensors remain")
    if dyn_new:
        failures.append(f"{dyn_new} dynamic tensors")

    report["failures"] = failures
    with open(os.path.join(OUT, "export_htp_report.json"), "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    if failures:
        print("\nVERIFICATION FAILED:\n  " + "\n  ".join(failures))
        sys.exit(1)
    print(f"\nVERIFIED: {new_path}")


if __name__ == "__main__":
    main()
