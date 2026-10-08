import onnx

model = onnx.load("assets/models/mt/encoder_with_tokenizer.onnx")

for node in model.graph.node:
    if "input_ids" in node.output:
        print(f"Node outputting input_ids: {node.op_type} -> Inputs: {node.input}")

