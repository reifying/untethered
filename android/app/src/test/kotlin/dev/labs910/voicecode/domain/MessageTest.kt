package dev.labs910.voicecode.domain

import dev.labs910.voicecode.domain.model.*
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

/**
 * Tests for Message domain model.
 */
class MessageTest {

    @Test
    fun `Message id is lowercase UUID`() {
        val message = Message(
            sessionId = "session-123",
            role = MessageRole.USER,
            text = "Hello"
        )

        assertEquals(message.id, message.id.lowercase())
        assertEquals(36, message.id.length) // UUID format
    }

    @Test
    fun `displayText returns full text when under limit`() {
        val shortText = "This is a short message."
        val message = Message(
            sessionId = "session-123",
            role = MessageRole.USER,
            text = shortText
        )

        assertEquals(shortText, message.displayText())
    }

    @Test
    fun `displayText truncates long text with middle marker`() {
        val longText = "A".repeat(1000)
        val message = Message(
            sessionId = "session-123",
            role = MessageRole.USER,
            text = longText
        )

        val displayed = message.displayText(maxLength = 500)

        assertTrue(displayed.contains("... [500 characters truncated] ..."))
        assertTrue(displayed.startsWith("A".repeat(250)))
        assertTrue(displayed.endsWith("A".repeat(250)))
    }

    @Test
    fun `displayText respects custom maxLength`() {
        val text = "A".repeat(200)
        val message = Message(
            sessionId = "session-123",
            role = MessageRole.USER,
            text = text
        )

        val displayedDefault = message.displayText()
        val displayedCustom = message.displayText(maxLength = 100)

        assertEquals(text, displayedDefault) // 200 < 500 default
        assertTrue(displayedCustom.contains("[100 characters truncated]"))
    }

    @Test
    fun `MessageRole fromString handles all cases`() {
        assertEquals(MessageRole.USER, MessageRole.fromString("user"))
        assertEquals(MessageRole.USER, MessageRole.fromString("USER"))
        assertEquals(MessageRole.USER, MessageRole.fromString("User"))
        assertEquals(MessageRole.ASSISTANT, MessageRole.fromString("assistant"))
        assertEquals(MessageRole.ASSISTANT, MessageRole.fromString("ASSISTANT"))
        assertEquals(MessageRole.SYSTEM, MessageRole.fromString("system"))
        assertEquals(MessageRole.USER, MessageRole.fromString("unknown")) // Default
    }

    @Test
    fun `MessageRole toString returns lowercase`() {
        assertEquals("user", MessageRole.USER.toString())
        assertEquals("assistant", MessageRole.ASSISTANT.toString())
        assertEquals("system", MessageRole.SYSTEM.toString())
    }

    @Test
    fun `MessageUsage calculates total tokens`() {
        val usage = MessageUsage(inputTokens = 100, outputTokens = 50)
        assertEquals(150, usage.totalTokens)
    }

    @Test
    fun `Message status defaults to CONFIRMED`() {
        val message = Message(
            sessionId = "session-123",
            role = MessageRole.USER,
            text = "Hello"
        )

        assertEquals(MessageStatus.CONFIRMED, message.status)
    }

    @Test
    fun `Message timestamp defaults to now`() {
        val before = Instant.now()
        val message = Message(
            sessionId = "session-123",
            role = MessageRole.USER,
            text = "Hello"
        )
        val after = Instant.now()

        assertTrue(message.timestamp >= before)
        assertTrue(message.timestamp <= after)
    }
}
