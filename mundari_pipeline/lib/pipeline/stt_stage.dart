import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter/services.dart' show rootBundle;
import 'package:sherpa_onnx/sherpa_onnx.dart';
import 'package:path_provider/path_provider.dart';

import 'pipeline.dart' show kDefaultSttThreads, TranslationDirection;

class SttStage {
  static const String _hindiModelAssetKey = 'assets/models/asr/model.int8.onnx';
  static const String _hindiTokensAssetKey = 'assets/models/asr/tokens.txt';

  static const String _mundariModelAssetKey = 'assets/models/tts/mundari_stt_int8/mundari_stt_ctc.int8.onnx';
  static const String _mundariTokensAssetKey = 'assets/models/tts/mundari_stt_int8/vocab.txt';

  final int threads;

  SttStage({this.threads = kDefaultSttThreads});

  OfflineRecognizer? _recognizer;
  String? _modelPath;
  String? _tokensPath;
  TranslationDirection _currentDirection = TranslationDirection.hindiToMundari;

  bool get isReady => _recognizer != null;
  TranslationDirection get currentDirection => _currentDirection;

  final StreamController<SttClauseResult> _clauseController = StreamController<SttClauseResult>.broadcast();
  Stream<SttClauseResult> get clauseStream => _clauseController.stream;

  StreamSubscription<Uint8List>? _audioSub;

  int _clauseIndex = 0;
  String _emittedText = '';

  // VAD Constants (tuned for conversational speech)
  static const double SILENCE_THRESHOLD_RMS = 0.005;
  static const int SILENCE_FRAMES_TO_FLUSH = 3; // 480ms
  static const int MAX_BUFFER_FRAMES = 15; // 2.4s
  static const int MIN_BUFFER_FRAMES_TO_INFER = 4; // 640ms
  static const int MIN_SPEECH_ENERGY_FRAMES = 2; // 320ms
  static const double MAX_CHARS_PER_SECOND = 25.0; // Accommodate Devanagari UTF-16 matras

  // Buffering state
  final List<Float32List> _chunkBuffer = [];
  int _silentFramesCount = 0;
  DateTime? _speechStartTime;

  Future<void> initModel({TranslationDirection direction = TranslationDirection.hindiToMundari}) async {
    _currentDirection = direction;
    final bool isMundari = direction == TranslationDirection.mundariToHindi;

    final dir = await getApplicationDocumentsDirectory();
    final asrDir = Directory('${dir.path}/asr');
    if (!await asrDir.exists()) await asrDir.create();

    final modelKey = isMundari ? _mundariModelAssetKey : _hindiModelAssetKey;
    final tokensKey = isMundari ? _mundariTokensAssetKey : _hindiTokensAssetKey;

    _modelPath = isMundari ? '${asrDir.path}/mundari_ctc.int8.onnx' : '${asrDir.path}/model.int8.onnx';
    _tokensPath = isMundari ? '${asrDir.path}/vocab_mundari.txt' : '${asrDir.path}/tokens.txt';

    await _extractAsset(modelKey, _modelPath!);
    await _extractAsset(tokensKey, _tokensPath!);

    final config = OfflineRecognizerConfig(
      feat: const FeatureConfig(sampleRate: 16000, featureDim: 80),
      model: OfflineModelConfig(
        nemoCtc: OfflineNemoEncDecCtcModelConfig(model: _modelPath!),
        tokens: _tokensPath!,
        provider: 'cpu',
        numThreads: threads,
        debug: false,
      ),
      decodingMethod: 'greedy_search',
    );
    _recognizer = OfflineRecognizer(config);
  }

  /// Dynamically switches the active ASR language model (Hindi vs Mundari).
  Future<void> switchDirection(TranslationDirection direction) async {
    if (_currentDirection == direction && isReady) return;
    _recognizer = null;
    await initModel(direction: direction);
  }

  Future<void> _extractAsset(String key, String path) async {
    // Always overwrite to ensure fresh model files after app updates
    final bytes = await rootBundle.load(key);
    await File(path).writeAsBytes(bytes.buffer.asUint8List(), flush: true);
  }

