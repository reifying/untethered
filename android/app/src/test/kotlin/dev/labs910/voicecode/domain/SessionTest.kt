package dev.labs910.voicecode.domain

import dev.labs910.voicecode.domain.model.*
import org.junit.Assert.*
import org.junit.Test

/**
 * Tests for Session domain model.
 * Verifies UUID lowercase requirement per STANDARDS.md.
 */
class SessionTest {

    @Test
    fun `Session id is lowercase UUID`() {
        val session = Session()

        assertEquals(session.id, session.id.lowercase())
        assertEquals(36, session.id.length) // UUID format
    }

    @Test
    fun `backendName returns lowercase id`() {
        val session = Session(id = "ABC123DE-4567-89AB-CDEF-0123456789AB")

        assertEquals("abc123de-4567-89ab-cdef-0123456789ab", session.backendName)
    }

    @Test
    fun `displayName priority - customName first`() {
        val session = Session(
            customName = "My Custom Name",
            name = "Auto Name",
            workingDirectory = "/Users/test/project"
        )

        assertEquals("My Custom Name", session.displayName)
    }

    @Test
    fun `displayName priority - name second`() {
        val session = Session(
            customName = null,
            name = "Auto Name",
            workingDirectory = "/Users/test/project"
        )

        assertEquals("Auto Name", session.displayName)
    }

    @Test
    fun `displayName priority - workingDirectory basename third`() {
        val session = Session(
            customName = null,
            name = null,
            workingDirectory = "/Users/test/project"
        )

        assertEquals("project", session.displayName)
    }

    @Test
    fun `displayName priority - id prefix fallback`() {
        val session = Session(
            id = "abc123de-4567-89ab-cdef-0123456789ab",
            customName = null,
            name = null,
            workingDirectory = null
        )

        assertEquals("abc123de", session.displayName)
    }

    @Test
    fun `Session defaults are correct`() {
        val session = Session()

        assertEquals(0, session.messageCount)
        assertEquals(0, session.unreadCount)
        assertFalse(session.isUserDeleted)
        assertFalse(session.isLocked)
        assertNull(session.backendSessionId)
        // Priority queue defaults
        assertFalse(session.isInPriorityQueue)
        assertEquals(10, session.priority) // Default to Low
        assertEquals(0.0, session.priorityOrder, 0.001)
        assertNull(session.priorityQueuedAt)
    }

    @Test
    fun `CreateSessionParams holds optional values`() {
        val params = CreateSessionParams(
            workingDirectory = "/Users/test/project",
            name = "Test Session"
        )

        assertEquals("/Users/test/project", params.workingDirectory)
        assertEquals("Test Session", params.name)
    }

    @Test
    fun `CreateSessionParams allows null values`() {
        val params = CreateSessionParams()

        assertNull(params.workingDirectory)
        assertNull(params.name)
    }

    // ==========================================================================
    // MARK: - Priority Queue Tests
    // ==========================================================================

    @Test
    fun `Session can be added to priority queue`() {
        val now = java.time.Instant.now()
        val session = Session(
            isInPriorityQueue = true,
            priority = 5, // Medium
            priorityOrder = 1.0,
            priorityQueuedAt = now
        )

        assertTrue(session.isInPriorityQueue)
        assertEquals(5, session.priority)
        assertEquals(1.0, session.priorityOrder, 0.001)
        assertEquals(now, session.priorityQueuedAt)
    }

    @Test
    fun `Priority levels are High=1, Medium=5, Low=10`() {
        val highPriority = Session(priority = 1)
        val mediumPriority = Session(priority = 5)
        val lowPriority = Session(priority = 10)

        // Lower number = higher priority
        assertTrue(highPriority.priority < mediumPriority.priority)
        assertTrue(mediumPriority.priority < lowPriority.priority)
    }

    @Test
    fun `Priority order allows for decimal positioning`() {
        // Used for drag-and-drop reordering within a priority level
        val session1 = Session(priority = 5, priorityOrder = 1.0)
        val session2 = Session(priority = 5, priorityOrder = 1.5) // Inserted between 1 and 2
        val session3 = Session(priority = 5, priorityOrder = 2.0)

        assertTrue(session1.priorityOrder < session2.priorityOrder)
        assertTrue(session2.priorityOrder < session3.priorityOrder)
    }

    @Test
    fun `Session not in queue has default priority values`() {
        val session = Session(isInPriorityQueue = false)

        assertFalse(session.isInPriorityQueue)
        assertEquals(10, session.priority) // Default Low
        assertEquals(0.0, session.priorityOrder, 0.001)
        assertNull(session.priorityQueuedAt)
    }

    @Test
    fun `Session copy preserves priority queue fields`() {
        val now = java.time.Instant.now()
        val original = Session(
            isInPriorityQueue = true,
            priority = 1,
            priorityOrder = 5.5,
            priorityQueuedAt = now
        )

        val copy = original.copy(name = "Updated Name")

        assertEquals(original.isInPriorityQueue, copy.isInPriorityQueue)
        assertEquals(original.priority, copy.priority)
        assertEquals(original.priorityOrder, copy.priorityOrder, 0.001)
        assertEquals(original.priorityQueuedAt, copy.priorityQueuedAt)
        assertEquals("Updated Name", copy.name)
    }
}
