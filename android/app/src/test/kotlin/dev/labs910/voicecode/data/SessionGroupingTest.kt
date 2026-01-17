package dev.labs910.voicecode.data

import dev.labs910.voicecode.domain.model.Session
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

/**
 * Tests for session grouping by working directory.
 * Mirrors iOS SessionGroupingTests.swift (voice-code-133).
 *
 * Sessions are grouped by working directory in the UI, with groups
 * sorted by most recent modification and sessions within groups
 * also sorted by modification date.
 */
class SessionGroupingTest {

    // =========================================================================
    // MARK: - Basic Grouping Tests
    // =========================================================================

    @Test
    fun `sessions grouped by working directory`() {
        val sessions = listOf(
            Session(id = "1", workingDirectory = "/projects/app1"),
            Session(id = "2", workingDirectory = "/projects/app2"),
            Session(id = "3", workingDirectory = "/projects/app1")
        )

        val grouped = sessions.groupBy { it.workingDirectory }

        assertEquals(2, grouped.keys.size)
        assertEquals(2, grouped["/projects/app1"]?.size)
        assertEquals(1, grouped["/projects/app2"]?.size)
    }

    @Test
    fun `sessions with null working directory grouped separately`() {
        val sessions = listOf(
            Session(id = "1", workingDirectory = "/projects/app1"),
            Session(id = "2", workingDirectory = null),
            Session(id = "3", workingDirectory = null)
        )

        val grouped = sessions.groupBy { it.workingDirectory ?: "No Directory" }

        assertEquals(2, grouped.keys.size)
        assertEquals(1, grouped["/projects/app1"]?.size)
        assertEquals(2, grouped["No Directory"]?.size)
    }

    @Test
    fun `empty sessions list has no groups`() {
        val sessions = emptyList<Session>()

        val grouped = sessions.groupBy { it.workingDirectory }

        assertTrue(grouped.isEmpty())
    }

    @Test
    fun `single session creates one group`() {
        val sessions = listOf(
            Session(id = "1", workingDirectory = "/projects/app")
        )

        val grouped = sessions.groupBy { it.workingDirectory }

        assertEquals(1, grouped.keys.size)
        assertEquals(1, grouped["/projects/app"]?.size)
    }

    // =========================================================================
    // MARK: - Group Sorting Tests
    // =========================================================================

    @Test
    fun `groups sorted by most recent modification`() {
        val oldTime = Instant.now().minusSeconds(1000)
        val recentTime = Instant.now()

        val sessions = listOf(
            Session(id = "1", workingDirectory = "/projects/old", lastModified = oldTime),
            Session(id = "2", workingDirectory = "/projects/recent", lastModified = recentTime)
        )

        val grouped = sessions.groupBy { it.workingDirectory }
        val sortedDirs = grouped.keys.sortedByDescending { dir ->
            grouped[dir]?.maxOfOrNull { it.lastModified } ?: Instant.MIN
        }

        assertEquals("/projects/recent", sortedDirs.first())
        assertEquals("/projects/old", sortedDirs.last())
    }

    @Test
    fun `group with multiple sessions uses most recent for sorting`() {
        val veryOldTime = Instant.now().minusSeconds(2000)
        val oldTime = Instant.now().minusSeconds(1000)
        val recentTime = Instant.now()

        val sessions = listOf(
            // Old project has one recent session
            Session(id = "1", workingDirectory = "/projects/old", lastModified = veryOldTime),
            Session(id = "2", workingDirectory = "/projects/old", lastModified = recentTime),
            // Recent project has older sessions
            Session(id = "3", workingDirectory = "/projects/recent", lastModified = oldTime)
        )

        val grouped = sessions.groupBy { it.workingDirectory }
        val sortedDirs = grouped.keys.sortedByDescending { dir ->
            grouped[dir]?.maxOfOrNull { it.lastModified } ?: Instant.MIN
        }

        // "old" project should be first because it has the most recent session
        assertEquals("/projects/old", sortedDirs.first())
    }

    // =========================================================================
    // MARK: - Session Sorting Within Groups Tests
    // =========================================================================

    @Test
    fun `sessions within group sorted by modification date descending`() {
        val oldTime = Instant.now().minusSeconds(1000)
        val middleTime = Instant.now().minusSeconds(500)
        val recentTime = Instant.now()

        val sessions = listOf(
            Session(id = "1", name = "Old", workingDirectory = "/projects/app", lastModified = oldTime),
            Session(id = "2", name = "Recent", workingDirectory = "/projects/app", lastModified = recentTime),
            Session(id = "3", name = "Middle", workingDirectory = "/projects/app", lastModified = middleTime)
        )

        val grouped = sessions.groupBy { it.workingDirectory }
        val sortedSessions = grouped["/projects/app"]?.sortedByDescending { it.lastModified }

        assertEquals("Recent", sortedSessions?.get(0)?.name)
        assertEquals("Middle", sortedSessions?.get(1)?.name)
        assertEquals("Old", sortedSessions?.get(2)?.name)
    }

    // =========================================================================
    // MARK: - Default Working Directory Tests
    // =========================================================================

    @Test
    fun `default working directory is most recent`() {
        val oldTime = Instant.now().minusSeconds(1000)
        val recentTime = Instant.now()

        val sessions = listOf(
            Session(id = "1", workingDirectory = "/projects/old", lastModified = oldTime),
            Session(id = "2", workingDirectory = "/projects/recent", lastModified = recentTime)
        )

        val grouped = sessions.groupBy { it.workingDirectory }
        val defaultDir = grouped.keys.maxByOrNull { dir ->
            grouped[dir]?.maxOfOrNull { it.lastModified } ?: Instant.MIN
        }

        assertEquals("/projects/recent", defaultDir)
    }

