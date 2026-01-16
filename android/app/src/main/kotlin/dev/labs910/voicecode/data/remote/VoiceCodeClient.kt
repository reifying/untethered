package dev.labs910.voicecode.data.remote

import dev.labs910.voicecode.data.model.*
import dev.labs910.voicecode.domain.model.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.Json
import okhttp3.*
import java.time.Instant
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * WebSocket client for voice-code backend communication.
 * Implements the protocol defined in STANDARDS.md.
 *
 * Key features:
 * - Automatic reconnection with exponential backoff
 * - Session locking to prevent concurrent Claude executions
 * - Message acknowledgment and delivery tracking
 * - Ping/keepalive for connection health
 */
class VoiceCodeClient(
    private val scope: CoroutineScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
) {
    companion object {
        private const val TAG = "VoiceCodeClient"

        // Reconnection settings (matching iOS)
        private const val INITIAL_RETRY_DELAY_MS = 1000L
        private const val MAX_RETRY_DELAY_MS = 30_000L
        private const val RETRY_MULTIPLIER = 2.0
        private const val MAX_RETRY_DURATION_MS = 17 * 60 * 1000L // ~17 minutes

        // Keepalive settings
        private const val PING_INTERVAL_MS = 30_000L

        // Default message size limit (iOS URLSessionWebSocketTask limit is 256KB)
        private const val DEFAULT_MAX_MESSAGE_SIZE_KB = 200
    }

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        encodeDefaults = true
    }

    private val client = OkHttpClient.Builder()
        .pingInterval(PING_INTERVAL_MS, TimeUnit.MILLISECONDS)
        .build()

    private var webSocket: WebSocket? = null
    private var serverUrl: String = ""
    private var apiKey: String = ""
    private var currentSessionId: String = ""

    // Connection state
    private val _connectionState = MutableStateFlow(ConnectionState.DISCONNECTED)
    val connectionState: StateFlow<ConnectionState> = _connectionState.asStateFlow()

    private val _isAuthenticated = MutableStateFlow(false)
    val isAuthenticated: StateFlow<Boolean> = _isAuthenticated.asStateFlow()

    private val _requiresReauthentication = MutableStateFlow(false)
    val requiresReauthentication: StateFlow<Boolean> = _requiresReauthentication.asStateFlow()

    // Session state
    private val _lockedSessions = MutableStateFlow<Set<String>>(emptySet())
    val lockedSessions: StateFlow<Set<String>> = _lockedSessions.asStateFlow()

    // Message events
    private val _messages = MutableSharedFlow<WebSocketEvent>(extraBufferCapacity = 64)
    val messages: SharedFlow<WebSocketEvent> = _messages.asSharedFlow()

    // Reconnection state
    private val isReconnecting = AtomicBoolean(false)
    private val reconnectAttempt = AtomicInteger(0)
    private var reconnectJob: Job? = null
    private var reconnectStartTime: Long = 0L

    // Keepalive
    private var pingJob: Job? = null

    /**
     * Connect to the voice-code backend.
     *
     * @param url WebSocket URL (e.g., "ws://localhost:9999/ws")
     * @param apiKey API key in format "untethered-<32-hex-chars>"
     * @param sessionId iOS session UUID (lowercase)
     */
    fun connect(url: String, apiKey: String, sessionId: String) {
        this.serverUrl = url
        this.apiKey = apiKey
        this.currentSessionId = sessionId.lowercase()

        _connectionState.value = ConnectionState.CONNECTING
        reconnectAttempt.set(0)
        reconnectStartTime = 0L

        doConnect()
    }

    private fun doConnect() {
        val request = Request.Builder()
            .url(serverUrl)
            .build()

        webSocket = client.newWebSocket(request, createWebSocketListener())
    }

    private fun createWebSocketListener() = object : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            _connectionState.value = ConnectionState.CONNECTED
            isReconnecting.set(false)
            reconnectAttempt.set(0)
            startPingJob()
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            handleMessage(text)
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(1000, null)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            handleDisconnect()
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            _messages.tryEmit(WebSocketEvent.Error(t.message ?: "Connection failed"))
            handleDisconnect()
        }
    }

    private fun handleMessage(text: String) {
        try {
            val genericMessage = json.decodeFromString<GenericMessage>(text)

            when (genericMessage.type) {
                "hello" -> {
                    val message = json.decodeFromString<HelloMessage>(text)
                    _messages.tryEmit(WebSocketEvent.Hello(message))
                    // Send connect message with authentication
                    sendConnect()
                }

                "connected" -> {
                    val message = json.decodeFromString<ConnectedMessage>(text)
                    _isAuthenticated.value = true
                    _requiresReauthentication.value = false
                    _messages.tryEmit(WebSocketEvent.Connected(message))
                    // Send max message size configuration
                    sendMaxMessageSize(DEFAULT_MAX_MESSAGE_SIZE_KB)
                }

                "auth_error" -> {
                    val message = json.decodeFromString<AuthErrorMessage>(text)
                    _isAuthenticated.value = false
                    _requiresReauthentication.value = true
                    _messages.tryEmit(WebSocketEvent.AuthError(message))
                }

                "ack" -> {
                    val message = json.decodeFromString<AckMessage>(text)
                    _messages.tryEmit(WebSocketEvent.Ack(message))
                }

                "response" -> {
                    val message = json.decodeFromString<ResponseMessage>(text)
                    _messages.tryEmit(WebSocketEvent.Response(message))
                    // Acknowledge delivery if message has ID
                    message.messageId?.let { sendMessageAck(it) }
                }

                "error" -> {
                    val message = json.decodeFromString<ErrorMessage>(text)
                    _messages.tryEmit(WebSocketEvent.ErrorMessage(message))
                    // Unlock session if error contains session_id
                    message.sessionId?.let { unlockSession(it) }
                }

                "session_locked" -> {
                    val message = json.decodeFromString<SessionLockedMessage>(text)
                    _messages.tryEmit(WebSocketEvent.SessionLocked(message))
                }

                "turn_complete" -> {
                    val message = json.decodeFromString<TurnCompleteMessage>(text)
                    unlockSession(message.sessionId)
                    _messages.tryEmit(WebSocketEvent.TurnComplete(message))
                }

                "pong" -> {
                    val message = json.decodeFromString<PongMessage>(text)
                    _messages.tryEmit(WebSocketEvent.Pong(message))
                }

                "replay" -> {
                    val message = json.decodeFromString<ReplayMessage>(text)
                    _messages.tryEmit(WebSocketEvent.Replay(message))
                    // Acknowledge replayed message
                    sendMessageAck(message.messageId)
                }

                "session_history" -> {
                    val message = json.decodeFromString<SessionHistoryMessage>(text)
                    _messages.tryEmit(WebSocketEvent.SessionHistory(message))
                }

                "recent_sessions" -> {
                    val message = json.decodeFromString<RecentSessionsMessage>(text)
                    _messages.tryEmit(WebSocketEvent.RecentSessions(message))
                }

                "session_list" -> {
                    val message = json.decodeFromString<SessionListMessage>(text)
                    _messages.tryEmit(WebSocketEvent.SessionList(message))
                }

                "compaction_complete" -> {
                    val message = json.decodeFromString<CompactionCompleteMessage>(text)
                    _messages.tryEmit(WebSocketEvent.CompactionComplete(message))
                }

                "compaction_error" -> {
                    val message = json.decodeFromString<CompactionErrorMessage>(text)
                    _messages.tryEmit(WebSocketEvent.CompactionError(message))
                }

                "available_commands" -> {
                    val message = json.decodeFromString<AvailableCommandsMessage>(text)
                    _messages.tryEmit(WebSocketEvent.AvailableCommands(message))
                }

                "command_started" -> {
                    val message = json.decodeFromString<CommandStartedMessage>(text)
                    _messages.tryEmit(WebSocketEvent.CommandStarted(message))
                }

                "command_output" -> {
                    val message = json.decodeFromString<CommandOutputMessage>(text)
                    _messages.tryEmit(WebSocketEvent.CommandOutput(message))
                }

                "command_complete" -> {
                    val message = json.decodeFromString<CommandCompleteMessage>(text)
                    _messages.tryEmit(WebSocketEvent.CommandComplete(message))
                }

                "command_history" -> {
                    val message = json.decodeFromString<CommandHistoryMessage>(text)
                    _messages.tryEmit(WebSocketEvent.CommandHistory(message))
                }

                "command_output_full" -> {
                    val message = json.decodeFromString<CommandOutputFullMessage>(text)
                    _messages.tryEmit(WebSocketEvent.CommandOutputFull(message))
                }

                else -> {
                    _messages.tryEmit(WebSocketEvent.Unknown(genericMessage.type, text))
                }
            }
        } catch (e: Exception) {
            _messages.tryEmit(WebSocketEvent.ParseError(text, e.message ?: "Parse error"))
        }
    }

    private fun handleDisconnect() {
        stopPingJob()
        _connectionState.value = ConnectionState.DISCONNECTED
        _isAuthenticated.value = false

        // Don't reconnect if authentication failed
        if (_requiresReauthentication.value) {
            return
        }

        // Start reconnection with exponential backoff
        if (!isReconnecting.getAndSet(true)) {
            reconnectStartTime = System.currentTimeMillis()
            scheduleReconnect()
        }
    }

    private fun scheduleReconnect() {
        reconnectJob?.cancel()
        reconnectJob = scope.launch {
            val elapsed = System.currentTimeMillis() - reconnectStartTime
            if (elapsed >= MAX_RETRY_DURATION_MS) {
                _messages.tryEmit(WebSocketEvent.Error("Max reconnection time exceeded"))
                isReconnecting.set(false)
                return@launch
            }

            val attempt = reconnectAttempt.getAndIncrement()
            val delayMs = (INITIAL_RETRY_DELAY_MS * Math.pow(RETRY_MULTIPLIER, attempt.toDouble()))
                .toLong()
                .coerceAtMost(MAX_RETRY_DELAY_MS)

            delay(delayMs)

            _connectionState.value = ConnectionState.RECONNECTING
            doConnect()
        }
    }

    private fun startPingJob() {
        stopPingJob()
        pingJob = scope.launch {
            while (isActive) {
                delay(PING_INTERVAL_MS)
                sendPing()
            }
        }
    }

    private fun stopPingJob() {
        pingJob?.cancel()
        pingJob = null
    }

    // ==========================================================================
    // MARK: - Outgoing Messages
    // ==========================================================================

    private fun sendConnect() {
        val message = ConnectMessage(
            sessionId = currentSessionId,
            apiKey = apiKey
        )
        send(json.encodeToString(ConnectMessage.serializer(), message))
    }

    private fun sendMaxMessageSize(sizeKb: Int) {
        val message = SetMaxMessageSizeMessage(sizeKb = sizeKb)
        send(json.encodeToString(SetMaxMessageSizeMessage.serializer(), message))
    }

    private fun sendMessageAck(messageId: String) {
        val message = MessageAckMessage(messageId = messageId)
        send(json.encodeToString(MessageAckMessage.serializer(), message))
    }

    private fun sendPing() {
        val message = PingMessage()
        send(json.encodeToString(PingMessage.serializer(), message))
    }

    /**
     * Send a prompt to Claude.
     *
     * @param text The prompt text
     * @param sessionId Claude session ID (nil for new session)
     * @param workingDirectory Optional working directory override
     * @param systemPrompt Optional custom system prompt
     */
    fun sendPrompt(
        text: String,
        sessionId: String? = null,
        workingDirectory: String? = null,
        systemPrompt: String? = null
    ) {
        // Optimistic locking - lock session before sending
        sessionId?.let { lockSession(it) }

        val message = PromptMessage(
            text = text,
            sessionId = sessionId,
            workingDirectory = workingDirectory,
            systemPrompt = systemPrompt?.takeIf { it.isNotBlank() }
        )
        send(json.encodeToString(PromptMessage.serializer(), message))
    }

    /**
     * Subscribe to a session's history.
     *
     * @param sessionId Claude session ID
     * @param lastMessageId Last known message ID for delta sync
     */
    fun subscribe(sessionId: String, lastMessageId: String? = null) {
        val message = SubscribeMessage(
            sessionId = sessionId.lowercase(),
            lastMessageId = lastMessageId
        )
        send(json.encodeToString(SubscribeMessage.serializer(), message))
    }

    /**
     * Set the working directory for the current session.
     */
    fun setDirectory(path: String) {
        val message = SetDirectoryMessage(path = path)
        send(json.encodeToString(SetDirectoryMessage.serializer(), message))
    }

    /**
     * Request session compaction.
     */
    fun compactSession(sessionId: String) {
        val message = CompactSessionMessage(sessionId = sessionId.lowercase())
        send(json.encodeToString(CompactSessionMessage.serializer(), message))
    }

    /**
     * Refresh the session list.
     */
    fun refreshSessions(limit: Int? = null) {
        val message = RefreshSessionsMessage(recentSessionsLimit = limit)
        send(json.encodeToString(RefreshSessionsMessage.serializer(), message))
    }

    /**
     * Execute a command.
     */
    fun executeCommand(commandId: String, workingDirectory: String) {
        val message = ExecuteCommandMessage(
            commandId = commandId,
            workingDirectory = workingDirectory
        )
        send(json.encodeToString(ExecuteCommandMessage.serializer(), message))
    }

    /**
     * Get command history.
     */
    fun getCommandHistory(workingDirectory: String? = null, limit: Int? = null) {
        val message = GetCommandHistoryMessage(
            workingDirectory = workingDirectory,
            limit = limit
        )
        send(json.encodeToString(GetCommandHistoryMessage.serializer(), message))
    }

    /**
     * Get full command output.
     */
    fun getCommandOutput(commandSessionId: String) {
        val message = GetCommandOutputMessage(commandSessionId = commandSessionId)
        send(json.encodeToString(GetCommandOutputMessage.serializer(), message))
    }

    private fun send(text: String): Boolean {
        return webSocket?.send(text) ?: false
    }

    // ==========================================================================
    // MARK: - Session Locking
    // ==========================================================================

    private fun lockSession(sessionId: String) {
        _lockedSessions.value = _lockedSessions.value + sessionId
    }

    private fun unlockSession(sessionId: String) {
        _lockedSessions.value = _lockedSessions.value - sessionId
    }

    /**
     * Manually unlock a stuck session.
     */
    fun forceUnlockSession(sessionId: String) {
        unlockSession(sessionId)
    }

    /**
     * Check if a session is locked.
     */
    fun isSessionLocked(sessionId: String): Boolean {
        return sessionId in _lockedSessions.value
    }

    // ==========================================================================
    // MARK: - Lifecycle
    // ==========================================================================

    /**
     * Disconnect from the backend.
     */
    fun disconnect() {
        isReconnecting.set(false)
        reconnectJob?.cancel()
        stopPingJob()
        webSocket?.close(1000, "Client disconnect")
        webSocket = null
        _connectionState.value = ConnectionState.DISCONNECTED
        _isAuthenticated.value = false
    }

    /**
     * Clean up resources.
     */
    fun destroy() {
        disconnect()
        scope.cancel()
    }
}

