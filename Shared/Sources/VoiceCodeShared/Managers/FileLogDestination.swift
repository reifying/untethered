// FileLogDestination.swift
// File-based logging with daily rotation

import Foundation

/// Configuration for file-based logging
public enum FileLogConfig {
    /// Default log directory: ~/Library/Logs/VoiceCode/ (macOS only)
    public static var logDirectory: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VoiceCode")
        #else
        // iOS: Use app's Documents directory (file logging not typically used on iOS)
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs")
        #endif
    }

    /// Number of days to retain log files (default: 7)
    nonisolated(unsafe) public static var retentionDays: Int = 7
}

/// Protocol for file system operations (enables testing)
public protocol FileSystemProtocol: Sendable {
    func createDirectory(at url: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws
    func fileExists(atPath path: String) -> Bool
    func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options: FileManager.DirectoryEnumerationOptions) throws -> [URL]
    func removeItem(at url: URL) throws
    func appendData(_ data: Data, to url: URL) throws
}

/// Default file system implementation using FileManager
public final class DefaultFileSystem: FileSystemProtocol, @unchecked Sendable {
    public static let shared = DefaultFileSystem()
    private init() {}

    public func createDirectory(at url: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories, attributes: attributes)
    }

    public func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options: FileManager.DirectoryEnumerationOptions) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: options)
    }

    public func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    public func appendData(_ data: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let fileHandle = try FileHandle(forWritingTo: url)
            defer { try? fileHandle.close() }
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }
}

/// File-based logging destination with daily rotation
/// Thread-safe and supports configurable log directory and retention period
public final class FileLogDestination: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.voicecode.shared.FileLogDestination")
    private let logDirectory: URL
    private let retentionDays: Int
    private let fileSystem: FileSystemProtocol
    private let dateProvider: @Sendable () -> Date
    private var currentLogFile: URL?
    private var currentDate: String?
    private var directoryCreated = false

    /// Initialize with default configuration
    public convenience init() {
        self.init(
            logDirectory: FileLogConfig.logDirectory,
            retentionDays: FileLogConfig.retentionDays
        )
    }

    /// Initialize with custom configuration
    public init(
        logDirectory: URL,
        retentionDays: Int,
        fileSystem: FileSystemProtocol = DefaultFileSystem.shared,
        dateProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.logDirectory = logDirectory
        self.retentionDays = retentionDays
        self.fileSystem = fileSystem
        self.dateProvider = dateProvider
    }

    /// Write a log line to the file
    /// - Parameter line: Pre-formatted log line (including timestamp and category)
    public func write(_ line: String) {
        queue.async { [weak self] in
            self?.writeSync(line)
        }
    }

    /// Write synchronously (for testing)
    private func writeSync(_ line: String) {
        do {
            try ensureDirectoryExists()
            let logFile = try currentLogFileURL()

            guard let data = (line + "\n").data(using: .utf8) else {
                return
            }

            try fileSystem.appendData(data, to: logFile)
        } catch {
            // Log to stderr on failure - don't crash the app
            fputs("FileLogDestination: Failed to write log: \(error.localizedDescription)\n", stderr)
        }
    }

    /// Clean up old log files beyond retention period
    public func cleanupOldLogs() {
        queue.async { [weak self] in
            self?.cleanupOldLogsSync()
        }
    }

    /// Synchronous cleanup (for testing)
    private func cleanupOldLogsSync() {
        guard directoryCreated || fileSystem.fileExists(atPath: logDirectory.path) else {
            return
        }

        do {
            let files = try fileSystem.contentsOfDirectory(
                at: logDirectory,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )

            let cutoffDate = Calendar.current.date(
                byAdding: .day,
                value: -retentionDays,
                to: dateProvider()
            ) ?? dateProvider()

            let dateFormatter = Self.makeDateFormatter()

            for file in files {
                guard file.pathExtension == "log" else { continue }

                // Extract date from filename (format: voicecode-YYYY-MM-DD.log)
                let filename = file.deletingPathExtension().lastPathComponent
                guard filename.hasPrefix("voicecode-"),
                      let dateString = filename.components(separatedBy: "voicecode-").last,
                      let fileDate = dateFormatter.date(from: dateString) else {
                    continue
                }

                if fileDate < cutoffDate {
                    try fileSystem.removeItem(at: file)
                }
            }
        } catch {
            fputs("FileLogDestination: Failed to cleanup old logs: \(error.localizedDescription)\n", stderr)
        }
    }

    /// Get the current log file path
    public var currentLogFilePath: URL? {
        queue.sync {
            try? currentLogFileURL()
        }
    }

    /// Get all log files in the directory
    public func getAllLogFiles() -> [URL] {
        queue.sync {
            guard fileSystem.fileExists(atPath: logDirectory.path) else {
                return []
            }

            do {
                let files = try fileSystem.contentsOfDirectory(
                    at: logDirectory,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: .skipsHiddenFiles
                )

                return files
                    .filter { $0.pathExtension == "log" }
                    .sorted { $0.lastPathComponent > $1.lastPathComponent } // Most recent first
            } catch {
                return []
            }
        }
    }

    // MARK: - Private Helpers

    private func ensureDirectoryExists() throws {
        guard !directoryCreated else { return }

        if !fileSystem.fileExists(atPath: logDirectory.path) {
            try fileSystem.createDirectory(
                at: logDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
        directoryCreated = true
    }

    private func currentLogFileURL() throws -> URL {
        let dateString = Self.formatDate(dateProvider())

        // Check if we need a new file (date changed)
        if let current = currentLogFile, currentDate == dateString {
            return current
        }

        let filename = "voicecode-\(dateString).log"
        let logFile = logDirectory.appendingPathComponent(filename)

        currentLogFile = logFile
        currentDate = dateString

        return logFile
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = makeDateFormatter()
        return formatter.string(from: date)
    }

    private static func makeDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter
    }
}