  Future<String> transcribeFile(String wavPath) async {
    if (!isReady) throw StateError('Not initialized');
    
    // Read WAV (assuming 16kHz mono 16-bit PCM for simplicity, skip 44 byte header)
    final file = File(wavPath);
    final bytes = await file.readAsBytes();
    final pcmBytes = bytes.sublist(44);
    final float32Samples = _pcm16ToFloat32(pcmBytes);

    final stream = _recognizer!.createStream();
    stream.acceptWaveform(sampleRate: 16000, samples: float32Samples);
    _recognizer!.decode(stream);
    final text = _recognizer!.getResult(stream).text;
    stream.free();
    
    return _cleanText(text);
  }

  Float32List _pcm16ToFloat32(Uint8List pcm16) {
    final int16List = pcm16.buffer.asInt16List(pcm16.offsetInBytes, pcm16.lengthInBytes ~/ 2);
    final float32List = Float32List(int16List.length);
    for (int i = 0; i < int16List.length; i++) {
      float32List[i] = int16List[i] / 32768.0;
    }
    return float32List;
  }

  double _computeRms(Float32List samples) {
    double sumSq = 0.0;
    for (final s in samples) {
      sumSq += s * s;
    }
    return math.sqrt(sumSq / samples.length);
  }

  // Ring buffer accumulation
  final List<int> _rawByteQueue = [];

  Future<void> startLive(Stream<Uint8List> pcm16Stream, {void Function(String partial)? onPartial}) async {
    if (!isReady) throw StateError('Call initModel() first.');

    _emittedText = '';
    _clauseIndex = 0;
    _chunkBuffer.clear();
    _silentFramesCount = 0;
    _rawByteQueue.clear();
    _speechStartTime = null;

    print('[STT-Live] Starting IndicConformer offline-streaming session...');

    _audioSub = pcm16Stream.listen((data) {
      _rawByteQueue.addAll(data);
      // 160ms chunks = 2560 samples = 5120 bytes
      while (_rawByteQueue.length >= 5120) {
        final chunkBytes = Uint8List.fromList(_rawByteQueue.sublist(0, 5120));
        _rawByteQueue.removeRange(0, 5120);
        _processChunk(chunkBytes);
      }
    });
  }

  void _processChunk(Uint8List pcm16) {
    final float32Samples = _pcm16ToFloat32(pcm16);
    final rms = _computeRms(float32Samples);
    
    _chunkBuffer.add(float32Samples);
    if (_speechStartTime == null) _speechStartTime = DateTime.now();

    if (rms < SILENCE_THRESHOLD_RMS) {
      _silentFramesCount++;
    } else {
      _silentFramesCount = 0;
    }

    if (_silentFramesCount >= SILENCE_FRAMES_TO_FLUSH || _chunkBuffer.length >= MAX_BUFFER_FRAMES) {
      _flushBuffer();
    }
  }

