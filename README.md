# 🎙️ Hindi-to-Mundari Edge Audio Pipeline

> **Fully Offline, Low-Latency Speech-to-Speech Translation (S2ST) for Android ARM Devices**  
> *Hindi Speech (Audio) ➔ Hindi Transcription (STT) ➔ Mundari Translation (MT) ➔ Mundari Speech (TTS)*

---

## 📖 Overview

The **Hindi-to-Mundari Edge Audio Pipeline** is an end-to-end, on-device Speech-to-Speech Translation system designed specifically for resource-constrained mobile hardware (Android ARM64 devices with 2GB–4GB RAM). It enables conversational translation from spoken **Hindi** to spoken **Mundari** (an Austroasiatic language spoken predominantly across Jharkhand, Odisha, and West Bengal in eastern India).

### Key Highlights
- **100% Offline & Private:** Operates entirely on-device without cloud dependencies, external APIs, or network access.
- **Streaming Pipeline Architecture:** Overlaps Speech-to-Text, Machine Translation, Text-to-Speech, and Audio Playback to dramatically minimize **Time-to-First-Audio-Heard (TTFAH)**.
- **Extreme Quantization & Optimization:** Utilizes INT8 quantized models, in-graph ArgMax operations, stripped tokenizers, and custom-compiled C/C++ native binaries.
- **Hardware Acceleration:** Employs Android NNAPI (Neural Networks API) via custom-built `sherpa-onnx` and ONNX Runtime libraries.
- **Real-Time Hardware Telemetry:** Directly samples Linux `/proc` and `/sys` interfaces without root to monitor CPU core frequencies, memory RSS/peak, context switches, and thermal throttling.

---

## 🏗️ System Architecture

The pipeline processes speech through four concurrent stages:

```
[ Microphone Stream / WAV Audio (16 kHz Mono) ]
                     │
                     ▼
┌────────────────────────────────────────────────────────┐
│  STAGE 1: Hindi Speech-to-Text (STT)                   │
│  - Engine: whisper_ggml (whisper.cpp v1.9.1 GGML FFI)  │
│  - Model: Fine-tuned Hindi Whisper Tiny INT8 (~43 MB)  │
│  - Core Allocation: 2 Efficiency Cores (Little Cores)  │
│  - Output: Streaming Hindi Text Clauses                │
└────────────────────────────┬───────────────────────────┘
                             │
                             ▼
┌────────────────────────────────────────────────────────┐
│  STAGE 2: Machine Translation (MT: Hindi ➔ Mundari)    │
│  - Engine: ONNX Runtime + Native Dart SentencePiece    │
│  - Pre-processing: SPM Tokenizer (spm.model)          │
│  - Encoder: Stripped ONNX Encoder (encoder.onnx)       │
│  - Decoder: Autoregressive INT8 ONNX with In-Graph     │
│             ArgMax (decoder_model_int8_argmax.onnx)    │
│  - Vocabulary Remap: tgt_remap_table.bin               │
│  - Post-processing: Devanagari-to-Odia Transliteration │
│    & Phonetic Halant Smoothing (script_utils.dart)     │
│  - Output: Natural Mundari Text Clauses (15-20 chars)  │
└────────────────────────────┬───────────────────────────┘
                             │
                             ▼
┌────────────────────────────────────────────────────────┐
│  STAGE 3: Mundari Text-to-Speech (TTS)                 │
│  - Engine: sherpa_onnx (VITS / MMS Architecture)      │
│  - Hardware Provider: Android NNAPI / CPU Fallback     │
│  - Model: Fine-tuned Mundari VITS INT8 Mixed (~95 MB)  │
│  - Output: 16 kHz 16-bit Mono Linear PCM Audio         │
└────────────────────────────┬───────────────────────────┘
                             │
                             ▼
┌────────────────────────────────────────────────────────┐
│  STAGE 4: Concurrent Gapless Playback & Telemetry      │
│  - Player: AudioPlaybackWorker (async low-latency)     │
│  - Plays clause 1 immediately while downstream clauses │
│    are concurrently translated and synthesized!        │
│  - Telemetry: CPU Freq (Big/Little), RAM RSS, Thermals │
└────────────────────────────────────────────────────────┘
```

