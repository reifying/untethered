package dev.labs910.voicecode.util

import org.junit.Assert.*
import org.junit.Test

/**
 * Tests for TextProcessor utility.
 * Mirrors iOS TextProcessor tests.
 */
class TextProcessorTest {

    // =========================================================================
    // MARK: - Code Block Removal Tests
    // =========================================================================

    @Test
    fun `removeCodeBlocks removes fenced code blocks`() {
        val input = """
            Here is some code:
            ```kotlin
            fun hello() {
                println("Hello")
            }
            ```
            After the code.
        """.trimIndent()

        val result = TextProcessor.removeCodeBlocks(input)

        assertTrue(result.contains("[code block]"))
        assertFalse(result.contains("```"))
        assertFalse(result.contains("println"))
    }

    @Test
    fun `removeCodeBlocks handles multiple code blocks`() {
        val input = """
            First block:
            ```python
            print("hello")
            ```
            Second block:
            ```java
            System.out.println("world");
            ```
            Done.
        """.trimIndent()

        val result = TextProcessor.removeCodeBlocks(input)

        // Should have two [code block] markers
        val count = result.split("[code block]").size - 1
        assertEquals(2, count)
    }

    @Test
    fun `removeCodeBlocks preserves inline code content`() {
        val input = "Use the `println` function to print."

        val result = TextProcessor.removeCodeBlocks(input)

        assertTrue(result.contains("println"))
        assertFalse(result.contains("`"))
    }

    @Test
    fun `removeCodeBlocks handles nested backticks in code blocks`() {
        val input = """
            ```
            val x = "`nested`"
            ```
        """.trimIndent()

        val result = TextProcessor.removeCodeBlocks(input)

        assertTrue(result.contains("[code block]"))
        assertFalse(result.contains("nested"))
    }

    @Test
    fun `removeCodeBlocks collapses multiple newlines`() {
        val input = "First line.\n\n\n\n\nSecond line."

        val result = TextProcessor.removeCodeBlocks(input)

        assertFalse(result.contains("\n\n\n"))
        assertTrue(result.contains("\n\n") || result.contains("First line.") && result.contains("Second line."))
    }

    @Test
    fun `removeCodeBlocks handles empty input`() {
        val result = TextProcessor.removeCodeBlocks("")

        assertEquals("", result)
    }

    @Test
    fun `removeCodeBlocks handles text without code`() {
        val input = "Just regular text without any code."

        val result = TextProcessor.removeCodeBlocks(input)

        assertEquals("Just regular text without any code.", result)
    }

    // =========================================================================
    // MARK: - Truncate Tests
    // =========================================================================

    @Test
    fun `truncate returns original text when under limit`() {
        val input = "Short text"

        val result = TextProcessor.truncate(input, 100)

        assertEquals("Short text", result)
    }

    @Test
    fun `truncate adds ellipsis when over limit`() {
        val input = "This is a longer piece of text that should be truncated"

        val result = TextProcessor.truncate(input, 20)

        assertTrue(result.endsWith("..."))
        assertTrue(result.length <= 20)
    }

    @Test
    fun `truncate handles exact length`() {
        val input = "Exact"

        val result = TextProcessor.truncate(input, 5)

        assertEquals("Exact", result)
    }

    @Test
    fun `truncate handles empty string`() {
        val result = TextProcessor.truncate("", 10)

        assertEquals("", result)
    }

    // =========================================================================
    // MARK: - Middle Truncate Tests
    // =========================================================================

    @Test
    fun `middleTruncate returns original when under limit`() {
        val input = "Short text"

        val result = TextProcessor.middleTruncate(input, 100, 100)

        assertEquals("Short text", result)
    }

    @Test
    fun `middleTruncate preserves start and end`() {
        val input = "A".repeat(100) + "MIDDLE" + "B".repeat(100)

        val result = TextProcessor.middleTruncate(input, keepStart = 50, keepEnd = 50)

        assertTrue(result.startsWith("A".repeat(50)))
        assertTrue(result.endsWith("B".repeat(50)))
        assertTrue(result.contains("..."))
        assertFalse(result.contains("MIDDLE"))
    }

