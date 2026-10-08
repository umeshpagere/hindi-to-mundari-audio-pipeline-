import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'pipeline/mt_stage.dart';
import 'pipeline/pipeline.dart';
import 'pipeline/stt_stage.dart';
import 'pipeline/tts_stage.dart';
import 'stt_test_screen.dart';

// ─── Entry point ─────────────────────────────────────────────────────────────

void main() {
  runApp(const MundariPipelineApp());
}

class MundariPipelineApp extends StatelessWidget {
  const MundariPipelineApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hindi STT Lab & Mundari Pipeline',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5C6BC0),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const MainNavigationShell(),
    );
  }
}

class MainNavigationShell extends StatefulWidget {
  const MainNavigationShell({super.key});

  @override
  State<MainNavigationShell> createState() => _MainNavigationShellState();
}

class _MainNavigationShellState extends State<MainNavigationShell> {
  int _currentIndex = 0;

  final List<Widget> _screens = const [
    SttTestScreen(),
    PipelineTestScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (idx) {
          setState(() {
            _currentIndex = idx;
          });
        },
        backgroundColor: const Color(0xFF131722),
        indicatorColor: Colors.cyanAccent.withOpacity(0.25),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.mic_none),
            selectedIcon: Icon(Icons.mic, color: Colors.cyanAccent),
            label: '🎙️ STT Isolated Lab',
          ),
          NavigationDestination(
            icon: Icon(Icons.stream_outlined),
            selectedIcon: Icon(Icons.stream, color: Colors.indigoAccent),
            label: '⚡ Full Pipeline (E2E)',
          ),
        ],
      ),
    );
  }
}

// ─── PipelineTestScreen ───────────────────────────────────────────────────────

class PipelineTestScreen extends StatefulWidget {
  const PipelineTestScreen({super.key});

  @override
  State<PipelineTestScreen> createState() => _PipelineTestScreenState();
}

class _PipelineTestScreenState extends State<PipelineTestScreen> {
  late SpeechPipeline _pipeline;

  _ScreenState _state = _ScreenState.initialising;
  TranslationDirection _activeDirection = TranslationDirection.hindiToMundari;
  String _errorMessage = '';
  PipelineResult? _result;
  String _savedWavPath = '';

