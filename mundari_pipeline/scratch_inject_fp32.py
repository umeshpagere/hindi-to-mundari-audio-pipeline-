import onnx
model_path = 'assets/models/tts/mundari_tts_fp32.onnx'
model = onnx.load(model_path)
found = False
for prop in model.metadata_props:
    if prop.key == 'blank_id':
        prop.value = '0'
        found = True
if not found:
    prop = model.metadata_props.add()
    prop.key = 'blank_id'
    prop.value = '0'
onnx.save(model, model_path)
print("Injected blank_id=0 into FP32 model")
