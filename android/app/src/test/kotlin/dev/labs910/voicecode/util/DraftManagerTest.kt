package dev.labs910.voicecode.util

import android.content.Context
import android.content.SharedPreferences
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.mockito.Mockito.*

/**
 * Tests for DraftManager utility.
 * Mirrors iOS DraftManager tests.
 *
 * Note: These tests use Mockito to mock SharedPreferences since we can't
 * use Android context in unit tests without instrumentation.
 */
class DraftManagerTest {

    private lateinit var mockContext: Context
    private lateinit var mockPrefs: SharedPreferences
    private lateinit var mockEditor: SharedPreferences.Editor

    @Before
    fun setUp() {
        mockContext = mock(Context::class.java)
        mockPrefs = mock(SharedPreferences::class.java)
        mockEditor = mock(SharedPreferences.Editor::class.java)

        `when`(mockContext.getSharedPreferences(anyString(), anyInt())).thenReturn(mockPrefs)
        `when`(mockPrefs.edit()).thenReturn(mockEditor)
        `when`(mockEditor.putString(anyString(), anyString())).thenReturn(mockEditor)
        `when`(mockEditor.remove(anyString())).thenReturn(mockEditor)
        `when`(mockEditor.clear()).thenReturn(mockEditor)
        `when`(mockPrefs.all).thenReturn(emptyMap())
    }

    // =========================================================================
    // MARK: - Initialization Tests
    // =========================================================================

    @Test
    fun `DraftManager initializes with context`() {
        val manager = DraftManager(mockContext)

        verify(mockContext).getSharedPreferences("session_drafts", Context.MODE_PRIVATE)
    }

    @Test
    fun `DraftManager loads existing drafts on init`() {
        val existingDrafts = mapOf<String, Any>(
            "session-1" to "Draft 1",
            "session-2" to "Draft 2"
        )
        `when`(mockPrefs.all).thenReturn(existingDrafts)

        val manager = DraftManager(mockContext)

        assertEquals("Draft 1", manager.getDraft("session-1"))
        assertEquals("Draft 2", manager.getDraft("session-2"))
    }

    // =========================================================================
    // MARK: - Save/Get Draft Tests
    // =========================================================================

    @Test
    fun `saveDraft stores draft in memory`() {
        val manager = DraftManager(mockContext)

        manager.saveDraft("session-123", "Test draft")

        assertEquals("Test draft", manager.getDraft("session-123"))
    }

    @Test
    fun `saveDraft normalizes session ID to lowercase`() {
        val manager = DraftManager(mockContext)

        manager.saveDraft("SESSION-ABC", "Test draft")

        assertEquals("Test draft", manager.getDraft("session-abc"))
        assertEquals("Test draft", manager.getDraft("SESSION-ABC"))
    }

    @Test
    fun `saveDraft removes draft when text is empty`() {
        val manager = DraftManager(mockContext)

        manager.saveDraft("session-123", "Initial draft")
        assertEquals("Initial draft", manager.getDraft("session-123"))

        manager.saveDraft("session-123", "")
        assertEquals("", manager.getDraft("session-123"))
    }

    @Test
    fun `getDraft returns empty string for unknown session`() {
        val manager = DraftManager(mockContext)

        val result = manager.getDraft("nonexistent-session")

        assertEquals("", result)
    }

    @Test
    fun `getDraft normalizes session ID to lowercase`() {
        val manager = DraftManager(mockContext)
        manager.saveDraft("session-abc", "Test")

        assertEquals("Test", manager.getDraft("SESSION-ABC"))
        assertEquals("Test", manager.getDraft("Session-Abc"))
    }

    // =========================================================================
    // MARK: - Has Draft Tests
    // =========================================================================

    @Test
    fun `hasDraft returns true when draft exists`() {
        val manager = DraftManager(mockContext)
        manager.saveDraft("session-123", "Test draft")

        assertTrue(manager.hasDraft("session-123"))
    }

    @Test
    fun `hasDraft returns false when no draft`() {
        val manager = DraftManager(mockContext)

        assertFalse(manager.hasDraft("nonexistent"))
    }

    @Test
    fun `hasDraft returns false after clearing draft`() {
        val manager = DraftManager(mockContext)
        manager.saveDraft("session-123", "Test")

        manager.clearDraft("session-123")

        assertFalse(manager.hasDraft("session-123"))
    }

    @Test
    fun `hasDraft normalizes session ID`() {
        val manager = DraftManager(mockContext)
        manager.saveDraft("session-abc", "Test")

        assertTrue(manager.hasDraft("SESSION-ABC"))
    }

