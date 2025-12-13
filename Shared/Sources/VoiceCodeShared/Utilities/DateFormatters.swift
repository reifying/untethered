// DateFormatters.swift
// Shared date formatting utilities

import Foundation

/// Date formatting utilities for ISO-8601 parsing and formatting
/// Creates new formatter instances per call (thread-safe for Swift 6 concurrency)
public enum DateFormatters {

    /// Parse ISO-8601 date string with fallback for missing fractional seconds
    /// - Parameter string: ISO-8601 formatted date string
    /// - Returns: Parsed Date, or nil if parsing fails
    public static func parseISO8601(_ string: String) -> Date? {
        // Try with fractional seconds first (most common from backend)
        let formatterWithFractional = ISO8601DateFormatter()
        formatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatterWithFractional.date(from: string) {
            return date
        }
        // Fallback to without fractional seconds
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    /// Format date as ISO-8601 string with fractional seconds
    /// - Parameter date: Date to format
    /// - Returns: ISO-8601 formatted string
    public static func formatISO8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
