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
            self.appendToFile(logLine)
            #if DEBUG
            if Self.echoToStandardError {
                FileHandle.standardError.write(Data((logLine + "\n").utf8))
            }
            #endif
        }
    }

    #if DEBUG
    /// Debug builds launched with UNTETHERED_LOG_STDERR set also write every log
    /// line to standard error. The log file is inside the app's sandbox container,
    /// which another process cannot read without a privacy prompt, so this is how
    /// a developer or an agent running the app from a shell watches what it does.
    static let echoToStandardError = ProcessInfo.processInfo.environment["UNTETHERED_LOG_STDERR"] != nil
    #endif

    // MARK: - Persisting to disk
    //
    // The buffer above lives in memory, so a crash took the log with it and left
    // nothing to say what the app was doing. On the Mac the log is also written to
    // a file as it goes. Each launch starts a new file and keeps the two before it;
    // when the previous run did not end with a clean exit, its last lines are
    // copied into the new buffer, so they show up in the in-app log viewer and in
    // Share Logs without anyone having to go and find the file.

    static let logFileName = "untethered.log"
    static let cleanExitMarker = "=== clean exit ==="
    /// A file is rotated when it reaches this size, so a long session is bounded.
    static let maxFileBytes = 4 * 1024 * 1024
    /// Lines of an unclean previous run carried into the new buffer.
    static let carriedOverLines = 300

    private var fileHandle: FileHandle?
    private var fileDirectory: URL?
    private var fileBytes = 0

    /// The folder log files are written to by default: Application Support, inside
    /// the app's own container.
    static var defaultLogDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Untethered/Logs", isDirectory: true)
    }

    /// Start writing the log to `directory` (the default folder when nil). Does
    /// nothing in a test run unless a directory is given, so running the tests
    /// never rotates away the log of a real session.
    func startPersisting(in directory: URL? = nil) {
        guard directory != nil || !TestingEnvironment.isTestRun else { return }
        guard let directory = directory ?? Self.defaultLogDirectory else { return }
        queue.async {
            let files = FileManager.default
            do {
                try files.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                self.logLines.append("[LogManager] could not create log folder \(directory.path): \(error.localizedDescription)")
                return
            }
            self.fileDirectory = directory
            let current = directory.appendingPathComponent(Self.logFileName)
            let previousTail = Self.tail(of: current, lines: Self.carriedOverLines)
            self.rotateFiles()
            self.openFile()

            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
            let started = ISO8601DateFormatter().string(from: Date())
            let header = "=== launch \(started) build \(version) pid \(ProcessInfo.processInfo.processIdentifier) ==="
            self.logLines.append(header)
            self.appendToFile(header)

            if let tail = previousTail, !tail.isEmpty, tail.last != Self.cleanExitMarker {
                let notice = "=== the previous run did not exit cleanly (crash, force quit or power loss); its last \(tail.count) log lines follow ==="
                let end = "=== end of the previous run's log ==="
                self.logLines.append(notice)
                self.logLines.append(contentsOf: tail.map { "  | " + $0 })
                self.logLines.append(end)
                self.appendToFile(notice)
                self.appendToFile(end)
            }
        }
    }

    /// Record that the app is quitting on purpose. Synchronous: the process is
    /// about to end.
    func markCleanExit() {
        queue.sync {
            self.appendToFile(Self.cleanExitMarker)
            try? self.fileHandle?.synchronize()
        }
    }

    /// Whether the log is currently being written to a file.
    var isPersisting: Bool {
        queue.sync { fileHandle != nil }
    }

    /// Stop writing to disk (tests).
    func stopPersisting() {
        queue.sync {
            try? self.fileHandle?.close()
            self.fileHandle = nil
            self.fileDirectory = nil
            self.fileBytes = 0
        }
    }

    private func appendToFile(_ line: String) {
        guard let handle = fileHandle, let data = (line + "\n").data(using: .utf8) else { return }
        do {
            try handle.write(contentsOf: data)
            fileBytes += data.count
        } catch {
            // The disk is full or the file is gone. Keep the app running on the
            // in-memory buffer rather than fail on every later line.
            fileHandle = nil
            return
        }
        if fileBytes >= Self.maxFileBytes {
            try? handle.close()
            fileHandle = nil
            rotateFiles()
            openFile()
        }
    }

    /// untethered.log → untethered.1.log → untethered.2.log; the oldest is dropped.
    private func rotateFiles() {
        guard let directory = fileDirectory else { return }
        let files = FileManager.default
        let current = directory.appendingPathComponent(Self.logFileName)
        let first = directory.appendingPathComponent("untethered.1.log")
        let second = directory.appendingPathComponent("untethered.2.log")
        guard files.fileExists(atPath: current.path) else { return }
        try? files.removeItem(at: second)
        try? files.moveItem(at: first, to: second)
        try? files.moveItem(at: current, to: first)
    }

    private func openFile() {
        guard let directory = fileDirectory else { return }
        let current = directory.appendingPathComponent(Self.logFileName)
        FileManager.default.createFile(atPath: current.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: current)
        fileBytes = 0
    }

    /// The last `lines` lines of a log file, or nil when there is no file.
    static func tail(of url: URL, lines: Int) -> [String]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let all = text.split(separator: "\n", omittingEmptySubsequences: true)
        return all.suffix(lines).map(String.init)
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
