package id.nst.focus_launcher

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/**
 * `flute/voice` (MethodChannel) and `flute/voice_events` (EventChannel): speech recognition and
 * text-to-speech for the agent's voice mode. Engines are created on first use, all calls and
 * callbacks run on the main thread, and [release] tears them down with the launcher activity.
 */
object VoiceNative : MethodChannel.MethodCallHandler {
    const val CHANNEL = "flute/voice"
    const val EVENTS_CHANNEL = "flute/voice_events"
    const val PERMISSION_REQUEST_CODE = 4713

    private val main = Handler(Looper.getMainLooper())
    private var appContext: Context? = null
    private var sink: EventChannel.EventSink? = null

    private var recognizer: SpeechRecognizer? = null
    private var recognizerOnDevice = false

    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private val waitingSpeech = ArrayList<Speech>()

    private var pendingPermission: MethodChannel.Result? = null

    private class Speech(val text: String, val id: String, val language: String?, val rate: Float)

    fun register(messenger: BinaryMessenger, context: Context) {
        appContext = context.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
        EventChannel(messenger, EVENTS_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                sink = events
            }

            override fun onCancel(arguments: Any?) {
                sink = null
            }
        })
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val context = appContext ?: return result.error("not_registered", "voice channel not registered", null)
        try {
            when (call.method) {
                "hasMicPermission" -> result.success(hasMicPermission(context))
                "requestMicPermission" -> requestPermission(context, result)
                "isOnDeviceAvailable" -> result.success(onDeviceAvailable(context))
                "listen" -> result.success(
                    listen(context, call.argument<String>("locale"), call.argument<Boolean>("onDevice") ?: false),
                )
                "stopListening" -> {
                    recognizer?.stopListening()
                    result.success(null)
                }
                "cancelListening" -> {
                    recognizer?.cancel()
                    result.success(null)
                }
                "speak" -> {
                    enqueueSpeech(
                        context,
                        Speech(
                            text = call.argument<String>("text") ?: "",
                            id = call.argument<String>("id") ?: "",
                            language = call.argument<String>("language"),
                            rate = (call.argument<Number>("rate")?.toFloat()) ?: 1f,
                        ),
                    )
                    result.success(null)
                }
                "stopSpeaking" -> {
                    waitingSpeech.clear()
                    tts?.stop()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: RuntimeException) {
            result.error("voice_failed", e.message, null)
        }
    }

    /** Called from MainActivity.onDestroy. The next call recreates whatever it needs. */
    fun release() {
        recognizer?.destroy()
        recognizer = null
        tts?.shutdown()
        tts = null
        ttsReady = false
        waitingSpeech.clear()
    }

    /** Main thread only, from MainActivity.onRequestPermissionsResult. */
    fun onPermissionResult(grantResults: IntArray) {
        val result = pendingPermission ?: return
        pendingPermission = null
        result.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
    }

    /** Main thread only, from MainActivity.onDestroy: a dialog answer will never arrive now. */
    fun abandonPermissionRequest() {
        val result = pendingPermission ?: return
        pendingPermission = null
        result.success(false)
    }

    private fun hasMicPermission(context: Context): Boolean =
        context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun requestPermission(context: Context, result: MethodChannel.Result) {
        if (hasMicPermission(context)) {
            result.success(true)
            return
        }
        if (pendingPermission != null) {
            result.success(false)
            return
        }
        pendingPermission = result
        val shown = try {
            MainActivity.requestMicrophone()
        } catch (e: RuntimeException) {
            false
        }
        if (!shown) {
            pendingPermission = null
            result.success(false)
        }
    }

    private fun onDeviceAvailable(context: Context): Boolean =
        Build.VERSION.SDK_INT >= 33 && SpeechRecognizer.isOnDeviceRecognitionAvailable(context)

    private fun listen(context: Context, language: String?, onDevice: Boolean): Boolean {
        if (!hasMicPermission(context)) {
            emit(mapOf("type" to "error", "code" to "permission"))
            return false
        }
        val engine = recognizerFor(context, onDevice)
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        language?.let { intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE, it) }
        engine.startListening(intent)
        return true
    }

    private fun recognizerFor(context: Context, onDevice: Boolean): SpeechRecognizer {
        val useOnDevice = onDevice && onDeviceAvailable(context)
        recognizer?.let {
            if (recognizerOnDevice == useOnDevice) return it
            it.destroy()
        }
        val created = if (useOnDevice && Build.VERSION.SDK_INT >= 31) {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        } else {
            SpeechRecognizer.createSpeechRecognizer(context)
        }
        created.setRecognitionListener(recognitionListener)
        recognizer = created
        recognizerOnDevice = useOnDevice
        return created
    }

    private val recognitionListener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBeginningOfSpeech() {}

        // Android reports roughly -2..10 dB; scale to 0..1 for the orb.
        override fun onRmsChanged(rmsdB: Float) {
            val level = ((rmsdB + 2f) / 12f).coerceIn(0f, 1f)
            emit(mapOf("type" to "level", "value" to level.toDouble()))
        }

        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}

        override fun onError(error: Int) {
            emit(mapOf("type" to "error", "code" to recognitionErrorCode(error)))
        }

        override fun onResults(results: Bundle?) {
            emit(mapOf("type" to "final", "text" to firstResult(results)))
        }

        override fun onPartialResults(partialResults: Bundle?) {
            emit(mapOf("type" to "partial", "text" to firstResult(partialResults)))
        }

        override fun onEvent(eventType: Int, params: Bundle?) {}
    }

    private fun firstResult(bundle: Bundle?): String =
        bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: ""

    private fun recognitionErrorCode(error: Int): String = when (error) {
        SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "no_speech"
        SpeechRecognizer.ERROR_NETWORK,
        SpeechRecognizer.ERROR_NETWORK_TIMEOUT,
        SpeechRecognizer.ERROR_SERVER,
        SpeechRecognizer.ERROR_SERVER_DISCONNECTED -> "network"
        SpeechRecognizer.ERROR_AUDIO -> "audio"
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "permission"
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "busy"
        else -> "unknown"
    }

    private fun enqueueSpeech(context: Context, speech: Speech) {
        waitingSpeech.add(speech)
        if (tts == null) {
            tts = TextToSpeech(context) { status -> main.post { onTtsInit(status) } }
                .also { it.setOnUtteranceProgressListener(utteranceListener) }
        }
        if (ttsReady) flushSpeech()
    }

    private fun onTtsInit(status: Int) {
        if (status == TextToSpeech.SUCCESS) {
            ttsReady = true
            flushSpeech()
            return
        }
        // No usable engine: every queued sentence fails so the controller can move on.
        waitingSpeech.forEach { emit(mapOf("type" to "speechError", "id" to it.id, "message" to "tts_unavailable")) }
        waitingSpeech.clear()
        tts?.shutdown()
        tts = null
    }

    private fun flushSpeech() {
        val engine = tts ?: return
        for (speech in waitingSpeech) {
            speech.language?.let { engine.setLanguage(Locale.forLanguageTag(it)) }
            engine.setSpeechRate(speech.rate)
            val queued = engine.speak(speech.text, TextToSpeech.QUEUE_ADD, null, speech.id)
            if (queued == TextToSpeech.ERROR) {
                emit(mapOf("type" to "speechError", "id" to speech.id, "message" to "tts_failed"))
            }
        }
        waitingSpeech.clear()
    }

    // Utterance callbacks arrive on a binder thread; the channel is only touched on the main thread.
    private val utteranceListener = object : UtteranceProgressListener() {
        override fun onStart(utteranceId: String?) {}

        override fun onDone(utteranceId: String?) {
            emit(mapOf("type" to "speechDone", "id" to utteranceId))
        }

        override fun onError(utteranceId: String?) {
            emit(mapOf("type" to "speechError", "id" to utteranceId, "message" to "tts_failed"))
        }

        override fun onError(utteranceId: String?, errorCode: Int) {
            emit(mapOf("type" to "speechError", "id" to utteranceId, "message" to "tts_failed"))
        }

        override fun onStop(utteranceId: String?, interrupted: Boolean) {
            emit(mapOf("type" to "speechStopped", "id" to utteranceId))
        }
    }

    private fun emit(event: Map<String, Any?>) {
        main.post { sink?.success(event) }
    }
}
