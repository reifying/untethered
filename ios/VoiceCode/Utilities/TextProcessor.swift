// TextProcessor.swift
// Utilities for processing text before text-to-speech

import Foundation

struct TextProcessor {
    /// Prepare text for text-to-speech: drop tool-call announcements, remove
    /// code blocks and split CamelCase identifiers into separate words so TTS
    /// reads them naturally instead of announcing each capital letter.
    ///
    /// Tool stripping runs first: the markers are structural, and letting
    /// `removeCodeBlocks` (backticks inside a Bash `command=` parameter) or
    /// `splitCamelCase` ("[Tool: WebFetch]" → "[Tool: Web Fetch]") rewrite them
    /// first would make them harder to recognise.
    ///
    /// - Parameter text: The text to process
    /// - Returns: Text ready for TTS. May be empty — a message that was nothing
    ///   but tool calls has nothing left to say, and callers must not speak it.
    static func prepareForSpeech(from text: String) -> String {
        splitCamelCase(in: removeCodeBlocks(from: removeToolAnnouncements(from: text)))
    }

    // MARK: - Tool announcements

    /// Matches one backend tool-call announcement, e.g.
    /// `[Tool: Read file_path=/tmp/x]` or `[Tool: Bash command=ls -la ...]`
    /// (see `summarize-tool-use` in backend/src/voice_code/providers.clj).
    ///
    /// The closing bracket must sit at end-of-line, so a parameter value that
    /// itself contains `]` — a Grep `pattern=[0-9]+`, say — doesn't cut the
    /// match short and leave the tail to be spoken. The body may span newlines
    /// (a truncated multi-line Bash command) but never a blank line, so a stray
    /// unterminated "[Tool:" in prose can't swallow the paragraphs after it.
    private static let toolUsePattern = #"\[Tool:(?:(?!\n\n)[\s\S])*?\][ \t]*(?=\n|\z)"#

    /// Literal marker the backend emits ahead of tool-result content. The
    /// content that follows has no terminator we can recognise, so everything
    /// from the marker onwards is dropped.
    private static let toolResultMarker = "[Tool Result]"

    /// Remove tool-call chatter so it is never spoken.
    ///
    /// The backend folds `tool_use` and `tool_result` content blocks into the
    /// message's display text as bracketed markers, and that same text feeds
    /// both the on-screen transcript and TTS. The transcript wants them; a
    /// listener does not. This strips them from the speech copy only.
    ///
    /// `[Thinking: ...]` markers are deliberately left alone — thinking is
    /// signal for a listener.
    ///
    /// - Parameter text: The message text to filter
    /// - Returns: The text with tool announcements removed, trimmed. Empty when
    ///   the message was nothing but tool calls.
    static func removeToolAnnouncements(from text: String) -> String {
        var result = text

        if let regex = try? NSRegularExpression(pattern: toolUsePattern, options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // Tool-result content runs to the end of the block with no marker we can
        // anchor on, so truncate here. Prose before the marker is preserved.
        if let markerRange = result.range(of: toolResultMarker) {
            result = String(result[result.startIndex..<markerRange.lowerBound])
        }

        // Collapse the blank runs the removals leave behind.
        if let regex = try? NSRegularExpression(pattern: #"\n{3,}"#, options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "\n\n")
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Split CamelCase / PascalCase identifiers into space-separated words.
    /// Example: "XMLHttpRequest" → "XML Http Request", "FooBar" → "Foo Bar".
    /// AVSpeechSynthesizer then reads the result as words rather than
    /// spelling out each capital letter.
    ///
    /// - Parameter text: The text to process
    /// - Returns: Text with CamelCase boundaries expanded to spaces
    static func splitCamelCase(in text: String) -> String {
        var result = text
        // ACRONYMWord → ACRONYM Word (e.g. "XMLHttp" → "XML Http")
        if let regex = try? NSRegularExpression(pattern: #"([A-Z]+)([A-Z][a-z])"#, options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1 $2")
        }
        // lowerUpper → lower Upper (e.g. "FooBar" → "Foo Bar")
        if let regex = try? NSRegularExpression(pattern: #"([a-z])([A-Z])"#, options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1 $2")
        }
        return result
    }

    /// Remove code blocks from markdown text for better text-to-speech experience
    /// Removes both fenced code blocks (```...```) and inline code (`...`)
    /// Replaces them with spoken descriptions
    ///
    /// - Parameter markdown: The markdown text to process
    /// - Returns: Text with code blocks removed/replaced
    static func removeCodeBlocks(from markdown: String) -> String {
        var text = markdown
        
        // Remove fenced code blocks (```language\ncode\n```)
        // Replace with a brief mention that code was here
        let fencedCodePattern = #"```[\s\S]*?```"#
        if let regex = try? NSRegularExpression(pattern: fencedCodePattern, options: []) {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(
                in: text,
                options: [],
                range: range,
                withTemplate: "[code block]"
            )
        }
        
        // Remove inline code (`code`)
        // Replace with just the code content without backticks for better flow
        let inlineCodePattern = #"`([^`\n]+?)`"#
        if let regex = try? NSRegularExpression(pattern: inlineCodePattern, options: []) {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(
                in: text,
                options: [],
                range: range,
                withTemplate: "$1"
            )
        }
        
        // Clean up multiple consecutive newlines left by code block removal
        let multipleNewlinesPattern = #"\n{3,}"#
        if let regex = try? NSRegularExpression(pattern: multipleNewlinesPattern, options: []) {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(
                in: text,
                options: [],
                range: range,
                withTemplate: "\n\n"
            )
        }
        
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
