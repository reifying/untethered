package dev.labs910.voicecode.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

/**
 * WebSocket message types following the voice-code protocol.
 * All messages use snake_case for JSON keys as per STANDARDS.md.
 *
 * Protocol version: Compatible with backend v0.2.0+
 */

// =============================================================================
// MARK: - Outgoing Messages (Client -> Backend)
// =============================================================================

/**
 * Connect message sent after WebSocket connection established.
 * Required for authentication before any other messages.
 */
@Serializable
data class ConnectMessage(
    @SerialName("type") val type: String = "connect",
    @SerialName("session_id") val sessionId: String,
    @SerialName("api_key") val apiKey: String
)

/**
 * Prompt message to send to Claude.
 */
@Serializable
data class PromptMessage(
    @SerialName("type") val type: String = "prompt",
    @SerialName("text") val text: String,
    @SerialName("session_id") val sessionId: String? = null,
    @SerialName("working_directory") val workingDirectory: String? = null,
    @SerialName("system_prompt") val systemPrompt: String? = null
)

/**
 * Subscribe to a session's history and real-time updates.
 */
@Serializable
data class SubscribeMessage(
    @SerialName("type") val type: String = "subscribe",
    @SerialName("session_id") val sessionId: String,
    @SerialName("last_message_id") val lastMessageId: String? = null
)

/**
 * Acknowledge receipt of a message (for delivery tracking).
 */
@Serializable
data class MessageAckMessage(
    @SerialName("type") val type: String = "message_ack",
    @SerialName("message_id") val messageId: String
)

/**
 * Set the working directory for the session.
 */
@Serializable
data class SetDirectoryMessage(
    @SerialName("type") val type: String = "set_directory",
    @SerialName("path") val path: String
)

/**
 * Ping message to keep connection alive.
 */
@Serializable
data class PingMessage(
    @SerialName("type") val type: String = "ping"
)

/**
 * Request session compaction to reduce context window usage.
 */
@Serializable
data class CompactSessionMessage(
    @SerialName("type") val type: String = "compact_session",
    @SerialName("session_id") val sessionId: String
)

/**
 * Set maximum message size for this client connection.
 */
@Serializable
data class SetMaxMessageSizeMessage(
    @SerialName("type") val type: String = "set_max_message_size",
    @SerialName("size_kb") val sizeKb: Int
)

/**
 * Request session list refresh.
 */
@Serializable
data class RefreshSessionsMessage(
    @SerialName("type") val type: String = "refresh_sessions",
    @SerialName("recent_sessions_limit") val recentSessionsLimit: Int? = null
)

/**
 * Execute a command.
 */
@Serializable
data class ExecuteCommandMessage(
    @SerialName("type") val type: String = "execute_command",
    @SerialName("command_id") val commandId: String,
    @SerialName("working_directory") val workingDirectory: String
)

/**
 * Get command history.
 */
@Serializable
data class GetCommandHistoryMessage(
    @SerialName("type") val type: String = "get_command_history",
    @SerialName("working_directory") val workingDirectory: String? = null,
    @SerialName("limit") val limit: Int? = null
)

/**
 * Get full command output.
 */
@Serializable
data class GetCommandOutputMessage(
    @SerialName("type") val type: String = "get_command_output",
    @SerialName("command_session_id") val commandSessionId: String
)

// =============================================================================
// MARK: - Incoming Messages (Backend -> Client)
// =============================================================================

/**
 * Hello message received after WebSocket connection.
 */
@Serializable
data class HelloMessage(
    @SerialName("type") val type: String,
    @SerialName("message") val message: String,
    @SerialName("version") val version: String,
    @SerialName("auth_version") val authVersion: Int,
    @SerialName("instructions") val instructions: String
)

/**
 * Connected confirmation after successful authentication.
 */
@Serializable
data class ConnectedMessage(
    @SerialName("type") val type: String,
    @SerialName("message") val message: String,
    @SerialName("session_id") val sessionId: String
)

/**
 * Acknowledgment that prompt is being processed.
 */
@Serializable
data class AckMessage(
    @SerialName("type") val type: String,
    @SerialName("message") val message: String
)

/**
 * Usage statistics for a response.
 */
@Serializable
data class UsageData(
    @SerialName("input_tokens") val inputTokens: Int,
    @SerialName("output_tokens") val outputTokens: Int
)

/**
 * Cost breakdown for a response.
 */
@Serializable
data class CostData(
    @SerialName("input_cost") val inputCost: Double,
    @SerialName("output_cost") val outputCost: Double,
    @SerialName("total_cost") val totalCost: Double
)

/**
 * Claude response message.
 */
@Serializable
data class ResponseMessage(
    @SerialName("type") val type: String,
    @SerialName("message_id") val messageId: String? = null,
    @SerialName("success") val success: Boolean,
    @SerialName("text") val text: String? = null,
    @SerialName("error") val error: String? = null,
    @SerialName("session_id") val sessionId: String? = null,
    @SerialName("usage") val usage: UsageData? = null,
    @SerialName("cost") val cost: CostData? = null
)

/**
 * Error message.
 */
@Serializable
data class ErrorMessage(
    @SerialName("type") val type: String,
    @SerialName("message") val message: String,
    @SerialName("session_id") val sessionId: String? = null
)

/**
 * Authentication error - connection will be closed.
 */
@Serializable
data class AuthErrorMessage(
    @SerialName("type") val type: String,
    @SerialName("message") val message: String
)

/**
 * Session is locked (processing another prompt).
 */
@Serializable
data class SessionLockedMessage(
    @SerialName("type") val type: String,
    @SerialName("message") val message: String,
    @SerialName("session_id") val sessionId: String
)