  void _flushBuffer() {
    if (_chunkBuffer.isEmpty) return;

    final framesCount = _chunkBuffer.length;
    
    // Silence Trimming (Keep 2 chunks on each side)
    int startIndex = 0;
    while (startIndex < _chunkBuffer.length && _computeRms(_chunkBuffer[startIndex]) < SILENCE_THRESHOLD_RMS) {
      startIndex++;
    }
    startIndex = math.max(0, startIndex - 2);

    int endIndex = _chunkBuffer.length - 1;
    while (endIndex >= 0 && _computeRms(_chunkBuffer[endIndex]) < SILENCE_THRESHOLD_RMS) {
      endIndex--;
    }
    endIndex = math.min(_chunkBuffer.length - 1, endIndex + 2);

    // Gate 1: Min Buffer Context
    if (framesCount < MIN_BUFFER_FRAMES_TO_INFER) {
      _chunkBuffer.clear();
      _silentFramesCount = 0;
      _speechStartTime = null;
      return;
    }

    // Gate 2: Min Speech Energy
    int activeFrames = 0;
    for (int i = startIndex; i <= endIndex; i++) {
      if (_computeRms(_chunkBuffer[i]) >= SILENCE_THRESHOLD_RMS) activeFrames++;
    }
    if (activeFrames < MIN_SPEECH_ENERGY_FRAMES) {
      _chunkBuffer.clear();
      _silentFramesCount = 0;
      _speechStartTime = null;
      return;
    }

    // Prepare inference data
    final inferenceBuffer = _chunkBuffer.sublist(startIndex, endIndex + 1);
    final totalSamples = inferenceBuffer.length * 2560;
    final float32List = Float32List(totalSamples);
    int offset = 0;
    for (final chunk in inferenceBuffer) {
      float32List.setAll(offset, chunk);
      offset += chunk.length;
    }
    final durationSecs = float32List.length / 16000.0;
    
    // Clear buffer for next accumulation
    _chunkBuffer.clear();
    _silentFramesCount = 0;
    final startT = _speechStartTime!;
    _speechStartTime = null;

    // Run inference
    final stream = _recognizer!.createStream();
    stream.acceptWaveform(sampleRate: 16000, samples: float32List);
    _recognizer!.decode(stream);
    final rawText = _recognizer!.getResult(stream).text;
    stream.free();

    final text = _cleanText(rawText);
    if (text.isEmpty) return;

    // Gate 3: Character Rate Plausibility Filter
    final charsPerSec = text.length / durationSecs;
    if (charsPerSec > MAX_CHARS_PER_SECOND) {
      print('⚠️ [STT-Live] Hallucination dropped (rate $charsPerSec chars/s): "$text"');
      return;
    }

    // Post-Processing: Trailing Repetition Filter
    if (_emittedText.endsWith(text)) {
      print('⚠️ [STT-Live] Trailing repetition dropped: "$text"');
      return;
    }

    _emittedText += '$text ';
    _emitClause(text, startT, durationSecs);
  }

  String _cleanText(String input) {
    if (input.isEmpty) return '';
    var text = input.trim();
    // Prefix deduplication and Intra-word loop collapse
    // (A simplified regex based cleanup for CTC repetitions)
    text = text.replaceAll(RegExp(r'(.+?)\1{2,}'), r'$1'); // Collapse 3+ repeats of any pattern

    final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return '';
    
    final cleanWords = <String>[];
    for (int i = 0; i < words.length; i++) {
      if (cleanWords.isNotEmpty) {
        // prefix deduplication: drop word if next word starts with it
        final prev = cleanWords.last;
        final curr = words[i];
        if (curr.startsWith(prev) && curr != prev) {
          cleanWords.removeLast();
        } else if (curr == prev) {
          continue; // Consecutive duplicate removal
        }
      }
      cleanWords.add(words[i]);
    }
    return cleanWords.join(' ');
  }

  void _emitClause(String text, DateTime startT, double durationSecs) {
    if (text.isEmpty) return;
    
    final emittedIndex = _clauseIndex++;
    final result = SttClauseResult(
      index: emittedIndex,
      text: text,
      timestamp: DateTime.now(),
      durationMs: (durationSecs * 1000).toInt(),
      isFinal: false,
    );
    print('🎙️ [STT-Live] Emitted clause #$emittedIndex: "$text"');
    _clauseController.add(result);
  }

  Future<String> stopLive() async {
    print('[STT-Live] Stopping live session...');
    await _audioSub?.cancel();
    _audioSub = null;
    
    _flushBuffer(); // Process any remaining
    
    final finalTranscript = _emittedText.trim();
    print('[STT-Live] Session stopped. Total final transcript: "$finalTranscript"');
    return finalTranscript;
  }

  Future<void> dispose() async {
    await stopLive();
    await _clauseController.close();
    _recognizer?.free();
    _recognizer = null;
  }
}

class SttClauseResult {
  final int index;
  final String text;
  final DateTime timestamp;
  final int durationMs;
  final bool isFinal;

  SttClauseResult({
    required this.index,
    required this.text,
    required this.timestamp,
    required this.durationMs,
    this.isFinal = false,
  });
}
