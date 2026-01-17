package dev.labs910.voicecode.util

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.mockito.Mockito.*

/**
 * Tests for ClipboardUtility.
 * Mirrors iOS ClipboardUtilityTests.swift.
 *
 * Note: These tests use Mockito to mock Android's ClipboardManager
 * since we can't use the real clipboard in unit tests.
 */
class ClipboardUtilityTest {

    private lateinit var mockContext: Context
    private lateinit var mockClipboardManager: ClipboardManager

    @Before
    fun setUp() {
        mockContext = mock(Context::class.java)
        mockClipboardManager = mock(ClipboardManager::class.java)

        `when`(mockContext.getSystemService(Context.CLIPBOARD_SERVICE))
            .thenReturn(mockClipboardManager)
    }

    // =========================================================================
    // MARK: - Copy Tests
    // =========================================================================

    @Test
    fun `copy sets clipboard content`() {
        val text = "Hello, World!"

        ClipboardUtility.copy(mockContext, text)

        verify(mockClipboardManager).setPrimaryClip(any())
    }

    @Test
    fun `copy handles empty string`() {
        val text = ""

        ClipboardUtility.copy(mockContext, text)

        verify(mockClipboardManager).setPrimaryClip(any())
    }

    @Test
    fun `copy handles multiline text`() {
        val text = "Line 1\nLine 2\nLine 3"

        ClipboardUtility.copy(mockContext, text)

        verify(mockClipboardManager).setPrimaryClip(any())
    }

    @Test
    fun `copy handles unicode text`() {
        val text = "こんにちは 🌍 مرحبا"

        ClipboardUtility.copy(mockContext, text)

        verify(mockClipboardManager).setPrimaryClip(any())
    }

    @Test
    fun `copy handles long text`() {
        val text = "A".repeat(10000)

        ClipboardUtility.copy(mockContext, text)

        verify(mockClipboardManager).setPrimaryClip(any())
    }

    // =========================================================================
    // MARK: - Paste Tests
    // =========================================================================

    @Test
    fun `paste returns null when clipboard is empty`() {
        `when`(mockClipboardManager.primaryClip).thenReturn(null)

        val result = ClipboardUtility.paste(mockContext)

        assertNull(result)
    }

    @Test
    fun `paste returns null when clipboard has zero items`() {
        val mockClipData = mock(ClipData::class.java)
        `when`(mockClipData.itemCount).thenReturn(0)
        `when`(mockClipboardManager.primaryClip).thenReturn(mockClipData)

        val result = ClipboardUtility.paste(mockContext)

        assertNull(result)
    }

    @Test
    fun `paste returns text from clipboard`() {
        val expectedText = "Copied text"
        val mockClipData = mock(ClipData::class.java)
        val mockItem = mock(ClipData.Item::class.java)

        `when`(mockItem.text).thenReturn(expectedText)
        `when`(mockClipData.itemCount).thenReturn(1)
        `when`(mockClipData.getItemAt(0)).thenReturn(mockItem)
        `when`(mockClipboardManager.primaryClip).thenReturn(mockClipData)

        val result = ClipboardUtility.paste(mockContext)

        assertEquals(expectedText, result)
    }

    @Test
    fun `paste handles null text in clipboard item`() {
        val mockClipData = mock(ClipData::class.java)
        val mockItem = mock(ClipData.Item::class.java)

        `when`(mockItem.text).thenReturn(null)
        `when`(mockClipData.itemCount).thenReturn(1)
        `when`(mockClipData.getItemAt(0)).thenReturn(mockItem)
        `when`(mockClipboardManager.primaryClip).thenReturn(mockClipData)

        val result = ClipboardUtility.paste(mockContext)

        assertNull(result)
    }

    // =========================================================================
    // MARK: - HasText Tests
    // =========================================================================

    @Test
    fun `hasText returns false when no primary clip`() {
        `when`(mockClipboardManager.hasPrimaryClip()).thenReturn(false)

        val result = ClipboardUtility.hasText(mockContext)

        assertFalse(result)
    }

    @Test
    fun `hasText returns false when clip is not text`() {
        val mockDescription = mock(android.content.ClipDescription::class.java)
        `when`(mockDescription.hasMimeType("text/plain")).thenReturn(false)
        `when`(mockClipboardManager.hasPrimaryClip()).thenReturn(true)
        `when`(mockClipboardManager.primaryClipDescription).thenReturn(mockDescription)

        val result = ClipboardUtility.hasText(mockContext)

        assertFalse(result)
    }

    @Test
    fun `hasText returns true when clipboard has text`() {
        val mockDescription = mock(android.content.ClipDescription::class.java)
        `when`(mockDescription.hasMimeType("text/plain")).thenReturn(true)
        `when`(mockClipboardManager.hasPrimaryClip()).thenReturn(true)
        `when`(mockClipboardManager.primaryClipDescription).thenReturn(mockDescription)

        val result = ClipboardUtility.hasText(mockContext)

        assertTrue(result)
    }

    // =========================================================================
    // MARK: - Clear Tests
    // =========================================================================

    @Test
    fun `clear sets empty clip on older Android`() {
        // For pre-P Android versions, clear sets an empty clip
        ClipboardUtility.clear(mockContext)

        verify(mockClipboardManager).setPrimaryClip(any())
    }

    // =========================================================================
    // MARK: - Integration Scenario Tests
    // =========================================================================

    @Test
    fun `copy then paste scenario`() {
        val testText = "Test content"
        val mockClipData = mock(ClipData::class.java)
        val mockItem = mock(ClipData.Item::class.java)

        // After copy, clipboard has content
        `when`(mockItem.text).thenReturn(testText)
        `when`(mockClipData.itemCount).thenReturn(1)
        `when`(mockClipData.getItemAt(0)).thenReturn(mockItem)
        `when`(mockClipboardManager.primaryClip).thenReturn(mockClipData)

        // Copy
        ClipboardUtility.copy(mockContext, testText)
        verify(mockClipboardManager).setPrimaryClip(any())

        // Paste
        val result = ClipboardUtility.paste(mockContext)
        assertEquals(testText, result)
    }

    @Test
    fun `multiple copies overwrite previous content`() {
        ClipboardUtility.copy(mockContext, "First")
        ClipboardUtility.copy(mockContext, "Second")

        // Should have called setPrimaryClip twice
        verify(mockClipboardManager, times(2)).setPrimaryClip(any())
    }

    // =========================================================================
    // MARK: - Special Characters Tests
    // =========================================================================

    @Test
    fun `copy handles special characters`() {
        val specialChars = "Tab:\t Newline:\n Quote:\" Backslash:\\"

        ClipboardUtility.copy(mockContext, specialChars)

        verify(mockClipboardManager).setPrimaryClip(any())
    }

    @Test
    fun `copy handles code snippets`() {
        val code = """
            fun main() {
                println("Hello, World!")
            }
        """.trimIndent()

        ClipboardUtility.copy(mockContext, code)

        verify(mockClipboardManager).setPrimaryClip(any())
    }

    @Test
    fun `copy handles JSON`() {
        val json = """{"name": "test", "value": 123}"""

        ClipboardUtility.copy(mockContext, json)

        verify(mockClipboardManager).setPrimaryClip(any())
    }
}
