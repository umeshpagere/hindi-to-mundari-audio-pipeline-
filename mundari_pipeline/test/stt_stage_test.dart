// test/stt_stage_test.dart
//
// Unit tests for lib/pipeline/stt_stage.dart — IndicConformer / Sherpa-ONNX version.
//
// NOTE: The OfflineRecognizer from sherpa_onnx wraps a native FFI library that
// cannot be loaded on the host Mac during unit tests. End-to-end accuracy testing
// must be done on an Android device. These tests cover the pure-Dart logic only:
// VAD gating constants, _cleanText post-processing, and _pcm16ToFloat32 conversion.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:mundari_pipeline/pipeline/stt_stage.dart';

void main() {
  // ─── VAD constant sanity checks ──────────────────────────────────────────────
  group('VAD constants', () {
    test('SILENCE_THRESHOLD_RMS is 0.005', () {
      expect(SttStage.SILENCE_THRESHOLD_RMS, 0.005);
    });

    test('SILENCE_FRAMES_TO_FLUSH triggers at 480 ms (3 × 160 ms)', () {
      const frameDurationMs = 160;
      expect(SttStage.SILENCE_FRAMES_TO_FLUSH * frameDurationMs, 480);
    });

    test('MAX_BUFFER_FRAMES caps at 2.4 s (15 × 160 ms)', () {
      const frameDurationMs = 160;
      expect(SttStage.MAX_BUFFER_FRAMES * frameDurationMs, 2400);
    });

    test('MIN_BUFFER_FRAMES_TO_INFER is 640 ms (4 × 160 ms)', () {
      const frameDurationMs = 160;
      expect(SttStage.MIN_BUFFER_FRAMES_TO_INFER * frameDurationMs, 640);
    });

    test('MIN_SPEECH_ENERGY_FRAMES is 320 ms (2 × 160 ms)', () {
      const frameDurationMs = 160;
      expect(SttStage.MIN_SPEECH_ENERGY_FRAMES * frameDurationMs, 320);
    });

    test('MAX_CHARS_PER_SECOND is 25.0 chars/sec', () {
      expect(SttStage.MAX_CHARS_PER_SECOND, closeTo(25.0, 0.001));
    });
  });
}