    @Test
    fun `middleTruncate includes truncated character count`() {
        val input = "A".repeat(1000)

        val result = TextProcessor.middleTruncate(input, keepStart = 100, keepEnd = 100)

        // Should contain marker showing how many chars were truncated
        assertTrue(result.contains("800") || result.contains("truncated"))
    }

    @Test
    fun `middleTruncate handles empty input`() {
        val result = TextProcessor.middleTruncate("", 10, 10)

        assertEquals("", result)
    }

    // =========================================================================
    // MARK: - ANSI Code Removal Tests
    // =========================================================================

    @Test
    fun `removeAnsiCodes strips color codes`() {
        val input = "\u001B[31mRed text\u001B[0m"

        val result = TextProcessor.removeAnsiCodes(input)

        assertEquals("Red text", result)
    }

    @Test
    fun `removeAnsiCodes handles multiple codes`() {
        val input = "\u001B[1m\u001B[32mBold green\u001B[0m \u001B[34mblue\u001B[0m"

        val result = TextProcessor.removeAnsiCodes(input)

        assertEquals("Bold green blue", result)
    }

    @Test
    fun `removeAnsiCodes handles cursor movement codes`() {
        val input = "\u001B[2J\u001B[HClear screen"

        val result = TextProcessor.removeAnsiCodes(input)

        assertEquals("Clear screen", result)
    }

    @Test
    fun `removeAnsiCodes handles text without codes`() {
        val input = "Plain text"

        val result = TextProcessor.removeAnsiCodes(input)

        assertEquals("Plain text", result)
    }

    @Test
    fun `removeAnsiCodes handles empty input`() {
        val result = TextProcessor.removeAnsiCodes("")

        assertEquals("", result)
    }

    // =========================================================================
    // MARK: - Extract Preview Tests
    // =========================================================================

    @Test
    fun `extractPreview returns first N chars`() {
        val input = "This is a long piece of text that we want to preview"

        val result = TextProcessor.extractPreview(input, 20)

        assertTrue(result.length <= 23) // 20 + "..."
        assertTrue(result.startsWith("This is a"))
    }

    @Test
    fun `extractPreview returns full text when short`() {
        val input = "Short"

        val result = TextProcessor.extractPreview(input, 100)

        assertEquals("Short", result)
    }

    @Test
    fun `extractPreview handles empty input`() {
        val result = TextProcessor.extractPreview("", 100)

        assertEquals("", result)
    }

    @Test
    fun `extractPreview uses default max length`() {
        val input = "A".repeat(200)

        val result = TextProcessor.extractPreview(input)

        assertTrue(result.length <= 103) // 100 default + "..."
    }

    // =========================================================================
    // MARK: - Normalize Whitespace Tests
    // =========================================================================

    @Test
    fun `normalizeWhitespace collapses multiple spaces`() {
        val input = "word    with    spaces"

        val result = TextProcessor.normalizeWhitespace(input)

        assertEquals("word with spaces", result)
    }

    @Test
    fun `normalizeWhitespace trims leading and trailing`() {
        val input = "   trimmed   "

        val result = TextProcessor.normalizeWhitespace(input)

        assertEquals("trimmed", result)
    }

    @Test
    fun `normalizeWhitespace handles tabs and newlines`() {
        val input = "word\t\twith\n\ntabs"

        val result = TextProcessor.normalizeWhitespace(input)

        assertEquals("word with tabs", result)
    }

    @Test
    fun `normalizeWhitespace handles empty input`() {
        val result = TextProcessor.normalizeWhitespace("")

        assertEquals("", result)
    }

    @Test
    fun `normalizeWhitespace handles only whitespace`() {
        val result = TextProcessor.normalizeWhitespace("   \t\n   ")

        assertEquals("", result)
    }

    // =========================================================================
    // MARK: - Integration Tests
    // =========================================================================

    @Test
    fun `combined processing for TTS`() {
        val input = """
            Here's my response:
            ```kotlin
            println("hello")
            ```
            The `println` function outputs text.



            Multiple newlines above.
        """.trimIndent()

        var result = TextProcessor.removeCodeBlocks(input)
        result = TextProcessor.normalizeWhitespace(result)

        assertFalse(result.contains("```"))
        assertFalse(result.contains("`"))
        assertTrue(result.contains("[code block]"))
        assertTrue(result.contains("println"))
    }
}
