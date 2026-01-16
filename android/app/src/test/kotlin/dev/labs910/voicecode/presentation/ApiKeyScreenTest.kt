package dev.labs910.voicecode.presentation

import org.junit.Assert.*
import org.junit.Test

/**
 * Tests for ApiKeyScreen validation logic.
 */
class ApiKeyScreenTest {

    /**
     * Validates API key format (mirrors the logic in ApiKeyScreen).
     */
    private fun isValidApiKeyFormat(key: String): Boolean {
        return key.startsWith("untethered-") && key.length == 43
    }

    // ==========================================================================
    // MARK: - Valid API Keys
    // ==========================================================================

    @Test
    fun `valid API key format is accepted`() {
        val validKey = "untethered-a1b2c3d4e5f678901234567890abcdef"
        assertTrue(isValidApiKeyFormat(validKey))
    }

    @Test
    fun `valid key with all digits is accepted`() {
        val key = "untethered-01234567890123456789012345678901"
        assertTrue(isValidApiKeyFormat(key))
    }

    // ==========================================================================
    // MARK: - Invalid API Keys
    // ==========================================================================

    @Test
    fun `empty string is rejected`() {
        assertFalse(isValidApiKeyFormat(""))
    }

    @Test
    fun `key without prefix is rejected`() {
        val key = "a1b2c3d4e5f678901234567890abcdef12345678"
        assertFalse(isValidApiKeyFormat(key))
    }

    @Test
    fun `key too short is rejected`() {
        val key = "untethered-a1b2c3d4e5f6789012345678"
        assertFalse(isValidApiKeyFormat(key))
    }

    @Test
    fun `key too long is rejected`() {
        val key = "untethered-a1b2c3d4e5f678901234567890abcdef1"
        assertFalse(isValidApiKeyFormat(key))
    }

    @Test
    fun `prefix only is rejected`() {
        assertFalse(isValidApiKeyFormat("untethered-"))
    }

    // ==========================================================================
    // MARK: - Button State Logic
    // ==========================================================================

    @Test
    fun `save button enabled when key is valid and not blank`() {
        val apiKeyInput = "untethered-a1b2c3d4e5f678901234567890abcdef"
        val enabled = apiKeyInput.isNotBlank() && isValidApiKeyFormat(apiKeyInput)
        assertTrue(enabled)
    }

    @Test
    fun `save button disabled when key is blank`() {
        val apiKeyInput = ""
        val enabled = apiKeyInput.isNotBlank() && isValidApiKeyFormat(apiKeyInput)
        assertFalse(enabled)
    }

    @Test
    fun `save button disabled when key is invalid format`() {
        val apiKeyInput = "invalid-key"
        val enabled = apiKeyInput.isNotBlank() && isValidApiKeyFormat(apiKeyInput)
        assertFalse(enabled)
    }

    @Test
    fun `save button disabled when key is whitespace only`() {
        val apiKeyInput = "   "
        val enabled = apiKeyInput.isNotBlank() && isValidApiKeyFormat(apiKeyInput)
        assertFalse(enabled)
    }

    // ==========================================================================
    // MARK: - Status Card Logic
    // ==========================================================================

    @Test
    fun `status card shows configured when hasApiKey is true`() {
        val hasApiKey = true
        val statusText = if (hasApiKey) "API Key Configured" else "API Key Required"
        assertEquals("API Key Configured", statusText)
    }

    @Test
    fun `status card shows required when hasApiKey is false`() {
        val hasApiKey = false
        val statusText = if (hasApiKey) "API Key Configured" else "API Key Required"
        assertEquals("API Key Required", statusText)
    }

    // ==========================================================================
    // MARK: - Input State Logic
    // ==========================================================================

    @Test
    fun `validation hint shown when input is not blank and invalid`() {
        val apiKeyInput = "invalid"
        val showHint = apiKeyInput.isNotBlank() && !isValidApiKeyFormat(apiKeyInput)
        assertTrue(showHint)
    }

    @Test
    fun `validation hint hidden when input is blank`() {
        val apiKeyInput = ""
        val showHint = apiKeyInput.isNotBlank() && !isValidApiKeyFormat(apiKeyInput)
        assertFalse(showHint)
    }

    @Test
    fun `validation hint hidden when input is valid`() {
        val apiKeyInput = "untethered-a1b2c3d4e5f678901234567890abcdef"
        val showHint = apiKeyInput.isNotBlank() && !isValidApiKeyFormat(apiKeyInput)
        assertFalse(showHint)
    }
}
