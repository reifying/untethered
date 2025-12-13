// Logging.swift
// Shared logging utilities for VoiceCodeShared

import Foundation
import OSLog

/// Configurable subsystem for logging
/// Apps should set this early in their lifecycle (e.g., in AppDelegate or @main)
public enum LoggingConfig {
    /// The subsystem identifier for OSLog
    /// Defaults to "com.voicecode.shared" but apps should override
    /// Note: This is safe because it's only set once at app launch before any logging occurs
    nonisolated(unsafe) public static var subsystem: String = "com.voicecode.shared"
}

// MARK: - Shared Loggers
extension Logger {
    /// Logger for priority queue operations
    public static var priorityQueue: Logger {
        Logger(subsystem: LoggingConfig.subsystem, category: "PriorityQueue")
    }
}
