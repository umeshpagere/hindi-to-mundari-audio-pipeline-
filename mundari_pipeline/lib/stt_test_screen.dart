import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'pipeline/pipeline.dart' show kDefaultSttThreads;
import 'pipeline/stt_stage.dart';

/// Dedicated Isolated Hindi Speech-To-Text (STT) Testing Screen.
/// Allows real-time streaming speech transcription, live VU audio meter,
/// push-to-talk recording, and built-in audio sample benchmark without
/// any MT or TTS interference.
class SttTestScreen extends StatefulWidget {
  const SttTestScreen({super.key});

  @override
  State<SttTestScreen> createState() => _SttTestScreenState();
}

class _SttTestScreenState extends State<SttTestScreen> {
  final SttStage _stt = SttStage(threads: kDefaultSttThreads);
  AudioRecorder? _recorder;

  bool _isModelLoaded = false;
  bool _isLoading = true;
  String _statusMessage = 'Loading Whisper Tiny GGML model...';

  // Live streaming state
  bool _isStreaming = false;
  String _currentPartial = '';
  final List<_RecognizedClause> _clauses = [];
  final ScrollController _scrollController = ScrollController();

  // Audio level monitoring
  double _currentRms = 0.0;
  double _peakRms = 0.0;
  StreamSubscription<Uint8List>? _micAudioSub;
  StreamSubscription<SttClauseResult>? _clauseSub;

  // One-shot recording state
  bool _isOneShotRecording = false;
  bool _isTranscribingFile = false;

  // Bundled test audio
  static const String _testAssetKey = 'assets/test/short_7s.wav';
  String? _bundledWavPath;

  @override
  void initState() {
    super.initState();
    _initSttLab();
  }

  Future<void> _initSttLab() async {
    try {
      final t0 = DateTime.now();
      await _stt.initModel();

      // Extract test WAV
      final tmpDir = await getTemporaryDirectory();
      final wavFile = File('${tmpDir.path}/short_7s.wav');
      if (!await wavFile.exists()) {
        final data = await rootBundle.load(_testAssetKey);
        await wavFile.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }
      _bundledWavPath = wavFile.path;

      // Force microphone permission prompt on startup
      final recorder = AudioRecorder();
      final hasMic = await recorder.hasPermission();
      await recorder.dispose();

      final elapsed = DateTime.now().difference(t0).inMilliseconds;
      if (mounted) {
        setState(() {
          _isModelLoaded = true;
          _isLoading = false;
          _statusMessage = hasMic
              ? 'Whisper Tiny ready ($elapsed ms). Tap "Live Mic" to speak.'
              : '⚠️ Mic permission not granted. Please allow microphone access.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _statusMessage = 'Failed to load model: $e';
        });
      }
    }
  }

  // ─── Live Streaming Mode ───────────────────────────────────────────────────

  Future<void> _toggleLiveStreaming() async {
    if (_isStreaming) {
      await _stopLiveStreaming();
    } else {
      await _startLiveStreaming();
    }
  }

