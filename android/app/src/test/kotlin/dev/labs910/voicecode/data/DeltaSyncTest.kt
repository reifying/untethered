package dev.labs910.voicecode.data

import dev.labs910.voicecode.data.model.*
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

/**
 * Tests for delta sync functionality.
 * Mirrors iOS SessionSyncManagerDeltaSyncTests.swift.
 *
 * Delta sync allows efficient reconnection by only fetching messages
 * newer than the last known message ID.
 */
class DeltaSyncTest {

    private lateinit var json: Json

    @Before
    fun setUp() {
        json = Json {
            ignoreUnknownKeys = true
            isLenient = true
            encodeDefaults = true
        }
    }

    // =========================================================================
    // MARK: - Subscribe Message Tests
    // =========================================================================

    @Test
    fun `SubscribeMessage without lastMessageId requests full history`() {
        val message = SubscribeMessage(
            sessionId = "abc123de-4567-89ab-cdef-0123456789ab"
        )

        val jsonString = json.encodeToString(SubscribeMessage.serializer(), message)

        assertTrue(jsonString.contains("\"type\":\"subscribe\""))
        assertTrue(jsonString.contains("\"session_id\":\"abc123de-4567-89ab-cdef-0123456789ab\""))
        // last_message_id should be null/absent
        assertFalse(jsonString.contains("\"last_message_id\":\""))
    }

    @Test
    fun `SubscribeMessage with lastMessageId requests delta sync`() {
        val message = SubscribeMessage(
            sessionId = "abc123de-4567-89ab-cdef-0123456789ab",
            lastMessageId = "msg-550e8400-e29b-41d4-a716-446655440000"
        )

        val jsonString = json.encodeToString(SubscribeMessage.serializer(), message)

        assertTrue(jsonString.contains("\"type\":\"subscribe\""))
        assertTrue(jsonString.contains("\"session_id\":\"abc123de-4567-89ab-cdef-0123456789ab\""))
        assertTrue(jsonString.contains("\"last_message_id\":\"msg-550e8400-e29b-41d4-a716-446655440000\""))
    }

    @Test
    fun `SubscribeMessage uses snake_case keys`() {
        val message = SubscribeMessage(
            sessionId = "test-session",
            lastMessageId = "test-message-id"
        )

        val jsonString = json.encodeToString(SubscribeMessage.serializer(), message)

        assertTrue(jsonString.contains("session_id"))
        assertTrue(jsonString.contains("last_message_id"))
        assertFalse(jsonString.contains("sessionId"))
        assertFalse(jsonString.contains("lastMessageId"))
    }

    // =========================================================================
    // MARK: - Session History Response Tests
    // =========================================================================

    @Test
    fun `SessionHistoryMessage parses full history response`() {
        val jsonString = """
            {
                "type": "session_history",
                "session_id": "test-session",
                "messages": [
                    {"role": "user", "text": "Hello", "id": "msg-1"},
                    {"role": "assistant", "text": "Hi there!", "id": "msg-2"}
                ],
                "total_count": 2,
                "oldest_message_id": "msg-1",
                "newest_message_id": "msg-2",
                "is_complete": true
            }
        """.trimIndent()

        val message = json.decodeFromString<SessionHistoryMessage>(jsonString)

        assertEquals("session_history", message.type)
        assertEquals("test-session", message.sessionId)
        assertEquals(2, message.messages.size)
        assertEquals(2, message.totalCount)
        assertEquals("msg-1", message.oldestMessageId)
        assertEquals("msg-2", message.newestMessageId)
        assertTrue(message.isComplete)
    }

    @Test
    fun `SessionHistoryMessage parses delta sync response`() {
        // Delta sync returns only messages newer than lastMessageId
        val jsonString = """
            {
                "type": "session_history",
                "session_id": "test-session",
                "messages": [
                    {"role": "assistant", "text": "New message", "id": "msg-5"}
                ],
                "total_count": 5,
                "oldest_message_id": "msg-5",
                "newest_message_id": "msg-5",
                "is_complete": true
            }
        """.trimIndent()

        val message = json.decodeFromString<SessionHistoryMessage>(jsonString)

        // Total count reflects all messages, but only new ones returned
        assertEquals(5, message.totalCount)
        assertEquals(1, message.messages.size)
        assertEquals("New message", message.messages[0].text)
        assertTrue(message.isComplete)
    }

