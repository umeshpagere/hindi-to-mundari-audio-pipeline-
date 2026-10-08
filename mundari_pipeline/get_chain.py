import onnx
model = onnx.load("assets/models/mt/encoder_with_tokenizer.onnx")

def get_node_by_input(name):
    for n in model.graph.node:
        if name in n.input:
            print(f"{n.op_type}: {n.input} -> {n.output}")
            for o in n.output:
                get_node_by_input(o)

get_node_by_input("spm_ids_int32")
