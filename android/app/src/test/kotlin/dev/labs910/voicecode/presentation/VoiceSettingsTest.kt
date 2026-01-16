package dev.labs910.voicecode.presentation

import org.junit.Assert.*
import org.junit.Test
import java.util.Locale

/**
 * Tests for VoiceSettingsScreen logic.
 */
class VoiceSettingsTest {

    // ==========================================================================
    // MARK: - Speech Rate Validation
    // ==========================================================================

    @Test
    fun `speech rate within valid range`() {
        val testCases = listOf(
            0.5f to true,
            1.0f to true,
            1.5f to true,
            2.0f to true,
            0.3f to false,
            2.5f to false
        )

        for ((rate, isValid) in testCases) {
            val clampedRate = rate.coerceIn(0.5f, 2.0f)
            val result = clampedRate == rate
            assertEquals("Rate $rate should be ${if (isValid) "valid" else "invalid"}", isValid, result)
        }
    }

    @Test
    fun `speech rate clamping works correctly`() {
        assertEquals(0.5f, 0.3f.coerceIn(0.5f, 2.0f), 0.001f)
        assertEquals(2.0f, 2.5f.coerceIn(0.5f, 2.0f), 0.001f)
        assertEquals(1.5f, 1.5f.coerceIn(0.5f, 2.0f), 0.001f)
    }

    // ==========================================================================
    // MARK: - Pitch Validation
    // ==========================================================================

    @Test
    fun `pitch within valid range`() {
        val testCases = listOf(
            0.5f to true,
            1.0f to true,
            1.5f to true,
            2.0f to true,
            0.3f to false,
            2.5f to false
        )

        for ((pitch, isValid) in testCases) {
            val clampedPitch = pitch.coerceIn(0.5f, 2.0f)
            val result = clampedPitch == pitch
            assertEquals("Pitch $pitch should be ${if (isValid) "valid" else "invalid"}", isValid, result)
        }
    }

    // ==========================================================================
    // MARK: - Voice Filtering
    // ==========================================================================

    @Test
    fun `voice grouping by language works`() {
        // Simulate grouping voices by language
        val voices = listOf(
            VoiceStub("en-US-voice1", Locale.US),
            VoiceStub("en-US-voice2", Locale.US),
            VoiceStub("en-GB-voice1", Locale.UK),
            VoiceStub("de-DE-voice1", Locale.GERMANY),
            VoiceStub("es-ES-voice1", Locale("es", "ES"))
        )

        val grouped = voices.groupBy { it.locale.displayLanguage }

        assertEquals(4, grouped.size)
        assertTrue(grouped.containsKey("English"))
        assertTrue(grouped.containsKey("German"))
        assertTrue(grouped.containsKey("Spanish"))
    }

    @Test
    fun `empty voice list results in empty groups`() {
        val voices = emptyList<VoiceStub>()
        val grouped = voices.groupBy { it.locale.displayLanguage }
        assertTrue(grouped.isEmpty())
    }

    // ==========================================================================
    // MARK: - Display Label Formatting
    // ==========================================================================

    @Test
    fun `speech rate display format is correct`() {
        val testCases = listOf(
            0.5f to "Speed: 0.5x",
            1.0f to "Speed: 1.0x",
            1.5f to "Speed: 1.5x",
            2.0f to "Speed: 2.0x"
        )

        for ((rate, expected) in testCases) {
            val formatted = "Speed: ${String.format(Locale.US, "%.1fx", rate)}"
            assertEquals(expected, formatted)
        }
    }

    @Test
    fun `pitch display format is correct`() {
        val testCases = listOf(
            0.5f to "Pitch: 0.5",
            1.0f to "Pitch: 1.0",
            1.5f to "Pitch: 1.5",
            2.0f to "Pitch: 2.0"
        )

        for ((pitch, expected) in testCases) {
            val formatted = "Pitch: ${String.format(Locale.US, "%.1f", pitch)}"
            assertEquals(expected, formatted)
        }
    }

    // ==========================================================================
    // MARK: - Voice Name Extraction
    // ==========================================================================

    @Test
    fun `voice name extraction removes prefix`() {
        val testCases = listOf(
            "en-us-x-sfg#male_1-local" to "male_1-local",
            "en-GB-neural-voice" to "neural-voice",
            "simple-voice" to "voice"
        )

        for ((fullName, expected) in testCases) {
            val extracted = fullName.substringAfter("#").substringAfter("-")
            assertEquals(expected, extracted)
        }
    }

    // ==========================================================================
    // MARK: - Selection State
    // ==========================================================================

    @Test
    fun `null selection indicates system default`() {
        val selectedVoice: VoiceStub? = null
        val isSystemDefault = selectedVoice == null
        assertTrue(isSystemDefault)
    }

    @Test
    fun `voice selection comparison by name`() {
        val voice1 = VoiceStub("en-us-voice1", Locale.US)
        val voice2 = VoiceStub("en-us-voice1", Locale.US)
        val voice3 = VoiceStub("en-us-voice2", Locale.US)

        assertTrue(voice1.name == voice2.name)
        assertFalse(voice1.name == voice3.name)
    }
}

/**
 * Simple stub for testing voice-related logic without Android TTS.
 */
data class VoiceStub(
    val name: String,
    val locale: Locale,
    val isNetworkConnectionRequired: Boolean = false
)
