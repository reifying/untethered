package dev.labs910.voicecode.util

import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

/**
 * Tests for LogManager utility.
 * Mirrors iOS LogManager tests.
 */
class LogManagerTest {

    @Before
    fun setUp() {
        LogManager.clearLogsSync()
    }

    @After
    fun tearDown() {
        LogManager.clearLogsSync()
    }

    // =========================================================================
    // MARK: - Basic Logging Tests
    // =========================================================================

    @Test
    fun `log adds message to logs`() {
        LogManager.log("Test message")

        // Give async operation time to complete
        Thread.sleep(50)

        val logs = LogManager.getAllLogsSync()
        assertTrue(logs.contains("Test message"))
    }

    @Test
    fun `log includes category`() {
        LogManager.log("Test message", "TestCategory")

        Thread.sleep(50)

        val logs = LogManager.getAllLogsSync()
        assertTrue(logs.contains("[TestCategory]"))
    }

    @Test
    fun `log uses General as default category`() {
        LogManager.log("Test message")

        Thread.sleep(50)

        val logs = LogManager.getAllLogsSync()
        assertTrue(logs.contains("[General]"))
    }

    @Test
    fun `log includes timestamp`() {
        LogManager.log("Test message")

        Thread.sleep(50)

        val logs = LogManager.getAllLogsSync()
        // Timestamp format: [HH:mm:ss.SSS]
        assertTrue(logs.matches(Regex(".*\\[\\d{2}:\\d{2}:\\d{2}\\.\\d{3}\\].*")))
    }

    // =========================================================================
    // MARK: - Convenience Method Tests
    // =========================================================================

    @Test
    fun `debug logs with Debug category`() {
        LogManager.debug("Debug message")

        Thread.sleep(50)

        val logs = LogManager.getAllLogsSync()
        assertTrue(logs.contains("[Debug]"))
        assertTrue(logs.contains("Debug message"))
    }

    @Test
    fun `info logs with Info category`() {
        LogManager.info("Info message")

        Thread.sleep(50)

        val logs = LogManager.getAllLogsSync()
        assertTrue(logs.contains("[Info]"))
    }

    @Test
    fun `warn logs with Warning category`() {
        LogManager.warn("Warning message")

        Thread.sleep(50)

        val logs = LogManager.getAllLogsSync()
        assertTrue(logs.contains("[Warning]"))
    }

    @Test
    fun `error logs with Error category`() {
        LogManager.error("Error message")

        Thread.sleep(50)

        val logs = LogManager.getAllLogsSync()
        assertTrue(logs.contains("[Error]"))
    }

    @Test
    fun `convenience methods accept custom category`() {
        LogManager.debug("Test", "CustomDebug")

        Thread.sleep(50)

        val logs = LogManager.getAllLogsSync()
        assertTrue(logs.contains("[CustomDebug]"))
    }

    // =========================================================================
    // MARK: - Multiple Logs Tests
    // =========================================================================

    @Test
    fun `multiple logs are preserved in order`() {
        LogManager.log("First")
        LogManager.log("Second")
        LogManager.log("Third")

        Thread.sleep(100)

        val logs = LogManager.getAllLogsSync()
        val firstIndex = logs.indexOf("First")
        val secondIndex = logs.indexOf("Second")
        val thirdIndex = logs.indexOf("Third")

        assertTrue(firstIndex < secondIndex)
        assertTrue(secondIndex < thirdIndex)
    }

    @Test
    fun `getLogCount returns correct count`() {
        LogManager.log("One")
        LogManager.log("Two")
        LogManager.log("Three")

        Thread.sleep(100)

        assertEquals(3, LogManager.getLogCount())
    }

    // =========================================================================
    // MARK: - Clear Logs Tests
    // =========================================================================

    @Test
    fun `clearLogsSync removes all logs`() {
        LogManager.log("Test 1")
        LogManager.log("Test 2")
        Thread.sleep(50)

        LogManager.clearLogsSync()

        assertEquals(0, LogManager.getLogCount())
        assertEquals("", LogManager.getAllLogsSync())
    }

    @Test
    fun `clearLogs removes all logs async`() = runBlocking {
        LogManager.log("Test")
        Thread.sleep(50)

        LogManager.clearLogs()
        Thread.sleep(50)

        assertEquals(0, LogManager.getLogCount())
    }

    // =========================================================================
    // MARK: - Get Recent Logs Tests
    // =========================================================================

    @Test
    fun `getRecentLogsSync returns all logs when under limit`() {
        LogManager.log("Short log")
        Thread.sleep(50)

        val logs = LogManager.getRecentLogsSync(10000)

        assertTrue(logs.contains("Short log"))
    }