  Future<void> _changeDirection(TranslationDirection dir) async {
    if (_activeDirection == dir || _isLiveActive) return;
    setState(() {
      _state = _ScreenState.initialising;
      _activeDirection = dir;
      _result = null;
      _liveClauses.clear();
      _livePartial = '';
    });
    try {
      await _pipeline.setDirection(dir);
      if (mounted) {
        setState(() => _state = _ScreenState.ready);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _state = _ScreenState.error;
          _errorMessage = 'Failed to switch direction: $e';
        });
      }
    }
  }

  // Bundled test WAV path
  static const String _testAssetKey = 'assets/test/short_7s.wav';
  String _wavPath = '';

  // Live streaming state
  bool _isLiveActive = false;
  String _livePartial = '';
  final List<LiveClauseTiming> _liveClauses = [];
  final ScrollController _scrollController = ScrollController();

  StreamSubscription<LivePipelineEvent>? _eventSub;

  // Telemetry & Hardware state
  DeviceTelemetrySnapshot? _currentTelemetry;
  Timer? _telemetryTimer;

  @override
  void initState() {
    super.initState();
    _currentTelemetry = DeviceTelemetry.capture();
    _telemetryTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) {
        setState(() {
          _currentTelemetry = DeviceTelemetry.capture();
        });
      }
    });

    _pipeline = SpeechPipeline(
      sttStage: SttStage(threads: kDefaultSttThreads),
      mtStage: RealMtStage(threads: kDefaultMtThreads),
      ttsStage: TtsStage(threads: kDefaultTtsThreads, provider: 'cpu'),
    );

    _eventSub = _pipeline.liveEvents.listen((event) {
      if (!mounted) return;
      setState(() {
        final existingIdx = _liveClauses.indexWhere((c) => c.clauseIndex == event.clauseIndex);
        if (existingIdx != -1) {
          _liveClauses[existingIdx] = event.timing;
        } else {
          _liveClauses.add(event.timing);
        }
      });
      // Auto-scroll to bottom of live stream
      Future.delayed(const Duration(milliseconds: 100), () {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    });

    _init();
  }

  @override
  void dispose() {
    _telemetryTimer?.cancel();
    _eventSub?.cancel();
    _scrollController.dispose();
    _pipeline.dispose();
    super.dispose();
  }

  // ── Initialisation ────────────────────────────────────────────────────────

  Future<void> _init() async {
    try {
      await _pipeline.init();
      await _extractTestWav();

      // Force microphone permission prompt on startup
      final recorder = AudioRecorder();
      final hasMic = await recorder.hasPermission();
      await recorder.dispose();
      if (!hasMic) {
        dev.log('[Pipeline] Microphone permission was not granted during init.');
      }

      if (mounted) {
        setState(() => _state = _ScreenState.ready);
        _runBatchPipeline();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _state = _ScreenState.error;
          _errorMessage = 'Initialisation failed:\n$e';
        });
      }
    }
  }

  Future<void> _extractTestWav() async {
    final ByteData bytes = await rootBundle.load(_testAssetKey);
    final Directory tmpDir = await getTemporaryDirectory();
    final File wavFile = File('${tmpDir.path}/short_7s.wav');
    await wavFile.writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
    _wavPath = wavFile.path;
  }

  // ── Batch File Pipeline ───────────────────────────────────────────────────

  Future<void> _runBatchPipeline() async {
    if (_wavPath.isEmpty) return;

    setState(() {
      _state = _ScreenState.running;
      _result = null;
      _savedWavPath = '';
      _errorMessage = '';
    });

    try {
      final result = await _pipeline.processFile(_wavPath);

      final int sampleRate = result.audioSampleRate;
      const int channels = 1;
      final int byteRate = sampleRate * channels * 2;
      final ByteData header = ByteData(44);
      header.setUint32(0, 0x52494646, Endian.big); // "RIFF"
      header.setUint32(4, 36 + result.audioBytes.length, Endian.little);
      header.setUint32(8, 0x57415645, Endian.big); // "WAVE"
      header.setUint32(12, 0x666D7420, Endian.big); // "fmt "
      header.setUint32(16, 16, Endian.little);
      header.setUint16(20, 1, Endian.little);
      header.setUint16(22, channels, Endian.little);
      header.setUint32(24, sampleRate, Endian.little);
      header.setUint32(28, byteRate, Endian.little);
      header.setUint16(32, channels * 2, Endian.little);
      header.setUint16(34, 16, Endian.little);
      header.setUint32(36, 0x64617461, Endian.big); // "data"
      header.setUint32(40, result.audioBytes.length, Endian.little);
      final BytesBuilder builder = BytesBuilder();
      builder.add(header.buffer.asUint8List());
      builder.add(result.audioBytes);
      final Uint8List wavBytes = builder.toBytes();

      final Directory tmpDir = await getTemporaryDirectory();
      final String outPath = '${tmpDir.path}/pipeline_output.wav';
      await File(outPath).writeAsBytes(wavBytes, flush: true);

      if (mounted) {
        setState(() {
          _result = result;
          _savedWavPath = outPath;
          _state = _ScreenState.ready;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _state = _ScreenState.error;
          _errorMessage = 'Pipeline failed:\n$e';
        });
      }
    }
  }

  // ── Live Streaming Pipeline ───────────────────────────────────────────────

  Stream<Uint8List> _createSimulatedContinuousStream(String wavPath, {int repeat = 2}) async* {
    final file = File(wavPath);
    final bytes = await file.readAsBytes();
    final pcmBytes = bytes.sublist(44); // Strip 44-byte WAV header

    const int chunkSize = 3200; // 100ms chunks (1600 samples * 2 bytes)
    for (int r = 0; r < repeat; r++) {
      print('[SimulatedStream] Streaming repetition ${r + 1}/$repeat...');
      for (int offset = 0; offset < pcmBytes.length; offset += chunkSize) {
        if (!_pipeline.isLiveSessionActive) break;
        final end = (offset + chunkSize < pcmBytes.length) ? offset + chunkSize : pcmBytes.length;
        yield pcmBytes.sublist(offset, end);
        await Future.delayed(const Duration(milliseconds: 100)); // Natural 1x speaking pace
      }
      if (r < repeat - 1) {
        await Future.delayed(const Duration(milliseconds: 500)); // Pause between sentences
      }
    }
  }

  Future<void> _startContinuousSimulatedStream() async {
    if (_wavPath.isEmpty) return;

    setState(() {
      _isLiveActive = true;
      _liveClauses.clear();
      _livePartial = '';
      _result = null;
    });

    try {
      final simStream = _createSimulatedContinuousStream(_wavPath, repeat: 2);
      await _pipeline.startLivePipeline(
        customAudioStream: simStream,
        onPartialTranscript: (p) {
          if (mounted) setState(() => _livePartial = p);
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLiveActive = false;
          _errorMessage = 'Live streaming test failed: $e';
        });
      }
    }
  }

  Future<void> _toggleMicLiveStream() async {
    if (_isLiveActive) {
      await _pipeline.stopLivePipeline();
      setState(() => _isLiveActive = false);
    } else {
      setState(() {
        _isLiveActive = true;
        _liveClauses.clear();
        _livePartial = '';
        _result = null;
      });

      try {
        await _pipeline.startLivePipeline(
          onPartialTranscript: (p) {
            if (mounted) setState(() => _livePartial = p);
          },
        );
      } catch (e) {
        if (mounted) {
          setState(() {
            _isLiveActive = false;
            _errorMessage = 'Live mic streaming failed: $e';
          });
        }
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surfaceContainerHigh,
        title: const Text('Mundari Pipeline — Bidirectional'),
        centerTitle: true,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: LinearProgressIndicator(
            value: _isLiveActive ? null : 1.0,
            backgroundColor: cs.surfaceContainerHighest,
            color: cs.primary,
            minHeight: 3,
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StatusBanner(
                state: _isLiveActive ? _ScreenState.running : _state,
                errorMessage: _errorMessage,
              ),
              const SizedBox(height: 8),
              SegmentedButton<TranslationDirection>(
                segments: const [
                  ButtonSegment(
                    value: TranslationDirection.hindiToMundari,
                    label: Text('Hindi ➔ Mundari'),
                    icon: Icon(Icons.east_rounded),
                  ),
                  ButtonSegment(
                    value: TranslationDirection.mundariToHindi,
                    label: Text('Mundari ➔ Hindi'),
                    icon: Icon(Icons.west_rounded),
                  ),
                ],
                selected: {_activeDirection},
                onSelectionChanged: (_state == _ScreenState.ready && !_isLiveActive)
                    ? (newSet) => _changeDirection(newSet.first)
                    : null,
              ),
              const SizedBox(height: 8),
              _buildTelemetryBar(context),
              const SizedBox(height: 8),

              // Action Buttons Row
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: (_state == _ScreenState.ready && !_isLiveActive) ? _startContinuousSimulatedStream : null,
                      icon: const Icon(Icons.stream_rounded),
                      label: const Text('Continuous Test'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF3F51B5),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _state == _ScreenState.ready ? _toggleMicLiveStream : null,
                      icon: Icon(_isLiveActive ? Icons.stop_rounded : Icons.mic_rounded),
                      label: Text(_isLiveActive ? 'Stop Mic' : 'Live Mic'),
                      style: FilledButton.styleFrom(
                        backgroundColor: _isLiveActive ? Colors.redAccent : const Color(0xFF00897B),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    onPressed: (_state == _ScreenState.ready && !_isLiveActive) ? _runBatchPipeline : null,
                    icon: const Icon(Icons.play_arrow_rounded),
                    tooltip: 'Run Batch File Test',
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Main Display Area
              Expanded(
                child: _isLiveActive || _liveClauses.isNotEmpty
                    ? _buildLiveStreamingView(context)
                    : _result != null
                        ? _ResultsPanel(result: _result!, savedWavPath: _savedWavPath)
                        : _EmptyState(state: _state),
              ),

              const SizedBox(height: 8),
              _PipelineLegend(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLiveStreamingView(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withAlpha(80)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Live Status Header
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isLiveActive ? Colors.greenAccent : Colors.grey,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _isLiveActive ? 'LIVE CONCURRENT PIPELINE ACTIVE' : 'STREAM FINISHED',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.8),
              ),
              const Spacer(),
              Text(
                '${_liveClauses.length} clauses processed',
                style: TextStyle(fontSize: 12, color: cs.outline),
              ),
            ],
          ),
          const Divider(height: 16),

          // In-progress partial text banner
          if (_livePartial.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: cs.primaryContainer.withAlpha(80),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.hearing_rounded, size: 16, color: Colors.amberAccent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Listening: "$_livePartial"',
                      style: const TextStyle(fontSize: 13, fontStyle: FontStyle.italic),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),

          // Clauses Timeline
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              itemCount: _liveClauses.length,
              itemBuilder: (context, idx) {
                final clause = _liveClauses[idx];
                return _buildClauseCard(context, clause);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildClauseCard(BuildContext context, LiveClauseTiming timing) {
    final cs = Theme.of(context).colorScheme;
    final isPlaying = timing.tPlay != null;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      color: cs.surfaceContainerHigh,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isPlaying ? Colors.greenAccent.withAlpha(120) : cs.outlineVariant.withAlpha(60),
          width: isPlaying ? 1.5 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header: Clause # & Status
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: cs.primary.withAlpha(50),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'Clause #${timing.clauseIndex + 1}',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: cs.primary),
                  ),
                ),
                const Spacer(),
                if (isPlaying)
                  const Row(
                    children: [
                      Icon(Icons.volume_up_rounded, size: 14, color: Colors.greenAccent),
                      SizedBox(width: 4),
                      Text('PLAYING / PLAYED', style: TextStyle(fontSize: 11, color: Colors.greenAccent, fontWeight: FontWeight.bold)),
                    ],
                  )
                else if (timing.tTts != null)
                  const Row(
                    children: [
                      Icon(Icons.check_circle_outline_rounded, size: 14, color: Colors.blueAccent),
                      SizedBox(width: 4),
                      Text('SYNTHESIZED (QUEUED)', style: TextStyle(fontSize: 11, color: Colors.blueAccent)),
                    ],
                  )
                else
                  const Row(
                    children: [
                      SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                      SizedBox(width: 6),
                      Text('PROCESSING...', style: TextStyle(fontSize: 11, color: Colors.orangeAccent)),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 8),

            // Source Text (STT)
            Text(
              '${timing.direction == TranslationDirection.hindiToMundari ? "Hindi" : "Mundari"}: "${timing.sourceText}"',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),

            // Target Text (MT)
            if (timing.targetText.isNotEmpty)
              Text(
                '${timing.direction == TranslationDirection.hindiToMundari ? "Mundari" : "Hindi"}: "${timing.targetText}"',
                style: TextStyle(fontSize: 13, color: cs.tertiary, fontWeight: FontWeight.w500),
              ),
            const SizedBox(height: 8),

            // Latency Metrics
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                _metricBadge('STT: ${timing.sttDurationMs}ms'),
                if (timing.mtDurationMs != null) _metricBadge('MT: ${timing.mtDurationMs}ms'),
                if (timing.ttsDurationMs != null) _metricBadge('TTS: ${timing.ttsDurationMs}ms'),
                if (timing.queueWaitMs != null) _metricBadge('Queue: ${timing.queueWaitMs}ms', color: Colors.cyanAccent),
                if (timing.totalLatencyToAudioHeardMs != null)
                  _metricBadge('⚡ Heard in: ${timing.totalLatencyToAudioHeardMs}ms', color: Colors.greenAccent),
                if (timing.delta != null)
                  _metricBadge('Preempt: ${timing.delta!.deltaNonvolCtxtSwitches}', color: Colors.amberAccent),
              ],
            ),
            if (timing.delta != null) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '📊 ${timing.delta!.formattedSummary}',
                  style: const TextStyle(fontSize: 10, color: Colors.white60, fontFamily: 'monospace'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTelemetryBar(BuildContext context) {
    if (_currentTelemetry == null) return const SizedBox.shrink();
    final t = _currentTelemetry!;
    final tempStr = t.tempC > 0 ? '${t.tempC.toStringAsFixed(0)}°C' : 'N/A';
    final ramMb = (t.rssKb / 1024).toStringAsFixed(0);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black45,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('⚡ CPU: ${t.bigFreqMhz}MHz', style: const TextStyle(fontSize: 11, color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
          Text('Lit: ${t.littleFreqMhz}MHz', style: const TextStyle(fontSize: 11, color: Colors.white70)),
          Text('🌡️ $tempStr', style: const TextStyle(fontSize: 11, color: Colors.orangeAccent)),
          Text('💾 RAM: ${ramMb}MB', style: const TextStyle(fontSize: 11, color: Colors.greenAccent)),
          Text('🧵 ${t.threads} thr / nonvol: ${t.nonvolCtxtSwitches}', style: const TextStyle(fontSize: 11, color: Colors.amberAccent)),
        ],
      ),
    );
  }

  Widget _metricBadge(String label, {Color? color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: (color ?? Colors.grey).withAlpha(40),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: color ?? Colors.white70, fontWeight: FontWeight.bold),
      ),
    );
  }
}

