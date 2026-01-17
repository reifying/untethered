package dev.labs910.voicecode.util

import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.temporal.ChronoUnit

/**
 * Tests for RelativeTimeFormatter utility.
 * Mirrors iOS RelativeTimeTextTests.swift.
 */
class RelativeTimeFormatterTest {

    // =========================================================================
    // MARK: - "Just Now" Tests
    // =========================================================================

    @Test
    fun `format returns just now for 0 seconds ago`() {
        val now = Instant.now()

        val result = RelativeTimeFormatter.format(now, now)

        assertEquals("just now", result)
    }

    @Test
    fun `format returns just now for 30 seconds ago`() {
        val now = Instant.now()
        val justNow = now.minusSeconds(30)

        val result = RelativeTimeFormatter.format(justNow, now)

        assertEquals("just now", result)
    }

    @Test
    fun `format returns just now for 59 seconds ago`() {
        val now = Instant.now()
        val almostMinute = now.minusSeconds(59)

        val result = RelativeTimeFormatter.format(almostMinute, now)

        assertEquals("just now", result)
    }

    // =========================================================================
    // MARK: - Minutes Tests
    // =========================================================================

    @Test
    fun `format returns 1 minute ago for 60 seconds ago`() {
        val now = Instant.now()
        val oneMinuteAgo = now.minusSeconds(60)

        val result = RelativeTimeFormatter.format(oneMinuteAgo, now)

        assertEquals("1 minute ago", result)
    }

    @Test
    fun `format returns 1 minute ago for 65 seconds ago`() {
        val now = Instant.now()
        val oneMinuteAgo = now.minusSeconds(65)

        val result = RelativeTimeFormatter.format(oneMinuteAgo, now)

        assertEquals("1 minute ago", result)
    }

    @Test
    fun `format returns 2 minutes ago for 120 seconds ago`() {
        val now = Instant.now()
        val twoMinutesAgo = now.minusSeconds(120)

        val result = RelativeTimeFormatter.format(twoMinutesAgo, now)

        assertEquals("2 minutes ago", result)
    }

    @Test
    fun `format returns 59 minutes ago for 59 minutes`() {
        val now = Instant.now()
        val fiftyNineMinutesAgo = now.minus(59, ChronoUnit.MINUTES)

        val result = RelativeTimeFormatter.format(fiftyNineMinutesAgo, now)

        assertEquals("59 minutes ago", result)
    }

    // =========================================================================
    // MARK: - Hours Tests
    // =========================================================================

    @Test
    fun `format returns 1 hour ago for 60 minutes`() {
        val now = Instant.now()
        val oneHourAgo = now.minus(60, ChronoUnit.MINUTES)

        val result = RelativeTimeFormatter.format(oneHourAgo, now)

        assertEquals("1 hour ago", result)
    }

    @Test
    fun `format returns 3 hours ago for 3 hours`() {
        val now = Instant.now()
        val threeHoursAgo = now.minus(3, ChronoUnit.HOURS)

        val result = RelativeTimeFormatter.format(threeHoursAgo, now)

        assertEquals("3 hours ago", result)
    }

    @Test
    fun `format returns 23 hours ago for 23 hours`() {
        val now = Instant.now()
        val twentyThreeHoursAgo = now.minus(23, ChronoUnit.HOURS)

        val result = RelativeTimeFormatter.format(twentyThreeHoursAgo, now)

        assertEquals("23 hours ago", result)
    }

    // =========================================================================
    // MARK: - Days Tests
    // =========================================================================

    @Test
    fun `format returns 1 day ago for 24 hours`() {
        val now = Instant.now()
        val oneDayAgo = now.minus(24, ChronoUnit.HOURS)

        val result = RelativeTimeFormatter.format(oneDayAgo, now)

        assertEquals("1 day ago", result)
    }

    @Test
    fun `format returns 2 days ago for 48 hours`() {
        val now = Instant.now()
        val twoDaysAgo = now.minus(2, ChronoUnit.DAYS)

        val result = RelativeTimeFormatter.format(twoDaysAgo, now)

        assertEquals("2 days ago", result)
    }

    @Test
    fun `format returns 6 days ago for 6 days`() {
        val now = Instant.now()
        val sixDaysAgo = now.minus(6, ChronoUnit.DAYS)

        val result = RelativeTimeFormatter.format(sixDaysAgo, now)

        assertEquals("6 days ago", result)
    }

    // =========================================================================
    // MARK: - Date Format Tests (7+ days)
    // =========================================================================

