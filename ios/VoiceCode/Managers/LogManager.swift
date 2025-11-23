// LogManager.swift
// Captures and manages app logs for debugging

import Foundation
import OSLog

class LogManager {
    static let shared = LogManager()

    private let maxLogLines = 1000 // Keep last 1000 lines in memory
    private var logLines: [String] = []
    private let queue = DispatchQueue(label: "com.travisbrown.VoiceCode.LogManager")

    private init() {
        // Start capturing logs
        startCapturing()
    }

    private func startCapturing() {
        // Redirect print statements and NSLog to our capture
        // Note: OSLog messages are not easily capturable in real-time
        // This captures Swift print() statements
        // For OSLog, we'll need to read from system logs
    }

    /// Append a log message (call this from your logging points)
    func log(_ message: String, category: String = "General") {
        queue.async {
            let timestamp = DateFormatter.logTimestamp.string(from: Date())
            let logLine = "[\(timestamp)] [\(category)] \(message)"
            self.logLines.append(logLine)

            // Keep only last N lines
            if self.logLines.count > self.maxLogLines {
                self.logLines.removeFirst(self.logLines.count - self.maxLogLines)
            }
        }
    }

    /// Get the last N lines of logs (default 15KB worth, complete lines only)
    func getRecentLogs(maxBytes: Int = 15_000) -> String {
        return queue.sync {
            // Join all lines
            let allLogs = logLines.joined(separator: "\n")

            // If total size is under limit, return all
            guard let data = allLogs.data(using: .utf8), data.count > maxBytes else {
                return allLogs
            }

            // Find the cutoff point to stay under maxBytes
            // Start from the end and work backwards
            var totalBytes = 0
            var includedLines: [String] = []

            for line in logLines.reversed() {
                let lineData = (line + "\n").data(using: .utf8) ?? Data()
                if totalBytes + lineData.count > maxBytes {
                    break
                }
                totalBytes += lineData.count
                includedLines.insert(line, at: 0)
            }

            return includedLines.joined(separator: "\n")
        }
    }

    /// Get all captured logs
    func getAllLogs() -> String {
        return queue.sync {
            logLines.joined(separator: "\n")
        }
    }

    /// Clear all logs
    func clearLogs() {
        queue.async {
            self.logLines.removeAll()
        }
    }

    /// App subsystem for filtering OSLog entries
    private static let appSubsystem = "com.travisbrown.VoiceCode"

    /// Get system logs from OSLog (last 15KB, complete lines)
    /// Filters to only include logs from the app's subsystem to exclude framework noise
    func getSystemLogs(maxBytes: Int = 15_000) async throws -> String {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(timeIntervalSinceEnd: -3600) // Last hour

        var logLines: [String] = []
        let entries = try store.getEntries(at: position)

        for entry in entries {
            // Filter to only include app-specific logs (excludes CoreData, SwiftUI, etc.)
            if let logEntry = entry as? OSLogEntryLog,
               logEntry.subsystem == Self.appSubsystem {
                let timestamp = DateFormatter.logTimestamp.string(from: logEntry.date)
                let logLine = "[\(timestamp)] [\(logEntry.category)] \(logEntry.composedMessage)"
                logLines.append(logLine)
            }
        }

        // Calculate size and trim to last 15KB of complete lines
        var totalBytes = 0
        var includedLines: [String] = []

        for line in logLines.reversed() {
            let lineData = (line + "\n").data(using: .utf8) ?? Data()
            if totalBytes + lineData.count > maxBytes {
                break
            }
            totalBytes += lineData.count
            includedLines.insert(line, at: 0)
        }

        return includedLines.joined(separator: "\n")
    }
}

// MARK: - Date Formatter Extension

extension DateFormatter {
    static let logTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
