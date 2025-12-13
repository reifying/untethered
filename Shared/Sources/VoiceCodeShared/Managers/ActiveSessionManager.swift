// ActiveSessionManager.swift
// Platform-agnostic active session tracking

import Foundation
import Combine
import OSLog

/// Configuration for ActiveSessionManager logging
public enum ActiveSessionConfig {
    /// The OSLog subsystem for ActiveSessionManager logging
    nonisolated(unsafe) public static var subsystem: String = "com.voicecode.shared"
}

/// Manages which session is currently active/visible to the user
/// Used for smart speaking logic - only auto-speak responses for active session
@MainActor
public final class ActiveSessionManager: ObservableObject, Sendable {

    // MARK: - Published Properties

    /// The currently active session ID (if any)
    @Published public private(set) var activeSessionId: UUID?

    // MARK: - Private Properties

    private let logger = Logger(subsystem: ActiveSessionConfig.subsystem, category: "ActiveSession")

    // MARK: - Initialization

    public init() {}

    // MARK: - Public Methods

    /// Mark a session as active (user opened it)
    /// - Parameter sessionId: The session ID to mark as active, or nil to clear
    public func setActiveSession(_ sessionId: UUID?) {
        logger.debug("Setting active session: \(sessionId?.uuidString.lowercased() ?? "nil")")
        activeSessionId = sessionId
    }

    /// Check if a given session is currently active
    /// - Parameter sessionId: The session ID to check
    /// - Returns: True if the session is currently active
    public func isActive(_ sessionId: UUID) -> Bool {
        return activeSessionId == sessionId
    }

    /// Clear the active session (user closed all sessions or navigated away)
    public func clearActiveSession() {
        logger.debug("Clearing active session")
        activeSessionId = nil
    }
}
