package dev.labs910.voicecode.util

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Manages the currently active session for smart speaking logic.
 * Corresponds to iOS ActiveSessionManager.swift.
 *
 * When a session is "active" (user is viewing it), responses are spoken aloud.
 * When a session is "inactive" (background), responses trigger notifications instead.
 *
 * This is a singleton to ensure consistent state across the app.
 */
object ActiveSessionManager {

    private val _activeSessionId = MutableStateFlow<String?>(null)

    /**
     * The currently active session ID (lowercase UUID), or null if no session is active.
     * Observers can collect this flow to react to active session changes.
     */
    val activeSessionId: StateFlow<String?> = _activeSessionId.asStateFlow()

    /**
     * Mark a session as active (user opened it).
     *
     * @param sessionId The session ID to mark as active (will be lowercased), or null to clear
     */
    fun setActiveSession(sessionId: String?) {
        val normalizedId = sessionId?.lowercase()
        LogManager.log("Setting active session: ${normalizedId ?: "nil"}", "ActiveSessionManager")
        _activeSessionId.value = normalizedId
    }

    /**
     * Check if a given session is currently active.
     *
     * @param sessionId The session ID to check
     * @return True if this session is the currently active one
     */
    fun isActive(sessionId: String): Boolean {
        return _activeSessionId.value == sessionId.lowercase()
    }

    /**
     * Clear active session (user closed all sessions or navigated away).
     */
    fun clearActiveSession() {
        LogManager.log("Clearing active session", "ActiveSessionManager")
        _activeSessionId.value = null
    }

    /**
     * Get the current active session ID synchronously.
     *
     * @return The active session ID or null if none is active
     */
    fun getActiveSessionId(): String? = _activeSessionId.value
}
