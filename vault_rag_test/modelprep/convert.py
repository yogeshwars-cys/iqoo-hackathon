"""
Convert all-MiniLM-L6-v2 ONNX -> TFLite for the Vault RAG Flutter app.

Produces a model with a STATIC 1x256 signature, matching tokenizer.dart's
fixed maxLen padding. Emits both float32 and dynamic-range-quantized
variants so we can measure the quantization's effect on retrieval quality
rather than assuming it's harmless.
"""
import os, sys, shutil

SRC = "D:/modelprep/src/model_int32_1x256.onnx"
OUT = "D:/modelprep/out2"
SEQ = 256

os.makedirs(OUT, exist_ok=True)

import onnx2tf

print(f"=== onnx2tf: {SRC} -> {OUT} (1x{SEQ}) ===", flush=True)
onnx2tf.convert(
    input_onnx_file_path=SRC,
    output_folder_path=OUT,
    overwrite_input_shape=[
        f"input_ids:1,{SEQ}",
        f"attention_mask:1,{SEQ}",
        f"token_type_ids:1,{SEQ}",
    ],
    output_signaturedefs=True,
    copy_onnx_input_output_names_to_tflite=True,
    output_dynamic_range_quantized_tflite=True,
    non_verbose=True,
)

print("\n=== produced files ===")
for f in sorted(os.listdir(OUT)):
    p = os.path.join(OUT, f)
    if os.path.isfile(p):
        print(f"  {f:45s} {os.path.getsize(p)/1e6:8.2f} MB")
