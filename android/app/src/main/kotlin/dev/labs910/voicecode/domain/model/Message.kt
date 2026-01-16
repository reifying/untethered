package dev.labs910.voicecode.domain.model

import java.time.Instant
import java.util.UUID

/**
 * Domain model for a conversation message.
 * Corresponds to iOS Message.swift model.
 */
data class Message(
    val id: String = UUID.randomUUID().toString().lowercase(),
    val sessionId: String,
    val role: MessageRole,
    val text: String,
    val timestamp: Instant = Instant.now(),
    val status: MessageStatus = MessageStatus.CONFIRMED,
    val usage: MessageUsage? = null,
    val cost: MessageCost? = null
) {
    /**
     * Truncated display text for list views.
     * Matches iOS behavior: first 250 + last 250 chars with middle marker.
     */
    fun displayText(maxLength: Int = 500): String {
        return if (text.length <= maxLength) {
            text
        } else {
            val halfLength = maxLength / 2
            val start = text.take(halfLength)
            val end = text.takeLast(halfLength)
            val truncatedCount = text.length - maxLength
            "$start\n\n... [$truncatedCount characters truncated] ...\n\n$end"
        }
    }
}

/**
 * Message sender role.
 */
enum class MessageRole {
    USER,
    ASSISTANT,
    SYSTEM;

    companion object {
        fun fromString(value: String): MessageRole = when (value.lowercase()) {
            "user" -> USER
            "assistant" -> ASSISTANT
            "system" -> SYSTEM
            else -> USER
        }
    }

    override fun toString(): String = name.lowercase()
}

/**
 * Message delivery status.
 */
enum class MessageStatus {
    SENDING,
    CONFIRMED,
    ERROR
}

/**
 * Token usage statistics for a message.
 * Includes cache token fields for Claude's Prompt Caching feature.
 */
data class MessageUsage(
    val inputTokens: Int,
    val outputTokens: Int,
    val cacheReadTokens: Int? = null,
    val cacheWriteTokens: Int? = null
) {
    val totalTokens: Int get() = inputTokens + outputTokens

    /** Total cache tokens (read + write) */
    val totalCacheTokens: Int get() = (cacheReadTokens ?: 0) + (cacheWriteTokens ?: 0)

    /** Whether this message used cached tokens */
    val usedCache: Boolean get() = (cacheReadTokens ?: 0) > 0
}

/**
 * Cost breakdown for a message.
 */
data class MessageCost(
    val inputCost: Double,
    val outputCost: Double,
    val totalCost: Double
)
