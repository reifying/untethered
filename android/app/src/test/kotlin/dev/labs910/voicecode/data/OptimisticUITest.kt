package dev.labs910.voicecode.data

import dev.labs910.voicecode.domain.model.*
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.util.UUID

/**
 * Tests for optimistic UI pattern.
 * Mirrors iOS OptimisticUITests.swift.
 *
 * Optimistic UI allows immediate feedback to users:
 * - User sends prompt → message appears instantly with SENDING status
 * - Backend confirms → status changes to CONFIRMED
 * - Backend error → status changes to ERROR
 */
class OptimisticUITest {

    // =========================================================================
    // MARK: - Optimistic Message Creation Tests
    // =========================================================================

    @Test
    fun `create optimistic user message`() {
        val sessionId = UUID.randomUUID().toString().lowercase()
        val promptText = "Test prompt"

        val message = createOptimisticMessage(sessionId, promptText)

        assertEquals(sessionId, message.sessionId)
        assertEquals(MessageRole.USER, message.role)
        assertEquals(promptText, message.text)
        assertEquals(MessageStatus.SENDING, message.status)
        assertNull(message.usage)
        assertNull(message.cost)
    }

    @Test
    fun `optimistic message has unique ID`() {
        val sessionId = UUID.randomUUID().toString().lowercase()

        val message1 = createOptimisticMessage(sessionId, "First")
        val message2 = createOptimisticMessage(sessionId, "Second")

        assertNotEquals(message1.id, message2.id)
    }

    @Test
    fun `optimistic message has current timestamp`() {
        val before = Instant.now()
        val message = createOptimisticMessage("session-123", "Test")
        val after = Instant.now()

        assertTrue(message.timestamp >= before)
        assertTrue(message.timestamp <= after)
    }

    // =========================================================================
    // MARK: - Message Status Transition Tests
    // =========================================================================

    @Test
    fun `message status transitions from SENDING to CONFIRMED`() {
        val message = createOptimisticMessage("session-123", "Test prompt")
        assertEquals(MessageStatus.SENDING, message.status)

        val confirmedMessage = message.copy(status = MessageStatus.CONFIRMED)

        assertEquals(MessageStatus.CONFIRMED, confirmedMessage.status)
    }

    @Test
    fun `message status transitions from SENDING to ERROR`() {
        val message = createOptimisticMessage("session-123", "Test prompt")
        assertEquals(MessageStatus.SENDING, message.status)

        val errorMessage = message.copy(status = MessageStatus.ERROR)

        assertEquals(MessageStatus.ERROR, errorMessage.status)
    }

    @Test
    fun `message preserves other fields during status transition`() {
        val message = createOptimisticMessage("session-123", "Test prompt")
        val originalId = message.id
        val originalText = message.text
        val originalTimestamp = message.timestamp

        val confirmedMessage = message.copy(status = MessageStatus.CONFIRMED)

        assertEquals(originalId, confirmedMessage.id)
        assertEquals(originalText, confirmedMessage.text)
        assertEquals(originalTimestamp, confirmedMessage.timestamp)
    }

    // =========================================================================
    // MARK: - Session Update Tests
    // =========================================================================

    @Test
    fun `session messageCount increments with optimistic message`() {
        val session = Session(messageCount = 5)

        val updatedSession = session.copy(messageCount = session.messageCount + 1)

        assertEquals(6, updatedSession.messageCount)
    }

    @Test
    fun `session preview updates with optimistic message`() {
        val session = Session(preview = "Old message")
        val newPrompt = "New prompt text"

        val updatedSession = session.copy(preview = newPrompt)

        assertEquals(newPrompt, updatedSession.preview)
    }

    @Test
    fun `session lastModified updates with optimistic message`() {
        val oldTime = Instant.now().minusSeconds(3600)
        val session = Session(lastModified = oldTime)

        val newTime = Instant.now()
        val updatedSession = session.copy(lastModified = newTime)

        assertTrue(updatedSession.lastModified > session.lastModified)
    }

    // =========================================================================
    // MARK: - Reconciliation Tests
    // =========================================================================

    @Test
    fun `backend response updates optimistic message`() {
        // Create optimistic message
        val optimistic = createOptimisticMessage("session-123", "Test")
        assertEquals(MessageStatus.SENDING, optimistic.status)

        // Simulate backend confirmation with usage data
        val usage = MessageUsage(inputTokens = 100, outputTokens = 50)
        val cost = MessageCost(inputCost = 0.01, outputCost = 0.02, totalCost = 0.03)

        val confirmed = optimistic.copy(
            status = MessageStatus.CONFIRMED,
            usage = usage,
            cost = cost
        )

        assertEquals(MessageStatus.CONFIRMED, confirmed.status)
        assertNotNull(confirmed.usage)
        assertNotNull(confirmed.cost)
        assertEquals(100, confirmed.usage?.inputTokens)
    }

