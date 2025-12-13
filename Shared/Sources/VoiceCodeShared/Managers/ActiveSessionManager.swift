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
///
/// ## Usage
/// Use the `.shared` singleton for production code:
/// ```swift
/// ActiveSessionManager.shared.setActiveSession(sessionId)
/// ```
///
/// The public `init()` is available for dependency injection in tests, but note that
/// `SessionSyncDelegate` implementations typically access `.shared` directly.
/// For testing delegate behavior, configure `.shared` state in your tests.
@MainActor
public final class ActiveSessionManager: ObservableObject, Sendable {

    // MARK: - Shared Instance

    /// Shared singleton instance for global access
    ///
    /// Use this instance in production code. The singleton ensures consistent
    /// active session state across the app.
    public static let shared = ActiveSessionManager()

    // MARK: - Published Properties

    /// The currently active session ID (if any)
    @Published public private(set) var activeSessionId: UUID?

    // MARK: - Private Properties

    private let logger = Logger(subsystem: ActiveSessionConfig.subsystem, category: "ActiveSession")

    // MARK: - Initialization

    /// Creates a new ActiveSessionManager instance.
    ///
    /// - Note: Prefer using `.shared` in production code. This initializer is
    ///   public primarily for testing purposes.
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
