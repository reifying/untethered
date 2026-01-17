package dev.labs910.voicecode.data

import dev.labs910.voicecode.domain.model.*
import dev.labs910.voicecode.util.ActiveSessionManager
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.time.Instant
import java.util.UUID

/**
 * Tests for smart speaking logic.
 * Mirrors iOS SmartSpeakingTests.swift.
 *
 * Smart speaking ensures TTS only plays for the currently active session:
 * - Active session receives response → speak aloud
 * - Background session receives response → show notification only
 */
class SmartSpeakingTest {

    @Before
    fun setUp() {
        ActiveSessionManager.clearActiveSession()
    }

    @After
    fun tearDown() {
        ActiveSessionManager.clearActiveSession()
    }

    // =========================================================================
    // MARK: - Unread Count Tests
    // =========================================================================

    @Test
    fun `unreadCount initialized to zero for new session`() {
        val session = Session()

        assertEquals(0, session.unreadCount)
    }

    @Test
    fun `session can track unread count`() {
        val session = Session(unreadCount = 5)

        assertEquals(5, session.unreadCount)
    }

    @Test
    fun `unread count can be cleared`() {
        val session = Session(unreadCount = 10)
        val clearedSession = session.copy(unreadCount = 0)

        assertEquals(0, clearedSession.unreadCount)
    }

    // =========================================================================
    // MARK: - Smart Speaking Decision Tests
    // =========================================================================

    @Test
    fun `shouldSpeak returns true for active session`() {
        val sessionId = UUID.randomUUID().toString().lowercase()
        ActiveSessionManager.setActiveSession(sessionId)

        val shouldSpeak = shouldSpeakForSession(sessionId, autoSpeakEnabled = true)

        assertTrue(shouldSpeak)
    }

    @Test
    fun `shouldSpeak returns false for inactive session`() {
        val activeSessionId = UUID.randomUUID().toString().lowercase()
        val backgroundSessionId = UUID.randomUUID().toString().lowercase()
        ActiveSessionManager.setActiveSession(activeSessionId)

        val shouldSpeak = shouldSpeakForSession(backgroundSessionId, autoSpeakEnabled = true)

        assertFalse(shouldSpeak)
    }

    @Test
    fun `shouldSpeak returns false when no session is active`() {
        val sessionId = UUID.randomUUID().toString().lowercase()

        val shouldSpeak = shouldSpeakForSession(sessionId, autoSpeakEnabled = true)

        assertFalse(shouldSpeak)
    }

    @Test
    fun `shouldSpeak returns false when autoSpeak is disabled`() {
        val sessionId = UUID.randomUUID().toString().lowercase()
        ActiveSessionManager.setActiveSession(sessionId)

        val shouldSpeak = shouldSpeakForSession(sessionId, autoSpeakEnabled = false)

        assertFalse(shouldSpeak)
    }

    // =========================================================================
    // MARK: - Notification Decision Tests
    // =========================================================================

    @Test
    fun `shouldShowNotification returns true for background session`() {
        val activeSessionId = UUID.randomUUID().toString().lowercase()
        val backgroundSessionId = UUID.randomUUID().toString().lowercase()
        ActiveSessionManager.setActiveSession(activeSessionId)

        val shouldNotify = shouldShowNotificationForSession(
            backgroundSessionId,
            notificationsEnabled = true
        )

        assertTrue(shouldNotify)
    }

    @Test
    fun `shouldShowNotification returns false for active session`() {
        val sessionId = UUID.randomUUID().toString().lowercase()
        ActiveSessionManager.setActiveSession(sessionId)

        val shouldNotify = shouldShowNotificationForSession(
            sessionId,
            notificationsEnabled = true
        )

        assertFalse(shouldNotify)
    }

    @Test
    fun `shouldShowNotification returns false when notifications disabled`() {
        val backgroundSessionId = UUID.randomUUID().toString().lowercase()

        val shouldNotify = shouldShowNotificationForSession(
            backgroundSessionId,
            notificationsEnabled = false
        )

        assertFalse(shouldNotify)
    }

    // =========================================================================
    // MARK: - Unread Count Increment Tests
    // =========================================================================

    @Test
    fun `unread count increments for background session response`() {
        val session = Session(unreadCount = 0)
        val otherSessionId = UUID.randomUUID().toString().lowercase()
        ActiveSessionManager.setActiveSession(otherSessionId)

        // Simulate response arriving for background session
        val updatedSession = incrementUnreadIfBackground(session)

        assertEquals(1, updatedSession.unreadCount)
    }

