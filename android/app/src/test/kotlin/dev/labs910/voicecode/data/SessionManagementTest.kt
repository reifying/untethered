package dev.labs910.voicecode.data

import dev.labs910.voicecode.data.model.*
import dev.labs910.voicecode.domain.model.Session
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.time.Instant

/**
 * Tests for session management functionality.
 * Mirrors iOS session management tests (SessionDeletionTests, SessionGroupingTests, etc.).
 */
class SessionManagementTest {

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
    // MARK: - Session Creation Tests
    // =========================================================================

    @Test
    fun `Session has lowercase UUID by default`() {
        val session = Session()

        assertEquals(session.id, session.id.lowercase())
        assertEquals(36, session.id.length) // UUID format
    }

    @Test
    fun `Session backendName returns lowercase ID`() {
        val session = Session(id = "ABC123DE-4567-89AB-CDEF-0123456789AB")

        assertEquals("abc123de-4567-89ab-cdef-0123456789ab", session.backendName)
    }

    @Test
    fun `new Session has sensible defaults`() {
        val session = Session()

        assertNull(session.backendSessionId)
        assertNull(session.name)
        assertNull(session.workingDirectory)
        assertEquals(0, session.messageCount)
        assertNull(session.preview)
        assertEquals(0, session.unreadCount)
        assertFalse(session.isUserDeleted)
        assertNull(session.customName)
        assertFalse(session.isLocked)
        assertFalse(session.isInQueue)
        assertFalse(session.isInPriorityQueue)
    }

    // =========================================================================
    // MARK: - Display Name Priority Tests
    // =========================================================================

    @Test
    fun `displayName prefers customName over all`() {
        val session = Session(
            customName = "My Custom Name",
            name = "Backend Name",
            workingDirectory = "/Users/test/project"
        )

        assertEquals("My Custom Name", session.displayName)
    }

    @Test
    fun `displayName uses name when customName is null`() {
        val session = Session(
            customName = null,
            name = "Backend Name",
            workingDirectory = "/Users/test/project"
        )

        assertEquals("Backend Name", session.displayName)
    }

    @Test
    fun `displayName uses directory basename when name is null`() {
        val session = Session(
            customName = null,
            name = null,
            workingDirectory = "/Users/test/my-project"
        )

        assertEquals("my-project", session.displayName)
    }

    @Test
    fun `displayName uses ID prefix as fallback`() {
        val session = Session(
            id = "abc123de-4567-89ab-cdef-0123456789ab",
            customName = null,
            name = null,
            workingDirectory = null
        )

        assertEquals("abc123de", session.displayName)
    }

    // =========================================================================
    // MARK: - Session List Parsing Tests
    // =========================================================================

    @Test
    fun `SessionListMessage parses session array`() {
        val jsonString = """
            {
                "type": "session_list",
                "sessions": [
                    {
                        "session_id": "session-1",
                        "name": "Project A",
                        "working_directory": "/path/to/project-a",
                        "last_modified": "2025-01-15T10:30:00.000Z"
                    },
                    {
                        "session_id": "session-2",
                        "name": "Project B",
                        "working_directory": "/path/to/project-b",
                        "last_modified": "2025-01-14T09:00:00.000Z"
                    }
                ]
            }
        """.trimIndent()

        val message = json.decodeFromString<SessionListMessage>(jsonString)

        assertEquals("session_list", message.type)
        assertEquals(2, message.sessions.size)
        assertEquals("session-1", message.sessions[0].sessionId)
        assertEquals("Project A", message.sessions[0].name)
        assertEquals("/path/to/project-a", message.sessions[0].workingDirectory)
    }

    @Test
    fun `RecentSessionsMessage parses with limit`() {
        val jsonString = """
            {
                "type": "recent_sessions",
                "sessions": [
                    {
                        "session_id": "recent-1",
                        "name": "Recent Session",
                        "working_directory": "/path/to/recent"
                    }
                ],
                "limit": 10
            }
        """.trimIndent()

        val message = json.decodeFromString<RecentSessionsMessage>(jsonString)

        assertEquals("recent_sessions", message.type)
        assertEquals(1, message.sessions.size)
        assertEquals(10, message.limit)
    }

    @Test
    fun `SessionMetadata handles optional fields`() {
        val jsonString = """
            {
                "session_id": "minimal-session"
            }
        """.trimIndent()

        val metadata = json.decodeFromString<SessionMetadata>(jsonString)

        assertEquals("minimal-session", metadata.sessionId)
        assertNull(metadata.name)
        assertNull(metadata.workingDirectory)
        assertNull(metadata.lastModified)
    }

    // =========================================================================
    // MARK: - Session Grouping Tests
    // =========================================================================