### Thread Budgeting & Core Affinity
To prevent thread starvation and thermal throttling on mobile SoCs (e.g., MediaTek Helio, Qualcomm Snapdragon):
- **STT (Whisper):** 2 threads (`kDefaultSttThreads = 2`), budgeted for efficiency cores.
- **MT (ONNX Runtime):** 2 intra-op threads (`kDefaultMtThreads = 2`), budgeted for performance cores.
- **TTS (Sherpa-ONNX):** 3 threads (`kDefaultTtsThreads = 3`), feeding hardware acceleration (NNAPI / GPU / NPU).

---

## 📂 Repository Structure

```
hindi-to-mandari-audio-pipeline/
├── README.md                           # Master project documentation (this file)
├── scratch_compare_wavs.py             # Audio diagnostic tool to compare waveform metrics
│
├── mundari_pipeline/                   # Main Flutter Android Application
│   ├── pubspec.yaml                    # Flutter dependencies, assets, and metadata
│   ├── analysis_options.yaml           # Dart analyzer and linting rules
│   │
│   ├── lib/
│   │   ├── main.dart                   # Application UI, live stream view, & telemetry dashboard
│   │   └── pipeline/                   # Pure business logic (modular, headless, reusable)
│   │       ├── pipeline.dart           # SpeechPipeline orchestrator (batch & live streaming)
│   │       ├── stt_stage.dart          # Stage 1: Whisper GGML Hindi speech-to-text
│   │       ├── mt_stage.dart           # Stage 2: ONNX Hindi-to-Mundari machine translation
│   │       ├── tts_stage.dart          # Stage 3: Sherpa-ONNX Mundari text-to-speech
│   │       ├── script_utils.dart       # Devanagari ➔ Odia transliteration & clause splitter
│   │       ├── audio_playback_worker.dart # Low-latency gapless audio playback worker
│   │       └── device_telemetry.dart   # Linux /proc and /sys hardware monitor
│   │
│   ├── assets/
│   │   ├── models/                     # Quantized on-device model artifacts (~468 MB total)
│   │   │   ├── ggml-tiny-hindi-int8.bin          # STT: Whisper Tiny Hindi INT8
│   │   │   ├── mt/                               # MT: Hindi ➔ Mundari models
│   │   │   │   ├── encoder.onnx                  # Stripped ONNX encoder (token IDs input)
│   │   │   │   ├── decoder_model_int8_argmax.onnx# INT8 decoder with internal ArgMax
│   │   │   │   ├── spm.model                     # SentencePiece tokenizer vocabulary
│   │   │   │   ├── detokenizer.onnx              # Target detokenizer
│   │   │   │   └── tgt_remap_table.bin           # Target vocab to SPM piece ID remap
│   │   │   └── tts/                              # TTS: Mundari VITS models
│   │   │       ├── model_int8_mixed_precision.onnx# Fine-tuned Mundari VITS INT8
│   │   │       └── tokens.txt                    # Mundari character/phoneme tokens
│   │   └── test/
│   │       └── short_7s.wav            # Bundled 7-second 16 kHz Hindi test audio
│   │
│   ├── android/
│   │   ├── app/
│   │   │   ├── build.gradle.kts        # Android build configuration (NDK, ABI filters, noCompress)
│   │   │   └── src/main/
│   │   │       ├── AndroidManifest.xml # Permissions (RECORD_AUDIO, MODIFY_AUDIO_SETTINGS)
│   │   │       └── jniLibs/arm64-v8a/  # Precompiled native shared libraries
│   │   │           ├── libonnxruntime.so
│   │   │           ├── libsherpa-onnx-c-api.so
│   │   │           ├── libsherpa-onnx-cxx-api.so
│   │   │           └── libsherpa-onnx-jni.so
│   │
│   └── scripts/                        # Model optimization & graph transformation scripts
│       ├── add_argmax_to_decoder.py    # Injects Gather + ArgMax into ONNX decoder graph
│       ├── export_remap_table.py       # Extracts binary remap table from detokenizer ONNX
│       ├── strip_tokenizer.py          # Removes custom Sentencepiece node from encoder
│       └── inspect_onnx.py             # Inspects input/output nodes and shapes of ONNX graphs
│
└── sherpa-onnx/                        # Sherpa-ONNX upstream source & cross-compilation tree
    ├── CMakeLists.txt                  # CMake build configuration
    ├── build-android-arm64-v8a.sh      # Cross-compilation script for Android arm64-v8a
    └── ...                             # Toolchains and multi-platform build scripts
```

