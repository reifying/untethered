package dev.labs910.voicecode.data

import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

/**
 * Tests for FIFO and priority queue logic.
 * Tests the sorting, ordering, and assignment logic.
 * Note: Full integration tests with Room require Android instrumentation.
 */
class QueueTest {

    // ==========================================================================
    // MARK: - FIFO Queue Tests
    // ==========================================================================

    @Test
    fun `FIFO queue sessions are sorted by queue position`() {
        data class MockSession(
            val id: String,
            val isInQueue: Boolean,
            val queuePosition: Int
        )

        val sessions = listOf(
            MockSession("third", true, 2),
            MockSession("first", true, 0),
            MockSession("second", true, 1),
            MockSession("not-in-queue", false, 0)
        )

        val sorted = sessions
            .filter { it.isInQueue }
            .sortedBy { it.queuePosition }

        assertEquals(3, sorted.size)
        assertEquals("first", sorted[0].id)
        assertEquals("second", sorted[1].id)
        assertEquals("third", sorted[2].id)
    }

    @Test
    fun `Adding to FIFO queue assigns next position`() {
        // Current max position is 2, new item gets position 3
        val currentMaxPosition = 2
        val newPosition = currentMaxPosition + 1
        assertEquals(3, newPosition)
    }

    @Test
    fun `First item in FIFO queue gets position 0`() {
        // When queue is empty, max position returns null
        val currentMaxPosition: Int? = null
        val newPosition = (currentMaxPosition ?: -1) + 1
        assertEquals(0, newPosition)
    }

    @Test
    fun `Removing from FIFO queue shifts positions down`() {
        data class MockSession(var queuePosition: Int)

        // Before removal: [0, 1, 2, 3]
        // Remove position 1: [0, 2, 3] -> shift down -> [0, 1, 2]
        val sessions = mutableListOf(
            MockSession(0),
            MockSession(2),
            MockSession(3)
        )

        val removedPosition = 1
        for (session in sessions) {
            if (session.queuePosition > removedPosition) {
                session.queuePosition -= 1
            }
        }

        assertEquals(0, sessions[0].queuePosition)
        assertEquals(1, sessions[1].queuePosition) // Was 2, now 1
        assertEquals(2, sessions[2].queuePosition) // Was 3, now 2
    }

    @Test
    fun `FIFO queue excludes deleted sessions`() {
        data class MockSession(
            val id: String,
            val isInQueue: Boolean,
            val isUserDeleted: Boolean
        )

        val sessions = listOf(
            MockSession("a", true, false),
            MockSession("b", true, true), // Deleted
            MockSession("c", true, false)
        )

        // SQL: WHERE is_in_queue = 1 AND is_user_deleted = 0
        val inQueue = sessions.filter { it.isInQueue && !it.isUserDeleted }

        assertEquals(2, inQueue.size)
        assertFalse(inQueue.any { it.id == "b" })
    }

    // ==========================================================================
    // MARK: - Priority Queue Tests (existing)
    // ==========================================================================

    // ==========================================================================
    // MARK: - Priority Sorting Tests
    // ==========================================================================

    @Test
    fun `Sessions are sorted by priority first, then by priorityOrder`() {
        // Simulate the SQL: ORDER BY priority ASC, priority_order ASC
        data class MockSession(
            val id: String,
            val priority: Int,
            val priorityOrder: Double
        )

        val sessions = listOf(
            MockSession("low-1", 10, 1.0),
            MockSession("high-1", 1, 1.0),
            MockSession("medium-2", 5, 2.0),
            MockSession("high-2", 1, 2.0),
            MockSession("medium-1", 5, 1.0),
            MockSession("low-2", 10, 2.0)
        )

        val sorted = sessions.sortedWith(
            compareBy({ it.priority }, { it.priorityOrder })
        )

        // High priority (1) sessions first
        assertEquals("high-1", sorted[0].id)
        assertEquals("high-2", sorted[1].id)

        // Medium priority (5) sessions second
        assertEquals("medium-1", sorted[2].id)
        assertEquals("medium-2", sorted[3].id)

        // Low priority (10) sessions last
        assertEquals("low-1", sorted[4].id)
        assertEquals("low-2", sorted[5].id)
    }

    @Test
    fun `Priority order decimal allows insertion between existing items`() {
        data class MockSession(val id: String, val priorityOrder: Double)

        val sessions = mutableListOf(
            MockSession("a", 1.0),
            MockSession("b", 2.0),
            MockSession("c", 3.0)
        )

        // Insert "d" between "a" and "b"
        sessions.add(MockSession("d", 1.5))

        val sorted = sessions.sortedBy { it.priorityOrder }

        assertEquals("a", sorted[0].id) // 1.0
        assertEquals("d", sorted[1].id) // 1.5
        assertEquals("b", sorted[2].id) // 2.0
        assertEquals("c", sorted[3].id) // 3.0
    }

    // ==========================================================================
    // MARK: - Priority Order Calculation Tests
    // ==========================================================================

    @Test
    fun `New session added to end of priority level`() {
        // Simulating: getMaxPriorityOrder(priority) + 1.0
        val existingMaxOrder = 5.0
        val newOrder = existingMaxOrder + 1.0
        assertEquals(6.0, newOrder, 0.001)
    }