/**
 * Turn is complete, session is unlocked.
 */
@Serializable
data class TurnCompleteMessage(
    @SerialName("type") val type: String,
    @SerialName("session_id") val sessionId: String
)

/**
 * Pong response to ping.
 */
@Serializable
data class PongMessage(
    @SerialName("type") val type: String
)

/**
 * Message within session history.
 */
@Serializable
data class HistoryMessageData(
    @SerialName("role") val role: String,
    @SerialName("text") val text: String,
    @SerialName("session_id") val sessionId: String? = null,
    @SerialName("timestamp") val timestamp: String? = null,
    @SerialName("id") val id: String? = null
)

/**
 * Replayed message during reconnection.
 */
@Serializable
data class ReplayMessage(
    @SerialName("type") val type: String,
    @SerialName("message_id") val messageId: String,
    @SerialName("message") val message: HistoryMessageData
)

/**
 * Session history response.
 */
@Serializable
data class SessionHistoryMessage(
    @SerialName("type") val type: String,
    @SerialName("session_id") val sessionId: String,
    @SerialName("messages") val messages: List<HistoryMessageData>,
    @SerialName("total_count") val totalCount: Int,
    @SerialName("oldest_message_id") val oldestMessageId: String? = null,
    @SerialName("newest_message_id") val newestMessageId: String? = null,
    @SerialName("is_complete") val isComplete: Boolean
)

/**
 * Session metadata for recent sessions list.
 */
@Serializable
data class SessionMetadata(
    @SerialName("session_id") val sessionId: String,
    @SerialName("name") val name: String? = null,
    @SerialName("working_directory") val workingDirectory: String? = null,
    @SerialName("last_modified") val lastModified: String? = null
)

/**
 * Recent sessions list.
 */
@Serializable
data class RecentSessionsMessage(
    @SerialName("type") val type: String,
    @SerialName("sessions") val sessions: List<SessionMetadata>,
    @SerialName("limit") val limit: Int? = null
)

/**
 * Session list.
 */
@Serializable
data class SessionListMessage(
    @SerialName("type") val type: String,
    @SerialName("sessions") val sessions: List<SessionMetadata>
)

/**
 * Compaction complete notification.
 */
@Serializable
data class CompactionCompleteMessage(
    @SerialName("type") val type: String,
    @SerialName("session_id") val sessionId: String
)

/**
 * Compaction error notification.
 */
@Serializable
data class CompactionErrorMessage(
    @SerialName("type") val type: String,
    @SerialName("session_id") val sessionId: String,
    @SerialName("error") val error: String
)

// =============================================================================
// MARK: - Command Execution Messages
// =============================================================================

/**
 * Single command definition.
 */
@Serializable
data class CommandDefinition(
    @SerialName("id") val id: String,
    @SerialName("label") val label: String,
    @SerialName("type") val type: String,
    @SerialName("description") val description: String? = null,
    @SerialName("children") val children: List<CommandDefinition>? = null
)

/**
 * Available commands for a working directory.
 */
@Serializable
data class AvailableCommandsMessage(
    @SerialName("type") val type: String,
    @SerialName("working_directory") val workingDirectory: String,
    @SerialName("project_commands") val projectCommands: List<CommandDefinition>,
    @SerialName("general_commands") val generalCommands: List<CommandDefinition>
)

/**
 * Command started notification.
 */
@Serializable
data class CommandStartedMessage(
    @SerialName("type") val type: String,
    @SerialName("command_session_id") val commandSessionId: String,
    @SerialName("command_id") val commandId: String,
    @SerialName("shell_command") val shellCommand: String
)

/**
 * Command output line.
 */
@Serializable
data class CommandOutputMessage(
    @SerialName("type") val type: String,
    @SerialName("command_session_id") val commandSessionId: String,
    @SerialName("stream") val stream: String,
    @SerialName("text") val text: String
)

/**
 * Command complete notification.
 */
@Serializable
data class CommandCompleteMessage(
    @SerialName("type") val type: String,
    @SerialName("command_session_id") val commandSessionId: String,
    @SerialName("exit_code") val exitCode: Int,
    @SerialName("duration_ms") val durationMs: Long
)

/**
 * Command session metadata for history.
 */
@Serializable
data class CommandSessionData(
    @SerialName("command_session_id") val commandSessionId: String,
    @SerialName("command_id") val commandId: String,
    @SerialName("shell_command") val shellCommand: String,
    @SerialName("working_directory") val workingDirectory: String,
    @SerialName("timestamp") val timestamp: String,
    @SerialName("exit_code") val exitCode: Int? = null,
    @SerialName("duration_ms") val durationMs: Long? = null,
    @SerialName("output_preview") val outputPreview: String? = null
)

/**
 * Command history response.
 */
@Serializable
data class CommandHistoryMessage(
    @SerialName("type") val type: String,
    @SerialName("sessions") val sessions: List<CommandSessionData>,
    @SerialName("limit") val limit: Int
)

/**
 * Full command output response.
 */
@Serializable
data class CommandOutputFullMessage(
    @SerialName("type") val type: String,
    @SerialName("command_session_id") val commandSessionId: String,
    @SerialName("output") val output: String,
    @SerialName("exit_code") val exitCode: Int,
    @SerialName("timestamp") val timestamp: String,
    @SerialName("duration_ms") val durationMs: Long,
    @SerialName("command_id") val commandId: String,
    @SerialName("shell_command") val shellCommand: String,
    @SerialName("working_directory") val workingDirectory: String
)

/**
 * Generic message type for parsing the type field first.
 */
@Serializable
data class GenericMessage(
    @SerialName("type") val type: String
)