---

## ⚡ Technical Optimizations & Innovations

### 1. In-Graph ArgMax for MT Decoder (`add_argmax_to_decoder.py`)
In standard seq2seq ONNX decoders, each autoregressive decoding step returns a full logits tensor:
$$\text{shape: } [1, \text{sequence\_length}, \text{vocab\_size}]$$
Transferring this large float array across the Dart FFI boundary at every token step causes heavy memory copying and GC overhead.  
**Optimization:** We injected `Gather(logits[:, -1, :])` and `ArgMax(axis=-1)` directly into the ONNX graph. The decoder now outputs a single scalar INT64 `token_id`, reducing memory bandwidth by over **99%** per decoding step.

### 2. Stripped Encoder Graph (`strip_tokenizer.py`)
Mobile ONNX Runtime does not natively support custom SentencePiece tokenizer operators (`SentencepieceTokenizer`).  
**Optimization:** We stripped the custom tokenizer operator from the ONNX graph and replaced the graph input with raw `spm_ids_int32`. Tokenization is executed in native Dart via `dart_sentencepiece_tokenizer`, allowing pure ONNX Runtime to execute the encoder on mobile without custom operator builds.

### 3. Devanagari-to-Odia Transliteration & Halant Smoothing (`script_utils.dart`)
The MT model decodes into Devanagari script, while the character-level Mundari TTS model expects Odia script representations aligned with `tokens.txt`.
- Translates character blocks with Unicode offset $+0\text{x}0200$.
- Implements phonetic corrections (e.g., Devanagari YA `य` ➔ Odia Yya `ୟ`, `ଈ` ➔ `ଇ`, `ଵ` ➔ `ବ`).
- Strips conjunct halants/viramas (`୍`) to prevent vocoder phase discontinuities and glottal clicks in character-level MMS-TTS.

### 4. Overlapped Streaming Clauses (`AudioPlaybackWorker`)
Instead of waiting for the user to finish speaking an entire paragraph:
1. Whisper emits partial clauses based on pause and punctuation boundaries.
2. The clause is immediately sent to `RealMtStage`.
3. The translated clause is chunked into 15–20 character units and sent to `TtsStage`.
4. `AudioPlaybackWorker` plays clause audio on the speaker without gaps while subsequent clauses are still processing.

---

## 📊 Model Asset Summary

| Stage | Model Name | Format / Precision | Size | Description |
| :--- | :--- | :--- | :--- | :--- |
| **STT** | `ggml-tiny-hindi-int8.bin` | GGML / INT8 | ~43.5 MB | Whisper Tiny architecture fine-tuned on Hindi speech |
| **MT** | `encoder.onnx` | ONNX / FP32 | ~122.1 MB | Stripped Seq2Seq encoder accepting token IDs |
| **MT** | `decoder_model_int8_argmax.onnx`| ONNX / INT8 | ~203.6 MB | Quantized autoregressive decoder with in-graph ArgMax |
| **MT** | `spm.model` | SentencePiece Model | ~3.3 MB | Source & target subword vocabulary |
| **MT** | `tgt_remap_table.bin` | Binary Int32 Table | ~491 KB | Remaps target model tokens to SentencePiece IDs |
| **TTS** | `model_int8_mixed_precision.onnx`| ONNX / Mixed INT8 | ~94.9 MB | Fine-tuned Mundari VITS acoustic model & vocoder |
| **TTS** | `tokens.txt` | Text / Phoneme map | ~362 B | Target phoneme / character lexicon |