    @Test
    fun `format returns date format for 7 days ago`() {
        val now = Instant.now()
        val sevenDaysAgo = now.minus(7, ChronoUnit.DAYS)

        val result = RelativeTimeFormatter.format(sevenDaysAgo, now)

        // Should not contain "day" since it's at the threshold
        assertFalse(result.contains("day"))
        // Should have some formatted date content
        assertTrue(result.isNotEmpty())
    }

    @Test
    fun `format returns date format for 10 days ago`() {
        val now = Instant.now()
        val tenDaysAgo = now.minus(10, ChronoUnit.DAYS)

        val result = RelativeTimeFormatter.format(tenDaysAgo, now)

        assertFalse(result.contains("day"))
        assertTrue(result.isNotEmpty())
    }

    @Test
    fun `format returns date format for 30 days ago`() {
        val now = Instant.now()
        val thirtyDaysAgo = now.minus(30, ChronoUnit.DAYS)

        val result = RelativeTimeFormatter.format(thirtyDaysAgo, now)

        assertFalse(result.contains("ago"))
        assertTrue(result.isNotEmpty())
    }

    // =========================================================================
    // MARK: - isRecent Tests
    // =========================================================================

    @Test
    fun `isRecent returns true for just now`() {
        val now = Instant.now()

        assertTrue(RelativeTimeFormatter.isRecent(now, now))
    }

    @Test
    fun `isRecent returns true for 6 days ago`() {
        val now = Instant.now()
        val sixDaysAgo = now.minus(6, ChronoUnit.DAYS)

        assertTrue(RelativeTimeFormatter.isRecent(sixDaysAgo, now))
    }

    @Test
    fun `isRecent returns false for 7 days ago`() {
        val now = Instant.now()
        val sevenDaysAgo = now.minus(7, ChronoUnit.DAYS)

        assertFalse(RelativeTimeFormatter.isRecent(sevenDaysAgo, now))
    }

    @Test
    fun `isRecent returns false for 30 days ago`() {
        val now = Instant.now()
        val thirtyDaysAgo = now.minus(30, ChronoUnit.DAYS)

        assertFalse(RelativeTimeFormatter.isRecent(thirtyDaysAgo, now))
    }

    // =========================================================================
    // MARK: - Milliseconds Overload Tests
    // =========================================================================

    @Test
    fun `format with milliseconds works correctly`() {
        val nowMillis = System.currentTimeMillis()
        val fiveMinutesAgoMillis = nowMillis - (5 * 60 * 1000)

        val result = RelativeTimeFormatter.format(fiveMinutesAgoMillis, nowMillis)

        assertEquals("5 minutes ago", result)
    }

    @Test
    fun `format with milliseconds handles hours`() {
        val nowMillis = System.currentTimeMillis()
        val twoHoursAgoMillis = nowMillis - (2 * 60 * 60 * 1000)

        val result = RelativeTimeFormatter.format(twoHoursAgoMillis, nowMillis)

        assertEquals("2 hours ago", result)
    }

    // =========================================================================
    // MARK: - Edge Cases
    // =========================================================================

    @Test
    fun `format handles boundary between minutes and hours`() {
        val now = Instant.now()
        val fiftyNineMinutes = now.minus(59, ChronoUnit.MINUTES)
        val sixtyMinutes = now.minus(60, ChronoUnit.MINUTES)

        assertEquals("59 minutes ago", RelativeTimeFormatter.format(fiftyNineMinutes, now))
        assertEquals("1 hour ago", RelativeTimeFormatter.format(sixtyMinutes, now))
    }

    @Test
    fun `format handles boundary between hours and days`() {
        val now = Instant.now()
        val twentyThreeHours = now.minus(23, ChronoUnit.HOURS)
        val twentyFourHours = now.minus(24, ChronoUnit.HOURS)

        assertEquals("23 hours ago", RelativeTimeFormatter.format(twentyThreeHours, now))
        assertEquals("1 day ago", RelativeTimeFormatter.format(twentyFourHours, now))
    }

    @Test
    fun `format handles boundary between days and date format`() {
        val now = Instant.now()
        val sixDays = now.minus(6, ChronoUnit.DAYS)
        val sevenDays = now.minus(7, ChronoUnit.DAYS)

        assertTrue(RelativeTimeFormatter.format(sixDays, now).contains("day"))
        assertFalse(RelativeTimeFormatter.format(sevenDays, now).contains("day"))
    }
}
