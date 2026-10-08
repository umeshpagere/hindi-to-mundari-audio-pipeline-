import onnx
import os

model_path = 'assets/models/tts/mundari_tts_fixed.onnx'
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
print("Verified ONNX blank_id = 0")

vocab_path = '/Users/umeshpagere/model quatization/mms_tts_work/vocab.txt'
tokens_path = 'assets/models/tts/tokens.txt'
with open(vocab_path, 'r', encoding='utf-8') as f:
    symbols = [line.strip() for line in f.readlines()]

with open(tokens_path, 'w', encoding='utf-8') as f:
    for idx, sym in enumerate(symbols):
        if sym:
            f.write(f"{sym} {idx}\n")

print(f"Restored tokens.txt with {len([s for s in symbols if s])} tokens starting from 0.")
