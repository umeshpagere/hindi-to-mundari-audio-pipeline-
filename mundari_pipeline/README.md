# 📱 Mundari Pipeline (Flutter Mobile Client)

> **On-Device Hindi-to-Mundari Streaming Audio Pipeline**  
> Flutter client application featuring Whisper STT, ONNX Runtime MT, Sherpa-ONNX TTS, and real-time Linux hardware telemetry.

---

## 📌 Overview

This directory contains the Flutter Android application for the **Hindi-to-Mundari Edge Audio Pipeline**. It hosts both the user interface for live/batch translation testing and the pure headless business logic library located in [`lib/pipeline/`](file:///Users/umeshpagere/hindi-to-mandari-audio-pipeline/mundari_pipeline/lib/pipeline).

For the overarching project architecture, model conversion utilities, and native compilation guides, please refer to the [Root README](file:///Users/umeshpagere/hindi-to-mandari-audio-pipeline/README.md).

---

## 📂 Directory Layout

```
mundari_pipeline/
├── pubspec.yaml                 # Dependencies and asset declarations
├── analysis_options.yaml        # Flutter analysis linter settings
├── lib/
│   ├── main.dart                # Flutter UI (Batch Testing, Live Mic Streaming, Telemetry Cards)
│   └── pipeline/                # Modular Headless Pipeline (NO BuildContext / UI dependencies)
│       ├── pipeline.dart        # SpeechPipeline orchestrator (batch & live streaming workflows)
│       ├── stt_stage.dart       # Whisper GGML STT wrapper (ggml-tiny-hindi-int8)
│       ├── mt_stage.dart        # ONNX Runtime Seq2Seq MT wrapper (RealMtStage)
│       ├── tts_stage.dart       # Sherpa-ONNX VITS TTS wrapper (NNAPI / CPU acceleration)
│       ├── script_utils.dart    # Devanagari -> Odia transliteration & clause splitter
│       ├── audio_playback_worker.dart # Gapless async audio playback queue
│       └── device_telemetry.dart# Linux /proc & /sys hardware performance profiler
├── assets/
│   ├── models/                  # On-device model binaries (STT, MT, TTS)
│   └── test/                    # 16 kHz WAV audio files for validation (short_7s.wav)
├── android/
│   └── app/
│       ├── build.gradle.kts     # Build script, NDK 28, ABI filters, noCompress rules
│       └── src/main/
│           ├── AndroidManifest.xml # RECORD_AUDIO & MODIFY_AUDIO_SETTINGS permissions
│           └── jniLibs/arm64-v8a/  # Prebuilt shared libraries (ONNX Runtime, Sherpa-ONNX)
└── scripts/                     # Python scripts for ONNX graph edits and quantization
```

---

## ⚡ Architecture at a Glance

The pipeline orchestrator ([`pipeline.dart`](file:///Users/umeshpagere/hindi-to-mandari-audio-pipeline/mundari_pipeline/lib/pipeline/pipeline.dart)) coordinates three decoupled stages:

1. **STT Stage ([`stt_stage.dart`](file:///Users/umeshpagere/hindi-to-mandari-audio-pipeline/mundari_pipeline/lib/pipeline/stt_stage.dart)):**
   - Uses `whisper_ggml` (whisper.cpp GGML FFI).
   - Transcribes 16 kHz Hindi audio stream into clause chunks.
   - 2 dedicated threads allocated to efficiency cores.

2. **MT Stage ([`mt_stage.dart`](file:///Users/umeshpagere/hindi-to-mandari-audio-pipeline/mundari_pipeline/lib/pipeline/mt_stage.dart)):**
   - Native Dart SentencePiece tokenization (`dart_sentencepiece_tokenizer`).
   - ONNX Runtime session for encoder (`encoder.onnx`) and quantized decoder (`decoder_model_int8_argmax.onnx`).
   - Target token remap via binary table (`tgt_remap_table.bin`).
   - Transliterates Devanagari to Odia script and smooths halants for phoneme-aligned TTS.

3. **TTS Stage ([`tts_stage.dart`](file:///Users/umeshpagere/hindi-to-mandari-audio-pipeline/mundari_pipeline/lib/pipeline/tts_stage.dart)):**
   - Uses `sherpa_onnx` (`OfflineTts`) with mixed-precision INT8 VITS model.
   - Leverages Android NNAPI for hardware acceleration (PowerVR/Mali/Adreno GPU/NPU).
   - Generates 16 kHz 16-bit mono linear PCM audio.

4. **Audio Playback Worker ([`audio_playback_worker.dart`](file:///Users/umeshpagere/hindi-to-mandari-audio-pipeline/mundari_pipeline/lib/pipeline/audio_playback_worker.dart)):**
   - Implements low-latency gapless queueing.
   - Begins speaker playback as soon as Clause 1 finishes synthesis, overlapping playback with downstream translation.

5. **Device Telemetry ([`device_telemetry.dart`](file:///Users/umeshpagere/hindi-to-mandari-audio-pipeline/mundari_pipeline/lib/pipeline/device_telemetry.dart)):**
   - Continuously samples `/sys/devices/system/cpu/cpu*/cpufreq/` for Big and Little core frequencies.
   - Tracks process RSS, peak memory (HWM), voluntary/involuntary context switches, and thermal zone temperatures.

---

## 🚀 Quick Setup & Run

### Prerequisites
- Flutter SDK `^3.13.2` or newer
- Android SDK & NDK `28.2.13676358`
- Physical Android ARM64 device with USB debugging enabled

### Commands
```bash
# 1. Fetch dependencies
flutter pub get

# 2. Run static analysis
flutter analyze

# 3. Deploy to connected device in Release mode
flutter run --release
```

> **Why Release Mode?**  
> Flutter debug mode disables compiler optimizations, adds Dart JIT overhead, and significantly inflates ONNX Runtime FFI calls. Always evaluate latency and Time-to-First-Audio in `--release` mode.
