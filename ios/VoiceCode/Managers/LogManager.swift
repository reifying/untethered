// LogManager.swift
// Captures and manages app logs for debugging

import Foundation

class LogManager {
    static let shared = LogManager()

    private let maxLogLines = 5000 // Keep last 5000 lines in memory
    private var logLines: [String] = []
    private let queue = DispatchQueue(label: "com.travisbrown.VoiceCode.LogManager")

    private init() {
        // Start capturing logs
        startCapturing()
    }

    private func startCapturing() {
        // Logs are captured via explicit LogManager.shared.log() calls
        // throughout the app; there is no automatic redirection here.
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

    /// Get the last N lines of logs (default 100KB worth, complete lines only)
    func getRecentLogs(maxBytes: Int = 100_000) -> String {
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
}

// MARK: - Date Formatter Extension

extension DateFormatter {
    static let logTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