    @Test
    fun `sessions can be grouped by working directory`() {
        val sessions = listOf(
            Session(id = "1", workingDirectory = "/project-a"),
            Session(id = "2", workingDirectory = "/project-a"),
            Session(id = "3", workingDirectory = "/project-b"),
            Session(id = "4", workingDirectory = null)
        )

        val grouped = sessions.groupBy { it.workingDirectory ?: "No Directory" }

        assertEquals(3, grouped.size)
        assertEquals(2, grouped["/project-a"]?.size)
        assertEquals(1, grouped["/project-b"]?.size)
        assertEquals(1, grouped["No Directory"]?.size)
    }

    @Test
    fun `sessions sorted by lastModified descending`() {
        val now = Instant.now()
        val sessions = listOf(
            Session(id = "1", lastModified = now.minusSeconds(100)),
            Session(id = "2", lastModified = now.minusSeconds(50)),
            Session(id = "3", lastModified = now)
        )

        val sorted = sessions.sortedByDescending { it.lastModified }

        assertEquals("3", sorted[0].id)
        assertEquals("2", sorted[1].id)
        assertEquals("1", sorted[2].id)
    }

    // =========================================================================
    // MARK: - Session Deletion Tests
    // =========================================================================

    @Test
    fun `soft delete marks session as deleted`() {
        val original = Session(id = "to-delete", isUserDeleted = false)
        val deleted = original.copy(isUserDeleted = true)

        assertFalse(original.isUserDeleted)
        assertTrue(deleted.isUserDeleted)
    }

    @Test
    fun `deleted sessions filtered from list`() {
        val sessions = listOf(
            Session(id = "1", isUserDeleted = false),
            Session(id = "2", isUserDeleted = true),
            Session(id = "3", isUserDeleted = false)
        )

        val visible = sessions.filter { !it.isUserDeleted }

        assertEquals(2, visible.size)
        assertFalse(visible.any { it.id == "2" })
    }

    // =========================================================================
    // MARK: - Session Renaming Tests
    // =========================================================================

    @Test
    fun `custom name can be set on session`() {
        val original = Session(id = "rename-me", name = "Original")
        val renamed = original.copy(customName = "My Custom Name")

        assertEquals("My Custom Name", renamed.displayName)
    }

    @Test
    fun `custom name can be cleared`() {
        val withCustom = Session(
            id = "test",
            name = "Backend Name",
            customName = "Custom"
        )
        val cleared = withCustom.copy(customName = null)

        assertEquals("Backend Name", cleared.displayName)
    }

    // =========================================================================
    // MARK: - Session Locking Tests
    // =========================================================================

    @Test
    fun `session can be locked and unlocked`() {
        val unlocked = Session(id = "lockable", isLocked = false)
        val locked = unlocked.copy(isLocked = true)
        val unlockedAgain = locked.copy(isLocked = false)

        assertFalse(unlocked.isLocked)
        assertTrue(locked.isLocked)
        assertFalse(unlockedAgain.isLocked)
    }

    @Test
    fun `SessionLockedMessage parses correctly`() {
        val jsonString = """
            {
                "type": "session_locked",
                "message": "Session is currently processing a prompt",
                "session_id": "locked-session-123"
            }
        """.trimIndent()

        val message = json.decodeFromString<SessionLockedMessage>(jsonString)

        assertEquals("session_locked", message.type)
        assertEquals("locked-session-123", message.sessionId)
    }

    @Test
    fun `TurnCompleteMessage signals unlock`() {
        val jsonString = """
            {
                "type": "turn_complete",
                "session_id": "completed-session-123"
            }
        """.trimIndent()

        val message = json.decodeFromString<TurnCompleteMessage>(jsonString)

        assertEquals("turn_complete", message.type)
        assertEquals("completed-session-123", message.sessionId)
    }

    // =========================================================================
    // MARK: - FIFO Queue Tests
    // =========================================================================

    @Test
    fun `session can be added to FIFO queue`() {
        val now = Instant.now()
        val session = Session(id = "queue-me")
        val queued = session.copy(
            isInQueue = true,
            queuePosition = 0,
            queuedAt = now
        )

        assertTrue(queued.isInQueue)
        assertEquals(0, queued.queuePosition)
        assertEquals(now, queued.queuedAt)
    }

    @Test
    fun `FIFO queue sessions sorted by position`() {
        val sessions = listOf(
            Session(id = "3", isInQueue = true, queuePosition = 2),
            Session(id = "1", isInQueue = true, queuePosition = 0),
            Session(id = "2", isInQueue = true, queuePosition = 1)
        )

        val sorted = sessions.sortedBy { it.queuePosition }

        assertEquals("1", sorted[0].id)
        assertEquals("2", sorted[1].id)
        assertEquals("3", sorted[2].id)
    }

