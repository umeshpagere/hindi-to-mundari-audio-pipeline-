import 'dart:developer' as dev;
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:path_provider/package:path_provider.dart';
import 'package:onnxruntime/onnxruntime.dart';

import 'mt_stage.dart';
import 'script_utils.dart';

class RealMtStage implements MtStage {
  OrtSessionOptions? _sessionOptions;
  OrtSession? _encoderSession;
  OrtSession? _decoderSession;
  OrtSession? _detokenizerSession;

  static const String _encoderAsset = 'assets/models/mt/encoder_with_tokenizer.onnx';
  static const String _decoderAsset = 'assets/models/mt/decoder_model_int8.onnx';
  static const String _detokenizerAsset = 'assets/models/mt/detokenizer.onnx';

  @override
  Future<void> initModel() async {
    // onnxruntime needs initialization
    OrtEnv.instance.init();

    _sessionOptions = OrtSessionOptions()
      ..setInterOpNumThreads(1)
      ..setIntraOpNumThreads(4)
      ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);

    final tmpDir = await getTemporaryDirectory();

    Future<String> extractAsset(String assetKey, String fileName) async {
      final destPath = '${tmpDir.path}/$fileName';
      final file = File(destPath);
      if (!await file.exists()) {
        dev.log('[RealMtStage] Extracting $assetKey to $destPath');
        final data = await rootBundle.load(assetKey);
        await file.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      }
      return destPath;
    }

    final encoderPath = await extractAsset(_encoderAsset, 'encoder_with_tokenizer.onnx');
    final decoderPath = await extractAsset(_decoderAsset, 'decoder_model_int8.onnx');
    final detokenizerPath = await extractAsset(_detokenizerAsset, 'detokenizer.onnx');

    dev.log('[RealMtStage] Loading encoder...');
    _encoderSession = OrtSession.fromFile(encoderPath, _sessionOptions!);

    dev.log('[RealMtStage] Loading decoder...');
    _decoderSession = OrtSession.fromFile(decoderPath, _sessionOptions!);

    dev.log('[RealMtStage] Loading detokenizer...');
    _detokenizerSession = OrtSession.fromFile(detokenizerPath, _sessionOptions!);

    dev.log('[RealMtStage] Models loaded successfully.');
  }

  void release() {
    _encoderSession?.release();
    _decoderSession?.release();
    _detokenizerSession?.release();
    _sessionOptions?.release();
  }

  @override
  Future<MtResult> translate(String hindiText) async {
    if (_encoderSession == null || _decoderSession == null || _detokenizerSession == null) {
      throw Exception('MtStage models not initialized.');
    }

    // -- 1. Encoder --
    final encStart = DateTime.now();
    final encoderRunOptions = OrtRunOptions();
    final encoderInputTensor = OrtValueTensor.createTensorWithStringList([hindiText], [1]);
    
    final encInputs = {'hindi_text': encoderInputTensor};
    final encOutputs = _encoderSession!.run(encoderRunOptions, encInputs);
    
    final encoderHiddenStatesValue = encOutputs.firstWhere((o) => o?.name == 'last_hidden_state')!;
    // Extract hidden states data and shape
    // Assuming type Float32. It returns a flattened List<double> or similar in dart wrapper?
    // Wait, let's just pass the OrtValue directly to decoder if possible.
    // Actually, OrtValueTensor cannot be easily reused directly as input in the Dart wrapper without extracting and recreating.
    // The Dart wrapper returns the underlying data as nested lists: List<List<List<double>>> for 3D tensor.
    final hiddenStatesNested = encoderHiddenStatesValue.value as List<List<List<double>>>;
    final int srcLen = hiddenStatesNested[0].length;
    
    encoderInputTensor.release();
    encoderRunOptions.release();
    encOutputs.forEach((o) => o?.release());
    final encMs = DateTime.now().difference(encStart).inMilliseconds;
    dev.log('[MT-Encoder] $encMs ms (src_len: $srcLen)');

    // -- 2. Decoder Loop --
    final decStart = DateTime.now();
    const int bosToken = 2;
    const int eosToken = 2;
    const int maxLen = 128;
    
    List<int> decoderInputIds = [bosToken];
    
    // Create tensors for static encoder outputs
    // We recreate it from nested list.
    // The mask is [1, src_len] of int64 ones.
    final encoderMaskList = List.filled(1, Int64List.fromList(List.filled(srcLen, 1)));
    
    for (int i = 0; i < maxLen; i++) {
      final decRunOptions = OrtRunOptions();
      
      // The decoder expects Float32List, but we have List<List<List<double>>>.
      // Wait, OrtValueTensor.createTensorWithDataList handles nested lists!
      final hiddenStatesTensor = OrtValueTensor.createTensorWithDataList(hiddenStatesNested);
      final maskTensor = OrtValueTensor.createTensorWithDataList(encoderMaskList);
      final inputIdsTensor = OrtValueTensor.createTensorWithDataList([Int64List.fromList(decoderInputIds)]);
      
      final decInputs = {
        'decoder_input_ids': inputIdsTensor,
        'encoder_hidden_states': hiddenStatesTensor,
        'encoder_attention_mask': maskTensor,
      };
      
      final decOutputs = _decoderSession!.run(decRunOptions, decInputs);
      
      // Output is logits: [1, dec_len, vocab_size] (nested list of double)
      final logitsNested = decOutputs[0]!.value as List<List<List<double>>>;
      final currentLogits = logitsNested[0].last; // last token's logits
      
      // argmax
      double maxLogit = double.negativeInfinity;
      int nextToken = 0;
      for (int v = 0; v < currentLogits.length; v++) {
        if (currentLogits[v] > maxLogit) {
          maxLogit = currentLogits[v];
          nextToken = v;
        }
      }
      
      decoderInputIds.add(nextToken);
      
      inputIdsTensor.release();
      hiddenStatesTensor.release();
      maskTensor.release();
      decRunOptions.release();
      decOutputs.forEach((o) => o?.release());
      
      if (nextToken == eosToken) {
        break;
      }
    }
    
    final decMs = DateTime.now().difference(decStart).inMilliseconds;
    final int decLen = decoderInputIds.length;
    dev.log('[MT-Decoder] $decMs ms (dec_len: $decLen, avg: ${(decMs/decLen).toStringAsFixed(1)} ms/token)');

    // -- 3. Detokenizer --
    final detokStart = DateTime.now();
    final detokRunOptions = OrtRunOptions();
    
    // We remove the BOS token before detokenizing
    final finalIds = decoderInputIds.sublist(1);
    final detokInputTensor = OrtValueTensor.createTensorWithDataList(Int64List.fromList(finalIds), [finalIds.length]);
    
    final detokInputs = {'token_ids': detokInputTensor};
    final detokOutputs = _detokenizerSession!.run(detokRunOptions, detokInputs);
    
    final detokValue = detokOutputs[0]!.value as List<String>;
    final String devaText = detokValue.isNotEmpty ? detokValue[0] : '';
    
    detokInputTensor.release();
    detokRunOptions.release();
    detokOutputs.forEach((o) => o?.release());
    
    final detokMs = DateTime.now().difference(detokStart).inMilliseconds;
    dev.log('[MT-Detokenizer] $detokMs ms');

    // -- 4. Transliterate --
    final String odiaText = transliterateDevaToOdia(devaText);

    return MtResult(
      displayText: odiaText,
      synthesizeText: odiaText,
    );
  }
}
