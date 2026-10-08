import 'dart:developer' as dev;
import 'dart:io';
import 'package:flutter/services.dart';

/// Service interfacing with native Android on-device TextToSpeech for Hindi (hi-IN).
///
/// On Android, uses the OS-level `android.speech.tts.TextToSpeech` service.
/// On desktop/macOS/iOS, logs or gracefully handles calls so unit tests and
/// headless benchmarking do not crash.
class HindiTtsService {
  static const MethodChannel _channel =
      MethodChannel('com.mundari.pipeline/hindi_tts');

  static final HindiTtsService instance = HindiTtsService._();
  HindiTtsService._();

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  /// Initializes the on-device Hindi TTS engine.
  Future<bool> init() async {
    if (_isInitialized) return true;

    if (!Platform.isAndroid) {
      dev.log('[HindiTtsService] Non-Android platform: using simulated on-device Hindi TTS.');
      _isInitialized = true;
      return true;
    }

    try {
      final bool? success = await _channel.invokeMethod<bool>('init');
      _isInitialized = success ?? false;
      dev.log('[HindiTtsService] Android Hindi TextToSpeech init result: $_isInitialized');
      return _isInitialized;
    } catch (e) {
      dev.log('[HindiTtsService] Failed to initialize Android Hindi TTS: $e');
      _isInitialized = false;
      return false;
    }
  }

  /// Speaks the given Hindi [text] using on-device TTS.
  Future<bool> speak(String text) async {
    if (text.trim().isEmpty) return true;

    if (!Platform.isAndroid) {
      dev.log('[HindiTtsService] (Simulated Playback) Speaking Hindi: "$text"');
      return true;
    }

    try {
      if (!_isInitialized) {
        await init();
      }
      final bool? success = await _channel.invokeMethod<bool>('speak', {'text': text});
      return success ?? false;
    } catch (e) {
      dev.log('[HindiTtsService] Error speaking Hindi text: $e');
      return false;
    }
  }

  /// Stops any currently playing speech.
  Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (e) {
      dev.log('[HindiTtsService] Error stopping speech: $e');
    }
  }
}