    @Test
    fun `removing from queue clears queue fields`() {
        val queued = Session(
            id = "queued",
            isInQueue = true,
            queuePosition = 5,
            queuedAt = Instant.now()
        )
        val removed = queued.copy(
            isInQueue = false,
            queuePosition = 0,
            queuedAt = null
        )

        assertFalse(removed.isInQueue)
        assertEquals(0, removed.queuePosition)
        assertNull(removed.queuedAt)
    }

    // =========================================================================
    // MARK: - Priority Queue Tests
    // =========================================================================

    @Test
    fun `session can be added to priority queue`() {
        val now = Instant.now()
        val session = Session(id = "prioritize-me")
        val prioritized = session.copy(
            isInPriorityQueue = true,
            priority = 1, // High priority
            priorityOrder = 100.0,
            priorityQueuedAt = now
        )

        assertTrue(prioritized.isInPriorityQueue)
        assertEquals(1, prioritized.priority)
        assertEquals(100.0, prioritized.priorityOrder, 0.001)
        assertEquals(now, prioritized.priorityQueuedAt)
    }

    @Test
    fun `priority queue sorted by priority then order`() {
        val sessions = listOf(
            Session(id = "low", isInPriorityQueue = true, priority = 10, priorityOrder = 1.0),
            Session(id = "high-2", isInPriorityQueue = true, priority = 1, priorityOrder = 2.0),
            Session(id = "high-1", isInPriorityQueue = true, priority = 1, priorityOrder = 1.0),
            Session(id = "medium", isInPriorityQueue = true, priority = 5, priorityOrder = 1.0)
        )

        val sorted = sessions.sortedWith(compareBy({ it.priority }, { it.priorityOrder }))

        assertEquals("high-1", sorted[0].id) // Priority 1, order 1.0
        assertEquals("high-2", sorted[1].id) // Priority 1, order 2.0
        assertEquals("medium", sorted[2].id) // Priority 5
        assertEquals("low", sorted[3].id)    // Priority 10
    }

    @Test
    fun `priority levels have correct values`() {
        // Per STANDARDS.md: 1 = High, 5 = Medium, 10 = Low
        val high = Session(priority = 1)
        val medium = Session(priority = 5)
        val low = Session(priority = 10)

        assertTrue(high.priority < medium.priority)
        assertTrue(medium.priority < low.priority)
    }

    // =========================================================================
    // MARK: - Session Compaction Tests
    // =========================================================================

    @Test
    fun `CompactSessionMessage uses lowercase session_id`() {
        val message = CompactSessionMessage(
            sessionId = "abc123de-4567-89ab-cdef-0123456789ab"
        )

        val jsonString = json.encodeToString(CompactSessionMessage.serializer(), message)

        assertTrue(jsonString.contains("\"type\":\"compact_session\""))
        assertTrue(jsonString.contains("\"session_id\":\"abc123de-4567-89ab-cdef-0123456789ab\""))
    }

    @Test
    fun `CompactionCompleteMessage parses successfully`() {
        val jsonString = """
            {
                "type": "compaction_complete",
                "session_id": "compacted-session"
            }
        """.trimIndent()

        val message = json.decodeFromString<CompactionCompleteMessage>(jsonString)

        assertEquals("compaction_complete", message.type)
        assertEquals("compacted-session", message.sessionId)
    }

    @Test
    fun `CompactionErrorMessage includes error details`() {
        val jsonString = """
            {
                "type": "compaction_error",
                "session_id": "failed-session",
                "error": "Session not found"
            }
        """.trimIndent()

        val message = json.decodeFromString<CompactionErrorMessage>(jsonString)

        assertEquals("compaction_error", message.type)
        assertEquals("failed-session", message.sessionId)
        assertEquals("Session not found", message.error)
    }

    // =========================================================================
    // MARK: - RefreshSessions Tests
    // =========================================================================

    @Test
    fun `RefreshSessionsMessage serializes correctly`() {
        val message = RefreshSessionsMessage(recentSessionsLimit = 10)

        val jsonString = json.encodeToString(RefreshSessionsMessage.serializer(), message)

        assertTrue(jsonString.contains("\"type\":\"refresh_sessions\""))
        assertTrue(jsonString.contains("\"recent_sessions_limit\":10"))
    }

    @Test
    fun `RefreshSessionsMessage works without limit`() {
        val message = RefreshSessionsMessage(recentSessionsLimit = null)

        val jsonString = json.encodeToString(RefreshSessionsMessage.serializer(), message)

        assertTrue(jsonString.contains("\"type\":\"refresh_sessions\""))
        // recent_sessions_limit should be null or absent
    }
}
