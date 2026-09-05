package dev.labs910.voicecode.util

/**
 * Utilities for processing text before text-to-speech.
 * Corresponds to iOS TextProcessor.swift.
 */
object TextProcessor {

    /**
     * Matches one backend tool-call announcement, e.g.
     * "[Tool: Read file_path=/tmp/x]" or "[Tool: Bash command=ls -la ...]"
     * (see summarize-tool-use in backend/src/voice_code/providers.clj).
     *
     * The closing bracket must sit at end-of-line, so a parameter value that
     * itself contains "]" — a Grep pattern=[0-9]+, say — doesn't cut the match
     * short and leave the tail to be spoken. The body may span newlines (a
     * truncated multi-line Bash command) but never a blank line, so a stray
     * unterminated "[Tool:" in prose can't swallow the paragraphs after it.
     */
    private val TOOL_USE_PATTERN = Regex("\\[Tool:(?:(?!\\n\\n)[\\s\\S])*?\\][ \\t]*(?=\\n|\\z)")

    /**
     * Literal marker the backend emits ahead of tool-result content. The content
     * that follows has no terminator we can recognise, so everything from the
     * marker onwards is dropped.
     */
    private const val TOOL_RESULT_MARKER = "[Tool Result]"

    /**
     * Remove tool-call chatter so it is never spoken.
     *
     * The backend folds tool_use and tool_result content blocks into the
     * message's display text as bracketed markers, and that same text feeds both
     * the on-screen transcript and TTS. The transcript wants them; a listener
     * does not. This strips them from the speech copy only.
     *
     * "[Thinking: ...]" markers are deliberately left alone — thinking is signal
     * for a listener.
     *
     * Corresponds to iOS TextProcessor.removeToolAnnouncements(from:).
     *
     * @param text The message text to filter
     * @return The text with tool announcements removed, trimmed. Empty when the
     *   message was nothing but tool calls — callers must not speak that.
     */
    fun removeToolAnnouncements(text: String): String {
        var result = TOOL_USE_PATTERN.replace(text, "")

        // Tool-result content runs to the end of the block with no marker we can
        // anchor on, so truncate here. Prose before the marker is preserved.
        val markerIndex = result.indexOf(TOOL_RESULT_MARKER)
        if (markerIndex >= 0) {
            result = result.substring(0, markerIndex)
        }

        // Collapse the blank runs the removals leave behind.
        result = Regex("\\n{3,}").replace(result, "\n\n")

        return result.trim()
    }

    /**
     * Remove code blocks from markdown text for better text-to-speech experience.
     * Removes both fenced code blocks (```...```) and inline code (`...`).
     * Replaces them with spoken descriptions.
     *
     * @param markdown The markdown text to process
     * @return Text with code blocks removed/replaced
     */
    fun removeCodeBlocks(markdown: String): String {
        var text = markdown

        // Remove fenced code blocks (```language\ncode\n```)
        // Replace with a brief mention that code was here
        val fencedCodePattern = Regex("```[\\s\\S]*?```")
        text = fencedCodePattern.replace(text, "[code block]")

        // Remove inline code (`code`)
        // Replace with just the code content without backticks for better flow
        val inlineCodePattern = Regex("`([^`\\n]+?)`")
        text = inlineCodePattern.replace(text, "$1")

        // Clean up multiple consecutive newlines left by code block removal
        val multipleNewlinesPattern = Regex("\\n{3,}")
        text = multipleNewlinesPattern.replace(text, "\n\n")

        return text.trim()
    }

    /**
     * Truncate text to a maximum length with ellipsis.
     *
     * @param text The text to truncate
     * @param maxLength Maximum length before truncation
     * @return Truncated text with ellipsis if needed
     */
    fun truncate(text: String, maxLength: Int): String {
        return if (text.length <= maxLength) {
            text
        } else {
            text.take(maxLength - 3) + "..."
        }
    }

    /**
     * Middle-truncate text keeping first N and last N characters.
     * Used for displaying long messages in UI.
     *
     * @param text The text to truncate
     * @param keepStart Number of characters to keep at start
     * @param keepEnd Number of characters to keep at end
     * @return Middle-truncated text
     */
    fun middleTruncate(text: String, keepStart: Int = 250, keepEnd: Int = 250): String {
        val minLength = keepStart + keepEnd + 20 // Need room for marker
        if (text.length <= minLength) {
            return text
        }

        val truncatedSize = text.length - keepStart - keepEnd
        return "${text.take(keepStart)}\n\n... [${truncatedSize} characters truncated] ...\n\n${text.takeLast(keepEnd)}"
    }

    /**
     * Remove ANSI escape codes from terminal output.
     *
     * @param text Text potentially containing ANSI codes
     * @return Clean text without ANSI codes
     */
    fun removeAnsiCodes(text: String): String {
        // ANSI escape sequence pattern: ESC [ ... m (or other endings)
        val ansiPattern = Regex("\\u001B\\[[0-9;]*[a-zA-Z]")
        return ansiPattern.replace(text, "")
    }

    /**
     * Extract the first line of text for preview purposes.
     *
     * @param text The full text
     * @param maxLength Maximum length for the preview
     * @return First line, truncated if needed
     */
    fun extractPreview(text: String, maxLength: Int = 100): String {
        val firstLine = text.lineSequence().firstOrNull() ?: ""
        return truncate(firstLine, maxLength)
    }

    /**
     * Normalize whitespace in text.
     * Converts multiple spaces/tabs/newlines to single space, trims.
     *
     * @param text The text to normalize
     * @return Normalized text
     */
    fun normalizeWhitespace(text: String): String {
        return text
            .replace(Regex("[\\s]+"), " ")
            .trim()
    }
}
