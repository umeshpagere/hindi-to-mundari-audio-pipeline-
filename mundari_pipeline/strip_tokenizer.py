import onnx

model = onnx.load("assets/models/mt/encoder_with_tokenizer.onnx")

tokenizer_node_idx = -1
for i, node in enumerate(model.graph.node):
    if node.op_type == "SentencepieceTokenizer":
        tokenizer_node_idx = i
        break

if tokenizer_node_idx != -1:
    tokenizer_node = model.graph.node[tokenizer_node_idx]
    
    # We want to replace the model input.
    # The tokenizer outputs three tensors: ['spm_ids_int32', 'spm_indices', 'spm_tok_indices']
    # 'spm_ids_int32' is used by the rest of the graph.
    
    # Remove the old input 'hindi_text'
    old_input = model.graph.input[0]
    model.graph.input.remove(old_input)
    
    # Create new input for 'spm_ids_int32' (int32 type)
    new_input = onnx.helper.make_tensor_value_info('spm_ids_int32', onnx.TensorProto.INT32, [None, None])
    model.graph.input.insert(0, new_input)
    
    # Remove the tokenizer node
    del model.graph.node[tokenizer_node_idx]
    
    onnx.save(model, "assets/models/mt/encoder.onnx")
    print("Stripped tokenizer and saved as encoder.onnx")
else:
    print("Tokenizer node not found.")