  Future<void> _startLiveStreaming() async {
    if (!_isModelLoaded) return;

    _recorder = AudioRecorder();
    final hasPermission = await _recorder!.hasPermission();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission denied!')),
        );
      }
      return;
    }

    setState(() {
      _isStreaming = true;
      _currentPartial = '';
      _statusMessage = '🎙️ Listening... Speak Hindi now!';
    });

    try {
      final rawStream = await _recorder!.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          autoGain: true,
          echoCancel: true,
          noiseSuppress: true,
        ),
      );

      // Stream controller to duplicate stream for RMS monitoring and STT feeding
      final pcmStreamController = StreamController<Uint8List>.broadcast();

      _micAudioSub = rawStream.listen((chunk) {
        // Calculate RMS on the 16-bit PCM chunk
        final rms = _calculateRms(chunk);
        if (mounted) {
          setState(() {
            _currentRms = rms;
            if (rms > _peakRms) _peakRms = rms;
          });
        }
        pcmStreamController.add(chunk);
      });

      // Listen for emitted completed clauses
      _clauseSub = _stt.clauseStream.listen((clause) {
        if (mounted) {
          setState(() {
            _clauses.insert(
              0,
              _RecognizedClause(
                text: clause.text,
                durationMs: clause.durationMs,
                timestamp: clause.timestamp,
                isFinal: clause.isFinal,
              ),
            );
          });
        }
      });

      await _stt.startLive(
        pcmStreamController.stream,
        onPartial: (partial) {
          if (mounted) {
            setState(() {
              _currentPartial = partial;
            });
          }
        },
      );
    } catch (e) {
      await _stopLiveStreaming();
      if (mounted) {
        setState(() {
          _statusMessage = 'Streaming error: $e';
        });
      }
    }
  }

  Future<void> _stopLiveStreaming() async {
    setState(() {
      _isStreaming = false;
      _statusMessage = 'Stopping microphone...';
    });

    await _micAudioSub?.cancel();
    _micAudioSub = null;
    await _clauseSub?.cancel();
    _clauseSub = null;

    try {
      await _recorder?.stop();
      await _recorder?.dispose();
      _recorder = null;

      final finalTranscript = await _stt.stopLive();
      if (mounted) {
        setState(() {
          _statusMessage = finalTranscript.isNotEmpty
              ? 'Session finished. Final transcript: "$finalTranscript"'
              : 'Session stopped.';
          _currentPartial = '';
          _currentRms = 0.0;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusMessage = 'Error stopping: $e';
        });
      }
    }
  }

  // ─── One-Shot Push-To-Talk Mode ───────────────────────────────────────────

  Future<void> _startOneShotRecording() async {
    if (_isStreaming || _isTranscribingFile) return;

    _recorder = AudioRecorder();
    if (!await _recorder!.hasPermission()) return;

    final tmp = await getTemporaryDirectory();
    final path = '${tmp.path}/stt_oneshot_${DateTime.now().millisecondsSinceEpoch}.wav';

    await _recorder!.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
        autoGain: true,
        noiseSuppress: true,
      ),
      path: path,
    );

    setState(() {
      _isOneShotRecording = true;
      _statusMessage = '🔴 Recording audio clip... Speak now!';
    });
  }

  Future<void> _stopAndTranscribeOneShot() async {
    if (!_isOneShotRecording) return;

    final path = await _recorder!.stop();
    await _recorder!.dispose();
    _recorder = null;

    setState(() {
      _isOneShotRecording = false;
      _isTranscribingFile = true;
      _statusMessage = '⏳ Transcribing recorded audio file with Whisper...';
    });

    if (path != null && await File(path).exists()) {
      final t0 = DateTime.now();
      try {
        final text = await _stt.transcribeFile(path);
        final elapsed = DateTime.now().difference(t0).inMilliseconds;
        if (mounted) {
          setState(() {
            _isTranscribingFile = false;
            _statusMessage = 'Done in $elapsed ms!';
            _clauses.insert(
              0,
              _RecognizedClause(
                text: text.isNotEmpty ? text : '(No speech recognized)',
                durationMs: elapsed,
                timestamp: DateTime.now(),
                isFinal: true,
                isBatch: true,
              ),
            );
          });
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _isTranscribingFile = false;
            _statusMessage = 'Transcription failed: $e';
          });
        }
      }
    }
  }

  // ─── Benchmark Test File ───────────────────────────────────────────────────

  Future<void> _transcribeBundledTestFile() async {
    if (_bundledWavPath == null || _isTranscribingFile || _isStreaming) return;

    setState(() {
      _isTranscribingFile = true;
      _statusMessage = '⏳ Transcribing bundled 7.5s test sample (short_7s.wav)...';
    });

    final t0 = DateTime.now();
    try {
      final text = await _stt.transcribeFile(_bundledWavPath!);
      final elapsed = DateTime.now().difference(t0).inMilliseconds;
      if (mounted) {
        setState(() {
          _isTranscribingFile = false;
          _statusMessage = 'Benchmark complete in $elapsed ms!';
          _clauses.insert(
            0,
            _RecognizedClause(
              text: text,
              durationMs: elapsed,
              timestamp: DateTime.now(),
              isFinal: true,
              isBenchmark: true,
            ),
          );
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isTranscribingFile = false;
          _statusMessage = 'Benchmark failed: $e';
        });
      }
    }
  }

  double _calculateRms(Uint8List bytes) {
    if (bytes.isEmpty) return 0;
    int sumSq = 0;
    final count = bytes.length ~/ 2;
    final buffer = ByteData.sublistView(bytes);
    for (int i = 0; i < count; i++) {
      final sample = buffer.getInt16(i * 2, Endian.host);
      sumSq += sample * sample;
    }
    return math.sqrt(sumSq / count) / 32768.0;
  }

  @override
  void dispose() {
    _micAudioSub?.cancel();
    _clauseSub?.cancel();
    _recorder?.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ─── UI Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: const Color(0xFF0F111A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF171B26),
        elevation: 0,
        title: const Row(
          children: [
            Icon(Icons.mic_external_on, color: Colors.cyanAccent),
            SizedBox(width: 10),
            Text(
              'Hindi STT Live Lab',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            margin: const EdgeInsets.only(right: 12),
            decoration: BoxDecoration(
              color: _isModelLoaded ? Colors.green.withOpacity(0.2) : Colors.amber.withOpacity(0.2),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _isModelLoaded ? Colors.greenAccent : Colors.amberAccent,
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _isModelLoaded ? Icons.check_circle : Icons.hourglass_top,
                  size: 14,
                  color: _isModelLoaded ? Colors.greenAccent : Colors.amberAccent,
                ),
                const SizedBox(width: 6),
                Text(
                  _isModelLoaded ? 'Whisper Tiny INT8' : 'Loading Model',
                  style: TextStyle(
                    fontSize: 11,
                    color: _isModelLoaded ? Colors.greenAccent : Colors.amberAccent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Colors.cyanAccent),
                  SizedBox(height: 16),
                  Text('Initializing offline Whisper Tiny engine...'),
                ],
              ),
            )
          : Column(
              children: [
                // Top Status & VU Meter Bar
                _buildAudioVisualizerCard(cs),

                // Live Streaming Transcript Box
                _buildLiveTranscriptCard(cs),

                // Main Action Controls
                _buildControlsRow(cs),

                const SizedBox(height: 8),

                // List of Emitted Clauses
                Expanded(
                  child: _buildClausesList(cs),
                ),
              ],
            ),
    );
  }

  Widget _buildAudioVisualizerCard(ColorScheme cs) {
    final isVoiceDetected = _currentRms > 0.0012;
    final rmsDisplay = (_currentRms * 100).toStringAsFixed(2);
    final peakDisplay = (_peakRms * 100).toStringAsFixed(2);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF171B26),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _isStreaming
              ? (isVoiceDetected ? Colors.greenAccent.withOpacity(0.6) : Colors.cyanAccent.withOpacity(0.4))
              : Colors.white12,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    _isStreaming ? Icons.graphic_eq : Icons.mic_none,
                    size: 18,
                    color: _isStreaming ? Colors.greenAccent : Colors.white54,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _isStreaming
                        ? (isVoiceDetected ? '🎙️ VOICE ACTIVE' : '🤫 AMBIENT SILENCE')
                        : 'MIC IDLE',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: _isStreaming
                          ? (isVoiceDetected ? Colors.greenAccent : Colors.cyanAccent)
                          : Colors.white54,
                    ),
                  ),
                ],
              ),
              Text(
                'RMS: $rmsDisplay% | Peak: $peakDisplay%',
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.white70),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Dynamic Level Bar
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: (_currentRms * 20).clamp(0.0, 1.0),
              minHeight: 12,
              backgroundColor: Colors.white.withOpacity(0.08),
              valueColor: AlwaysStoppedAnimation<Color>(
                isVoiceDetected ? Colors.greenAccent : Colors.cyanAccent,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _statusMessage,
            style: const TextStyle(fontSize: 11, color: Colors.white60),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildLiveTranscriptCard(ColorScheme cs) {
    final hasText = _currentPartial.isNotEmpty;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(16),
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 90),
      decoration: BoxDecoration(
        color: const Color(0xFF1E2333),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: hasText ? Colors.amberAccent.withOpacity(0.8) : Colors.white10,
          width: hasText ? 1.5 : 1.0,
        ),
        boxShadow: hasText
            ? [
                BoxShadow(
                  color: Colors.amberAccent.withOpacity(0.15),
                  blurRadius: 12,
                  spreadRadius: 2,
                )
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'LIVE IN-PROGRESS STREAM:',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.0,
                  fontWeight: FontWeight.bold,
                  color: hasText ? Colors.amberAccent : Colors.white38,
                ),
              ),
              if (_isStreaming)
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Colors.redAccent,
                    shape: BoxShape.circle,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            hasText ? _currentPartial : (_isStreaming ? 'Listening for Hindi speech...' : 'Press "Live Mic" below to start speaking.'),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: hasText ? Colors.white : Colors.white38,
              fontStyle: hasText ? FontStyle.normal : FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlsRow(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // 1. Primary Live Mic Button
          Expanded(
            flex: 3,
            child: ElevatedButton.icon(
              onPressed: _isOneShotRecording || _isTranscribingFile ? null : _toggleLiveStreaming,
              style: ElevatedButton.styleFrom(
                backgroundColor: _isStreaming ? Colors.redAccent.shade700 : const Color(0xFF3F51B5),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              icon: Icon(_isStreaming ? Icons.stop : Icons.mic),
              label: Text(
                _isStreaming ? 'Stop Streaming' : 'Start Live Mic',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
          ),
          const SizedBox(width: 8),

          // 2. One-shot Record Button
          Expanded(
            flex: 2,
            child: ElevatedButton.icon(
              onPressed: _isStreaming || _isTranscribingFile
                  ? null
                  : () {
                      if (_isOneShotRecording) {
                        _stopAndTranscribeOneShot();
                      } else {
                        _startOneShotRecording();
                      }
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: _isOneShotRecording ? Colors.orangeAccent.shade700 : const Color(0xFF263238),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              icon: Icon(_isOneShotRecording ? Icons.stop : Icons.fiber_manual_record, size: 18),
              label: Text(
                _isOneShotRecording ? 'Done' : 'Record 3s',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
            ),
          ),
          const SizedBox(width: 8),

          // 3. Bundled Sample Benchmark
          IconButton(
            onPressed: _isStreaming || _isTranscribingFile ? null : _transcribeBundledTestFile,
            tooltip: 'Benchmark short_7s.wav',
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFF263238),
              padding: const EdgeInsets.all(12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.audio_file, color: Colors.cyanAccent),
          ),
        ],
      ),
    );
  }

  Widget _buildClausesList(ColorScheme cs) {
    if (_clauses.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.speaker_notes_off_outlined, size: 48, color: Colors.white24),
            const SizedBox(height: 12),
            const Text(
              'No speech recognized yet.\nTap "Start Live Mic" and speak "मेरा नाम उमेश है".',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 13),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: _clauses.length,
      itemBuilder: (context, index) {
        final item = _clauses[index];
        final timeStr = '${item.timestamp.hour.toString().padLeft(2, '0')}:${item.timestamp.minute.toString().padLeft(2, '0')}:${item.timestamp.second.toString().padLeft(2, '0')}';

        return Card(
          color: const Color(0xFF1E2333),
          margin: const EdgeInsets.only(bottom: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: item.isBenchmark
                                ? Colors.purpleAccent.withOpacity(0.2)
                                : (item.isBatch ? Colors.orangeAccent.withOpacity(0.2) : Colors.cyanAccent.withOpacity(0.2)),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            item.isBenchmark
                                ? 'BENCHMARK'
                                : (item.isBatch ? 'BATCH WAV' : 'STREAMED CLAUSE'),
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: item.isBenchmark
                                  ? Colors.purpleAccent
                                  : (item.isBatch ? Colors.orangeAccent : Colors.cyanAccent),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          timeStr,
                          style: const TextStyle(fontSize: 10, color: Colors.white54, fontFamily: 'monospace'),
                        ),
                      ],
                    ),
                    Text(
                      '${item.durationMs} ms',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.greenAccent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SelectableText(
                  item.text,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _RecognizedClause {
  final String text;
  final int durationMs;
  final DateTime timestamp;
  final bool isFinal;
  final bool isBatch;
  final bool isBenchmark;

  _RecognizedClause({
    required this.text,
    required this.durationMs,
    required this.timestamp,
    this.isFinal = false,
    this.isBatch = false,
    this.isBenchmark = false,
  });
}