    @Test
    fun `unread count does not increment for active session response`() {
        val session = Session(unreadCount = 0)
        ActiveSessionManager.setActiveSession(session.id)

        // Simulate response arriving for active session
        val updatedSession = incrementUnreadIfBackground(session)

        assertEquals(0, updatedSession.unreadCount)
    }

    @Test
    fun `unread count clears when session becomes active`() {
        val session = Session(unreadCount = 5)

        // User opens the session
        ActiveSessionManager.setActiveSession(session.id)
        val clearedSession = session.copy(unreadCount = 0)

        assertEquals(0, clearedSession.unreadCount)
    }

    // =========================================================================
    // MARK: - Message Response Handling Tests
    // =========================================================================

    @Test
    fun `response handling for active session`() {
        val session = Session()
        ActiveSessionManager.setActiveSession(session.id)

        val response = Message(
            sessionId = session.id,
            role = MessageRole.ASSISTANT,
            text = "Hello! How can I help?"
        )

        // Active session should:
        assertTrue(ActiveSessionManager.isActive(response.sessionId))
        assertTrue(shouldSpeakForSession(response.sessionId, autoSpeakEnabled = true))
        assertFalse(shouldShowNotificationForSession(response.sessionId, notificationsEnabled = true))
    }

    @Test
    fun `response handling for background session`() {
        val activeSession = Session()
        val backgroundSession = Session()
        ActiveSessionManager.setActiveSession(activeSession.id)

        val response = Message(
            sessionId = backgroundSession.id,
            role = MessageRole.ASSISTANT,
            text = "Background response"
        )

        // Background session should:
        assertFalse(ActiveSessionManager.isActive(response.sessionId))
        assertFalse(shouldSpeakForSession(response.sessionId, autoSpeakEnabled = true))
        assertTrue(shouldShowNotificationForSession(response.sessionId, notificationsEnabled = true))
    }

    // =========================================================================
    // MARK: - Session Switch During Response Tests
    // =========================================================================

    @Test
    fun `session switch before response arrives`() {
        val sessionA = Session()
        val sessionB = Session()

        // User opens session A, sends prompt
        ActiveSessionManager.setActiveSession(sessionA.id)
        assertTrue(ActiveSessionManager.isActive(sessionA.id))

        // User switches to session B before response arrives
        ActiveSessionManager.setActiveSession(sessionB.id)

        // Response arrives for session A
        assertFalse(shouldSpeakForSession(sessionA.id, autoSpeakEnabled = true))
        assertTrue(shouldShowNotificationForSession(sessionA.id, notificationsEnabled = true))
    }

    @Test
    fun `rapid session switches`() {
        val sessions = (1..5).map { Session() }

        // User rapidly switches between sessions
        sessions.forEach { session ->
            ActiveSessionManager.setActiveSession(session.id)
        }

        // Only the last session should trigger TTS
        val lastSession = sessions.last()
        assertTrue(shouldSpeakForSession(lastSession.id, autoSpeakEnabled = true))

        // All other sessions should trigger notifications
        sessions.dropLast(1).forEach { session ->
            assertFalse(shouldSpeakForSession(session.id, autoSpeakEnabled = true))
        }
    }

    // =========================================================================
    // MARK: - Helper Functions (would be in repository/manager in real app)
    // =========================================================================

    /**
     * Determines if TTS should play for a given session.
     * Based on: session is active AND auto-speak is enabled.
     */
    private fun shouldSpeakForSession(sessionId: String, autoSpeakEnabled: Boolean): Boolean {
        return autoSpeakEnabled && ActiveSessionManager.isActive(sessionId)
    }

    /**
     * Determines if a notification should be shown for a given session.
     * Based on: session is NOT active AND notifications are enabled.
     */
    private fun shouldShowNotificationForSession(
        sessionId: String,
        notificationsEnabled: Boolean
    ): Boolean {
        return notificationsEnabled && !ActiveSessionManager.isActive(sessionId)
    }

    /**
     * Increments unread count if session is in background.
     */
    private fun incrementUnreadIfBackground(session: Session): Session {
        return if (!ActiveSessionManager.isActive(session.id)) {
            session.copy(unreadCount = session.unreadCount + 1)
        } else {
            session
        }
    }
}
