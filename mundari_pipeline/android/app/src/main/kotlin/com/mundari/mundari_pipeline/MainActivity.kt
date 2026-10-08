package com.mundari.mundari_pipeline

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.speech.tts.TextToSpeech
import java.util.Locale

class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "AsrChecker"
        private const val CHANNEL_NAME = "com.mundari.pipeline/asr_checker"
        private const val TTS_CHANNEL_NAME = "com.mundari.pipeline/hindi_tts"

        // Structured status contracts
        private const val STATUS_READY_OFFLINE = "READY_OFFLINE"
        private const val STATUS_NEEDS_DOWNLOAD = "NEEDS_DOWNLOAD"
        private const val STATUS_NOT_SUPPORTED = "NOT_SUPPORTED"

        private const val CHECK_TIMEOUT_MS = 5000L
    }

    private var hindiTts: TextToSpeech? = null
    private var isHindiTtsReady = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkSystemHindiAsr" -> {
                        checkHindiAsrSupport(result)
                    }
                    "openVoiceInputSettings" -> {
                        openVoiceInputSettings(result)
                    }
                    else -> {
                        result.notImplemented()
                    }
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, TTS_CHANNEL_NAME)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "init" -> {
                        initHindiTts(result)
                    }
                    "speak" -> {
                        val text = call.argument<String>("text") ?: ""
                        speakHindi(text, result)
                    }
                    "stop" -> {
                        stopHindiTts()
                        result.success(true)
                    }
                    else -> {
                        result.notImplemented()
                    }
                }
            }
    }

    private fun initHindiTts(result: MethodChannel.Result) {
        if (isHindiTtsReady && hindiTts != null) {
            result.success(true)
            return
        }
        hindiTts = TextToSpeech(applicationContext) { status ->
            if (status == TextToSpeech.SUCCESS) {
                val langRes = hindiTts?.setLanguage(Locale("hi", "IN"))
                isHindiTtsReady = langRes != TextToSpeech.LANG_MISSING_DATA &&
                                  langRes != TextToSpeech.LANG_NOT_SUPPORTED
                Log.i("HindiTts", "TextToSpeech init success. hi_IN status: $langRes (ready: $isHindiTtsReady)")
                result.success(isHindiTtsReady)
            } else {
                Log.e("HindiTts", "TextToSpeech init failed with status: $status")
                result.success(false)
            }
        }
    }

    private fun speakHindi(text: String, result: MethodChannel.Result) {
        if (hindiTts == null) {
            result.error("TTS_NOT_INITIALIZED", "Hindi TextToSpeech is not initialized", null)
            return
        }
        val utteranceId = "hindi_utt_${System.currentTimeMillis()}"
        val speakStatus = hindiTts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, utteranceId)
        result.success(speakStatus == TextToSpeech.SUCCESS)
    }

    private fun stopHindiTts() {
        hindiTts?.stop()
    }

    override fun onDestroy() {
        super.onDestroy()
        hindiTts?.shutdown()
        hindiTts = null
    }

    /**
     * Entry point to verify offline Hindi ASR support.
     * Defensive checks:
     * 1. Speech recognition engine availability globally.
     * 2. On-device engine availability (API 31+) or direct Google Recognition Service binding.
     * 3. API 33+ detailed asset check (READY_OFFLINE vs NEEDS_DOWNLOAD vs NOT_SUPPORTED).
     */
    private fun checkHindiAsrSupport(result: MethodChannel.Result) {
        val context = applicationContext

        // Step 1: Check basic recognition availability across all engines
        if (!SpeechRecognizer.isRecognitionAvailable(context)) {
            Log.w(TAG, "SpeechRecognizer is not available on this device.")
            result.success(STATUS_NOT_SUPPORTED)
            return
        }

        // Step 2: For Android 13+ (API 33), query fine-grained language asset status
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Api33SpeechSupportChecker.checkHindiSupport(context, result)
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // On API 31-32, check isOnDeviceRecognitionAvailable
            val isAvail = SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
            Log.i(TAG, "API ${Build.VERSION.SDK_INT}: isOnDeviceRecognitionAvailable = $isAvail")
            result.success(if (isAvail) STATUS_READY_OFFLINE else STATUS_NOT_SUPPORTED)
        } else {
            Log.i(
                TAG,
                "API ${Build.VERSION.SDK_INT} < 31: Native OS cannot verify on-device offline recognition."
            )
            result.success(STATUS_NOT_SUPPORTED)
        }
    }

    /**
     * Launch system voice input settings to allow user to manage language models.
     */
    private fun openVoiceInputSettings(result: MethodChannel.Result) {
        try {
            val intent = Intent("android.settings.VOICE_INPUT_SETTINGS").apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            try {
                val fallbackIntent = Intent(Settings.ACTION_SETTINGS).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                }
                startActivity(fallbackIntent)
                result.success(true)
            } catch (e2: Exception) {
                Log.e(TAG, "Failed to open settings: ${e2.message}")
                result.success(false)
            }
        }
    }

    /**
     * Isolated helper class for Android 13+ (API 33 / TIRAMISU).
     *
     * Isolating this class prevents the Android runtime (ART) on Android < 13
     * from attempting to resolve RecognitionSupportCallback / RecognitionSupport,
     * which would otherwise trigger ClassNotFoundException / NoClassDefFoundError.
     */
    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private object Api33SpeechSupportChecker {

        fun checkHindiSupport(context: Context, result: MethodChannel.Result) {
            // Guard: ensure method is called on the main thread
            if (Looper.myLooper() != Looper.getMainLooper()) {
                Handler(Looper.getMainLooper()).post {
                    checkHindiSupport(context, result)
                }
                return
            }

            // Create recognizer instance:
            // 1. Try on-device recognition engine if certified by OEM.
            // 2. If OEM has no default on-device engine (common on Samsung), target Google RecognitionService directly.
            val recognizer = try {
                if (SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) {
                    Log.d(TAG, "Using SpeechRecognizer.createOnDeviceSpeechRecognizer")
                    SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
                } else {
                    Log.i(
                        TAG,
                        "SpeechRecognizer.isOnDeviceRecognitionAvailable is false. Binding directly to Google Recognition Service..."
                    )
                    val gsaComponent = ComponentName(
                        "com.google.android.googlequicksearchbox",
                        "com.google.android.voicesearch.serviceapi.GoogleRecognitionService"
                    )
                    val ttsComponent = ComponentName(
                        "com.google.android.tts",
                        "com.google.android.apps.speech.tts.googletts.service.GoogleTTSRecognitionService"
                    )

                    try {
                        SpeechRecognizer.createSpeechRecognizer(context, gsaComponent)
                    } catch (eGsa: Throwable) {
                        Log.w(TAG, "Failed binding to Google App service: ${eGsa.message}. Trying TTS service...")
                        try {
                            SpeechRecognizer.createSpeechRecognizer(context, ttsComponent)
                        } catch (eTts: Throwable) {
                            SpeechRecognizer.createSpeechRecognizer(context)
                        }
                    }
                }
            } catch (e: Throwable) {
                Log.w(TAG, "Failed creating SpeechRecognizer: ${e.message}")
                null
            }

            if (recognizer == null) {
                result.success(STATUS_NOT_SUPPORTED)
                return
            }

            val responded = AtomicBoolean(false)
            val mainHandler = Handler(Looper.getMainLooper())

            // Watchdog timeout to prevent hangs on memory-constrained (2 GB) devices
            val timeoutRunnable = Runnable {
                if (responded.compareAndSet(false, true)) {
                    Log.w(TAG, "checkRecognitionSupport timed out after ${CHECK_TIMEOUT_MS}ms")
                    safeDestroyRecognizer(recognizer)
                    result.success(STATUS_NOT_SUPPORTED)
                }
            }
            mainHandler.postDelayed(timeoutRunnable, CHECK_TIMEOUT_MS)

            val recognizerIntent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, "hi-IN")
            }

            try {
                recognizer.checkRecognitionSupport(
                    recognizerIntent,
                    ContextCompat.getMainExecutor(context),
                    object : RecognitionSupportCallback {
                        override fun onSupportResult(recognitionSupport: RecognitionSupport) {
                            mainHandler.removeCallbacks(timeoutRunnable)
                            if (!responded.compareAndSet(false, true)) return

                            try {
                                val installed = recognitionSupport.installedOnDeviceLanguages
                                val supported = recognitionSupport.supportedOnDeviceLanguages
                                val pending = recognitionSupport.pendingOnDeviceLanguages

                                Log.d(
                                    TAG,
                                    "On-Device Languages -> Installed: $installed, Supported: $supported, Pending: $pending"
                                )

                                val isInstalled = installed.any { isHindiTag(it) }
                                val isSupported = supported.any { isHindiTag(it) }
                                val isPending = pending.any { isHindiTag(it) }

                                val status = when {
                                    isInstalled -> STATUS_READY_OFFLINE
                                    isSupported || isPending -> STATUS_NEEDS_DOWNLOAD
                                    else -> STATUS_NOT_SUPPORTED
                                }

                                Log.i(TAG, "Determined Hindi ASR status: $status")
                                result.success(status)
                            } catch (e: Throwable) {
                                Log.e(TAG, "Error evaluating RecognitionSupport: ${e.message}", e)
                                result.success(STATUS_NOT_SUPPORTED)
                            } finally {
                                // CRITICAL: Release resources immediately to prevent OOM on 2 GB RAM devices
                                safeDestroyRecognizer(recognizer)
                            }
                        }

                        override fun onError(errorCode: Int) {
                            mainHandler.removeCallbacks(timeoutRunnable)
                            if (!responded.compareAndSet(false, true)) return

                            Log.w(TAG, "checkRecognitionSupport onError code: $errorCode")
                            try {
                                result.success(STATUS_NOT_SUPPORTED)
                            } finally {
                                safeDestroyRecognizer(recognizer)
                            }
                        }
                    }
                )
            } catch (e: Throwable) {
                mainHandler.removeCallbacks(timeoutRunnable)
                if (responded.compareAndSet(false, true)) {
                    Log.e(TAG, "checkRecognitionSupport threw exception: ${e.message}", e)
                    safeDestroyRecognizer(recognizer)
                    result.success(STATUS_NOT_SUPPORTED)
                }
            }
        }

        /**
         * Matches Hindi language variations: "hi-IN", "hi_IN", "hi", "hi-Deva-IN", etc.
         */
        private fun isHindiTag(tag: String?): Boolean {
            if (tag.isNullOrBlank()) return false
            val normalized = tag.trim().lowercase().replace('_', '-')
            return normalized == "hi-in" || normalized == "hi" || normalized.startsWith("hi-")
        }

        /**
         * Defensive unbinding and cleanup function.
         * Calls speechRecognizer.destroy() safely on the main thread.
         */
        private fun safeDestroyRecognizer(recognizer: SpeechRecognizer?) {
            if (recognizer == null) return
            try {
                recognizer.destroy()
                Log.d(TAG, "SpeechRecognizer destroyed successfully.")
            } catch (e: Throwable) {
                Log.w(TAG, "Exception while destroying SpeechRecognizer: ${e.message}")
            }
        }
    }
}