> **Note:** Models are bundled inside the APK assets and extracted to device storage on first application launch. Android Gradle configuration disables compression for `.onnx`, `.model`, `.bin`, and `.wav` files to allow fast zero-copy memory mapping.

---

## 🛠️ Prerequisites & Requirements

### Development Host
- **Operating System:** macOS, Linux, or Windows (macOS recommended for iOS/Android cross-compilation).
- **Flutter SDK:** Version `3.13.2` or higher (compatible with Dart `^3.5.0` to `^3.13.2`).
- **Android SDK:** Compile SDK 36, Target SDK 34, Minimum SDK 24 (Android 7.0+; API 27+ recommended for NNAPI).
- **Android NDK:** Version `28.2.13676358` (or compatible NDK r26+).
- **Java Development Kit:** JDK 17.
- **Python (Optional for model conversion):** Python 3.9+ with `onnx`, `numpy`, `sentencepiece`.

### Target Device
- **Architecture:** `arm64-v8a` (64-bit ARM).
- **RAM:** Minimum 2 GB (3 GB+ recommended for continuous streaming sessions).
- **Permissions:** Microphone access (`RECORD_AUDIO`).

---

## 🚀 Setup & Installation Guide

### Step 1: Clone the Repository
```bash
git clone <repository_url> hindi-to-mandari-audio-pipeline
cd hindi-to-mandari-audio-pipeline
```

