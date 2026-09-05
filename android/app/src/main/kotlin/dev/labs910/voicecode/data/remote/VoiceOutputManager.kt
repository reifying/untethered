package dev.labs910.voicecode.data.remote

import android.content.Context
import android.media.AudioManager
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.Locale
import java.util.UUID

/**
 * Manager for text-to-speech output using Android's TextToSpeech.
 * Equivalent to iOS VoiceOutputManager using AVSpeechSynthesizer.
 *
 * Key features:
 * - Text-to-speech with configurable voice
 * - Speech queue management
 * - Audio ducking (lower other audio during speech)
 * - Completion callbacks
 */
class VoiceOutputManager(
    private val context: Context
) : TextToSpeech.OnInitListener {
    companion object {
        private const val TAG = "VoiceOutputManager"
        private const val DEFAULT_SPEECH_RATE = 1.0f
        private const val DEFAULT_PITCH = 1.0f
    }

    private var tts: TextToSpeech? = null
    private var audioManager: AudioManager? = null
    private var isInitialized = false

    // State
    private val _state = MutableStateFlow(VoiceOutputState.IDLE)
    val state: StateFlow<VoiceOutputState> = _state.asStateFlow()

    private val _isSpeaking = MutableStateFlow(false)
    val isSpeaking: StateFlow<Boolean> = _isSpeaking.asStateFlow()

    private val _availableVoices = MutableStateFlow<List<Voice>>(emptyList())
    val availableVoices: StateFlow<List<Voice>> = _availableVoices.asStateFlow()

    private val _selectedVoice = MutableStateFlow<Voice?>(null)
    val selectedVoice: StateFlow<Voice?> = _selectedVoice.asStateFlow()

    // Settings
    private var speechRate = DEFAULT_SPEECH_RATE
    private var pitch = DEFAULT_PITCH
    private var respectSilentMode = true

    // Callbacks
    private val pendingCallbacks = mutableMapOf<String, () -> Unit>()

    /**
     * Initialize the TTS engine.
     * Call this early in the app lifecycle.
     */
    fun initialize() {
        if (tts != null) return

        audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        tts = TextToSpeech(context, this)
    }

    override fun onInit(status: Int) {
        if (status == TextToSpeech.SUCCESS) {
            isInitialized = true
            _state.value = VoiceOutputState.READY

            // Configure TTS
            tts?.let { engine ->
                engine.language = Locale.getDefault()
                engine.setSpeechRate(speechRate)
                engine.setPitch(pitch)

                // Get available voices
                _availableVoices.value = engine.voices?.toList() ?: emptyList()

                // Set up progress listener
                engine.setOnUtteranceProgressListener(createProgressListener())
            }
        } else {
            isInitialized = false
            _state.value = VoiceOutputState.ERROR
        }
    }

    /**
     * Speak the given text.
     *
     * @param text Text to speak
     * @param queueMode How to handle existing speech queue
     * @param onComplete Callback when speech completes
     */
    fun speak(
        text: String,
        queueMode: QueueMode = QueueMode.FLUSH,
        onComplete: (() -> Unit)? = null
    ) {
        if (!isInitialized) {
            onComplete?.invoke()
            return
        }

        // Nothing to say. A message that was only a tool call filters down to an
        // empty string upstream; handing that to the engine with QUEUE_FLUSH
        // would cut off whatever is currently being read.
        if (text.isBlank()) {
            onComplete?.invoke()
            return
        }

        // Check silent mode
        if (respectSilentMode && isDeviceSilent()) {
            onComplete?.invoke()
            return
        }

        val utteranceId = UUID.randomUUID().toString()

        // Store callback if provided
        onComplete?.let { pendingCallbacks[utteranceId] = it }

        // Request audio focus for ducking
        requestAudioFocus()

        val params = Bundle().apply {
            putString(TextToSpeech.Engine.KEY_PARAM_UTTERANCE_ID, utteranceId)
        }

        val mode = when (queueMode) {
            QueueMode.FLUSH -> TextToSpeech.QUEUE_FLUSH
            QueueMode.ADD -> TextToSpeech.QUEUE_ADD
        }

        tts?.speak(text, mode, params, utteranceId)
    }

    /**
     * Stop speaking immediately.
     */
    fun stop() {
        tts?.stop()
        _isSpeaking.value = false
        _state.value = VoiceOutputState.READY
        abandonAudioFocus()
        pendingCallbacks.clear()
    }

    /**
     * Check if TTS engine is currently speaking.
     */
    fun isSpeaking(): Boolean {
        return tts?.isSpeaking == true
    }

    /**
     * Set the speech rate.
     *
     * @param rate Speech rate (0.5 = half speed, 1.0 = normal, 2.0 = double)
     */
    fun setSpeechRate(rate: Float) {
        speechRate = rate.coerceIn(0.5f, 2.0f)
        tts?.setSpeechRate(speechRate)
    }

    /**
     * Set the pitch.
     *
     * @param pitch Pitch (0.5 = low, 1.0 = normal, 2.0 = high)
     */
    fun setPitch(pitch: Float) {
        this.pitch = pitch.coerceIn(0.5f, 2.0f)
        tts?.setPitch(this.pitch)
    }

    /**
     * Set the voice to use.
     */
    fun setVoice(voice: Voice) {
        tts?.voice = voice
        _selectedVoice.value = voice
    }

    /**
     * Set whether to respect device silent mode.
     */
    fun setRespectSilentMode(respect: Boolean) {
        respectSilentMode = respect
    }

    /**
     * Get voices for a specific locale.
     */
    fun getVoicesForLocale(locale: Locale): List<Voice> {
        return _availableVoices.value.filter { it.locale == locale }
    }

    /**
     * Release resources.
     */
    fun destroy() {
        stop()
        tts?.shutdown()
        tts = null
        isInitialized = false
        _state.value = VoiceOutputState.IDLE
    }

    private fun createProgressListener(): UtteranceProgressListener {
        return object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {
                _isSpeaking.value = true
                _state.value = VoiceOutputState.SPEAKING
            }

            override fun onDone(utteranceId: String?) {
                _isSpeaking.value = false
                _state.value = VoiceOutputState.READY
                abandonAudioFocus()

                // Invoke callback if registered
                utteranceId?.let { id ->
                    pendingCallbacks.remove(id)?.invoke()
                }
            }

            @Deprecated("Deprecated in API")
            override fun onError(utteranceId: String?) {
                _isSpeaking.value = false
                _state.value = VoiceOutputState.ERROR
                abandonAudioFocus()

                // Invoke callback even on error
                utteranceId?.let { id ->
                    pendingCallbacks.remove(id)?.invoke()
                }
            }

            override fun onError(utteranceId: String?, errorCode: Int) {
                onError(utteranceId)
            }
        }
    }

    private fun isDeviceSilent(): Boolean {
        return audioManager?.ringerMode == AudioManager.RINGER_MODE_SILENT ||
            audioManager?.ringerMode == AudioManager.RINGER_MODE_VIBRATE
    }

    private fun requestAudioFocus() {
        audioManager?.requestAudioFocus(
            null,
            AudioManager.STREAM_MUSIC,
            AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
        )
    }

    private fun abandonAudioFocus() {
        audioManager?.abandonAudioFocus(null)
    }
}

/**
 * Voice output state.
 */
enum class VoiceOutputState {
    IDLE,
    READY,
    SPEAKING,
    ERROR
}

/**
 * Queue mode for speech.
 */
enum class QueueMode {
    /** Replace any existing speech */
    FLUSH,
    /** Add to the end of the queue */
    ADD
}
