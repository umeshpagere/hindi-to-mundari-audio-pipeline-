import urllib.request

# 1. Parse vocab exactly like C++ sherpa-onnx does it
vocab = {}
with open('assets/models/tts/tokens.txt', 'r', encoding='utf-8') as f:
    for line in f:
        # C++ ReadTokens logic splits by space from right
        parts = line.rstrip('\n').rsplit(' ', 1)
        if len(parts) == 2:
            vocab[parts[0]] = int(parts[1])

print(f"Vocab size: {len(vocab)}")
blank_id = 53
print(f"Using blank_id: {blank_id}")

# 2. Tokenize text
text = "ଅଲ୍ ଚିକି"

# 3. Interleave blanks like text_to_ids
def text_to_ids(text, vocab, add_blank=True):
    ids = [vocab[ch] for ch in text if ch in vocab]
    if add_blank:
        interleaved = [blank_id]
        for token_id in ids:
            interleaved.extend([token_id, blank_id])
        return interleaved
    return ids

tokens = text_to_ids(text, vocab)
print(f"Python text_to_ids() output:\n{tokens}")

# Now replicate what Sherpa-ONNX ConvertTextToTokenIds does:
print("\nSimulating sherpa-onnx ConvertTextToTokenIds() output:")
def sherpa_convert(text, token2id, add_blank=1):
    this_sentence = []
    if add_blank:
        this_sentence.append(blank_id)
        for c in text:
            if c in token2id:
                this_sentence.append(token2id[c])
                this_sentence.append(blank_id)
            else:
                print(f"Skip unknown character: {c}")
    return this_sentence

sherpa_tokens = sherpa_convert(text, vocab, add_blank=1)
print(f"Sherpa-onnx output:\n{sherpa_tokens}")

if tokens == sherpa_tokens:
    print("\nCONCLUSION: Both lists are IDENTICAL.")
else:
    print("\nCONCLUSION: Mismatch found!")

