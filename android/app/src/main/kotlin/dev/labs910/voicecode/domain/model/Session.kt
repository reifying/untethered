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

    /** Whether this session is currently locked (processing a prompt) */
    val isLocked: Boolean = false,

    // ==========================================================================
    // MARK: - FIFO Queue Fields
    // ==========================================================================

    /** Whether this session is in the FIFO queue */
    val isInQueue: Boolean = false,

    /** Position in FIFO queue (0-indexed) */
    val queuePosition: Int = 0,

    /** Timestamp when the session was added to the FIFO queue */
    val queuedAt: Instant? = null,

    // ==========================================================================
    // MARK: - Priority Queue Fields
    // ==========================================================================

    /** Whether this session is in the priority queue */
    val isInPriorityQueue: Boolean = false,

    /** Priority level: 1 (High), 5 (Medium), 10 (Low). Lower = higher priority */
    val priority: Int = 10,

    /** Order within the priority level for drag-and-drop reordering */
    val priorityOrder: Double = 0.0,

    /** Timestamp when the session was added to the priority queue */
    val priorityQueuedAt: Instant? = null
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