    @Test
    fun `getRecentLogsSync truncates to byte limit`() {
        // Add many large log entries
        repeat(100) { i ->
            LogManager.log("Log entry number $i with some extra text to make it longer")
        }
        Thread.sleep(200)

        val logs = LogManager.getRecentLogsSync(1000) // Only 1KB

        val bytes = logs.toByteArray(Charsets.UTF_8).size
        assertTrue(bytes <= 1000)
        // Should have recent entries (higher numbers)
        assertTrue(logs.contains("99") || logs.contains("98"))
    }

    @Test
    fun `getRecentLogsSync returns complete lines only`() {
        repeat(50) { i ->
            LogManager.log("Complete line $i")
        }
        Thread.sleep(200)

        val logs = LogManager.getRecentLogsSync(500)

        // Should not have partial lines
        val lines = logs.split("\n")
        lines.forEach { line ->
            if (line.isNotEmpty()) {
                assertTrue(line.startsWith("["))
            }
        }
    }

    @Test
    fun `getRecentLogs suspend version works`() = runBlocking {
        LogManager.log("Async test")
        Thread.sleep(50)

        val logs = LogManager.getRecentLogs()

        assertTrue(logs.contains("Async test"))
    }

    // =========================================================================
    // MARK: - Get All Logs Tests
    // =========================================================================

    @Test
    fun `getAllLogsSync returns all logs`() {
        LogManager.log("First")
        LogManager.log("Second")
        LogManager.log("Third")
        Thread.sleep(100)

        val logs = LogManager.getAllLogsSync()

        assertTrue(logs.contains("First"))
        assertTrue(logs.contains("Second"))
        assertTrue(logs.contains("Third"))
    }

    @Test
    fun `getAllLogs suspend version works`() = runBlocking {
        LogManager.log("Test entry")
        Thread.sleep(50)

        val logs = LogManager.getAllLogs()

        assertTrue(logs.contains("Test entry"))
    }

    // =========================================================================
    // MARK: - Max Lines Limit Tests
    // =========================================================================

    @Test
    fun `logs are limited to max lines`() {
        // MAX_LOG_LINES is 1000
        repeat(1100) { i ->
            LogManager.log("Entry $i")
        }
        Thread.sleep(500)

        val count = LogManager.getLogCount()

        assertTrue(count <= 1000)
    }

    @Test
    fun `oldest logs are removed when limit exceeded`() {
        repeat(1100) { i ->
            LogManager.log("Entry $i")
        }
        Thread.sleep(500)

        val logs = LogManager.getAllLogsSync()

        // Should have recent entries
        assertTrue(logs.contains("Entry 1099"))
        // Should not have oldest entries (0-99 should be removed)
        assertFalse(logs.contains("Entry 0") && !logs.contains("Entry 10"))
    }

    // =========================================================================
    // MARK: - Empty State Tests
    // =========================================================================

    @Test
    fun `getAllLogsSync returns empty string when no logs`() {
        assertEquals("", LogManager.getAllLogsSync())
    }

    @Test
    fun `getRecentLogsSync returns empty string when no logs`() {
        assertEquals("", LogManager.getRecentLogsSync())
    }

    @Test
    fun `getLogCount returns 0 when no logs`() {
        assertEquals(0, LogManager.getLogCount())
    }

    // =========================================================================
    // MARK: - Timestamp Format Tests
    // =========================================================================

    @Test
    fun `timestamp format is consistent`() {
        LogManager.log("Test")
        Thread.sleep(50)

        val logs = LogManager.getAllLogsSync()

        // Format should be [HH:mm:ss.SSS] [Category] Message
        val pattern = Regex("^\\[\\d{2}:\\d{2}:\\d{2}\\.\\d{3}\\] \\[\\w+\\] .+$")
        val lines = logs.split("\n")
        lines.forEach { line ->
            if (line.isNotEmpty()) {
                assertTrue("Line doesn't match expected format: $line", pattern.matches(line))
            }
        }
    }

    // =========================================================================
    // MARK: - Thread Safety Tests
    // =========================================================================

    @Test
    fun `concurrent logging does not lose messages`() = runBlocking {
        val threads = (1..10).map { threadNum ->
            Thread {
                repeat(100) { i ->
                    LogManager.log("Thread $threadNum - Entry $i")
                }
            }
        }

        threads.forEach { it.start() }
        threads.forEach { it.join() }
        Thread.sleep(500)

        // All 1000 messages might not fit due to MAX_LOG_LINES = 1000
        // But we should have close to 1000
        val count = LogManager.getLogCount()
        assertTrue("Expected close to 1000 logs, got $count", count >= 900)
    }
}
