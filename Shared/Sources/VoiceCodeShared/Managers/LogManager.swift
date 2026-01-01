// LogManager.swift
// Captures and manages app logs for debugging

import Foundation
import OSLog

/// Configuration for LogManager subsystem filtering
public enum LogManagerConfig {
    /// The OSLog subsystem to filter for when reading system logs
    /// Configure this at app startup (e.g., "com.yourcompany.YourApp")
    nonisolated(unsafe) public static var subsystem: String = "com.voicecode.shared"

    /// Enable file-based logging (macOS only)
    /// When enabled, logs are written to ~/Library/Logs/VoiceCode/
    nonisolated(unsafe) public static var fileLoggingEnabled: Bool = false
}

/// Manages app logs for debugging and crash reporting
/// Thread-safe singleton that captures logs in memory and retrieves system logs
public final class LogManager: Sendable {
    public static let shared = LogManager()

    private let maxLogLines = 1000
    private let storage = LogStorage()
    private let fileDestination: FileLogDestination?

    private init() {
        // Initialize file destination if enabled
        #if os(macOS)
        if LogManagerConfig.fileLoggingEnabled {
            self.fileDestination = FileLogDestination()
            // Run cleanup on startup
            self.fileDestination?.cleanupOldLogs()
        } else {
            self.fileDestination = nil
        }
        #else
        self.fileDestination = nil
        #endif
    }

    /// Initialize with a custom file destination (for testing)
    internal init(fileDestination: FileLogDestination?) {
        self.fileDestination = fileDestination
    }

    /// Append a log message
    /// - Parameters:
    ///   - message: The log message
    ///   - category: Category for filtering (default: "General")
    public func log(_ message: String, category: String = "General") {
        let timestamp = Self.formatTimestamp(Date())
        let logLine = "[\(timestamp)] [\(category)] \(message)"
        storage.append(logLine, maxLines: maxLogLines)

        // Also write to file if file logging is enabled
        fileDestination?.write(logLine)
    }

    /// Get the last N bytes of logs (complete lines only)
    /// - Parameter maxBytes: Maximum bytes to return (default: 15KB)
    /// - Returns: Recent log lines joined by newlines
    public func getRecentLogs(maxBytes: Int = 15_000) -> String {
        storage.getRecent(maxBytes: maxBytes)
    }

    /// Get all captured logs
    public func getAllLogs() -> String {
        storage.getAll()
    }

    /// Clear all logs
    public func clearLogs() {
        storage.clear()
    }

    // MARK: - File Logging (macOS)

    /// Get the current log file path (macOS only)
    /// - Returns: URL to current log file, or nil if file logging is disabled
    public var currentLogFilePath: URL? {
        fileDestination?.currentLogFilePath
    }

    /// Get all log files in the log directory (macOS only)
    /// - Returns: Array of URLs to log files, sorted most recent first
    public func getAllLogFiles() -> [URL] {
        fileDestination?.getAllLogFiles() ?? []
    }

    /// Get the log directory path
    /// - Returns: URL to the log directory
    public var logDirectory: URL {
        FileLogConfig.logDirectory
    }

    /// Trigger cleanup of old log files
    public func cleanupOldLogs() {
        fileDestination?.cleanupOldLogs()
    }

    /// Get system logs from OSLog (last hour, filtered to app subsystem)
    /// - Parameter maxBytes: Maximum bytes to return (default: 15KB)
    /// - Returns: Recent system log lines joined by newlines
    public func getSystemLogs(maxBytes: Int = 15_000) async throws -> String {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(timeIntervalSinceEnd: -3600) // Last hour

        var logLines: [String] = []
        let entries = try store.getEntries(at: position)
        let subsystem = LogManagerConfig.subsystem

        for entry in entries {
            if let logEntry = entry as? OSLogEntryLog,
               logEntry.subsystem == subsystem {
                let timestamp = Self.formatTimestamp(logEntry.date)
                let logLine = "[\(timestamp)] [\(logEntry.category)] \(logEntry.composedMessage)"
                logLines.append(logLine)
            }
        }

        return Self.trimToMaxBytes(logLines, maxBytes: maxBytes)
    }

    // MARK: - Private Helpers

    private static func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    private static func trimToMaxBytes(_ lines: [String], maxBytes: Int) -> String {
        var totalBytes = 0
        var includedLines: [String] = []

        for line in lines.reversed() {
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

// MARK: - Thread-Safe Storage

/// Internal thread-safe storage for log lines
private final class LogStorage: @unchecked Sendable {
    private var logLines: [String] = []
    private let queue = DispatchQueue(label: "com.voicecode.shared.LogManager")

    func append(_ line: String, maxLines: Int) {
        queue.async {
            self.logLines.append(line)
            if self.logLines.count > maxLines {
                self.logLines.removeFirst(self.logLines.count - maxLines)
            }
        }
    }

    func getRecent(maxBytes: Int) -> String {
        queue.sync {
            let allLogs = logLines.joined(separator: "\n")
            guard let data = allLogs.data(using: .utf8), data.count > maxBytes else {
                return allLogs
            }

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

    func getAll() -> String {
        queue.sync {
            logLines.joined(separator: "\n")
        }
    }

    func clear() {
        queue.async {
            self.logLines.removeAll()
        }
    }
}