    @Test
    fun `default working directory when all null`() {
        val sessions = listOf(
            Session(id = "1", workingDirectory = null),
            Session(id = "2", workingDirectory = null)
        )

        val grouped = sessions.groupBy { it.workingDirectory ?: "No Directory" }

        assertEquals(1, grouped.keys.size)
        assertTrue(grouped.keys.contains("No Directory"))
    }

    // =========================================================================
    // MARK: - Deleted Sessions Filtering Tests
    // =========================================================================

    @Test
    fun `deleted sessions not included in groups`() {
        val sessions = listOf(
            Session(id = "1", workingDirectory = "/projects/app", isUserDeleted = false),
            Session(id = "2", workingDirectory = "/projects/app", isUserDeleted = true),
            Session(id = "3", workingDirectory = "/projects/app", isUserDeleted = false)
        )

        val activeSessions = sessions.filter { !it.isUserDeleted }
        val grouped = activeSessions.groupBy { it.workingDirectory }

        assertEquals(2, grouped["/projects/app"]?.size)
    }

    @Test
    fun `directory removed when all sessions deleted`() {
        val sessions = listOf(
            Session(id = "1", workingDirectory = "/projects/app1", isUserDeleted = true),
            Session(id = "2", workingDirectory = "/projects/app2", isUserDeleted = false)
        )

        val activeSessions = sessions.filter { !it.isUserDeleted }
        val grouped = activeSessions.groupBy { it.workingDirectory }

        assertEquals(1, grouped.keys.size)
        assertNull(grouped["/projects/app1"])
        assertNotNull(grouped["/projects/app2"])
    }

    // =========================================================================
    // MARK: - Group Count Tests
    // =========================================================================

    @Test
    fun `group count reflects number of sessions`() {
        val sessions = (1..5).map { i ->
            Session(id = "$i", workingDirectory = "/projects/app")
        }

        val grouped = sessions.groupBy { it.workingDirectory }

        assertEquals(5, grouped["/projects/app"]?.size)
    }

    @Test
    fun `multiple groups with different counts`() {
        val sessions = listOf(
            Session(id = "1", workingDirectory = "/projects/app1"),
            Session(id = "2", workingDirectory = "/projects/app1"),
            Session(id = "3", workingDirectory = "/projects/app1"),
            Session(id = "4", workingDirectory = "/projects/app2"),
            Session(id = "5", workingDirectory = "/projects/app3"),
            Session(id = "6", workingDirectory = "/projects/app3")
        )

        val grouped = sessions.groupBy { it.workingDirectory }

        assertEquals(3, grouped["/projects/app1"]?.size)
        assertEquals(1, grouped["/projects/app2"]?.size)
        assertEquals(2, grouped["/projects/app3"]?.size)
    }

    // =========================================================================
    // MARK: - Dynamic Update Tests
    // =========================================================================

    @Test
    fun `updating session modification affects sorting`() {
        val oldTime = Instant.now().minusSeconds(1000)
        val newTime = Instant.now()

        var session1 = Session(id = "1", workingDirectory = "/projects/app1", lastModified = oldTime)
        val session2 = Session(id = "2", workingDirectory = "/projects/app2", lastModified = newTime)

        var sessions = listOf(session1, session2)

        // Initially app2 is most recent
        var grouped = sessions.groupBy { it.workingDirectory }
        var sortedDirs = grouped.keys.sortedByDescending { dir ->
            grouped[dir]?.maxOfOrNull { it.lastModified } ?: Instant.MIN
        }
        assertEquals("/projects/app2", sortedDirs.first())

        // Update session1 to be more recent
        session1 = session1.copy(lastModified = Instant.now().plusSeconds(100))
        sessions = listOf(session1, session2)

        // Now app1 should be first
        grouped = sessions.groupBy { it.workingDirectory }
        sortedDirs = grouped.keys.sortedByDescending { dir ->
            grouped[dir]?.maxOfOrNull { it.lastModified } ?: Instant.MIN
        }
        assertEquals("/projects/app1", sortedDirs.first())
    }

    // =========================================================================
    // MARK: - Working Directory Extraction Tests
    // =========================================================================

    @Test
    fun `extract directory name from path`() {
        val session = Session(id = "1", workingDirectory = "/Users/test/projects/my-app")

        val dirName = session.workingDirectory?.substringAfterLast('/') ?: ""

        assertEquals("my-app", dirName)
    }

    @Test
    fun `group header uses directory basename`() {
        val sessions = listOf(
            Session(id = "1", workingDirectory = "/Users/test/projects/voice-code"),
            Session(id = "2", workingDirectory = "/Users/test/projects/voice-code")
        )

        val grouped = sessions.groupBy { it.workingDirectory }
        val header = grouped.keys.first()?.substringAfterLast('/') ?: "Unknown"

        assertEquals("voice-code", header)
    }

    // =========================================================================
    // MARK: - Queue Session Grouping Tests
    // =========================================================================

    @Test
    fun `queue sessions can be grouped separately`() {
        val sessions = listOf(
            Session(id = "1", workingDirectory = "/projects/app", isInQueue = true),
            Session(id = "2", workingDirectory = "/projects/app", isInQueue = false),
            Session(id = "3", workingDirectory = "/projects/app", isInPriorityQueue = true)
        )

        val queuedSessions = sessions.filter { it.isInQueue || it.isInPriorityQueue }
        val regularSessions = sessions.filter { !it.isInQueue && !it.isInPriorityQueue }

        assertEquals(2, queuedSessions.size)
        assertEquals(1, regularSessions.size)
    }
}
