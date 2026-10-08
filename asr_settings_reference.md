# IndicConformer ASR Pipeline — Settings Reference

> All settings verified working on **Galaxy Tab A7 Lite** (MediaTek Helio P22T).
> Final inference latency: **~1.6s**. No hallucination on silence.

---

## 1. Model

| Setting | Value | Notes |
|---|---|---|
| **Model** | AI4Bharat IndicConformer | NeMo CTC architecture |
| **Model File** | `model.int8.onnx` | INT8 quantized (verified internally via ONNX graph — contains `DynamicQuantizeLinear` + `MatMulInteger` nodes) |
| **Model Size** | ~196 MB | Compressed from ~780MB FP32 |
| **Tokens File** | `tokens.txt` | Must be in the same directory as the model |
| **Model Type** | `OfflineNemoEncDecCtcModelConfig` | Sherpa-ONNX class for NeMo CTC models |

---

## 2. Sherpa-ONNX OfflineRecognizer Config

| Setting | Value | Notes |
|---|---|---|
| **`provider`** | `"xnnpack"` | ⚠️ Critical for performance on ARM Cortex devices. Do NOT use `"cpu"`. |
| **`numThreads`** | `2` | Leaves 2 cores free for UI thread + future MT/TTS models |
| **`decodingMethod`** | `"greedy_search"` | Fastest. Beam search would be more accurate but ~3× slower |
| **`sampleRate`** (FeatureConfig) | `16000` | 16kHz mono audio required |
| **`featureDim`** (FeatureConfig) | `80` | 80-dimensional log-mel filterbanks |
| **`debug`** | `false` | Set to `true` only during development to enable Sherpa verbose logs |

---

## 3. Audio Capture Pipeline

| Setting | Value | Notes |
|---|---|---|
| **Sample Rate** | `16000 Hz` | 16kHz mono |
| **Audio Format** | `PCM_16BIT` mono | Standard Android mic format |
| **Audio Source** | `MediaRecorder.AudioSource.MIC` | Change to `VOICE_COMMUNICATION` when you add TTS speaker output to enable hardware Acoustic Echo Cancellation |
| **Chunk Duration** | `160 ms` | 2560 samples @ 16kHz per chunk |
| **Stride Duration** | `160 ms` | Non-overlapping chunks (stride = chunk size). No audio duplication. |
| **Ring Buffer Size** | `3.2 seconds` | 51,200 samples @ 16kHz |

---

## 4. Voice Activity Detection (VAD)

| Setting | Constant | Value | Effective Duration | Notes |
|---|---|---|---|---|
| **Silence RMS Threshold** | `SILENCE_THRESHOLD_RMS` | `0.008f` | — | RMS amplitude below this = silence. Calibrated for typical Android mic. |
| **Silence Flush Trigger** | `SILENCE_FRAMES_TO_FLUSH` | `4 frames` | **640 ms** | After this many consecutive silent chunks, the engine flushes & runs inference |
| **Max Buffer Ceiling** | `MAX_BUFFER_FRAMES` | `15 frames` | **2.4 seconds** | Hard limit: forces a flush even mid-sentence to prevent the model from processing huge audio chunks |

---

## 5. Anti-Hallucination Gates

Three sequential gates must ALL pass before any inference is allowed:

### Gate 1 — Minimum Buffer Context
| Constant | Value | Effective Duration |
|---|---|---|
| `MIN_BUFFER_FRAMES_TO_INFER` | `12 frames` | **1.92 seconds** |

**What it does:** The model must have accumulated at least 1.92 seconds of total audio before a single inference call is made. Prevents the model from trying to transcribe a 160ms snippet of noise.

---

### Gate 2 — Minimum Speech Energy
| Constant | Value | Effective Duration |
|---|---|---|
| `MIN_SPEECH_ENERGY_FRAMES` | `6 frames` | **960 ms** |

**What it does:** Of the frames in the buffer, at least 6 must have an RMS above `SILENCE_THRESHOLD_RMS`. This ensures ~1 second of actual human voice energy is present. Room noise, AC hum, and tablet fan noise will never pass this gate.

---

### Gate 3 — Character Rate Plausibility Filter
| Constant | Value | Multiplier |
|---|---|---|
| `MAX_CHARS_PER_SECOND` | `6.0f chars/sec` | Reject if output exceeds `1.5×` this rate |

**What it does:** After inference, the output text's character count is checked against the trimmed audio duration. If the model outputs characters faster than a human can speak (~9 chars/sec), the result is discarded as a hallucination. Calibrated for Hindi.

---

## 6. Post-Processing

### CTC Repetition Artifact Cleaner
Runs on every raw inference output before it reaches the UI:
- **Prefix deduplication:** Drops a word if the next word starts with it (e.g., `मु मुझ` → `मुझ`). CTC emits a partial token just before the full token on ambiguous word boundaries.
- **Consecutive duplicate removal:** Drops repeated consecutive words.
- **Intra-word loop collapse:** Detects repeating character patterns within a word (e.g., `नंदंदंद` → `नंद`). Triggered on nasals in Hindi.

### Trailing Repetition Filter
Applied at the utterance finalization stage:
- Before appending a new partial result to the full transcript, it checks if the transcript already ends with that exact phrase.
- If yes, the new result is silently dropped (logged as a warning). This stops edge hallucinations like `है है है` from stacking up.

---

## 7. Silence Trimming (Pre-Inference)

Before passing the audio buffer to the model, leading and trailing silent chunks are trimmed:
- **Keeps 2 chunks (~320ms) of context on each side** to preserve phoneme boundary cues that the model expects at utterance edges.
- This significantly reduces the actual audio the model processes (e.g., a 2.4s buffer might contain only 1.2s of real speech after trimming).

---

## 8. Performance Summary (Galaxy Tab A7 Lite)

| Metric | Value |
|---|---|
| Feature Extraction Latency | ~3–9 ms per chunk |
| Inference Latency (final decode) | **~1,600–1,800 ms** |
| Total Perceived Latency (speech end → result) | **~2.2 seconds** |
| App RAM Usage | **~373 MB PSS** (stable, no leaks) |
| Silence Hallucination | **None** (all three gates block it) |

---

## 9. Thread Budget (for Future Multi-Model Pipeline)

| Model | Threads | Notes |
|---|---|---|
| **ASR (IndicConformer)** | `2` | Current setting |
| **MT (Machine Translation)** | `1` | Planned |
| **TTS (Text-to-Speech)** | `1` | Planned |
| **Total** | `4` | Fits on 4 performance cores without thermal throttling |

> [!IMPORTANT]
> When you add TTS speaker output alongside mic input, change `AudioSource.MIC` → `AudioSource.VOICE_COMMUNICATION` and enable `AcousticEchoCanceler` to prevent the speaker audio from looping back into the ASR mic.
