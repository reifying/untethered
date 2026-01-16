package dev.labs910.voicecode.presentation.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dev.labs910.voicecode.data.local.ApiKeyManager
import dev.labs910.voicecode.data.local.VoiceCodeNotificationManager
import dev.labs910.voicecode.data.remote.*
import dev.labs910.voicecode.data.repository.SessionRepository
import dev.labs910.voicecode.domain.model.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch

/**
 * Main ViewModel for the VoiceCode app.
 * Coordinates between UI, WebSocket client, and repository.
 */
class MainViewModel(
    private val client: VoiceCodeClient,
    private val repository: SessionRepository,
    private val apiKeyManager: ApiKeyManager,
    private val voiceInput: VoiceInputManager,
    private val voiceOutput: VoiceOutputManager,
    private val notificationManager: VoiceCodeNotificationManager? = null
) : ViewModel() {

    // ==========================================================================
    // MARK: - UI State
    // ==========================================================================

    private val _uiState = MutableStateFlow(MainUiState())
    val uiState: StateFlow<MainUiState> = _uiState.asStateFlow()

    // ==========================================================================
    // MARK: - Data Flows
    // ==========================================================================

    val sessions: StateFlow<List<Session>> = repository.getAllSessions()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val recentSessions: StateFlow<List<Session>> = repository.getRecentSessions()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    private val _currentSessionMessages = MutableStateFlow<List<Message>>(emptyList())
    val currentSessionMessages: StateFlow<List<Message>> = _currentSessionMessages.asStateFlow()

    // ==========================================================================
    // MARK: - Connection State
    // ==========================================================================

    val connectionState: StateFlow<ConnectionState> = client.connectionState
    val isAuthenticated: StateFlow<Boolean> = client.isAuthenticated
    val requiresReauthentication: StateFlow<Boolean> = client.requiresReauthentication
    val lockedSessions: StateFlow<Set<String>> = client.lockedSessions

    // ==========================================================================
    // MARK: - Voice State
    // ==========================================================================

    val voiceInputState: StateFlow<VoiceInputState> = voiceInput.state
    val voicePartialTranscription: StateFlow<String> = voiceInput.partialTranscription
    val voiceAudioLevel: StateFlow<Float> = voiceInput.audioLevel

    val voiceOutputState: StateFlow<VoiceOutputState> = voiceOutput.state
    val isSpeaking: StateFlow<Boolean> = voiceOutput.isSpeaking
    val availableVoices = voiceOutput.availableVoices
    val selectedVoice = voiceOutput.selectedVoice

    init {
        observeWebSocketEvents()
        initializeVoice()
    }

    // ==========================================================================
    // MARK: - Connection
    // ==========================================================================

    fun connect() {
        val apiKey = apiKeyManager.getApiKey() ?: return

        val serverUrl = _uiState.value.serverUrl.ifBlank { "localhost" }
        val serverPort = _uiState.value.serverPort.ifBlank { "9999" }
        val url = "ws://$serverUrl:$serverPort/ws"

        // Use current session ID or generate new one
        val sessionId = _uiState.value.currentSession?.id
            ?: java.util.UUID.randomUUID().toString().lowercase()

        client.connect(url, apiKey, sessionId)
    }

    fun disconnect() {
        client.disconnect()
    }

    // ==========================================================================
    // MARK: - Authentication
    // ==========================================================================

    fun setApiKey(apiKey: String): Boolean {
        return apiKeyManager.setApiKey(apiKey)
    }

    fun hasApiKey(): Boolean = apiKeyManager.hasApiKey()

    fun clearApiKey() {
        apiKeyManager.deleteApiKey()
    }

    fun getCurrentApiKey(): String? = apiKeyManager.getApiKey()

    // ==========================================================================
    // MARK: - Sessions
    // ==========================================================================

    fun selectSession(session: Session) {
        _uiState.update { it.copy(currentSession = session) }

        // Subscribe to session messages
        viewModelScope.launch {
            repository.getMessagesForSession(session.id).collect { messages ->
                _currentSessionMessages.value = messages
            }
        }

        // Subscribe via WebSocket if we have a backend session ID
        session.backendSessionId?.let { backendId ->
            val lastMessageId = _currentSessionMessages.value.lastOrNull()?.id
            client.subscribe(backendId, lastMessageId)
        }

        // Mark session as read
        viewModelScope.launch {
            repository.markSessionRead(session.id)
        }
    }

    fun createNewSession() {
        viewModelScope.launch {
            val session = repository.createSession()
            selectSession(session)
        }
    }

    fun deleteSession(session: Session) {
        viewModelScope.launch {
            repository.deleteSession(session.id)
            if (_uiState.value.currentSession?.id == session.id) {
                _uiState.update { it.copy(currentSession = null) }
                _currentSessionMessages.value = emptyList()
            }
        }
    }

    fun refreshSessions() {
        client.refreshSessions()
    }

    // ==========================================================================
    // MARK: - Messages
    // ==========================================================================

    fun sendMessage(text: String) {
        val session = _uiState.value.currentSession ?: return

        viewModelScope.launch {
            // Create optimistic message
            val message = repository.createUserMessage(session.id, text)

            // Send via WebSocket
            client.sendPrompt(
                text = text,
                sessionId = session.backendSessionId,
                workingDirectory = session.workingDirectory
            )
        }
    }

    // ==========================================================================
    // MARK: - Voice Input
    // ==========================================================================

    private fun initializeVoice() {
        voiceInput.initialize()
        voiceOutput.initialize()
    }

    fun startVoiceInput() {
        voiceInput.startRecording(
            onResult = { transcription ->
                if (transcription.isNotBlank()) {
                    sendMessage(transcription)
                }
            },
            onPartialResult = { partial ->
                // UI will observe partialTranscription StateFlow
            },
            onError = { error ->
                _uiState.update { it.copy(error = error.getMessage()) }
            }
        )
    }

    fun stopVoiceInput() {
        voiceInput.stopRecording()
    }

    fun cancelVoiceInput() {
        voiceInput.cancelRecording()
    }

    // ==========================================================================
    // MARK: - Voice Output
    // ==========================================================================

    fun speakResponse(text: String) {
        voiceOutput.speak(text)
    }

    fun stopSpeaking() {
        voiceOutput.stop()
    }

    fun setVoice(voice: android.speech.tts.Voice) {
        voiceOutput.setVoice(voice)
    }

    fun setSpeechRate(rate: Float) {
        voiceOutput.setSpeechRate(rate)
        _uiState.update { it.copy(speechRate = rate) }
    }

    fun setPitch(pitch: Float) {
        voiceOutput.setPitch(pitch)
        _uiState.update { it.copy(pitch = pitch) }
    }

    fun testVoice() {
        voiceOutput.speak("Hello! This is a test of the selected voice.", QueueMode.FLUSH)
    }

    // ==========================================================================
    // MARK: - Settings
    // ==========================================================================

    fun updateServerUrl(url: String) {
        _uiState.update { it.copy(serverUrl = url) }
    }

    fun updateServerPort(port: String) {
        _uiState.update { it.copy(serverPort = port) }
    }

    fun setNotificationsEnabled(enabled: Boolean) {
        _uiState.update { it.copy(notificationsEnabled = enabled) }
    }

    fun setSilentModeRespected(respected: Boolean) {
        _uiState.update { it.copy(silentModeRespected = respected) }
        voiceOutput.setRespectSilentMode(respected)
    }

    fun setAppInForeground(inForeground: Boolean) {
        _uiState.update { it.copy(isAppInForeground = inForeground) }
    }

    // ==========================================================================
    // MARK: - Session Actions
    // ==========================================================================

    fun compactSession() {
        val session = _uiState.value.currentSession ?: return
        session.backendSessionId?.let { backendId ->
            client.compactSession(backendId)
        }
    }

    fun forceUnlockSession(sessionId: String) {
        client.forceUnlockSession(sessionId)
    }

    // ==========================================================================
    // MARK: - Priority Queue
    // ==========================================================================

    val priorityQueueSessions: StateFlow<List<Session>> = repository.getPriorityQueueSessions()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    fun addToPriorityQueue(sessionId: String, priority: Int = 10) {
        viewModelScope.launch {
            repository.addToPriorityQueue(sessionId, priority)
            // Update current session if it's the one being modified
            if (_uiState.value.currentSession?.id == sessionId) {
                repository.getSession(sessionId)?.let { updatedSession ->
                    _uiState.update { it.copy(currentSession = updatedSession) }
                }
            }
        }
    }

    fun removeFromPriorityQueue(sessionId: String) {
        viewModelScope.launch {
            repository.removeFromPriorityQueue(sessionId)
            // Update current session if it's the one being modified
            if (_uiState.value.currentSession?.id == sessionId) {
                repository.getSession(sessionId)?.let { updatedSession ->
                    _uiState.update { it.copy(currentSession = updatedSession) }
                }
            }
        }
    }

    fun changeSessionPriority(sessionId: String, newPriority: Int) {
        viewModelScope.launch {
            repository.changeSessionPriority(sessionId, newPriority)
            // Update current session if it's the one being modified
            if (_uiState.value.currentSession?.id == sessionId) {
                repository.getSession(sessionId)?.let { updatedSession ->
                    _uiState.update { it.copy(currentSession = updatedSession) }
                }
            }
        }
    }

    fun reorderSession(sessionId: String, newOrder: Double) {
        viewModelScope.launch {
            repository.reorderSession(sessionId, newOrder)
        }
    }

    // ==========================================================================
    // MARK: - Error Handling
    // ==========================================================================

    fun clearError() {
        _uiState.update { it.copy(error = null) }
    }

    // ==========================================================================
    // MARK: - WebSocket Events
    // ==========================================================================

    private fun observeWebSocketEvents() {
        viewModelScope.launch {
            client.messages.collect { event ->
                handleWebSocketEvent(event)
            }
        }
    }

    private fun handleWebSocketEvent(event: WebSocketEvent) {
        when (event) {
            is WebSocketEvent.Connected -> {
                // Connection successful
            }

            is WebSocketEvent.AuthError -> {
                _uiState.update { it.copy(error = "Authentication failed. Please re-enter your API key.") }
            }

            is WebSocketEvent.Response -> {
                handleResponse(event.message)
            }

            is WebSocketEvent.SessionHistory -> {
                handleSessionHistory(event.message)
            }

            is WebSocketEvent.RecentSessions -> {
                handleRecentSessions(event.message)
            }

            is WebSocketEvent.TurnComplete -> {
                // Session unlocked - UI will update via lockedSessions flow
            }

            is WebSocketEvent.SessionLocked -> {
                // Session locked - UI will update via lockedSessions flow
            }

            is WebSocketEvent.CompactionComplete -> {
                // TODO: Notify user
            }

            is WebSocketEvent.CompactionError -> {
                _uiState.update { it.copy(error = "Compaction failed: ${event.message.error}") }
            }

            is WebSocketEvent.Error -> {
                _uiState.update { it.copy(error = event.error) }
            }

            is WebSocketEvent.ErrorMessage -> {
                _uiState.update { it.copy(error = event.message.message) }
            }

            is WebSocketEvent.ParseError -> {
                // Log parse errors but don't show to user
            }

            else -> {
                // Handle other events as needed
            }
        }
    }

    private fun handleResponse(response: dev.labs910.voicecode.data.model.ResponseMessage) {
        if (!response.success) {
            _uiState.update { it.copy(error = response.error ?: "Unknown error") }
            return
        }

        val sessionId = _uiState.value.currentSession?.id ?: return
        val text = response.text ?: return

        viewModelScope.launch {
            // Save the message
            repository.saveBackendMessage(
                sessionId = sessionId,
                messageId = response.messageId,
                role = "assistant",
                text = text,
                timestamp = null, // Use current time
                usage = response.usage,
                cost = response.cost
            )

            // Update backend session ID if this is a new session
            response.sessionId?.let { backendId ->
                repository.updateBackendSessionId(sessionId, backendId)
                _uiState.value.currentSession?.let { session ->
                    _uiState.update {
                        it.copy(currentSession = session.copy(backendSessionId = backendId))
                    }
                }
            }

            // Show notification if enabled and app is in background
            if (_uiState.value.notificationsEnabled && !_uiState.value.isAppInForeground) {
                val sessionName = _uiState.value.currentSession?.name ?: "Claude"
                val preview = if (text.length > 100) {
                    text.take(97) + "..."
                } else {
                    text
                }
                notificationManager?.showResponseNotification(sessionName, preview, sessionId)
            }

            // Speak the response if voice output is enabled
            if (_uiState.value.autoSpeakResponses) {
                speakResponse(text)
            }
        }
    }

    private fun handleSessionHistory(history: dev.labs910.voicecode.data.model.SessionHistoryMessage) {
        val sessionId = _uiState.value.currentSession?.id ?: return

        viewModelScope.launch {
            repository.saveHistoryMessages(sessionId, history.messages)
        }
    }

    private fun handleRecentSessions(recent: dev.labs910.voicecode.data.model.RecentSessionsMessage) {
        viewModelScope.launch {
            for (metadata in recent.sessions) {
                repository.updateSessionFromBackend(metadata)
            }
        }
    }

    // ==========================================================================
    // MARK: - Cleanup
    // ==========================================================================

    override fun onCleared() {
        super.onCleared()
        voiceInput.destroy()
        voiceOutput.destroy()
        client.destroy()
    }
}

/**
 * UI state for the main screen.
 */
data class MainUiState(
    val currentSession: Session? = null,
    val serverUrl: String = "localhost",
    val serverPort: String = "9999",
    val notificationsEnabled: Boolean = true,
    val silentModeRespected: Boolean = true,
    val autoSpeakResponses: Boolean = false,
    val isAppInForeground: Boolean = true,
    val speechRate: Float = 1.0f,
    val pitch: Float = 1.0f,
    val error: String? = null
)
