import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:onnxruntime/onnxruntime.dart';

import 'package:dart_sentencepiece_tokenizer/dart_sentencepiece_tokenizer.dart';

import 'script_utils.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'pipeline.dart' show kDefaultMtThreads, TranslationDirection;

// lib/pipeline/mt_stage.dart
//
// Stage 2 of the pipeline: Machine Translation (Bidirectional Hindi ↔ Mundari)

class MtResult {
  final String displayText;
  final String synthesizeText;

  const MtResult({
    required this.displayText,
    required this.synthesizeText,
  });
}

/// Contract that every MT implementation must satisfy.
abstract class MtStage {
  /// Initialises the MT model (if any).
  Future<void> initModel();

  /// Translate [text] in [direction] and return the target-language text.
  ///
  /// Implementations must be async-safe and must NOT perform UI work.
  Future<MtResult> translate(String text, {TranslationDirection direction = TranslationDirection.hindiToMundari});

  /// Releases resources held by the MT stage.
  void dispose();
}



class RealMtStage implements MtStage {
  final int threads;

  RealMtStage({this.threads = kDefaultMtThreads});

  SentencePieceTokenizer? _tokenizer;
  OrtSessionOptions? _sessionOptions;
  OrtSession? _encoderSession;
  OrtSession? _decoderSession;
  Int32List? _tgtRemapTable;
  Map<String, int> _srcDict = {};

  static const String _spmAsset = 'assets/models/mt/spm.model';
  static const String _srcDictAsset = 'assets/models/mt/dict.SRC.json';
  static const String _encoderAsset = 'assets/models/mt/model_int8.onnx';
  static const String _decoderAsset = 'assets/models/mt/decoder_model_int8_argmax.onnx';
  static const String _remapTableAsset = 'assets/models/mt/tgt_remap_table.bin';

  @override
  Future<void> initModel() async {
    OrtEnv.instance.init();

    _sessionOptions = OrtSessionOptions()
      ..setInterOpNumThreads(1)
      ..setIntraOpNumThreads(threads)
      ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);

    print('[RealMtStage] Configured ONNX Runtime with $threads intra-op threads');

    dev.log('[RealMtStage] Loading SentencePiece tokenizer...');
    final spmData = await rootBundle.load(_spmAsset);
    final spmBytes = spmData.buffer.asUint8List(spmData.offsetInBytes, spmData.lengthInBytes);
    _tokenizer = SentencePieceTokenizer.fromBytes(spmBytes);

    try {
      dev.log('[RealMtStage] Loading source dictionary (dict.SRC.json)...');
      final srcDictJson = await rootBundle.loadString(_srcDictAsset);
      final Map<String, dynamic> rawMap = json.decode(srcDictJson);
      _srcDict = rawMap.map((key, value) => MapEntry(key, value as int));
      dev.log('[RealMtStage] Source dictionary loaded with ${_srcDict.length} entries.');
    } catch (e) {
      dev.log('[RealMtStage] Source dictionary not loaded: $e');
    }

    try {
      dev.log('[RealMtStage] Loading target remap table...');
      final remapData = await rootBundle.load(_remapTableAsset);
      _tgtRemapTable = remapData.buffer.asInt32List(remapData.offsetInBytes, remapData.lengthInBytes ~/ 4);
      dev.log('[RealMtStage] Remap table loaded with ${_tgtRemapTable!.length} entries.');
    } catch (e) {
      dev.log('[RealMtStage] Remap table not loaded: $e');
    }

    Future<OrtSession?> loadSession(String assetKey) async {
      try {
        dev.log('[RealMtStage] Copying $assetKey to temporary file...');
        final data = await rootBundle.load(assetKey);
        final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

        final tmpDir = await getTemporaryDirectory();
        final filename = assetKey.split('/').last;
        final tempFile = File('${tmpDir.path}/$filename');
        await tempFile.writeAsBytes(bytes, flush: true);

        dev.log('[RealMtStage] Loading $filename from file...');
        return OrtSession.fromFile(tempFile, _sessionOptions!);
      } catch (e) {
        dev.log('[RealMtStage] Session $assetKey not loaded: $e');
        return null;
      }
    }

    _encoderSession = await loadSession(_encoderAsset);
    _decoderSession = await loadSession(_decoderAsset);

