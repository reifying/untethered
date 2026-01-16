package dev.labs910.voicecode.domain.model

import java.time.Instant
import java.util.UUID

/**
 * Domain model for a Claude session.
 * Corresponds to iOS CDBackendSession + CDUserSession models.
 *
 * IMPORTANT: Session IDs must be lowercase UUIDs as per STANDARDS.md.
 */
data class Session(
    /** Locally generated UUID, always lowercase */
    val id: String = UUID.randomUUID().toString().lowercase(),

    /** Claude session ID from backend (also lowercase UUID) */
    val backendSessionId: String? = null,

    /** Display name for the session */
    val name: String? = null,

    /** Working directory for this session */
    val workingDirectory: String? = null,

    /** Last modification timestamp */
    val lastModified: Instant = Instant.now(),

    /** Number of messages in this session */
    val messageCount: Int = 0,

    /** Preview text (first line or summary) */
    val preview: String? = null,

    /** Number of unread messages */
    val unreadCount: Int = 0,

    /** Whether user has soft-deleted this session */
    val isUserDeleted: Boolean = false,

    /** Custom name set by user */
    val customName: String? = null,

    /** Queue position if using priority queue */
    val queuePosition: Int? = null,

    /** Whether this session is currently locked (processing a prompt) */
    val isLocked: Boolean = false
) {
    /**
     * Display name for the session.
     * Priority: customName > name > working directory basename > session ID prefix
     */
    val displayName: String
        get() = customName
            ?: name
            ?: workingDirectory?.substringAfterLast('/')
            ?: id.take(8)

    /**
     * Returns the session ID in the format expected by the backend.
     * Always lowercase as per STANDARDS.md.
     */
    val backendName: String
        get() = id.lowercase()
}

/**
 * Session creation parameters.
 */
data class CreateSessionParams(
    val workingDirectory: String? = null,
    val name: String? = null
)
