package dev.labs910.voicecode.util

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.util.UUID

/**
 * Tests for ActiveSessionManager utility.
 * Mirrors iOS SmartSpeakingTests.swift ActiveSessionManager tests.
 */
class ActiveSessionManagerTest {

    @Before
    fun setUp() {
        // Clear any active session before each test
        ActiveSessionManager.clearActiveSession()
    }

    @After
    fun tearDown() {
        ActiveSessionManager.clearActiveSession()
    }

    // =========================================================================
    // MARK: - Basic Active Session Tests
    // =========================================================================

    @Test
    fun `activeSessionId is initially null`() {
        assertNull(ActiveSessionManager.getActiveSessionId())
    }

    @Test
    fun `setActiveSession sets the active session`() {
        val sessionId = UUID.randomUUID().toString()

        ActiveSessionManager.setActiveSession(sessionId)

        assertEquals(sessionId.lowercase(), ActiveSessionManager.getActiveSessionId())
    }

    @Test
    fun `setActiveSession normalizes ID to lowercase`() {
        val upperCaseId = "ABC123DE-4567-89AB-CDEF-0123456789AB"

        ActiveSessionManager.setActiveSession(upperCaseId)

        assertEquals(upperCaseId.lowercase(), ActiveSessionManager.getActiveSessionId())
    }

    @Test
    fun `clearActiveSession clears the active session`() {
        val sessionId = UUID.randomUUID().toString()
        ActiveSessionManager.setActiveSession(sessionId)

        ActiveSessionManager.clearActiveSession()

        assertNull(ActiveSessionManager.getActiveSessionId())
    }

    // =========================================================================
    // MARK: - isActive Tests
    // =========================================================================

    @Test
    fun `isActive returns true for active session`() {
        val sessionId = UUID.randomUUID().toString()
        ActiveSessionManager.setActiveSession(sessionId)

        assertTrue(ActiveSessionManager.isActive(sessionId))
    }

    @Test
    fun `isActive returns false for inactive session`() {
        val activeSessionId = UUID.randomUUID().toString()
        val otherSessionId = UUID.randomUUID().toString()
        ActiveSessionManager.setActiveSession(activeSessionId)

        assertFalse(ActiveSessionManager.isActive(otherSessionId))
    }

    @Test
    fun `isActive returns false when no session is active`() {
        val sessionId = UUID.randomUUID().toString()

        assertFalse(ActiveSessionManager.isActive(sessionId))
    }

    @Test
    fun `isActive normalizes ID to lowercase for comparison`() {
        val lowerCaseId = "abc123de-4567-89ab-cdef-0123456789ab"
        val upperCaseId = "ABC123DE-4567-89AB-CDEF-0123456789AB"

        ActiveSessionManager.setActiveSession(lowerCaseId)

        assertTrue(ActiveSessionManager.isActive(upperCaseId))
        assertTrue(ActiveSessionManager.isActive(lowerCaseId))
    }

    // =========================================================================
    // MARK: - Session Switching Tests
    // =========================================================================

    @Test
    fun `switching between sessions works correctly`() {
        val sessionId1 = UUID.randomUUID().toString()
        val sessionId2 = UUID.randomUUID().toString()

        // Set first session as active
        ActiveSessionManager.setActiveSession(sessionId1)
        assertTrue(ActiveSessionManager.isActive(sessionId1))
        assertFalse(ActiveSessionManager.isActive(sessionId2))

        // Switch to second session
        ActiveSessionManager.setActiveSession(sessionId2)
        assertFalse(ActiveSessionManager.isActive(sessionId1))
        assertTrue(ActiveSessionManager.isActive(sessionId2))
    }

    @Test
    fun `setActiveSession with null clears active session`() {
        val sessionId = UUID.randomUUID().toString()
        ActiveSessionManager.setActiveSession(sessionId)

        ActiveSessionManager.setActiveSession(null)

        assertNull(ActiveSessionManager.getActiveSessionId())
        assertFalse(ActiveSessionManager.isActive(sessionId))
    }

    // =========================================================================
    // MARK: - StateFlow Tests
    // =========================================================================

    @Test
    fun `activeSessionId StateFlow emits initial null`() = runBlocking {
        ActiveSessionManager.clearActiveSession()

        val value = ActiveSessionManager.activeSessionId.first()

        assertNull(value)
    }

    @Test
    fun `activeSessionId StateFlow emits updated value`() = runBlocking {
        val sessionId = UUID.randomUUID().toString()

        ActiveSessionManager.setActiveSession(sessionId)
        val value = ActiveSessionManager.activeSessionId.first()

        assertEquals(sessionId.lowercase(), value)
    }

    // =========================================================================
    // MARK: - Smart Speaking Scenario Tests
    // =========================================================================

    @Test
    fun `scenario - user opens session then receives response`() {
        val sessionId = UUID.randomUUID().toString()

        // User opens a session
        ActiveSessionManager.setActiveSession(sessionId)

        // Response arrives - should be spoken (session is active)
        assertTrue(ActiveSessionManager.isActive(sessionId))
    }

    @Test
    fun `scenario - user switches sessions before response arrives`() {
        val sessionA = UUID.randomUUID().toString()
        val sessionB = UUID.randomUUID().toString()

        // User opens session A
        ActiveSessionManager.setActiveSession(sessionA)

        // User switches to session B
        ActiveSessionManager.setActiveSession(sessionB)

        // Response arrives for session A - should NOT be spoken (no longer active)
        assertFalse(ActiveSessionManager.isActive(sessionA))

        // Response arrives for session B - should be spoken (currently active)
        assertTrue(ActiveSessionManager.isActive(sessionB))
    }

    @Test
    fun `scenario - user closes all sessions`() {
        val sessionId = UUID.randomUUID().toString()

        // User opens a session
        ActiveSessionManager.setActiveSession(sessionId)

        // User navigates away (closes session view)
        ActiveSessionManager.clearActiveSession()

        // Response arrives - should NOT be spoken (no active session)
        assertFalse(ActiveSessionManager.isActive(sessionId))
    }

    @Test
    fun `scenario - multiple rapid session switches`() {
        val sessions = (1..5).map { UUID.randomUUID().toString() }

        // Rapidly switch through sessions
        sessions.forEach { sessionId ->
            ActiveSessionManager.setActiveSession(sessionId)
        }

        // Only the last session should be active
        val lastSession = sessions.last()
        assertTrue(ActiveSessionManager.isActive(lastSession))

        // All others should be inactive
        sessions.dropLast(1).forEach { sessionId ->
            assertFalse(ActiveSessionManager.isActive(sessionId))
        }
    }

    // =========================================================================
    // MARK: - Thread Safety Tests
    // =========================================================================

    @Test
    fun `concurrent access does not crash`() = runBlocking {
        val threads = (1..10).map { threadNum ->
            Thread {
                repeat(100) {
                    val sessionId = UUID.randomUUID().toString()
                    ActiveSessionManager.setActiveSession(sessionId)
                    ActiveSessionManager.isActive(sessionId)
                    ActiveSessionManager.getActiveSessionId()
                }
            }
        }

        threads.forEach { it.start() }
        threads.forEach { it.join() }

        // If we get here without crashing, the test passes
        // The final state doesn't matter, just that it didn't crash
    }
}