    // =========================================================================
    // MARK: - Clear Draft Tests
    // =========================================================================

    @Test
    fun `clearDraft removes draft from memory`() {
        val manager = DraftManager(mockContext)
        manager.saveDraft("session-123", "Test draft")

        manager.clearDraft("session-123")

        assertEquals("", manager.getDraft("session-123"))
        assertFalse(manager.hasDraft("session-123"))
    }

    @Test
    fun `clearDraft normalizes session ID`() {
        val manager = DraftManager(mockContext)
        manager.saveDraft("session-abc", "Test")

        manager.clearDraft("SESSION-ABC")

        assertFalse(manager.hasDraft("session-abc"))
    }

    @Test
    fun `clearDraft is idempotent for nonexistent session`() {
        val manager = DraftManager(mockContext)

        // Should not throw
        manager.clearDraft("nonexistent")
        manager.clearDraft("nonexistent")

        assertFalse(manager.hasDraft("nonexistent"))
    }

    // =========================================================================
    // MARK: - Cleanup Draft Tests
    // =========================================================================

    @Test
    fun `cleanupDraft removes draft`() {
        val manager = DraftManager(mockContext)
        manager.saveDraft("deleted-session", "Orphaned draft")

        manager.cleanupDraft("deleted-session")

        assertFalse(manager.hasDraft("deleted-session"))
    }

    // =========================================================================
    // MARK: - Get Sessions With Drafts Tests
    // =========================================================================

    @Test
    fun `getSessionsWithDrafts returns all session IDs`() {
        val manager = DraftManager(mockContext)
        manager.saveDraft("session-1", "Draft 1")
        manager.saveDraft("session-2", "Draft 2")
        manager.saveDraft("session-3", "Draft 3")

        val sessions = manager.getSessionsWithDrafts()

        assertEquals(3, sessions.size)
        assertTrue(sessions.contains("session-1"))
        assertTrue(sessions.contains("session-2"))
        assertTrue(sessions.contains("session-3"))
    }

    @Test
    fun `getSessionsWithDrafts returns empty set when no drafts`() {
        val manager = DraftManager(mockContext)

        val sessions = manager.getSessionsWithDrafts()

        assertTrue(sessions.isEmpty())
    }

    @Test
    fun `getSessionsWithDrafts excludes cleared drafts`() {
        val manager = DraftManager(mockContext)
        manager.saveDraft("session-1", "Draft 1")
        manager.saveDraft("session-2", "Draft 2")

        manager.clearDraft("session-1")

        val sessions = manager.getSessionsWithDrafts()
        assertEquals(1, sessions.size)
        assertTrue(sessions.contains("session-2"))
    }

    // =========================================================================
    // MARK: - Clear All Drafts Tests
    // =========================================================================

    @Test
    fun `clearAllDrafts removes all drafts`() {
        val manager = DraftManager(mockContext)
        manager.saveDraft("session-1", "Draft 1")
        manager.saveDraft("session-2", "Draft 2")

        manager.clearAllDrafts()

        assertTrue(manager.getSessionsWithDrafts().isEmpty())
        assertEquals("", manager.getDraft("session-1"))
        assertEquals("", manager.getDraft("session-2"))
    }

    // =========================================================================
    // MARK: - Draft Count Tests
    // =========================================================================

    @Test
    fun `draftCount reflects number of drafts`() {
        val manager = DraftManager(mockContext)

        assertEquals(0, manager.draftCount.value)

        manager.saveDraft("session-1", "Draft 1")
        assertEquals(1, manager.draftCount.value)

        manager.saveDraft("session-2", "Draft 2")
        assertEquals(2, manager.draftCount.value)

        manager.clearDraft("session-1")
        assertEquals(1, manager.draftCount.value)
    }

    @Test
    fun `draftCount updates on clearAllDrafts`() {
        val manager = DraftManager(mockContext)
        manager.saveDraft("session-1", "Draft 1")
        manager.saveDraft("session-2", "Draft 2")

        manager.clearAllDrafts()

        assertEquals(0, manager.draftCount.value)
    }

    // =========================================================================
    // MARK: - UUID Normalization Tests
    // =========================================================================

    @Test
    fun `session IDs are stored as lowercase`() {
        val manager = DraftManager(mockContext)
        val upperUUID = "ABC123DE-4567-89AB-CDEF-0123456789AB"

        manager.saveDraft(upperUUID, "Test")

        val sessions = manager.getSessionsWithDrafts()
        assertTrue(sessions.all { it == it.lowercase() })
    }
}
