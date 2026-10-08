import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class _QueuedClause {
  final int index;
  final String wavPath;

  _QueuedClause({required this.index, required this.wavPath});
}

/// Worker responsible for real-time concurrent, gapless audio playback of TTS clauses.
///
/// Uses [audioplayers] with an asynchronous queue to play each synthesized clause
/// immediately, seamlessly advancing to subsequent clauses with no gap while TTS
/// continues synthesizing downstream clauses in the background.
class AudioPlaybackWorker {
  final AudioPlayer _player = AudioPlayer();
  final List<_QueuedClause> _queue = [];
  Directory? _tempDir;
  bool _isPlaying = false;
  bool _isInitialized = false;

  final StreamController<int> _clauseStartedController = StreamController<int>.broadcast();

  /// Emits the clause index whenever playback of that clause actually begins
  /// on the device speaker, allowing accurate measurement of Time-to-First-Audio-Heard.
  Stream<int> get onClausePlaybackStarted => _clauseStartedController.stream;

  Future<void> init() async {
    if (_isInitialized) return;

    _tempDir = await getTemporaryDirectory();

    // Configure low-latency playback mode
    await _player.setReleaseMode(ReleaseMode.stop);

    _player.onPlayerComplete.listen((_) {
      _playNext();
    });

    _isInitialized = true;
  }

  /// Wraps 16-bit linear PCM audio into a standard 44-byte WAV header.
  static Uint8List pcmToWav(Uint8List pcmBytes, {int sampleRate = 16000, int channels = 1}) {
    final byteRate = sampleRate * channels * 2;
    final blockAlign = channels * 2;
    final totalDataLen = pcmBytes.length;
    final totalAudioLen = totalDataLen + 36;

    final header = ByteData(44);
    // "RIFF"
    header.setUint8(0, 0x52); header.setUint8(1, 0x49); header.setUint8(2, 0x46); header.setUint8(3, 0x46);
    header.setUint32(4, totalAudioLen, Endian.little);
    // "WAVE"
    header.setUint8(8, 0x57); header.setUint8(9, 0x41); header.setUint8(10, 0x56); header.setUint8(11, 0x45);
    // "fmt "
    header.setUint8(12, 0x66); header.setUint8(13, 0x6D); header.setUint8(14, 0x74); header.setUint8(15, 0x20);
    header.setUint32(16, 16, Endian.little); // subchunk1size (16 for PCM)
    header.setUint16(20, 1, Endian.little);  // audioFormat (1 for PCM)
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, 16, Endian.little); // bitsPerSample
    // "data"
    header.setUint8(36, 0x64); header.setUint8(37, 0x61); header.setUint8(38, 0x74); header.setUint8(39, 0x61);
    header.setUint32(40, totalDataLen, Endian.little);

    final wav = Uint8List(44 + totalDataLen);
    wav.setRange(0, 44, header.buffer.asUint8List());
    wav.setRange(44, 44 + totalDataLen, pcmBytes);
    return wav;
  }

  /// Queues a newly synthesized clause's PCM audio and plays it immediately if idle.
  Future<void> queueClauseAudio(
    int clauseIndex,
    Uint8List pcmBytes, {
    int sampleRate = 16000,
  }) async {
    if (!_isInitialized) await init();

    if (pcmBytes.isEmpty) {
      debugPrint('[AudioPlayer] Skipping 0-byte audio for clause #$clauseIndex');
      return;
    }

    final wavBytes = pcmToWav(pcmBytes, sampleRate: sampleRate);
    final wavFile = File('${_tempDir!.path}/clause_${clauseIndex}_${DateTime.now().millisecondsSinceEpoch}.wav');
    await wavFile.writeAsBytes(wavBytes, flush: true);

    final item = _QueuedClause(index: clauseIndex, wavPath: wavFile.path);
    _queue.add(item);

    debugPrint('[AudioPlayer] Enqueued clause #$clauseIndex (${pcmBytes.length} bytes, queue size: ${_queue.length})');

    if (!_isPlaying) {
      _playNext();
    }
  }

  Future<void> _playNext() async {
    if (_queue.isEmpty) {
      _isPlaying = false;
      return;
    }

    _isPlaying = true;
    final item = _queue.removeAt(0);

    debugPrint('[AudioPlayer] Starting playback for clause #${item.index}');
    _clauseStartedController.add(item.index);

    try {
      await _player.play(DeviceFileSource(item.wavPath));
    } catch (e) {
      debugPrint('[AudioPlayer] Error playing clause #${item.index}: $e');
      _playNext();
    }
  }

  /// Resets the playback queue for a new session.
  Future<void> reset() async {
    await _player.stop();
    _queue.clear();
    _isPlaying = false;
  }

  Future<void> stop() async {
    await _player.stop();
    _queue.clear();
    _isPlaying = false;
  }

  Future<void> dispose() async {
    await _player.dispose();
    await _clauseStartedController.close();
    _isInitialized = false;
  }
}
