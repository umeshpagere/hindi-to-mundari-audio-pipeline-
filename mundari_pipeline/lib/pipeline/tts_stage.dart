import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle, AssetManifest;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart';

import '../services/hindi_tts_service.dart';
import 'pipeline.dart' show kDefaultTtsThreads, TranslationDirection;

/// Stage 4 of the pipeline: Text-to-Speech via sherpa-onnx with NNAPI acceleration.
///
/// Uses custom-compiled sherpa-onnx (targeting Android API 27) to enable
/// ONNX Runtime NNAPI hardware acceleration on Android devices.
class TtsStage {
  OfflineTts? _tts;
  bool _isInitialized = false;

  final int threads;
  final String provider; // 'nnapi' or 'cpu'

  TtsStage({
    this.threads = kDefaultTtsThreads,
    this.provider = 'cpu',
  });

  bool get isInitialized => _isInitialized;

  /// Reads current process RAM from Android /proc/self/status
  static String getMemoryInfo() {
    try {
      final status = File('/proc/self/status').readAsStringSync();
      final vmRssMatch = RegExp(r'VmRSS:\s+(\d+\s+\w+)').firstMatch(status);
      final vmHwmMatch = RegExp(r'VmHWM:\s+(\d+\s+\w+)').firstMatch(status);
      final rss = vmRssMatch?.group(1) ?? 'N/A';
      final peak = vmHwmMatch?.group(1) ?? 'N/A';
      return 'RAM: RSS=$rss, Peak=$peak';
    } catch (_) {
      return 'RAM: N/A';
    }
  }

  static const String _modelAssetKey = 'assets/models/tts/mundari.onnx';
  static const String _tokensAssetKey = 'assets/models/tts/tokens.txt';
  static const String _espeakAssetPrefix = 'assets/models/tts/espeak-ng-data/';

  /// Initializes the Sherpa ONNX OfflineTts engine with the Mundari Piper-VITS model
  /// and connects to Android on-device Hindi TextToSpeech.
  Future<void> initModel() async {
    // Proactively initialize on-device Android Hindi TTS
    await HindiTtsService.instance.init();

    if (_isInitialized) return;

    await initBindingsAsync();

    final Directory tmpDir = await getTemporaryDirectory();
    final String modelPath = '${tmpDir.path}/mundari.onnx';
    final String tokensPath = '${tmpDir.path}/tts_tokens.txt';
    final String espeakDir  = '${tmpDir.path}/espeak-ng-data';

    // Extract main model and tokens
    await _extractAsset(_modelAssetKey, modelPath);
    await _extractAsset(_tokensAssetKey, tokensPath);

    // Extract every espeak-ng-data file (sherpa-onnx needs real FS paths)
    await _extractEspeakData(espeakDir);

    print('[TTS-Init] Configuring sherpa-onnx OfflineTts: provider="$provider", threads=$threads (Piper-VITS) | ${getMemoryInfo()}');

    final vitsConfig = OfflineTtsVitsModelConfig(
      model: modelPath,
      lexicon: '',
      tokens: tokensPath,
      dataDir: espeakDir,
      noiseScale: 0.667,
      noiseScaleW: 0.8,
      lengthScale: 1.0,
    );

    final modelConfig = OfflineTtsModelConfig(
      vits: vitsConfig,
      numThreads: threads,
      debug: false,
      provider: provider,
    );

    final ttsConfig = OfflineTtsConfig(
      model: modelConfig,
      ruleFsts: '',
    );

    final initWatch = Stopwatch()..start();
    _tts = OfflineTts(ttsConfig);
    initWatch.stop();

    _isInitialized = true;
    print('[TTS-Init] sherpa-onnx OfflineTts (Piper-VITS mundari.onnx) created in ${initWatch.elapsedMilliseconds}ms | sample_rate=${_tts!.sampleRate} | ${getMemoryInfo()}');
  }

  Future<void> _extractAsset(String assetKey, String destPath) async {
    // Always overwrite to ensure fresh model files after app updates
    final ByteData data = await rootBundle.load(assetKey);
    final List<int> bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    await File(destPath).writeAsBytes(bytes, flush: true);
  }

