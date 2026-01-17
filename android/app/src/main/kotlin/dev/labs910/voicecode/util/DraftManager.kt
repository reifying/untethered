package dev.labs910.voicecode.util

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Manages draft prompt text persistence across app lifecycle.
 * Corresponds to iOS DraftManager.swift.
 *
 * Key features:
 * - Persists drafts in SharedPreferences
 * - Debounces writes to avoid conflicts during rapid typing
 * - Thread-safe access with coroutines
 */
class DraftManager(context: Context) {

    companion object {
        private const val PREFS_NAME = "session_drafts"
        private const val DEBOUNCE_DELAY_MS = 300L
    }

    private val prefs: SharedPreferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    // In-memory cache of drafts
    private val drafts = mutableMapOf<String, String>()

    // Debounce job for saving
    private var saveJob: Job? = null

    // State flow to notify observers when drafts change (optional)
    private val _draftCount = MutableStateFlow(0)
    val draftCount: StateFlow<Int> = _draftCount.asStateFlow()

    init {
        // Load all drafts from SharedPreferences
        loadDrafts()
    }

    private fun loadDrafts() {
        val allPrefs = prefs.all
        drafts.clear()
        allPrefs.forEach { (key, value) ->
            if (value is String && value.isNotEmpty()) {
                drafts[key] = value
            }
        }
        _draftCount.value = drafts.size
    }

    /**
     * Save draft text for a session. Removes entry if text is empty.
     *
     * @param sessionId The session ID (lowercase UUID)
     * @param text The draft text to save
     */
    fun saveDraft(sessionId: String, text: String) {
        val normalizedId = sessionId.lowercase()

        if (text.isEmpty()) {
            drafts.remove(normalizedId)
        } else {
            drafts[normalizedId] = text
        }
        _draftCount.value = drafts.size

        // Debounce SharedPreferences writes to avoid conflicts during rapid typing
        saveJob?.cancel()
        saveJob = scope.launch {
            delay(DEBOUNCE_DELAY_MS)
            persistDrafts()
        }
    }

    /**
     * Get draft text for a session.
     *
     * @param sessionId The session ID (lowercase UUID)
     * @return The draft text, or empty string if no draft exists
     */
    fun getDraft(sessionId: String): String {
        return drafts[sessionId.lowercase()] ?: ""
    }

    /**
     * Check if a session has a draft.
     *
     * @param sessionId The session ID (lowercase UUID)
     * @return True if a non-empty draft exists
     */
    fun hasDraft(sessionId: String): Boolean {
        return drafts[sessionId.lowercase()]?.isNotEmpty() == true
    }

    /**
     * Clear draft for a session (e.g., after sending prompt).
     *
     * @param sessionId The session ID to clear
     */
    fun clearDraft(sessionId: String) {
        val normalizedId = sessionId.lowercase()
        drafts.remove(normalizedId)
        _draftCount.value = drafts.size

        // Immediately persist the removal
        scope.launch {
            prefs.edit().remove(normalizedId).apply()
        }
    }

    /**
     * Remove draft for a deleted session (cleanup).
     *
     * @param sessionId The session ID to clean up
     */
    fun cleanupDraft(sessionId: String) {
        clearDraft(sessionId)
    }

    /**
     * Get all session IDs that have drafts.
     *
     * @return Set of session IDs with non-empty drafts
     */
    fun getSessionsWithDrafts(): Set<String> {
        return drafts.keys.toSet()
    }

    /**
     * Clear all drafts.
     */
    fun clearAllDrafts() {
        drafts.clear()
        _draftCount.value = 0

        scope.launch {
            prefs.edit().clear().apply()
        }
    }

    private fun persistDrafts() {
        val editor = prefs.edit()

        // Clear and rewrite all drafts
        editor.clear()
        drafts.forEach { (sessionId, text) ->
            editor.putString(sessionId, text)
        }
        editor.apply()
    }

    /**
     * Clean up resources when no longer needed.
     */
    fun destroy() {
        saveJob?.cancel()
        scope.cancel()
    }
}