    dev.log('[RealMtStage] Models initialization finished.');
  }

  void release() {
    _encoderSession?.release();
    _decoderSession?.release();
    _sessionOptions?.release();
  }

  bool get isInitialized => _tokenizer != null && _encoderSession != null;

  @override
  Future<MtResult> translate(String text, {TranslationDirection direction = TranslationDirection.hindiToMundari}) async {
    if (_tokenizer == null || _encoderSession == null) {
      dev.log('[RealMtStage] Warning: MT stage encoder not initialized. Falling back to input text.');
      return MtResult(
        displayText: text,
        synthesizeText: text,
      );
    }

    if (_decoderSession == null || _tgtRemapTable == null) {
      dev.log('[RealMtStage] Warning: MT stage decoder session or remap table not present. Falling back to input text.');
      return MtResult(
        displayText: text,
        synthesizeText: text,
      );
    }

    print('===================== [MT STAGE START] =====================');
    print('[MT-Input] (${direction.label}) text: "$text"');

    // -- 0. Tokenize (Dart SentencePiece + dict.SRC.json mapping) --
    final tokStart = DateTime.now();
    final encoding = _tokenizer!.encode(text, addSpecialTokens: false);
    final pieces = encoding.tokens;
    final List<int> mappedDictIds = pieces.map((p) => _srcDict[p] ?? 3).toList(); // 3 is <unk>
    final tokMs = DateTime.now().difference(tokStart).inMilliseconds;

    // IndicTrans2 input sequence format: [src_lang_id, tgt_lang_id, ...dictIds, eos_id]
    const int hinDevaId = 8;
    const int munDevaId = 122706;
    const int eosId = 2;
    final int srcId = direction == TranslationDirection.mundariToHindi ? munDevaId : hinDevaId;
    final int tgtId = direction == TranslationDirection.mundariToHindi ? hinDevaId : munDevaId;
    final List<int> fullInputIds = [srcId, tgtId, ...mappedDictIds, eosId];

    print('[MT-Stage 0] Tokenized in ${tokMs}ms (${fullInputIds.length} tokens): $fullInputIds');
    print('[MT-Stage 0] Pieces: $pieces');

    // -- 1. Encoder --
    final encStart = DateTime.now();
    final encoderRunOptions = OrtRunOptions();
    final Int64List inputIdsData = Int64List.fromList(fullInputIds);
    final Int64List maskData = Int64List.fromList(List.filled(fullInputIds.length, 1));

    final encoderInputTensor = OrtValueTensor.createTensorWithDataList(inputIdsData, [1, fullInputIds.length]);
    final encoderMaskTensor = OrtValueTensor.createTensorWithDataList(maskData, [1, fullInputIds.length]);

    final Map<String, OrtValue> encInputs = {
      'input_ids': encoderInputTensor,
      'attention_mask': encoderMaskTensor,
    };
    final encOutputs = _encoderSession!.run(encoderRunOptions, encInputs);

    final encoderHiddenStatesValue = encOutputs[0]!;
    final hiddenStatesNested = encoderHiddenStatesValue.value as List<List<List<double>>>;
    final int srcLen = hiddenStatesNested[0].length;
    final int hiddenDim = hiddenStatesNested[0][0].length;

    encoderInputTensor.release();
    encoderMaskTensor.release();
    encoderRunOptions.release();
    for (int i = 1; i < encOutputs.length; i++) {
      encOutputs[i]?.release();
    }

    final encMs = DateTime.now().difference(encStart).inMilliseconds;
    print('[MT-Stage 1] Encoder complete in ${encMs}ms (shape: [1, $srcLen, $hiddenDim])');

    // -- 2. Decoder Loop --
    final decStart = DateTime.now();
    const int bosToken = 2;
    const int eosToken = 2;
    // Bounded clause length: conversational clauses require 1.5x source tokens + 4
    final int maxLen = (srcLen * 1.5 + 4).round().clamp(8, 22);

    List<int> decoderInputIds = [bosToken];
    final encoderMaskData = Int64List.fromList(List.filled(srcLen, 1));
    final maskTensor = OrtValueTensor.createTensorWithDataList(encoderMaskData, [1, srcLen]);

    for (int i = 0; i < maxLen; i++) {
      final stepStart = DateTime.now();
      final decRunOptions = OrtRunOptions();
      final inputIdsTensor = OrtValueTensor.createTensorWithDataList(
        Int64List.fromList(decoderInputIds),
        [1, decoderInputIds.length],
      );

      final Map<String, OrtValue> decInputs = {
        'decoder_input_ids': inputIdsTensor,
        'encoder_hidden_states': encoderHiddenStatesValue,
        'encoder_attention_mask': maskTensor,
      };

      final decOutputs = _decoderSession!.run(decRunOptions, decInputs);
      final rawVal = decOutputs[0]!.value;
      final int nextToken;
      if (rawVal is List && rawVal.isNotEmpty) {
        final firstRow = rawVal[0];
        if (firstRow is List && firstRow.isNotEmpty) {
          nextToken = (firstRow[0] as num).toInt();
        } else {
          nextToken = (firstRow as num).toInt();
        }
      } else {
        nextToken = (rawVal as num).toInt();
      }

      decoderInputIds.add(nextToken);
      final stepMs = DateTime.now().difference(stepStart).inMilliseconds;
      print('[MT-Decoder-Step] step $i -> token $nextToken (${stepMs}ms)');

      inputIdsTensor.release();
      decRunOptions.release();
      for (final o in decOutputs) {
        o?.release();
      }

      if (nextToken == eosToken) {
        print('[MT-Decoder-Stop] Stopped on EOS token ($eosToken) at step $i');
        break;
      }

      // Repetition cycle detection (prevents infinite loops on non-canonical text/noise)
      final n = decoderInputIds.length;
      if (n >= 4 &&
          decoderInputIds[n - 1] == decoderInputIds[n - 2] &&
          decoderInputIds[n - 2] == decoderInputIds[n - 3]) {
        print('[MT-Decoder-Stop] Stopped due to 1-gram repetition at step $i');
        break;
      }
      if (n >= 6 &&
          decoderInputIds[n - 1] == decoderInputIds[n - 3] &&
          decoderInputIds[n - 3] == decoderInputIds[n - 5] &&
          decoderInputIds[n - 2] == decoderInputIds[n - 4] &&
          decoderInputIds[n - 4] == decoderInputIds[n - 6]) {
        print('[MT-Decoder-Stop] Stopped due to 2-gram cycle repetition at step $i');
        break;
      }
      if (n >= 9 &&
          decoderInputIds[n - 1] == decoderInputIds[n - 4] &&
          decoderInputIds[n - 4] == decoderInputIds[n - 7] &&
          decoderInputIds[n - 2] == decoderInputIds[n - 5] &&
          decoderInputIds[n - 5] == decoderInputIds[n - 8]) {
        print('[MT-Decoder-Stop] Stopped due to 3-gram cycle repetition at step $i');
        break;
      }

      if (i == maxLen - 1) {
        print('[MT-Decoder-Stop] Reached max length cap ($maxLen)');
      }
    }

    encoderHiddenStatesValue.release();
    maskTensor.release();

    final decMs = DateTime.now().difference(decStart).inMilliseconds;
    print('[MT-Stage 2] Decoder complete in ${decMs}ms: $decoderInputIds');

    // -- 3. Detokenizer (Remap via tgt_remap_table & Native Dart SPM Decode) --
    final detokStart = DateTime.now();

    // Drop BOS (and trailing EOS if present)
    List<int> rawTokens = decoderInputIds.sublist(1);
    if (rawTokens.isNotEmpty && rawTokens.last == eosToken) {
      rawTokens = rawTokens.sublist(0, rawTokens.length - 1);
    }

    // Remap: filter special tokens (<= 3) and map into true SentencePiece piece IDs
    final List<int> spmPieceIds = [];
    for (final id in rawTokens) {
      if (id > 3 && id < _tgtRemapTable!.length) {
        spmPieceIds.add(_tgtRemapTable![id]);
      }
    }
    print('[MT-Stage 3] Raw model IDs: $rawTokens');
    print('[MT-Stage 3] Remapped SPM piece IDs: $spmPieceIds');

    // Native Dart decode on correctly mapped SentencePiece piece IDs
    String devaText = _tokenizer!.decode(spmPieceIds);

    // Clean up immediate duplicate words (e.g. "रे , रे" or "रे रे")
    devaText = devaText.replaceAll(RegExp(r'\b(\S+)\s*(?:,\s*)?\1\b'), r'$1');
    final detokMs = DateTime.now().difference(detokStart).inMilliseconds;
    print('[MT-Stage 3] Decoded Devanagari text in ${detokMs}ms: "$devaText"');

    print('===================== [MT STAGE END] =====================');

    return MtResult(
      displayText: devaText,
      synthesizeText: devaText,
    );
  }

  @override
  void dispose() {
    _encoderSession?.release();
    _decoderSession?.release();
    _sessionOptions?.release();
    _encoderSession = null;
    _decoderSession = null;
    _sessionOptions = null;
  }
}

/// Simulated MT stage used for testing without full ONNX decoder models.
class MockMtStage implements MtStage {
  @override
  Future<void> initModel() async {}

  @override
  Future<MtResult> translate(String text, {TranslationDirection direction = TranslationDirection.hindiToMundari}) async {
    await Future.delayed(const Duration(milliseconds: 150));
    return MtResult(
      displayText: text,
      synthesizeText: text,
    );
  }

  @override
  void dispose() {}
}