  /// Extracts all files under assets/models/tts/espeak-ng-data/ to [destDir].
  Future<void> _extractEspeakData(String destDir) async {
    List<String> assetKeys = [];
    try {
      final AssetManifest manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      assetKeys = manifest.listAssets();
    } catch (_) {
      try {
        final String manifestJson = await rootBundle.loadString('AssetManifest.json');
        final Map<String, dynamic> manifest = _parseManifest(manifestJson);
        assetKeys = manifest.keys.toList();
      } catch (_) {
        assetKeys = [];
      }
    }

    final espeakFiles = assetKeys
        .where((k) => k.startsWith(_espeakAssetPrefix))
        .toList();

    for (final assetKey in espeakFiles) {
      final relativePath = assetKey.substring(_espeakAssetPrefix.length);
      final destPath = '$destDir/$relativePath';
      final destFile = File(destPath);
      await destFile.parent.create(recursive: true);
      final ByteData data = await rootBundle.load(assetKey);
      await destFile.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    print('[TTS-Init] Extracted ${espeakFiles.length} espeak-ng-data files to $destDir');
  }

  static Map<String, dynamic> _parseManifest(String json) {
    final Map<String, dynamic> result = {};
    final RegExp re = RegExp(r'"([^"]+)"\s*:');
    for (final m in re.allMatches(json)) {
      result[m.group(1)!] = true;
    }
    return result;
  }



  /// Synthesizes text into audio (Mundari via Sherpa-ONNX VITS, Hindi via Android on-device TextToSpeech).
  Future<TtsResult> synthesize(String text, {TranslationDirection direction = TranslationDirection.hindiToMundari}) async {
    if (direction == TranslationDirection.mundariToHindi) {
      final t0 = DateTime.now();
      await HindiTtsService.instance.speak(text);
      final elapsedMs = DateTime.now().difference(t0).inMilliseconds;
      debugPrint('[TTS] Spoke Hindi via Android on-device TextToSpeech in ${elapsedMs}ms: "$text"');
      return TtsResult(
        audioBytes: Uint8List(0),
        sampleRate: 16000,
      );
    }

    if (!_isInitialized || _tts == null) {
      throw StateError('TtsStage is not initialized. Call initModel() first.');
    }

    final t0 = DateTime.now();
    final GeneratedAudio audio = _tts!.generate(text: text, sid: 0, speed: 1.0);
    final elapsedMs = DateTime.now().difference(t0).inMilliseconds;

    final pcmBytes = _floatToPcm16(audio.samples);
    final sampleRate = audio.sampleRate;

    debugPrint('[TTS] Synthesized ${audio.samples.length} samples in ${elapsedMs}ms (${pcmBytes.lengthInBytes} bytes)');

    return TtsResult(
      audioBytes: pcmBytes,
      sampleRate: sampleRate,
    );
  }

  /// Synthesizes a list of clauses incrementally.
  Stream<TtsChunkResult> synthesizeClauses(List<String> clauses, {TranslationDirection direction = TranslationDirection.hindiToMundari}) async* {
    final validClauses = clauses.where((c) => c.trim().isNotEmpty).toList();

    if (direction == TranslationDirection.mundariToHindi) {
      for (int i = 0; i < validClauses.length; i++) {
        final clause = validClauses[i];
        final chunkStart = DateTime.now();
        await HindiTtsService.instance.speak(clause);
        final int chunkTotalMs = DateTime.now().difference(chunkStart).inMilliseconds;

        print('[TTS-Profile] Clause ${i + 1}/${validClauses.length} ("$clause") | '
            'Spoke via Android on-device TextToSpeech in ${chunkTotalMs}ms');

        yield TtsChunkResult(
          index: i,
          totalClauses: validClauses.length,
          clauseText: clause,
          audioBytes: Uint8List(0),
          sampleRate: 16000,
          synthesisMs: chunkTotalMs,
        );
      }
      return;
    }

    if (!_isInitialized || _tts == null) {
      throw StateError('TtsStage is not initialized. Call initModel() first.');
    }

    for (int i = 0; i < validClauses.length; i++) {
      final clause = validClauses[i];
      final chunkStart = DateTime.now();

      final GeneratedAudio audio = _tts!.generate(text: clause, sid: 0, speed: 1.0);
      final int chunkTotalMs = DateTime.now().difference(chunkStart).inMilliseconds;

      final pcmBytes = _floatToPcm16(audio.samples);
      final int sampleRate = audio.sampleRate;
      final double audioDurationSec = sampleRate > 0 ? audio.samples.length / sampleRate : 0.0;
      final double rtf = audioDurationSec > 0 ? (chunkTotalMs / 1000.0) / audioDurationSec : 0.0;

      print('[TTS-Profile] Clause ${i + 1}/${validClauses.length} ("$clause") | '
          'Inference: ${chunkTotalMs}ms | '
          'Audio duration: ${audioDurationSec.toStringAsFixed(2)}s | '
          'RTF: ${rtf.toStringAsFixed(2)}x | '
          'Provider: $provider | '
          '${getMemoryInfo()}');

      yield TtsChunkResult(
        index: i,
        totalClauses: validClauses.length,
        clauseText: clause,
        audioBytes: pcmBytes,
        sampleRate: sampleRate,
        synthesisMs: chunkTotalMs,
      );
    }
  }

  Uint8List _floatToPcm16(Float32List samples) {
    final Int16List pcmData = Int16List(samples.length);
    for (int i = 0; i < samples.length; i++) {
      double scaled = samples[i] * 32767.0;
      if (scaled > 32767.0) scaled = 32767.0;
      if (scaled < -32768.0) scaled = -32768.0;
      pcmData[i] = scaled.toInt();
    }
    return pcmData.buffer.asUint8List();
  }

  void release() {
    _tts = null;
    _isInitialized = false;
  }

  void dispose() {
    release();
  }
}

/// The result returned by [TtsStage.synthesize].
class TtsResult {
  final Uint8List audioBytes;
  final int sampleRate;

  TtsResult({
    required this.audioBytes,
    required this.sampleRate,
  });
}

/// A chunk yielded during streaming clause synthesis.
class TtsChunkResult {
  final int index;
  final int totalClauses;
  final String clauseText;
  final Uint8List audioBytes;
  final int sampleRate;
  final int synthesisMs;

  TtsChunkResult({
    required this.index,
    required this.totalClauses,
    required this.clauseText,
    required this.audioBytes,
    required this.sampleRate,
    required this.synthesisMs,
  });
}