    @Test
    fun `SessionHistoryMessage handles empty delta sync`() {
        // No new messages since lastMessageId
        val jsonString = """
            {
                "type": "session_history",
                "session_id": "test-session",
                "messages": [],
                "total_count": 10,
                "oldest_message_id": null,
                "newest_message_id": null,
                "is_complete": true
            }
        """.trimIndent()

        val message = json.decodeFromString<SessionHistoryMessage>(jsonString)

        assertEquals(10, message.totalCount)
        assertEquals(0, message.messages.size)
        assertNull(message.oldestMessageId)
        assertNull(message.newestMessageId)
        assertTrue(message.isComplete)
    }

    @Test
    fun `SessionHistoryMessage handles truncated response`() {
        // Backend truncates large responses
        val jsonString = """
            {
                "type": "session_history",
                "session_id": "test-session",
                "messages": [
                    {"role": "user", "text": "Hello", "id": "msg-1"}
                ],
                "total_count": 100,
                "oldest_message_id": "msg-1",
                "newest_message_id": "msg-1",
                "is_complete": false
            }
        """.trimIndent()

        val message = json.decodeFromString<SessionHistoryMessage>(jsonString)

        assertEquals(100, message.totalCount)
        assertEquals(1, message.messages.size)
        assertFalse(message.isComplete)
    }

    @Test
    fun `SessionHistoryMessage parses message timestamps`() {
        val jsonString = """
            {
                "type": "session_history",
                "session_id": "test-session",
                "messages": [
                    {
                        "role": "user",
                        "text": "Hello",
                        "id": "msg-1",
                        "timestamp": "2025-01-15T10:30:00.000Z"
                    }
                ],
                "total_count": 1,
                "is_complete": true
            }
        """.trimIndent()

        val message = json.decodeFromString<SessionHistoryMessage>(jsonString)
        val historyMessage = message.messages[0]

        assertEquals("2025-01-15T10:30:00.000Z", historyMessage.timestamp)
        assertEquals("msg-1", historyMessage.id)
    }

    // =========================================================================
    // MARK: - Message ID Tracking Tests
    // =========================================================================

    @Test
    fun `HistoryMessageData extracts message ID`() {
        val jsonString = """
            {
                "role": "assistant",
                "text": "Response text",
                "id": "msg-550e8400-e29b-41d4-a716-446655440000",
                "session_id": "session-123",
                "timestamp": "2025-01-15T10:30:00.000Z"
            }
        """.trimIndent()

        val message = json.decodeFromString<HistoryMessageData>(jsonString)

        assertEquals("msg-550e8400-e29b-41d4-a716-446655440000", message.id)
        assertEquals("assistant", message.role)
        assertEquals("Response text", message.text)
    }

    @Test
    fun `ResponseMessage extracts message ID for acknowledgment`() {
        val jsonString = """
            {
                "type": "response",
                "message_id": "msg-550e8400-e29b-41d4-a716-446655440000",
                "success": true,
                "text": "Response from Claude",
                "session_id": "session-123"
            }
        """.trimIndent()

        val message = json.decodeFromString<ResponseMessage>(jsonString)

        assertEquals("msg-550e8400-e29b-41d4-a716-446655440000", message.messageId)
    }

    @Test
    fun `MessageAckMessage uses correct format`() {
        val message = MessageAckMessage(
            messageId = "msg-550e8400-e29b-41d4-a716-446655440000"
        )

        val jsonString = json.encodeToString(MessageAckMessage.serializer(), message)

        assertTrue(jsonString.contains("\"type\":\"message_ack\""))
        assertTrue(jsonString.contains("\"message_id\":\"msg-550e8400-e29b-41d4-a716-446655440000\""))
    }

    // =========================================================================
    // MARK: - Reconnection Scenario Tests
    // =========================================================================

