import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Structured status of on-device Speech-to-Text (ASR) support for Hindi.
enum AsrSupportStatus {
  /// The on-device speech recognizer is present and the Hindi (hi-IN)
  /// language asset pack is downloaded and immediately usable 100% offline.
  readyOffline('READY_OFFLINE'),

  /// The on-device speech recognizer supports Hindi (hi-IN), but the
  /// localized asset pack has not yet been downloaded to the device.
  needsDownload('NEEDS_DOWNLOAD'),

  /// On-device speech recognition is not supported globally on this device,
  /// the OS API level is insufficient (< Android 13 for verified asset check),
  /// or Hindi is not among the supported on-device languages.
  notSupported('NOT_SUPPORTED');

  final String code;
  const AsrSupportStatus(this.code);

  /// Parse raw string status from native platform.
  static AsrSupportStatus fromRaw(String? raw) {
    switch (raw?.trim().toUpperCase()) {
      case 'READY_OFFLINE':
        return AsrSupportStatus.readyOffline;
      case 'NEEDS_DOWNLOAD':
        return AsrSupportStatus.needsDownload;
      case 'NOT_SUPPORTED':
      default:
        return AsrSupportStatus.notSupported;
    }
  }
}

/// Flutter bridge helper to diagnose native Android OS-level Speech-to-Text support
/// for offline Hindi (hi-IN) without risking Out-Of-Memory (OOM) on 2 GB RAM devices.
class AsrChecker {
  static const MethodChannel _channel =
      MethodChannel('com.mundari.pipeline/asr_checker');

  /// Internal constructor for dependency injection / testing.
  @visibleForTesting
  final MethodChannel channel;

  const AsrChecker({MethodChannel? channel})
      : channel = channel ?? _channel;

  /// Default singleton instance.
  static const AsrChecker instance = AsrChecker();

  /// Invokes the native platform method 'checkSystemHindiAsr' to verify
  /// whether the device physically supports offline Hindi ASR and whether
  /// the localized asset pack is downloaded.
  ///
  /// Returns one of:
  /// - `"READY_OFFLINE"`
  /// - `"NEEDS_DOWNLOAD"`
  /// - `"NOT_SUPPORTED"`
  Future<String> checkHindiSupport() async {
    try {
      final String? result =
          await channel.invokeMethod<String>('checkSystemHindiAsr');
      return result ?? AsrSupportStatus.notSupported.code;
    } on PlatformException catch (e) {
      debugPrint('[AsrChecker] PlatformException during checkSystemHindiAsr: ${e.message}');
      return AsrSupportStatus.notSupported.code;
    } catch (e) {
      debugPrint('[AsrChecker] Unexpected error during checkSystemHindiAsr: $e');
      return AsrSupportStatus.notSupported.code;
    }
  }

  /// Convenience method returning a typed [AsrSupportStatus] enum.
  Future<AsrSupportStatus> checkHindiSupportStatus() async {
    final String raw = await checkHindiSupport();
    return AsrSupportStatus.fromRaw(raw);
  }

  /// Convenience helper returning true if Hindi is ready for 100% offline recognition.
  Future<bool> isHindiOfflineReady() async {
    final status = await checkHindiSupportStatus();
    return status == AsrSupportStatus.readyOffline;
  }

  /// Convenience helper returning true if Hindi is supported but needs the model download.
  Future<bool> isHindiDownloadNeeded() async {
    final status = await checkHindiSupportStatus();
    return status == AsrSupportStatus.needsDownload;
  }

  /// Directs the user to the native Android Voice Input Settings / Speech Services
  /// so they can initiate downloading the Hindi language pack.
  Future<bool> openVoiceInputSettings() async {
    try {
      final bool? opened =
          await channel.invokeMethod<bool>('openVoiceInputSettings');
      return opened ?? false;
    } catch (e) {
      debugPrint('[AsrChecker] Failed to open voice input settings: $e');
      return false;
    }
  }
}