### Step 2: Verify Model Assets
Ensure all model assets are in place:
```bash
ls -lh mundari_pipeline/assets/models/
ls -lh mundari_pipeline/assets/models/mt/
ls -lh mundari_pipeline/assets/models/tts/
```
If any model files are missing, place the `.bin`, `.onnx`, `.model`, and `tokens.txt` files into their respective directories as described in the [Model Asset Summary](#-model-asset-summary).

### Step 3: Install Flutter Dependencies
Navigate to the Flutter project directory and fetch dependencies:
```bash
cd mundari_pipeline
flutter pub get
```

### Step 4: Verify Android Native Libraries (JNI)
Verify that the prebuilt shared libraries exist in `android/app/src/main/jniLibs/arm64-v8a/`:
```bash
ls -lh android/app/src/main/jniLibs/arm64-v8a/
```
Expected output:
- `libonnxruntime.so` (~21 MB)
- `libsherpa-onnx-c-api.so` (~4.2 MB)
- `libsherpa-onnx-cxx-api.so` (~380 KB)
- `libsherpa-onnx-jni.so` (~4.5 MB)

### Step 5: (Optional) Recompiling Sherpa-ONNX JNI Libraries
If you need to recompile the native libraries for another architecture (e.g., `armeabi-v7a`, `x86_64`) or update ONNX Runtime:
```bash
cd ../sherpa-onnx

# Ensure ANDROID_NDK points to your NDK installation
export ANDROID_NDK=/path/to/Android/sdk/ndk/28.2.13676358

# Build shared libraries for arm64-v8a
export BUILD_SHARED_LIBS=ON
./build-android-arm64-v8a.sh

# Copy the generated libraries to the Flutter project
cp -v build-android-arm64-v8a/install/lib/*.so \
  ../mundari_pipeline/android/app/src/main/jniLibs/arm64-v8a/
```

### Step 6: Connect Device & Run
Connect your Android phone or tablet via USB (ensure USB Debugging is enabled in Developer Options):
```bash
# Check connected devices
flutter devices

# Run in release mode (strongly recommended for accurate real-time inference latency)
flutter run --release
```

> ⚠️ **Important:** Running in `--release` mode is critical for benchmarking. Flutter debug mode introduces substantial JIT overhead, FFI boundary checks, and logging latency.

---

## 📱 Using the Application

The Flutter application provides a dual-mode interface:

### 1. Batch File Test Mode
- Tests the complete pipeline deterministically using the bundled audio sample (`assets/test/short_7s.wav`).
- Tap **"Run Pipeline on Test WAV"**.
- Displays step-by-step latency metrics:
  - **STT Duration:** Hindi transcription time.
  - **MT Duration:** SentencePiece tokenization, encoder execution, autoregressive decoding, and transliteration.
  - **TTS Duration:** Synthesis time for each clause and overall.
  - **Time-to-First-Audio:** Milliseconds elapsed from start to when the first audio chunk is synthesized.
- Tap **"Play Output Audio"** to listen to the synthesized Mundari translation.

### 2. Live Streaming Mode (Real-Time Mic)
- Tap **"Start Live Pipeline"** and grant microphone permissions when prompted.
- Speak in Hindi. As speech pauses occur:
  - Clause cards appear dynamically with live timestamps.
  - Telemetry badges show CPU frequencies, voluntary context switches, and thermal delta.
  - The phone speaker immediately streams the Mundari translation without waiting for you to finish speaking.
- Tap **"Stop Live Session"** to end recording and view the cumulative session breakdown.

---

## 🔧 Model Maintenance & Conversion Scripts

Located in `mundari_pipeline/scripts/` and `mundari_pipeline/`:

### 1. Adding In-Graph ArgMax to MT Decoder
```bash
cd mundari_pipeline
python3 scripts/add_argmax_to_decoder.py
```
Reads `assets/models/mt/decoder_model_int8.onnx`, adds `Gather` on the last sequence timestep and `ArgMax` on the vocabulary axis, then writes `assets/models/mt/decoder_model_int8_argmax.onnx`.

### 2. Extracting Target Remap Table
```bash
cd mundari_pipeline
python3 export_remap_table.py
```
Extracts the raw `tgt_remap_table` weights from `detokenizer.onnx` into a binary format `tgt_remap_table.bin` for fast zero-copy loading into Dart typed arrays (`Int32List`).

### 3. Stripping Tokenizer from Encoder
```bash
cd mundari_pipeline
python3 strip_tokenizer.py
```
Removes custom SentencePiece ONNX nodes from `encoder_with_tokenizer.onnx` so the model can be loaded by standard ONNX Runtime distributions without custom ops.

---

## 🔍 Troubleshooting & FAQs

### 1. `Microphone permission not granted` error
- Ensure you have granted Audio Recording permissions in the app settings or via the prompt.
- Check `AndroidManifest.xml` for `<uses-permission android:name="android.permission.RECORD_AUDIO" />`.

### 2. `UnsatisfiedLinkError` or Sherpa-ONNX bindings failure
- Ensure your device is an `arm64-v8a` device.
- Verify that `libonnxruntime.so` and `libsherpa-onnx-jni.so` exist in `android/app/src/main/jniLibs/arm64-v8a/`.
- Ensure `build.gradle.kts` specifies `ndk.abiFilters += listOf("arm64-v8a")` and `packaging.jniLibs.pickFirsts`.

### 3. Out of Memory (OOM) Crashes during Model Loading
- On devices with 2 GB RAM, concurrent model loading may spike RSS.
- In `SpeechPipeline.init()`, models are loaded in parallel via `Future.wait`. If memory is constrained on older hardware, change this to sequential loading:
  ```dart
  await sttStage.initModel();
  await mtStage.initModel();
  await ttsStage.initModel();
  ```

### 4. NNAPI Provider Fallback
- If `provider: 'nnapi'` fails or crashes on specific non-compliant chipsets, edit `lib/main.dart`:
  ```dart
  ttsStage: TtsStage(threads: kDefaultTtsThreads, provider: 'cpu'),
  ```

---

## 📄 License

This project is licensed under the Apache License 2.0. Third-party components and models (`sherpa-onnx`, `whisper.cpp`, `onnxruntime`) are subject to their respective upstream licenses.
# hindi-to-mundari-audio-pipeline-
