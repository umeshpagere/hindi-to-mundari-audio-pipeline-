import onnx
import sys

# 1. Update ONNX metadata
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
print("Updated ONNX blank_id to 0")

# 2. Shift tokens.txt
with open('assets/models/tts/tokens.txt', 'r', encoding='utf-8') as f:
    lines = f.read().splitlines()

new_lines = ["<blank> 0"]
for line in lines:
    if not line.strip(): continue
    parts = line.rstrip('\n').rsplit(' ', 1)
    if len(parts) == 2:
        char = parts[0]
        old_id = int(parts[1])
        new_lines.append(f"{char} {old_id + 1}")

with open('assets/models/tts/tokens.txt', 'w', encoding='utf-8') as f:
    f.write("\n".join(new_lines) + "\n")

print("Shifted tokens.txt by +1 and added <blank> 0")