    @Test
    fun `backend error updates optimistic message status`() {
        val optimistic = createOptimisticMessage("session-123", "Test")

        // Simulate backend error
        val failed = optimistic.copy(status = MessageStatus.ERROR)

        assertEquals(MessageStatus.ERROR, failed.status)
    }

    @Test
    fun `multiple optimistic messages can coexist`() {
        val sessionId = "session-123"
        val messages = mutableListOf<Message>()

        // Send multiple prompts rapidly (before any are confirmed)
        repeat(3) { i ->
            messages.add(createOptimisticMessage(sessionId, "Prompt $i"))
        }

        // All should be in SENDING status
        assertTrue(messages.all { it.status == MessageStatus.SENDING })

        // All should have unique IDs
        val ids = messages.map { it.id }.toSet()
        assertEquals(3, ids.size)
    }

    // =========================================================================
    // MARK: - Message List Ordering Tests
    // =========================================================================

    @Test
    fun `messages sorted by timestamp ascending`() {
        val now = Instant.now()
        val messages = listOf(
            Message(
                sessionId = "session-123",
                role = MessageRole.USER,
                text = "Third",
                timestamp = now
            ),
            Message(
                sessionId = "session-123",
                role = MessageRole.USER,
                text = "First",
                timestamp = now.minusSeconds(100)
            ),
            Message(
                sessionId = "session-123",
                role = MessageRole.USER,
                text = "Second",
                timestamp = now.minusSeconds(50)
            )
        )

        val sorted = messages.sortedBy { it.timestamp }

        assertEquals("First", sorted[0].text)
        assertEquals("Second", sorted[1].text)
        assertEquals("Third", sorted[2].text)
    }

    @Test
    fun `optimistic message appears at end of sorted list`() {
        val now = Instant.now()
        val existingMessages = listOf(
            Message(
                sessionId = "session-123",
                role = MessageRole.USER,
                text = "Old message",
                timestamp = now.minusSeconds(60),
                status = MessageStatus.CONFIRMED
            ),
            Message(
                sessionId = "session-123",
                role = MessageRole.ASSISTANT,
                text = "Response",
                timestamp = now.minusSeconds(30),
                status = MessageStatus.CONFIRMED
            )
        )

        val optimistic = createOptimisticMessage("session-123", "New prompt")
        val allMessages = (existingMessages + optimistic).sortedBy { it.timestamp }

        assertEquals(optimistic.id, allMessages.last().id)
        assertEquals(MessageStatus.SENDING, allMessages.last().status)
    }

    // =========================================================================
    // MARK: - Error Handling Tests
    // =========================================================================

    @Test
    fun `failed message can be retried`() {
        val originalMessage = createOptimisticMessage("session-123", "Original text")
        val failedMessage = originalMessage.copy(status = MessageStatus.ERROR)

        // Retry by creating new optimistic message with same text
        val retryMessage = createOptimisticMessage(failedMessage.sessionId, failedMessage.text)

        assertEquals(MessageStatus.SENDING, retryMessage.status)
        assertEquals(failedMessage.text, retryMessage.text)
        assertNotEquals(failedMessage.id, retryMessage.id) // New message ID for retry
    }

    @Test
    fun `failed messages filtered from active messages`() {
        val messages = listOf(
            Message(
                sessionId = "session-123",
                role = MessageRole.USER,
                text = "Success",
                status = MessageStatus.CONFIRMED
            ),
            Message(
                sessionId = "session-123",
                role = MessageRole.USER,
                text = "Failed",
                status = MessageStatus.ERROR
            ),
            Message(
                sessionId = "session-123",
                role = MessageRole.USER,
                text = "Pending",
                status = MessageStatus.SENDING
            )
        )

        // Filter to show only confirmed and sending (not errors)
        val activeMessages = messages.filter { it.status != MessageStatus.ERROR }

        assertEquals(2, activeMessages.size)
        assertFalse(activeMessages.any { it.text == "Failed" })
    }

    // =========================================================================
    // MARK: - Helper Functions
    // =========================================================================

    /**
     * Creates an optimistic message for immediate UI display.
     * The message starts in SENDING status and will be confirmed by backend.
     */
    private fun createOptimisticMessage(sessionId: String, text: String): Message {
        return Message(
            id = UUID.randomUUID().toString().lowercase(),
            sessionId = sessionId,
            role = MessageRole.USER,
            text = text,
            timestamp = Instant.now(),
            status = MessageStatus.SENDING,
            usage = null,
            cost = null
        )
    }
}
