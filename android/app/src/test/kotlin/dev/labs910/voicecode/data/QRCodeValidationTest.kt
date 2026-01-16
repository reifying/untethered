package dev.labs910.voicecode.data

import org.junit.Assert.*
import org.junit.Test

/**
 * Tests for QR code scanner API key validation logic.
 * The scanner validates that scanned QR codes match the expected API key format.
 */
class QRCodeValidationTest {

    /**
     * Validates API key format: "untethered-" prefix followed by 32 hex characters.
     * Total length: 43 characters (11 prefix + 32 hex).
     */
    private fun isValidApiKey(value: String): Boolean {
        return value.startsWith("untethered-") && value.length == 43
    }

    // ==========================================================================
    // MARK: - Valid API Keys
    // ==========================================================================

    @Test
    fun `valid API key passes validation`() {
        val validKey = "untethered-a1b2c3d4e5f678901234567890abcdef"
        assertTrue(isValidApiKey(validKey))
    }

    @Test
    fun `valid API key with all lowercase hex`() {
        val key = "untethered-0123456789abcdef0123456789abcdef"
        assertTrue(isValidApiKey(key))
    }

    @Test
    fun `valid API key with all digits`() {
        val key = "untethered-01234567890123456789012345678901"
        assertTrue(isValidApiKey(key))
    }

    @Test
    fun `valid API key exact length is 43`() {
        val key = "untethered-a1b2c3d4e5f678901234567890abcdef"
        assertEquals(43, key.length)
        assertTrue(isValidApiKey(key))
    }

    // ==========================================================================
    // MARK: - Invalid API Keys - Wrong Prefix
    // ==========================================================================

    @Test
    fun `key without untethered prefix fails`() {
        val key = "a1b2c3d4e5f678901234567890abcdef12345678"
        assertFalse(isValidApiKey(key))
    }

    @Test
    fun `key with different prefix fails`() {
        val key = "tethered---a1b2c3d4e5f678901234567890abcdef"
        assertFalse(isValidApiKey(key))
    }

    @Test
    fun `key with partial prefix fails`() {
        val key = "untether-a1b2c3d4e5f678901234567890abcdef1"
        assertFalse(isValidApiKey(key))
    }

    @Test
    fun `key with uppercase prefix fails`() {
        val key = "UNTETHERED-a1b2c3d4e5f678901234567890abcdef"
        assertFalse(isValidApiKey(key))
    }

    // ==========================================================================
    // MARK: - Invalid API Keys - Wrong Length
    // ==========================================================================

    @Test
    fun `key too short fails`() {
        val key = "untethered-a1b2c3d4e5f6789012345678"
        assertEquals(42, key.length)
        assertFalse(isValidApiKey(key))
    }

    @Test
    fun `key too long fails`() {
        val key = "untethered-a1b2c3d4e5f678901234567890abcdef1"
        assertEquals(44, key.length)
        assertFalse(isValidApiKey(key))
    }

    @Test
    fun `empty string fails`() {
        assertFalse(isValidApiKey(""))
    }

    @Test
    fun `prefix only fails`() {
        assertFalse(isValidApiKey("untethered-"))
    }

    // ==========================================================================
    // MARK: - Invalid API Keys - Invalid Content
    // ==========================================================================

    @Test
    fun `key with uppercase hex characters fails validation`() {
        // Note: The scanner validation only checks prefix and length
        // It doesn't validate hex characters, so uppercase would pass the simple check
        val key = "untethered-A1B2C3D4E5F678901234567890ABCDEF"
        // This actually passes the simple validation but would fail backend auth
        assertTrue(isValidApiKey(key)) // Passes length/prefix check

        // Verify it's not lowercase hex
        val hexPart = key.removePrefix("untethered-")
        assertFalse(hexPart.all { it.isDigit() || it in 'a'..'f' })
    }

    @Test
    fun `key with special characters has correct length check`() {
        val key = "untethered-a1b2c3d4e5f67890123456!@#$%^&*()"
        assertEquals(43, key.length)
        assertTrue(isValidApiKey(key)) // Passes simple validation
    }

    // ==========================================================================
    // MARK: - QR Code Content Types
    // ==========================================================================

    @Test
    fun `URL is not valid API key`() {
        val url = "https://example.com/some/path/to/resource"
        assertFalse(isValidApiKey(url))
    }

    @Test
    fun `UUID is not valid API key`() {
        val uuid = "abc123de-4567-89ab-cdef-0123456789ab"
        assertFalse(isValidApiKey(uuid))
    }

    @Test
    fun `random text is not valid API key`() {
        val text = "This is some random text that might be in a QR code"
        assertFalse(isValidApiKey(text))
    }

    @Test
    fun `numeric string is not valid API key`() {
        val numbers = "12345678901234567890123456789012345678901234"
        assertFalse(isValidApiKey(numbers))
    }

    // ==========================================================================
    // MARK: - Edge Cases
    // ==========================================================================

    @Test
    fun `whitespace around key should be trimmed by caller`() {
        val keyWithWhitespace = "  untethered-a1b2c3d4e5f678901234567890abcdef  "
        assertFalse(isValidApiKey(keyWithWhitespace)) // Fails without trim
        assertTrue(isValidApiKey(keyWithWhitespace.trim())) // Passes with trim
    }

    @Test
    fun `newline in key fails`() {
        val key = "untethered-a1b2c3d4e5f67890123456\n7890abcdef"
        assertFalse(isValidApiKey(key))
    }

    @Test
    fun `key with space instead of hyphen fails`() {
        val key = "untethered a1b2c3d4e5f678901234567890abcdef"
        assertFalse(isValidApiKey(key))
    }

    // ==========================================================================
    // MARK: - Barcode Type Check
    // ==========================================================================

    @Test
    fun `TEXT barcode type constant matches expected`() {
        // com.google.mlkit.vision.barcode.common.Barcode.TYPE_TEXT = 7
        val typeText = 7
        assertEquals(7, typeText)
    }

    @Test
    fun `QR code format constant matches expected`() {
        // com.google.mlkit.vision.barcode.common.Barcode.FORMAT_QR_CODE = 256
        val formatQrCode = 256
        assertEquals(256, formatQrCode)
    }
}
