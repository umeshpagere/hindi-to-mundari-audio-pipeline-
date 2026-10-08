import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mundari_pipeline/services/asr_checker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = 'com.mundari.pipeline/asr_checker';
  const channel = MethodChannel(channelName);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('AsrSupportStatus Enum Tests', () {
    test('parses READY_OFFLINE correctly', () {
      expect(AsrSupportStatus.fromRaw('READY_OFFLINE'), AsrSupportStatus.readyOffline);
      expect(AsrSupportStatus.fromRaw('ready_offline'), AsrSupportStatus.readyOffline);
    });

    test('parses NEEDS_DOWNLOAD correctly', () {
      expect(AsrSupportStatus.fromRaw('NEEDS_DOWNLOAD'), AsrSupportStatus.needsDownload);
      expect(AsrSupportStatus.fromRaw('needs_download '), AsrSupportStatus.needsDownload);
    });

    test('parses NOT_SUPPORTED and unknown values safely', () {
      expect(AsrSupportStatus.fromRaw('NOT_SUPPORTED'), AsrSupportStatus.notSupported);
      expect(AsrSupportStatus.fromRaw(null), AsrSupportStatus.notSupported);
      expect(AsrSupportStatus.fromRaw('UNKNOWN_CODE'), AsrSupportStatus.notSupported);
    });
  });

  group('AsrChecker MethodChannel Bridge Tests', () {
    test('returns READY_OFFLINE when native indicates offline asset is installed', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        expect(methodCall.method, 'checkSystemHindiAsr');
        return 'READY_OFFLINE';
      });

      final checker = AsrChecker(channel: channel);
      final rawStatus = await checker.checkHindiSupport();
      final typedStatus = await checker.checkHindiSupportStatus();
      final isReady = await checker.isHindiOfflineReady();
      final needsDownload = await checker.isHindiDownloadNeeded();

      expect(rawStatus, 'READY_OFFLINE');
      expect(typedStatus, AsrSupportStatus.readyOffline);
      expect(isReady, isTrue);
      expect(needsDownload, isFalse);
    });

    test('returns NEEDS_DOWNLOAD when language is supported but asset needs download', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        expect(methodCall.method, 'checkSystemHindiAsr');
        return 'NEEDS_DOWNLOAD';
      });

      final checker = AsrChecker(channel: channel);
      final rawStatus = await checker.checkHindiSupport();
      final typedStatus = await checker.checkHindiSupportStatus();
      final isReady = await checker.isHindiOfflineReady();
      final needsDownload = await checker.isHindiDownloadNeeded();

      expect(rawStatus, 'NEEDS_DOWNLOAD');
      expect(typedStatus, AsrSupportStatus.needsDownload);
      expect(isReady, isFalse);
      expect(needsDownload, isTrue);
    });

    test('returns NOT_SUPPORTED when native returns NOT_SUPPORTED', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        expect(methodCall.method, 'checkSystemHindiAsr');
        return 'NOT_SUPPORTED';
      });

      final checker = AsrChecker(channel: channel);
      final rawStatus = await checker.checkHindiSupport();
      final typedStatus = await checker.checkHindiSupportStatus();

      expect(rawStatus, 'NOT_SUPPORTED');
      expect(typedStatus, AsrSupportStatus.notSupported);
    });

    test('defensively handles PlatformException without throwing', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        throw PlatformException(
          code: 'UNAVAILABLE',
          message: 'SpeechRecognizer service disconnected',
        );
      });

      final checker = AsrChecker(channel: channel);
      final rawStatus = await checker.checkHindiSupport();
      final typedStatus = await checker.checkHindiSupportStatus();

      expect(rawStatus, 'NOT_SUPPORTED');
      expect(typedStatus, AsrSupportStatus.notSupported);
    });

    test('defensively handles null native return', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        return null;
      });

      final checker = AsrChecker(channel: channel);
      final rawStatus = await checker.checkHindiSupport();
      final typedStatus = await checker.checkHindiSupportStatus();

      expect(rawStatus, 'NOT_SUPPORTED');
      expect(typedStatus, AsrSupportStatus.notSupported);
    });

    test('openVoiceInputSettings delegates correctly', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        if (methodCall.method == 'openVoiceInputSettings') {
          return true;
        }
        return null;
      });

      final checker = AsrChecker(channel: channel);
      final opened = await checker.openVoiceInputSettings();
      expect(opened, isTrue);
    });
  });
}
