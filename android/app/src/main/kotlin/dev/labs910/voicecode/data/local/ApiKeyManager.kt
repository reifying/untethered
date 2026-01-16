package dev.labs910.voicecode.data.local

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * Secure storage for API key using EncryptedSharedPreferences.
 * Equivalent to iOS KeychainManager.
 *
 * API key format: "untethered-" prefix followed by 32 lowercase hex characters (43 chars total).
 */
class ApiKeyManager(context: Context) {
    companion object {
        private const val PREFS_NAME = "voice_code_secure_prefs"
        private const val KEY_API_KEY = "api_key"
        private const val API_KEY_PREFIX = "untethered-"
        private const val API_KEY_TOTAL_LENGTH = 43 // "untethered-" (11) + 32 hex chars
        private const val HEX_CHARS = "0123456789abcdef"
    }

    private val masterKey = MasterKey.Builder(context)
        .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
        .build()

    private val prefs: SharedPreferences = EncryptedSharedPreferences.create(
        context,
        PREFS_NAME,
        masterKey,
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
    )

    /**
     * Check if an API key is stored.
     */
    fun hasApiKey(): Boolean {
        return prefs.contains(KEY_API_KEY)
    }

    /**
     * Get the stored API key.
     * Returns null if no key is stored.
     */
    fun getApiKey(): String? {
        return prefs.getString(KEY_API_KEY, null)
    }

    /**
     * Store an API key securely.
     *
     * @param apiKey The API key to store
     * @return true if the key was valid and stored, false if validation failed
     */
    fun setApiKey(apiKey: String): Boolean {
        if (!isValidApiKey(apiKey)) {
            return false
        }

        // Normalize to lowercase
        val normalizedKey = apiKey.lowercase()

        prefs.edit()
            .putString(KEY_API_KEY, normalizedKey)
            .apply()

        return true
    }

    /**
     * Delete the stored API key.
     */
    fun deleteApiKey() {
        prefs.edit()
            .remove(KEY_API_KEY)
            .apply()
    }

    /**
     * Validate an API key format.
     *
     * Format: "untethered-" prefix + 32 lowercase hex characters
     * Total length: 43 characters
     */
    fun isValidApiKey(apiKey: String): Boolean {
        val key = apiKey.lowercase()

        // Check length
        if (key.length != API_KEY_TOTAL_LENGTH) {
            return false
        }

        // Check prefix
        if (!key.startsWith(API_KEY_PREFIX)) {
            return false
        }

        // Check hex suffix
        val hexPart = key.substring(API_KEY_PREFIX.length)
        return hexPart.all { it in HEX_CHARS }
    }

    /**
     * Format an API key as Bearer token for HTTP Authorization header.
     */
    fun getBearerToken(): String? {
        return getApiKey()?.let { "Bearer $it" }
    }
}