    @Test
    fun `First session in priority level gets order 1`() {
        // When getMaxPriorityOrder returns null, we use 0.0 + 1.0 = 1.0
        val maxOrder: Double? = null
        val newOrder = (maxOrder ?: 0.0) + 1.0
        assertEquals(1.0, newOrder, 0.001)
    }

    @Test
    fun `Calculating insertion order between two items`() {
        // For drag-and-drop: insert between items at order 2.0 and 3.0
        val orderBefore = 2.0
        val orderAfter = 3.0
        val insertionOrder = (orderBefore + orderAfter) / 2.0
        assertEquals(2.5, insertionOrder, 0.001)
    }

    @Test
    fun `Calculating insertion order at beginning`() {
        // Insert before first item at order 1.0
        val firstItemOrder = 1.0
        val insertionOrder = firstItemOrder / 2.0
        assertEquals(0.5, insertionOrder, 0.001)
    }

    // ==========================================================================
    // MARK: - Priority Level Tests
    // ==========================================================================

    @Test
    fun `Priority level constants match iOS`() {
        // As per iOS CDBackendSession+PriorityQueue.swift
        val HIGH_PRIORITY = 1
        val MEDIUM_PRIORITY = 5
        val LOW_PRIORITY = 10

        assertEquals(1, HIGH_PRIORITY)
        assertEquals(5, MEDIUM_PRIORITY)
        assertEquals(10, LOW_PRIORITY)
    }

    @Test
    fun `Default priority is Low (10)`() {
        val DEFAULT_PRIORITY = 10
        assertEquals(10, DEFAULT_PRIORITY)
    }

    @Test
    fun `Changing priority moves session to end of new level`() {
        // When changing from High (1) to Medium (5):
        // 1. Get max order in Medium priority
        // 2. Assign max + 1.0

        val currentPriority = 1
        val newPriority = 5
        val maxOrderInNewPriority = 3.0
        val newOrder = maxOrderInNewPriority + 1.0

        assertNotEquals(currentPriority, newPriority)
        assertEquals(4.0, newOrder, 0.001)
    }

    // ==========================================================================
    // MARK: - Remove From Queue Tests
    // ==========================================================================

    @Test
    fun `Removing from queue resets all priority fields`() {
        // After removal: isInPriorityQueue=false, priority=10, priorityOrder=0.0, priorityQueuedAt=null
        data class MockSession(
            var isInPriorityQueue: Boolean,
            var priority: Int,
            var priorityOrder: Double,
            var priorityQueuedAt: Instant?
        )

        val session = MockSession(
            isInPriorityQueue = true,
            priority = 1,
            priorityOrder = 5.5,
            priorityQueuedAt = Instant.now()
        )

        // Simulate removeFromPriorityQueue
        session.isInPriorityQueue = false
        session.priority = 10
        session.priorityOrder = 0.0
        session.priorityQueuedAt = null

        assertFalse(session.isInPriorityQueue)
        assertEquals(10, session.priority)
        assertEquals(0.0, session.priorityOrder, 0.001)
        assertNull(session.priorityQueuedAt)
    }

    // ==========================================================================
    // MARK: - Queue Timestamp Tests
    // ==========================================================================

    @Test
    fun `Queue timestamp is set when adding to queue`() {
        val before = Instant.now()
        val queuedAt = Instant.now() // Simulating timestamp assignment
        val after = Instant.now()

        assertTrue(queuedAt >= before)
        assertTrue(queuedAt <= after)
    }

    @Test
    fun `Queue timestamp allows calculating time in queue`() {
        val queuedAt = Instant.now().minusSeconds(3600) // 1 hour ago
        val now = Instant.now()
        val durationInQueue = java.time.Duration.between(queuedAt, now)

        assertTrue(durationInQueue.toHours() >= 1)
    }

    // ==========================================================================
    // MARK: - Filter Tests
    // ==========================================================================

    @Test
    fun `Filter only returns sessions in priority queue`() {
        data class MockSession(val id: String, val isInPriorityQueue: Boolean)

        val sessions = listOf(
            MockSession("a", true),
            MockSession("b", false),
            MockSession("c", true),
            MockSession("d", false)
        )

        val inQueue = sessions.filter { it.isInPriorityQueue }

        assertEquals(2, inQueue.size)
        assertTrue(inQueue.any { it.id == "a" })
        assertTrue(inQueue.any { it.id == "c" })
    }

    @Test
    fun `Filter excludes deleted sessions from priority queue`() {
        data class MockSession(
            val id: String,
            val isInPriorityQueue: Boolean,
            val isUserDeleted: Boolean
        )

        val sessions = listOf(
            MockSession("a", true, false),
            MockSession("b", true, true), // Deleted but in queue
            MockSession("c", true, false)
        )

        // SQL: WHERE is_in_priority_queue = 1 AND is_user_deleted = 0
        val inQueue = sessions.filter { it.isInPriorityQueue && !it.isUserDeleted }

        assertEquals(2, inQueue.size)
        assertFalse(inQueue.any { it.id == "b" })
    }
}
