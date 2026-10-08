import onnxruntime as ort
import numpy as np
import wave
import json

# 1. Parse vocab
vocab = {}
with open('assets/models/tts/tokens.txt', 'r', encoding='utf-8') as f:
    for line in f:
        parts = line.strip().split()
        if len(parts) >= 2:
            vocab[parts[0]] = int(parts[1])

print(f"Vocab size: {len(vocab)}")
blank_id = 53
print(f"Using blank_id: {blank_id}")

# 2. Tokenize text
text = "ଅଲ୍ ଚିକି"
# 3. Interleave blanks
def text_to_ids(text, vocab, add_blank=True):
    ids = [vocab[ch] for ch in text if ch in vocab]
    if add_blank:
        interleaved = [blank_id]
        for token_id in ids:
            interleaved.extend([token_id, blank_id])
        return interleaved
    return ids

tokens = text_to_ids(text, vocab)
print(f"Tokens for '{text}': {tokens}")

# 4. Run ONNX inference
model_path = 'assets/models/tts/mundari_tts_fixed.onnx'
sess = ort.InferenceSession(model_path)

x = np.array([tokens], dtype=np.int64)
x_length = np.array([len(tokens)], dtype=np.int64)
noise_scale = np.array([0.667], dtype=np.float32)
length_scale = np.array([1.0], dtype=np.float32)
noise_scale_w = np.array([0.8], dtype=np.float32)

inputs = {
    'x': x,
    'x_length': x_length,
    'noise_scale': noise_scale,
    'length_scale': length_scale,
    'noise_scale_w': noise_scale_w
}

outputs = sess.run(['y'], inputs)
audio = outputs[0].squeeze()

# 5. Save WAV
with wave.open('test_output.wav', 'wb') as wf:
    wf.setnchannels(1)
    wf.setsampwidth(2)
    wf.setframerate(16000) # Assuming MMS sample rate
    audio_int16 = (audio * 32767.0).astype(np.int16)
    wf.writeframes(audio_int16.tobytes())

print("Saved test_output.wav")
