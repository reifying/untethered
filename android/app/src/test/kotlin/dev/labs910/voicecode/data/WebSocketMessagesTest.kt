package dev.labs910.voicecode.data

import dev.labs910.voicecode.data.model.*
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

/**
 * Tests for WebSocket message serialization/deserialization.
 * Verifies protocol compliance with STANDARDS.md.
 */
class WebSocketMessagesTest {

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        encodeDefaults = true
    }

    // ==========================================================================
    // MARK: - Outgoing Messages (Client -> Backend)
    // ==========================================================================

    @Test
    fun `ConnectMessage serializes with snake_case keys`() {
        val message = ConnectMessage(
            sessionId = "abc123de-4567-89ab-cdef-0123456789ab",
            apiKey = "untethered-a1b2c3d4e5f678901234567890abcdef"
        )

        val serialized = json.encodeToString(ConnectMessage.serializer(), message)

        assertTrue(serialized.contains("\"type\":\"connect\""))
        assertTrue(serialized.contains("\"session_id\":\"abc123de-4567-89ab-cdef-0123456789ab\""))
        assertTrue(serialized.contains("\"api_key\":\"untethered-a1b2c3d4e5f678901234567890abcdef\""))
    }

    @Test
    fun `PromptMessage serializes with optional fields`() {
        val messageWithAll = PromptMessage(
            text = "Hello Claude",
            sessionId = "session-123",
            workingDirectory = "/Users/test/project",
            systemPrompt = "Be helpful"
        )

        val serialized = json.encodeToString(PromptMessage.serializer(), messageWithAll)

        assertTrue(serialized.contains("\"type\":\"prompt\""))
        assertTrue(serialized.contains("\"text\":\"Hello Claude\""))
        assertTrue(serialized.contains("\"session_id\":\"session-123\""))
        assertTrue(serialized.contains("\"working_directory\":\"/Users/test/project\""))
        assertTrue(serialized.contains("\"system_prompt\":\"Be helpful\""))
    }

    @Test
    fun `PromptMessage serializes with null optional fields`() {
        val messageMinimal = PromptMessage(
            text = "Hello"
        )

        val serialized = json.encodeToString(PromptMessage.serializer(), messageMinimal)

        assertTrue(serialized.contains("\"type\":\"prompt\""))
        assertTrue(serialized.contains("\"text\":\"Hello\""))
        // Null fields should serialize as null, not be omitted
        assertTrue(serialized.contains("\"session_id\":null"))
    }

    @Test
    fun `SubscribeMessage serializes with delta sync`() {
        val message = SubscribeMessage(
            sessionId = "session-123",
            lastMessageId = "msg-456"
        )

        val serialized = json.encodeToString(SubscribeMessage.serializer(), message)

        assertTrue(serialized.contains("\"type\":\"subscribe\""))
        assertTrue(serialized.contains("\"session_id\":\"session-123\""))
        assertTrue(serialized.contains("\"last_message_id\":\"msg-456\""))
    }

    @Test
    fun `ExecuteCommandMessage serializes correctly`() {
        val message = ExecuteCommandMessage(
            commandId = "git.status",
            workingDirectory = "/Users/test/project"
        )

        val serialized = json.encodeToString(ExecuteCommandMessage.serializer(), message)

        assertTrue(serialized.contains("\"type\":\"execute_command\""))
        assertTrue(serialized.contains("\"command_id\":\"git.status\""))
        assertTrue(serialized.contains("\"working_directory\":\"/Users/test/project\""))
    }

    // ==========================================================================
    // MARK: - Incoming Messages (Backend -> Client)
    // ==========================================================================

    @Test
    fun `HelloMessage deserializes correctly`() {
        val jsonString = """
            {
                "type": "hello",
                "message": "Welcome to voice-code backend",
                "version": "0.2.0",
                "auth_version": 1,
                "instructions": "Send connect message with api_key"
            }
        """.trimIndent()

        val message = json.decodeFromString<HelloMessage>(jsonString)

        assertEquals("hello", message.type)
        assertEquals("Welcome to voice-code backend", message.message)
        assertEquals("0.2.0", message.version)
        assertEquals(1, message.authVersion)
    }

    @Test
    fun `ConnectedMessage deserializes correctly`() {
        val jsonString = """
            {
                "type": "connected",
                "message": "Session registered",
                "session_id": "abc123de-4567-89ab-cdef-0123456789ab"
            }
        """.trimIndent()

        val message = json.decodeFromString<ConnectedMessage>(jsonString)

        assertEquals("connected", message.type)
        assertEquals("Session registered", message.message)
        assertEquals("abc123de-4567-89ab-cdef-0123456789ab", message.sessionId)
    }

    @Test
    fun `ResponseMessage deserializes with usage and cost`() {
        val jsonString = """
            {
                "type": "response",
                "message_id": "msg-123",
                "success": true,
                "text": "Hello! How can I help?",
                "session_id": "session-456",
                "usage": {
                    "input_tokens": 100,
                    "output_tokens": 50
                },
                "cost": {
                    "input_cost": 0.001,
                    "output_cost": 0.002,
                    "total_cost": 0.003
                }
            }
        """.trimIndent()

        val message = json.decodeFromString<ResponseMessage>(jsonString)

        assertEquals("response", message.type)
        assertEquals("msg-123", message.messageId)
        assertTrue(message.success)
        assertEquals("Hello! How can I help?", message.text)
        assertEquals("session-456", message.sessionId)
        assertNotNull(message.usage)
        assertEquals(100, message.usage?.inputTokens)
        assertEquals(50, message.usage?.outputTokens)
        assertNotNull(message.cost)
        assertEquals(0.003, message.cost?.totalCost ?: 0.0, 0.0001)
    }

    @Test
    fun `ResponseMessage deserializes error response`() {
        val jsonString = """
            {
                "type": "response",
                "success": false,
                "error": "Something went wrong"
            }
        """.trimIndent()

        val message = json.decodeFromString<ResponseMessage>(jsonString)

        assertEquals("response", message.type)
        assertFalse(message.success)
        assertEquals("Something went wrong", message.error)
        assertNull(message.text)
    }

    @Test
    fun `SessionLockedMessage deserializes correctly`() {
        val jsonString = """
            {
                "type": "session_locked",
                "message": "Session is currently processing a prompt. Please wait.",
                "session_id": "session-123"
            }
        """.trimIndent()

        val message = json.decodeFromString<SessionLockedMessage>(jsonString)

        assertEquals("session_locked", message.type)
        assertEquals("session-123", message.sessionId)
    }

    @Test
    fun `TurnCompleteMessage deserializes correctly`() {
        val jsonString = """
            {
                "type": "turn_complete",
                "session_id": "session-123"
            }
        """.trimIndent()

        val message = json.decodeFromString<TurnCompleteMessage>(jsonString)

        assertEquals("turn_complete", message.type)
        assertEquals("session-123", message.sessionId)
    }

    @Test
    fun `SessionHistoryMessage deserializes with messages`() {
        val jsonString = """
            {
                "type": "session_history",
                "session_id": "session-123",
                "messages": [
                    {
                        "role": "user",
                        "text": "Hello",
                        "timestamp": "2025-01-15T12:00:00Z",
                        "id": "msg-1"
                    },
                    {
                        "role": "assistant",
                        "text": "Hi there!",
                        "timestamp": "2025-01-15T12:00:01Z",
                        "id": "msg-2"
                    }
                ],
                "total_count": 2,
                "oldest_message_id": "msg-1",
                "newest_message_id": "msg-2",
                "is_complete": true
            }
        """.trimIndent()

        val message = json.decodeFromString<SessionHistoryMessage>(jsonString)

        assertEquals("session_history", message.type)
        assertEquals("session-123", message.sessionId)
        assertEquals(2, message.messages.size)
        assertEquals("user", message.messages[0].role)
        assertEquals("Hello", message.messages[0].text)
        assertEquals("assistant", message.messages[1].role)
        assertTrue(message.isComplete)
    }

    @Test
    fun `RecentSessionsMessage deserializes correctly`() {
        val jsonString = """
            {
                "type": "recent_sessions",
                "sessions": [
                    {
                        "session_id": "session-1",
                        "name": "Test Project",
                        "working_directory": "/Users/test/project",
                        "last_modified": "2025-01-15T12:00:00Z"
                    }
                ],
                "limit": 10
            }
        """.trimIndent()

        val message = json.decodeFromString<RecentSessionsMessage>(jsonString)

        assertEquals("recent_sessions", message.type)
        assertEquals(1, message.sessions.size)
        assertEquals("session-1", message.sessions[0].sessionId)
        assertEquals("Test Project", message.sessions[0].name)
    }

    // ==========================================================================
    // MARK: - Command Messages
    // ==========================================================================

    @Test
    fun `AvailableCommandsMessage deserializes with nested groups`() {
        val jsonString = """
            {
                "type": "available_commands",
                "working_directory": "/Users/test/project",
                "project_commands": [
                    {
                        "id": "build",
                        "label": "Build",
                        "type": "command"
                    },
                    {
                        "id": "docker",
                        "label": "Docker",
                        "type": "group",
                        "children": [
                            {
                                "id": "docker.up",
                                "label": "Up",
                                "type": "command"
                            },
                            {
                                "id": "docker.down",
                                "label": "Down",
                                "type": "command"
                            }
                        ]
                    }
                ],
                "general_commands": [
                    {
                        "id": "git.status",
                        "label": "Git Status",
                        "description": "Show git working tree status",
                        "type": "command"
                    }
                ]
            }
        """.trimIndent()

        val message = json.decodeFromString<AvailableCommandsMessage>(jsonString)

        assertEquals("available_commands", message.type)
        assertEquals("/Users/test/project", message.workingDirectory)
        assertEquals(2, message.projectCommands.size)
        assertEquals("build", message.projectCommands[0].id)
        assertEquals("group", message.projectCommands[1].type)
        assertEquals(2, message.projectCommands[1].children?.size)
        assertEquals(1, message.generalCommands.size)
        assertEquals("git.status", message.generalCommands[0].id)
    }

    @Test
    fun `CommandOutputMessage deserializes with stream type`() {
        val jsonString = """
            {
                "type": "command_output",
                "command_session_id": "cmd-123",
                "stream": "stdout",
                "text": "On branch main"
            }
        """.trimIndent()

        val message = json.decodeFromString<CommandOutputMessage>(jsonString)

        assertEquals("command_output", message.type)
        assertEquals("cmd-123", message.commandSessionId)
        assertEquals("stdout", message.stream)
        assertEquals("On branch main", message.text)
    }

    @Test
    fun `CommandCompleteMessage deserializes with exit code`() {
        val jsonString = """
            {
                "type": "command_complete",
                "command_session_id": "cmd-123",
                "exit_code": 0,
                "duration_ms": 1234
            }
        """.trimIndent()

        val message = json.decodeFromString<CommandCompleteMessage>(jsonString)

        assertEquals("command_complete", message.type)
        assertEquals("cmd-123", message.commandSessionId)
        assertEquals(0, message.exitCode)
        assertEquals(1234L, message.durationMs)
    }

    // ==========================================================================
    // MARK: - GenericMessage for Type Detection
    // ==========================================================================

    @Test
    fun `GenericMessage extracts type from any message`() {
        val testCases = listOf(
            """{"type": "hello", "other": "data"}""" to "hello",
            """{"type": "connected", "session_id": "123"}""" to "connected",
            """{"type": "response", "success": true}""" to "response",
            """{"type": "command_output", "text": "foo"}""" to "command_output"
        )

        for ((jsonString, expectedType) in testCases) {
            val message = json.decodeFromString<GenericMessage>(jsonString)
            assertEquals(expectedType, message.type)
        }
    }
}
