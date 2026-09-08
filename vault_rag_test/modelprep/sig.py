import sys, json
try:
    from ai_edge_litert.interpreter import Interpreter
except ImportError:
    from tensorflow.lite import Interpreter
p = sys.argv[1]
it = Interpreter(model_path=p); it.allocate_tensors()
print("=== INPUTS ===")
for d in it.get_input_details():
    print(f"  idx={d['index']:4d} name={d['name']!r:45s} shape={list(d['shape'])} dtype={d['dtype'].__name__}")
print("=== OUTPUTS ===")
for d in it.get_output_details():
    print(f"  idx={d['index']:4d} name={d['name']!r:45s} shape={list(d['shape'])} dtype={d['dtype'].__name__}")
try:
    sl = it.get_signature_list()
    print("=== SIGNATURES ===", json.dumps(sl, indent=2, default=str))
except Exception as e:
    print("no signatures:", e)
