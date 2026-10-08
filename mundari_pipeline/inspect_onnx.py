import onnx

model = onnx.load("assets/models/mt/encoder_with_tokenizer.onnx")

print("Inputs:")
for inp in model.graph.input:
    print(inp.name)

print("\nNodes:")
for node in model.graph.node:
    if node.op_type == "SentencepieceTokenizer":
        print("Found SentencepieceTokenizer!")
        for attr in node.attribute:
            print(f"Attribute: {attr.name}, type: {attr.type}")
            if attr.name == "model":
                # Save the model bytes
                with open("assets/models/mt/spm.model", "wb") as f:
                    f.write(attr.s)
                print("Saved spm.model to assets/models/mt/spm.model")
        print(f"Node outputs: {node.output}")