/**
 * Connection state enum.
 */
enum class ConnectionState {
    DISCONNECTED,
    CONNECTING,
    CONNECTED,
    RECONNECTING
}

/**
 * WebSocket events emitted to observers.
 */
sealed class WebSocketEvent {
    // Connection events
    data class Hello(val message: HelloMessage) : WebSocketEvent()
    data class Connected(val message: ConnectedMessage) : WebSocketEvent()
    data class AuthError(val message: AuthErrorMessage) : WebSocketEvent()
    data class Error(val error: String) : WebSocketEvent()

    // Response events
    data class Ack(val message: AckMessage) : WebSocketEvent()
    data class Response(val message: ResponseMessage) : WebSocketEvent()
    data class ErrorMessage(val message: dev.labs910.voicecode.data.model.ErrorMessage) : WebSocketEvent()
    data class SessionLocked(val message: SessionLockedMessage) : WebSocketEvent()
    data class TurnComplete(val message: TurnCompleteMessage) : WebSocketEvent()
    data class Pong(val message: PongMessage) : WebSocketEvent()

    // Replay events
    data class Replay(val message: ReplayMessage) : WebSocketEvent()

    // Session events
    data class SessionHistory(val message: SessionHistoryMessage) : WebSocketEvent()
    data class RecentSessions(val message: RecentSessionsMessage) : WebSocketEvent()
    data class SessionList(val message: SessionListMessage) : WebSocketEvent()
    data class CompactionComplete(val message: CompactionCompleteMessage) : WebSocketEvent()
    data class CompactionError(val message: CompactionErrorMessage) : WebSocketEvent()

    // Command events
    data class AvailableCommands(val message: AvailableCommandsMessage) : WebSocketEvent()
    data class CommandStarted(val message: CommandStartedMessage) : WebSocketEvent()
    data class CommandOutput(val message: CommandOutputMessage) : WebSocketEvent()
    data class CommandComplete(val message: CommandCompleteMessage) : WebSocketEvent()
    data class CommandHistory(val message: CommandHistoryMessage) : WebSocketEvent()
    data class CommandOutputFull(val message: CommandOutputFullMessage) : WebSocketEvent()

    // Parse events
    data class Unknown(val type: String, val raw: String) : WebSocketEvent()
    data class ParseError(val raw: String, val error: String) : WebSocketEvent()
}
