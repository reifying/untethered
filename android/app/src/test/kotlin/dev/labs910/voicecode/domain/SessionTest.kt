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
        assertNull(session.queuePosition)
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
}
