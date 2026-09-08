"""
Rewrite the MiniLM ONNX graph so the TFLite export is safe for tflite_flutter.

Two changes, both non-negotiable for this app:

1. INT64 -> INT32 inputs.
   tflite_flutter's ByteConversionUtils writes int32 tensors with
   Endian.little but int64 tensors with Endian.big. On ARM (little-endian)
   that means every int64 value handed to the interpreter arrives
   byte-swapped, so the model would silently embed garbage. Declaring the
   graph inputs as int32 and casting to int64 inside the graph keeps the
   model's semantics identical while staying on the code path that works.

2. Dynamic ['batch_size', 'sequence_length'] -> static [1, 256].
   tokenizer.dart always pads to exactly 256, so nothing is lost, and a
   static graph avoids per-call tensor reallocation on device.
"""
import onnx
from onnx import TensorProto, helper

SRC = "D:/modelprep/src/model.onnx"
DST = "D:/modelprep/src/model_int32_1x256.onnx"
BATCH, SEQ = 1, 256
INPUTS = ["input_ids", "attention_mask", "token_type_ids"]

model = onnx.load(SRC)
graph = model.graph

cast_nodes = []
for name in INPUTS:
    vi = next(v for v in graph.input if v.name == name)

    # 1. Declare the graph input as int32 with a fully static shape.
    vi.type.tensor_type.elem_type = TensorProto.INT32
    dims = vi.type.tensor_type.shape.dim
    del dims[:]
    for d in (BATCH, SEQ):
        dims.add().dim_value = d

    # 2. Everything downstream still expects int64, so cast right at the edge.
    cast_out = f"{name}_int64"
    for node in graph.node:
        for i, inp in enumerate(node.input):
            if inp == name:
                node.input[i] = cast_out
    cast_nodes.append(
        helper.make_node("Cast", [name], [cast_out],
                         name=f"cast_{name}_to_int64", to=TensorProto.INT64)
    )

# Casts must run before any consumer: ONNX requires topological order.
graph.node.extend(cast_nodes)
nodes = list(graph.node)
del graph.node[:]
graph.node.extend(cast_nodes + [n for n in nodes if n not in cast_nodes])

# Pin the output shape too, so shape inference has nothing left to guess.
out = graph.output[0]
dims = out.type.tensor_type.shape.dim
del dims[:]
for d in (BATCH, SEQ, 384):
    dims.add().dim_value = d

# Stale value_info from the dynamic graph would contradict the new shapes.
del graph.value_info[:]

model = onnx.shape_inference.infer_shapes(model, strict_mode=False)
onnx.checker.check_model(model, full_check=False)
onnx.save(model, DST)

print(f"wrote {DST}")
m = onnx.load(DST)
for vi in list(m.graph.input) + list(m.graph.output):
    tt = vi.type.tensor_type
    shape = [d.dim_param or d.dim_value for d in tt.shape.dim]
    print(f"  {vi.name:20s} {TensorProto.DataType.Name(tt.elem_type):8s} {shape}")

# Prove the rewrite did not change the maths.
import numpy as np, onnxruntime as ort

rng = np.random.default_rng(0)
ids = rng.integers(999, 29000, size=(BATCH, SEQ))
mask = np.ones((BATCH, SEQ), dtype=np.int64)
tt_ids = np.zeros((BATCH, SEQ), dtype=np.int64)

a = ort.InferenceSession(SRC, providers=["CPUExecutionProvider"]).run(
    None, {"input_ids": ids.astype(np.int64), "attention_mask": mask,
           "token_type_ids": tt_ids})[0]
b = ort.InferenceSession(DST, providers=["CPUExecutionProvider"]).run(
    None, {"input_ids": ids.astype(np.int32), "attention_mask": mask.astype(np.int32),
           "token_type_ids": tt_ids.astype(np.int32)})[0]
print(f"  max abs diff vs original ONNX: {np.abs(a - b).max():.3e}")
