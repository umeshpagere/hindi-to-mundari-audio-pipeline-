import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mundari_pipeline/pipeline/pipeline.dart';

void main() {
  group('Bidirectional Pipeline Logic & DTO Tests', () {
    test('PipelineResult preserves Hindi to Mundari mapping', () {
      final result = PipelineResult(
        sourceText: 'नमस्ते दुनिया',
        targetText: 'जोहार धरती',
        direction: TranslationDirection.hindiToMundari,
        sttMs: 250,
        mtMs: 120,
        ttsMs: 310,
        firstClauseTtsMs: 180,
        clauseCount: 1,
        audioBytes: Uint8List.fromList([0, 1, 2, 3]),
        audioSampleRate: 22050,
      );

      expect(result.direction, TranslationDirection.hindiToMundari);
      expect(result.sourceText, 'नमस्ते दुनिया');
      expect(result.targetText, 'जोहार धरती');
      expect(result.hindiText, 'नमस्ते दुनिया');
      expect(result.mundariText, 'जोहार धरती');
      expect(result.timeToFirstAudioMs, 250 + 120 + 180);
    });

    test('PipelineResult preserves Mundari to Hindi mapping', () {
      final result = PipelineResult(
        sourceText: 'जोहार धरती',
        targetText: 'नमस्ते दुनिया',
        direction: TranslationDirection.mundariToHindi,
        sttMs: 220,
        mtMs: 110,
        ttsMs: 15,
        firstClauseTtsMs: 15,
        clauseCount: 1,
        audioBytes: Uint8List(0),
        audioSampleRate: 22050,
      );

      expect(result.direction, TranslationDirection.mundariToHindi);
      expect(result.sourceText, 'जोहार धरती');
      expect(result.targetText, 'नमस्ते दुनिया');
      expect(result.hindiText, 'नमस्ते दुनिया');
      expect(result.mundariText, 'जोहार धरती');
      expect(result.timeToFirstAudioMs, 220 + 110 + 15);
    });

    test('LiveClauseTiming getters reflect direction correctly', () {
      final h2m = LiveClauseTiming(
        clauseIndex: 0,
        sourceText: 'मैं घर जा रहा हूँ',
        targetText: 'अइंग ओड़ाः सेनतन',
        tMic: DateTime.now(),
        tStt: DateTime.now(),
        chunkDurationMs: 480,
        direction: TranslationDirection.hindiToMundari,
      );

      expect(h2m.sourceText, 'मैं घर जा रहा हूँ');
      expect(h2m.targetText, 'अइंग ओड़ाः सेनतन');
      expect(h2m.hindiText, 'मैं घर जा रहा हूँ');
      expect(h2m.mundariText, 'अइंग ओड़ाः सेनतन');

      final m2h = LiveClauseTiming(
        clauseIndex: 1,
        sourceText: 'अइंग ओड़ाः सेनतन',
        targetText: 'मैं घर जा रहा हूँ',
        tMic: DateTime.now(),
        tStt: DateTime.now(),
        chunkDurationMs: 480,
        direction: TranslationDirection.mundariToHindi,
      );

      expect(m2h.sourceText, 'अइंग ओड़ाः सेनतन');
      expect(m2h.targetText, 'मैं घर जा रहा हूँ');
      expect(m2h.hindiText, 'मैं घर जा रहा हूँ');
      expect(m2h.mundariText, 'अइंग ओड़ाः सेनतन');
    });
  });
}
