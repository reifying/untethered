package dev.labs910.voicecode.util

import org.junit.Assert.*
import org.junit.Test

/**
 * Tests for API key validation.
 * Verifies format requirements from STANDARDS.md:
 * - Prefix: "untethered-"
 * - Suffix: 32 lowercase hex characters
 * - Total length: 43 characters
 */
class ApiKeyValidationTest {

    companion object {
        private const val API_KEY_PREFIX = "untethered-"
        private const val API_KEY_TOTAL_LENGTH = 43
        private const val HEX_CHARS = "0123456789abcdef"
    }

    /**
     * Validate an API key format (standalone function for testing without Context).
     */
    private fun isValidApiKey(apiKey: String): Boolean {
        val key = apiKey.lowercase()

        if (key.length != API_KEY_TOTAL_LENGTH) {
            return false
        }

        if (!key.startsWith(API_KEY_PREFIX)) {
            return false
        }

        val hexPart = key.substring(API_KEY_PREFIX.length)
        return hexPart.all { it in HEX_CHARS }
    }

    @Test
    fun `valid API key is accepted`() {
        val validKey = "untethered-a1b2c3d4e5f678901234567890abcdef"
        assertTrue(isValidApiKey(validKey))
    }

    @Test
    fun `valid API key with uppercase is accepted and normalized`() {
        val uppercaseKey = "UNTETHERED-A1B2C3D4E5F678901234567890ABCDEF"
        assertTrue(isValidApiKey(uppercaseKey))
    }

    @Test
    fun `API key without prefix is rejected`() {
        val noPrefix = "a1b2c3d4e5f678901234567890abcdef"
        assertFalse(isValidApiKey(noPrefix))
    }

    @Test
    fun `API key with wrong prefix is rejected`() {
        val wrongPrefix = "untether-a1b2c3d4e5f678901234567890abcdefab"
        assertFalse(isValidApiKey(wrongPrefix))
    }

    @Test
    fun `API key that is too short is rejected`() {
        val tooShort = "untethered-a1b2c3d4e5f6789012345678"
        assertFalse(isValidApiKey(tooShort))
    }

    @Test
    fun `API key that is too long is rejected`() {
        val tooLong = "untethered-a1b2c3d4e5f678901234567890abcdefabc"
        assertFalse(isValidApiKey(tooLong))
    }

    @Test
    fun `API key with non-hex characters is rejected`() {
        val nonHex = "untethered-g1b2c3d4e5f678901234567890abcdef"
        assertFalse(isValidApiKey(nonHex))
    }

    @Test
    fun `API key with spaces is rejected`() {
        val withSpaces = "untethered-a1b2c3d4 5f678901234567890abcdef"
        assertFalse(isValidApiKey(withSpaces))
    }

    @Test
    fun `empty string is rejected`() {
        assertFalse(isValidApiKey(""))
    }

    @Test
    fun `prefix only is rejected`() {
        assertFalse(isValidApiKey("untethered-"))
    }

    @Test
    fun `all zeros hex is valid`() {
        val allZeros = "untethered-00000000000000000000000000000000"
        assertTrue(isValidApiKey(allZeros))
    }

    @Test
    fun `all letters hex is valid`() {
        val allLetters = "untethered-abcdefabcdefabcdefabcdefabcdefab"
        assertTrue(isValidApiKey(allLetters))
    }

    @Test
    fun `mixed case hex is valid`() {
        val mixedCase = "untethered-AbCdEf0123456789AbCdEf0123456789"
        assertTrue(isValidApiKey(mixedCase))
    }
}