    @Test
    fun `delta sync with recent messages only fetches new ones`() {
        // Scenario: Client has messages 1-10, reconnects, server has 1-15
        // Client sends lastMessageId = "msg-10"
        // Server returns messages 11-15

        val subscribeMessage = SubscribeMessage(
            sessionId = "session-123",
            lastMessageId = "msg-10"
        )

        val responseJson = """
            {
                "type": "session_history",
                "session_id": "session-123",
                "messages": [
                    {"role": "assistant", "text": "Message 11", "id": "msg-11"},
                    {"role": "user", "text": "Message 12", "id": "msg-12"},
                    {"role": "assistant", "text": "Message 13", "id": "msg-13"},
                    {"role": "user", "text": "Message 14", "id": "msg-14"},
                    {"role": "assistant", "text": "Message 15", "id": "msg-15"}
                ],
                "total_count": 15,
                "oldest_message_id": "msg-11",
                "newest_message_id": "msg-15",
                "is_complete": true
            }
        """.trimIndent()

        val response = json.decodeFromString<SessionHistoryMessage>(responseJson)

        // Verify delta sync returned only new messages
        assertEquals(5, response.messages.size)
        assertEquals(15, response.totalCount)
        assertEquals("msg-11", response.oldestMessageId)
        assertEquals("msg-15", response.newestMessageId)
        assertTrue(response.isComplete)

        // Verify message ordering (oldest first)
        assertEquals("msg-11", response.messages[0].id)
        assertEquals("msg-15", response.messages[4].id)
    }

    @Test
    fun `delta sync handles unknown lastMessageId gracefully`() {
        // If lastMessageId is not found, server returns all messages
        val responseJson = """
            {
                "type": "session_history",
                "session_id": "session-123",
                "messages": [
                    {"role": "user", "text": "Hello", "id": "msg-1"},
                    {"role": "assistant", "text": "Hi", "id": "msg-2"}
                ],
                "total_count": 2,
                "oldest_message_id": "msg-1",
                "newest_message_id": "msg-2",
                "is_complete": true
            }
        """.trimIndent()

        val response = json.decodeFromString<SessionHistoryMessage>(responseJson)

        // All messages returned since lastMessageId wasn't found
        assertEquals(2, response.messages.size)
        assertEquals(2, response.totalCount)
    }

    // =========================================================================
    // MARK: - Replay Message Tests
    // =========================================================================

    @Test
    fun `ReplayMessage parses undelivered message during reconnection`() {
        val jsonString = """
            {
                "type": "replay",
                "message_id": "msg-123",
                "message": {
                    "role": "assistant",
                    "text": "Buffered response",
                    "session_id": "session-456",
                    "timestamp": "2025-01-15T10:30:00.000Z"
                }
            }
        """.trimIndent()

        val message = json.decodeFromString<ReplayMessage>(jsonString)

        assertEquals("replay", message.type)
        assertEquals("msg-123", message.messageId)
        assertEquals("assistant", message.message.role)
        assertEquals("Buffered response", message.message.text)
        assertEquals("session-456", message.message.sessionId)
    }

    @Test
    fun `ReplayMessage requires acknowledgment`() {
        // When receiving a replay message, client must send message_ack
        val replayJson = """
            {
                "type": "replay",
                "message_id": "msg-to-ack",
                "message": {
                    "role": "assistant",
                    "text": "Message requiring ack"
                }
            }
        """.trimIndent()

        val replay = json.decodeFromString<ReplayMessage>(replayJson)
        val ack = MessageAckMessage(messageId = replay.messageId)

        val ackJson = json.encodeToString(MessageAckMessage.serializer(), ack)

        assertTrue(ackJson.contains("\"message_id\":\"msg-to-ack\""))
    }

    // =========================================================================
    // MARK: - Session ID Normalization Tests
    // =========================================================================

    @Test
    fun `session IDs are always lowercase in subscribe`() {
        val upperCaseSessionId = "ABC123DE-4567-89AB-CDEF-0123456789AB"
        val message = SubscribeMessage(
            sessionId = upperCaseSessionId.lowercase()
        )

        val jsonString = json.encodeToString(SubscribeMessage.serializer(), message)

        assertTrue(jsonString.contains("abc123de-4567-89ab-cdef-0123456789ab"))
        assertFalse(jsonString.contains("ABC"))
    }

    @Test
    fun `message IDs preserve case from server`() {
        // Message IDs from server should be used as-is
        val jsonString = """
            {
                "type": "response",
                "message_id": "MSG-UpperCase-ID",
                "success": true,
                "text": "Test"
            }
        """.trimIndent()

        val message = json.decodeFromString<ResponseMessage>(jsonString)

        assertEquals("MSG-UpperCase-ID", message.messageId)
    }
}
