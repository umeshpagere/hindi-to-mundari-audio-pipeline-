import onnx
import sys
import numpy as np

# Load tokens
token_map = {}
with open('assets/models/tts/tokens.txt', 'r', encoding='utf-8') as f:
    for line in f:
        parts = line.strip().rsplit(' ', 1)
        if len(parts) == 2:
            token_map[parts[0]] = int(parts[1])

text = "ଦୁବଇ ଏଯର ପୋଟ କେ ରନବୀ ପର  ସ୍ଟାଇ ଜେଟ କୀ ଫ୍ଲାଇଟ  ଉଡାନ ବରନେ କୋ ପିଲ କୋଲତା ଯାରତୀ  ସଭୀ ପେସିଂଜେସ ଫଲାଇଟ କୀ"

def sherpa_convert(text, token2id, add_blank=1):
    blank_id = 0
    this_sentence = []
    if add_blank:
        this_sentence.append(blank_id)
        for c in text:
            if c in token2id:
                this_sentence.append(token2id[c])
                this_sentence.append(blank_id)
            else:
                pass # skip
    return this_sentence

sherpa_tokens = sherpa_convert(text, token_map, add_blank=1)
print(f"Exact Text:\n{text}")
print(f"\nSherpa-onnx Token ID Array (length {len(sherpa_tokens)}):")
print(sherpa_tokens)

