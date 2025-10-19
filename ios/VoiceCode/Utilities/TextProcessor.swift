// TextProcessor.swift
// Utilities for processing text before text-to-speech

import Foundation

struct TextProcessor {
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
