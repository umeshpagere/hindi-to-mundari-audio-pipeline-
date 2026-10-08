import onnx
from onnx import numpy_helper
import numpy as np
import os

model_path = "assets/models/mt/detokenizer.onnx"
output_path = "assets/models/mt/tgt_remap_table.bin"

print(f"Loading {model_path}...")
model = onnx.load(model_path)

table = None
for init in model.graph.initializer:
    if init.name == "tgt_remap_table":
        table = numpy_helper.to_array(init)
        break

if table is None:
    raise ValueError("tgt_remap_table not found in initializers!")

print(f"Found tgt_remap_table: shape={table.shape}, dtype={table.dtype}, min={table.min()}, max={table.max()}")

# Convert to int32 little-endian
table_int32 = table.astype(np.int32)
with open(output_path, "wb") as f:
    f.write(table_int32.tobytes())

file_size = os.path.getsize(output_path)
print(f"Successfully exported {output_path} ({file_size} bytes, {len(table_int32)} elements)")
