import onnx
from onnx import helper, TensorProto
import os

def add_argmax_to_decoder(
    input_path: str,
    output_path: str,
):
    print(f"Loading ONNX model from: {input_path} ({os.path.getsize(input_path)/1e6:.1f} MB)...")
    model = onnx.load(input_path)
    graph = model.graph

    # Identify original output name
    orig_output_names = [o.name for o in graph.output]
    print(f"Original graph outputs: {orig_output_names}")
    assert "logits" in orig_output_names, f"Expected 'logits' in outputs, got {orig_output_names}"

    # 1. Create initializer for last index (-1)
    last_idx_name = "last_timestep_idx"
    idx_tensor = helper.make_tensor(
        name=last_idx_name,
        data_type=TensorProto.INT64,
        dims=[],
        vals=[-1],
    )
    graph.initializer.append(idx_tensor)

    # 2. Create Gather node: logits[:, -1, :] on axis=1
    last_logits_name = "last_timestep_logits"
    gather_node = helper.make_node(
        op_type="Gather",
        inputs=["logits", last_idx_name],
        outputs=[last_logits_name],
        name="gather_last_timestep",
        axis=1,
    )
    graph.node.append(gather_node)

    # 3. Create ArgMax node on last_logits along axis=-1 (vocab dimension)
    token_id_name = "token_id"
    argmax_node = helper.make_node(
        op_type="ArgMax",
        inputs=[last_logits_name],
        outputs=[token_id_name],
        name="argmax_token_id",
        axis=-1,
        keepdims=1,
    )
    graph.node.append(argmax_node)

    # 4. Replace graph outputs with token_id (shape: [batch_size, 1], INT64)
    token_id_info = helper.make_tensor_value_info(
        token_id_name,
        TensorProto.INT64,
        ["batch_size", 1],
    )

    while len(graph.output) > 0:
        graph.output.pop()

    graph.output.append(token_id_info)
    print(f"Updated graph outputs: {[o.name for o in graph.output]}")

    # 5. Check and save model
    print("Checking modified model validity...")
    onnx.checker.check_model(model)

    print(f"Saving modified model to: {output_path}...")
    onnx.save(model, output_path)
    print(f"✅ Successfully saved: {output_path} ({os.path.getsize(output_path)/1e6:.1f} MB)")

if __name__ == "__main__":
    src = "assets/models/mt/decoder_model_int8.onnx"
    dst = "assets/models/mt/decoder_model_int8_argmax.onnx"
    add_argmax_to_decoder(src, dst)
