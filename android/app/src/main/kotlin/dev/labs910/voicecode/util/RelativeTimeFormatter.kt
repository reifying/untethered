package dev.labs910.voicecode.util

import java.time.Duration
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * Utilities for formatting relative time text.
 * Corresponds to iOS Date.relativeFormatted() extension and RelativeTimeText view.
 *
 * Formats timestamps as:
 * - "just now" for < 60 seconds ago
 * - "X minutes ago" for < 60 minutes ago
 * - "X hours ago" for < 24 hours ago
 * - "X days ago" for < 7 days ago
 * - Formatted date for >= 7 days ago
 */
object RelativeTimeFormatter {

    private const val SECONDS_PER_MINUTE = 60L
    private const val SECONDS_PER_HOUR = 3600L
    private const val SECONDS_PER_DAY = 86400L
    private const val DAYS_THRESHOLD = 7L

    private val dateFormatter = DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)

    /**
     * Format an Instant as relative time text.
     *
     * @param instant The timestamp to format
     * @param now Reference time (default: current time)
     * @return Human-readable relative time string
     */
    fun format(instant: Instant, now: Instant = Instant.now()): String {
        val secondsAgo = Duration.between(instant, now).seconds

        return when {
            secondsAgo < SECONDS_PER_MINUTE -> "just now"
            secondsAgo < SECONDS_PER_HOUR -> {
                val minutes = secondsAgo / SECONDS_PER_MINUTE
                if (minutes == 1L) "1 minute ago" else "$minutes minutes ago"
            }
            secondsAgo < SECONDS_PER_DAY -> {
                val hours = secondsAgo / SECONDS_PER_HOUR
                if (hours == 1L) "1 hour ago" else "$hours hours ago"
            }
            secondsAgo < SECONDS_PER_DAY * DAYS_THRESHOLD -> {
                val days = secondsAgo / SECONDS_PER_DAY
                if (days == 1L) "1 day ago" else "$days days ago"
            }
            else -> {
                val localDateTime = LocalDateTime.ofInstant(instant, ZoneId.systemDefault())
                localDateTime.format(dateFormatter)
            }
        }
    }

    /**
     * Format a timestamp in milliseconds as relative time text.
     *
     * @param timestampMillis The timestamp in milliseconds since epoch
     * @param nowMillis Reference time in milliseconds (default: current time)
     * @return Human-readable relative time string
     */
    fun format(timestampMillis: Long, nowMillis: Long = System.currentTimeMillis()): String {
        return format(
            Instant.ofEpochMilli(timestampMillis),
            Instant.ofEpochMilli(nowMillis)
        )
    }

    /**
     * Check if a timestamp is within the relative time threshold (< 7 days).
     *
     * @param instant The timestamp to check
     * @param now Reference time (default: current time)
     * @return True if the timestamp should be displayed as relative time
     */
    fun isRecent(instant: Instant, now: Instant = Instant.now()): Boolean {
        val secondsAgo = Duration.between(instant, now).seconds
        return secondsAgo < SECONDS_PER_DAY * DAYS_THRESHOLD
    }
}
