import onnx

model = onnx.load("assets/models/mt/encoder_with_tokenizer.onnx")

for node in model.graph.node:
    if "SentencepieceTokenizer" in node.op_type:
        continue
    # Just look at the nodes right after the tokenizer
    if "spm_ids_int32" in node.input or "input_ids" in node.input:
        print(f"Node OP: {node.op_type}")
        print(f"Inputs: {node.input}")
        print(f"Outputs: {node.output}")

# Find what the input to the actual encoder is
for inp in model.graph.value_info:
    if inp.name == "spm_ids_int32":
        print(f"ValueInfo spm_ids_int32: {inp}")

for inp in model.graph.input:
    print(f"Model Input: {inp.name} -> type {inp.type}")