// ── Supporting Widgets ────────────────────────────────────────────────────────

enum _ScreenState { initialising, ready, running, error }

class _StatusBanner extends StatelessWidget {
  final _ScreenState state;
  final String errorMessage;
  const _StatusBanner({required this.state, required this.errorMessage});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return switch (state) {
      _ScreenState.initialising => _banner(context,
          icon: Icons.hourglass_top,
          color: cs.tertiary,
          text: 'Loading models… (copying assets to device)'),
      _ScreenState.ready => _banner(context,
          icon: Icons.check_circle_outline,
          color: cs.primary,
          text: 'Ready — tap Continuous Test or Live Mic'),
      _ScreenState.running => _banner(context,
          icon: Icons.graphic_eq,
          color: cs.secondary,
          text: 'Streaming pipeline active (concurrent STT → MT → TTS → Playback)'),
      _ScreenState.error => _banner(context,
          icon: Icons.error_outline, color: cs.error, text: errorMessage),
    };
  }

  Widget _banner(BuildContext context,
      {required IconData icon, required Color color, required String text}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(80)),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: TextStyle(color: color, fontSize: 13))),
      ]),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final _ScreenState state;
  const _EmptyState({required this.state});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.stream_rounded, size: 56, color: cs.outline),
            const SizedBox(height: 16),
            Text('Real Overlapping Streaming', style: tt.titleMedium?.copyWith(color: cs.outline)),
            const SizedBox(height: 8),
            Text(
              state == _ScreenState.initialising
                  ? 'Initialising models…'
                  : 'Tap "Continuous Test" to test overlapping multi-sentence speech\nor "Live Mic" to speak into tablet.',
              style: tt.bodySmall?.copyWith(color: cs.outline.withAlpha(160)),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultsPanel extends StatelessWidget {
  final PipelineResult result;
  final String savedWavPath;
  const _ResultsPanel({required this.result, required this.savedWavPath});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isH2M = result.direction == TranslationDirection.hindiToMundari;
    final srcLang = isH2M ? 'Hindi' : 'Mundari';
    final tgtLang = isH2M ? 'Mundari' : 'Hindi';

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _StageCard(
            stageNum: 1,
            title: 'STT ($srcLang)',
            durationMs: result.sttMs,
            content: result.sourceText.isEmpty ? '(no speech recognised)' : result.sourceText,
            color: cs.primary,
            icon: Icons.mic_none_rounded,
          ),
          const SizedBox(height: 10),
          _StageCard(
            stageNum: 2,
            title: 'MT ($tgtLang)',
            durationMs: result.mtMs,
            content: result.targetText,
            color: cs.tertiary,
            icon: Icons.translate_rounded,
          ),
          const SizedBox(height: 10),
          _StageCard(
            stageNum: 4,
            title: isH2M ? 'TTS ($tgtLang audio)' : 'TTS ($tgtLang on-device audio)',
            durationMs: result.ttsMs,
            content: '⚡ Stream: 1st clause in ${result.firstClauseTtsMs}ms (${result.clauseCount} clauses total)\n'
                '${isH2M ? "WAV saved — pull via ADB:\nadb exec-out run-as com.mundari.mundari_pipeline cat cache/pipeline_output.wav > pipeline_output.wav" : "Spoken via Android on-device Hindi TextToSpeech."}',
            color: cs.secondary,
            icon: Icons.speaker_rounded,
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: cs.outlineVariant.withAlpha(60)),
            ),
            child: Row(
              children: [
                const Icon(Icons.bolt_rounded, color: Colors.amberAccent, size: 20),
                const SizedBox(width: 8),
                const Text('Time-to-First-Audio (TTFA)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const Spacer(),
                Text('${result.timeToFirstAudioMs} ms', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StageCard extends StatelessWidget {
  final int stageNum;
  final String title;
  final int durationMs;
  final String content;
  final Color color;
  final IconData icon;

  const _StageCard({
    required this.stageNum,
    required this.title,
    required this.durationMs,
    required this.content,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant.withAlpha(60)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 8),
              Text('Stage $stageNum · $title', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color)),
              const Spacer(),
              Text('${durationMs}ms', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color)),
            ],
          ),
          const SizedBox(height: 8),
          Text(content, style: const TextStyle(fontSize: 14)),
        ],
      ),
    );
  }
}

class _PipelineLegend extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('STT', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
        Icon(Icons.chevron_right_rounded, size: 16),
        Text('MT', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
        Icon(Icons.chevron_right_rounded, size: 16),
        Text('TTS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
        Icon(Icons.chevron_right_rounded, size: 16),
        Text('Playback', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.greenAccent)),
      ],
    );
  }
}
