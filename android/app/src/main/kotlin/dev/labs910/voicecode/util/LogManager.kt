package dev.labs910.voicecode.util

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Captures and manages app logs for debugging.
 * Corresponds to iOS LogManager.swift.
 *
 * Key features:
 * - Thread-safe log capture with coroutine mutex
 * - Configurable max lines (default 1000)
 * - Size-limited retrieval for efficient transmission
 * - Timestamp formatting consistent with iOS
 */
object LogManager {

    private const val MAX_LOG_LINES = 1000
    private const val DEFAULT_MAX_BYTES = 15_000

    private val logLines = CopyOnWriteArrayList<String>()
    private val mutex = Mutex()
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    private val timestampFormat = SimpleDateFormat("HH:mm:ss.SSS", Locale.US).apply {
        timeZone = TimeZone.getDefault()
    }

    /**
     * Append a log message.
     *
     * @param message The log message
     * @param category Log category (default "General")
     */
    fun log(message: String, category: String = "General") {
        scope.launch {
            mutex.withLock {
                val timestamp = timestampFormat.format(Date())
                val logLine = "[$timestamp] [$category] $message"
                logLines.add(logLine)

                // Keep only last N lines
                while (logLines.size > MAX_LOG_LINES) {
                    logLines.removeAt(0)
                }
            }
        }
    }

    /**
     * Convenience method for logging with different levels.
     */
    fun debug(message: String, category: String = "Debug") = log(message, category)
    fun info(message: String, category: String = "Info") = log(message, category)
    fun warn(message: String, category: String = "Warning") = log(message, category)
    fun error(message: String, category: String = "Error") = log(message, category)

    /**
     * Get the last N bytes worth of logs (complete lines only).
     *
     * @param maxBytes Maximum bytes to return (default 15KB)
     * @return Recent log lines joined by newlines
     */
    suspend fun getRecentLogs(maxBytes: Int = DEFAULT_MAX_BYTES): String {
        return withContext(Dispatchers.IO) {
            mutex.withLock {
                val allLogs = logLines.joinToString("\n")

                // If total size is under limit, return all
                val totalBytes = allLogs.toByteArray(Charsets.UTF_8).size
                if (totalBytes <= maxBytes) {
                    return@withLock allLogs
                }

                // Find the cutoff point to stay under maxBytes
                // Start from the end and work backwards
                var currentBytes = 0
                val includedLines = mutableListOf<String>()

                for (line in logLines.reversed()) {
                    val lineBytes = (line + "\n").toByteArray(Charsets.UTF_8).size
                    if (currentBytes + lineBytes > maxBytes) {
                        break
                    }
                    currentBytes += lineBytes
                    includedLines.add(0, line)
                }

                includedLines.joinToString("\n")
            }
        }
    }

    /**
     * Get the last N bytes worth of logs synchronously (for non-coroutine contexts).
     * Less efficient than the suspend version - use suspend version when possible.
     *
     * @param maxBytes Maximum bytes to return (default 15KB)
     * @return Recent log lines joined by newlines
     */
    fun getRecentLogsSync(maxBytes: Int = DEFAULT_MAX_BYTES): String {
        val allLogs = logLines.joinToString("\n")

        // If total size is under limit, return all
        val totalBytes = allLogs.toByteArray(Charsets.UTF_8).size
        if (totalBytes <= maxBytes) {
            return allLogs
        }

        // Find the cutoff point to stay under maxBytes
        var currentBytes = 0
        val includedLines = mutableListOf<String>()

        for (line in logLines.reversed()) {
            val lineBytes = (line + "\n").toByteArray(Charsets.UTF_8).size
            if (currentBytes + lineBytes > maxBytes) {
                break
            }
            currentBytes += lineBytes
            includedLines.add(0, line)
        }

        return includedLines.joinToString("\n")
    }

    /**
     * Get all captured logs.
     *
     * @return All log lines joined by newlines
     */
    suspend fun getAllLogs(): String {
        return withContext(Dispatchers.IO) {
            mutex.withLock {
                logLines.joinToString("\n")
            }
        }
    }

    /**
     * Get all captured logs synchronously.
     *
     * @return All log lines joined by newlines
     */
    fun getAllLogsSync(): String {
        return logLines.joinToString("\n")
    }

    /**
     * Clear all logs.
     */
    fun clearLogs() {
        scope.launch {
            mutex.withLock {
                logLines.clear()
            }
        }
    }

    /**
     * Clear all logs synchronously.
     */
    fun clearLogsSync() {
        logLines.clear()
    }

    /**
     * Get the current number of log lines.
     *
     * @return Number of stored log lines
     */
    fun getLogCount(): Int = logLines.size
}
