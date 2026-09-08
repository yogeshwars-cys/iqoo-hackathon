"""Inspect the MiniLM ONNX graph: input/output names, dtypes, shapes."""
import onnx
from onnx import TensorProto

m = onnx.load("D:/modelprep/src/model.onnx")
g = m.graph

def dt(t):
    return TensorProto.DataType.Name(t)

def shape_of(vi):
    d = vi.type.tensor_type.shape.dim
    return [x.dim_param if x.dim_param else x.dim_value for x in d]

print("ir_version:", m.ir_version)
print("opset:", [(o.domain or "ai.onnx", o.version) for o in m.opset_import])
print("\n=== INPUTS ===")
for vi in g.input:
    print(f"  {vi.name:20s} {dt(vi.type.tensor_type.elem_type):10s} {shape_of(vi)}")
print("\n=== OUTPUTS ===")
for vi in g.output:
    print(f"  {vi.name:20s} {dt(vi.type.tensor_type.elem_type):10s} {shape_of(vi)}")
print("\nnodes:", len(g.node))
