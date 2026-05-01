// TextProcessor.swift
// Utilities for processing text before text-to-speech

import Foundation

struct TextProcessor {
    /// Prepare text for text-to-speech: remove code blocks and split CamelCase
    /// identifiers into separate words so TTS reads them naturally instead of
    /// announcing each capital letter.
    ///
    /// - Parameter text: The text to process
    /// - Returns: Text ready for TTS
    static func prepareForSpeech(from text: String) -> String {
        splitCamelCase(in: removeCodeBlocks(from: text))
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
