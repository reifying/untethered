// ErrorRecovery.swift
// Error recovery patterns per Appendix Z

import Foundation
import OSLog

/// Configuration for error recovery logging
public enum ErrorRecoveryConfig {
    /// The OSLog subsystem for error recovery logging
    nonisolated(unsafe) public static var subsystem: String = "com.voicecode.shared"
}

// MARK: - Custom Error Types (Z.1.1)

/// Error thrown when a session is locked and cannot accept new prompts
public struct SessionLockError: Error {
    public let sessionId: String
    public let message: String

    public init(sessionId: String, message: String = "Session is locked") {
        self.sessionId = sessionId
        self.message = message
    }
}

extension SessionLockError: LocalizedError {
    public var errorDescription: String? {
        return message
    }
}

// MARK: - Error Categories (Z.1)

/// Categories of errors and their recovery strategies
public enum ErrorCategory: Sendable {
    /// Network timeout, server busy - auto-retry with backoff
    case transient
    /// Invalid URL, missing permission - show error + action button
    case userRecoverable
    /// Corrupted database, missing entitlement - show error + support info
    case fatal
}

/// Classifies an error into a recovery category
public func categorizeError(_ error: Error) -> ErrorCategory {
    if let urlError = error as? URLError {
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .dnsLookupFailed:
            return .transient
        case .badURL, .unsupportedURL:
            return .userRecoverable
        default:
            return .transient
        }
    }

    if error is SessionLockError {
        return .userRecoverable
    }

    // Default to transient for unknown network-like errors
    return .transient
}

// MARK: - Retryable Operation (Z.2)

/// Executes an async operation with automatic retry and exponential backoff
public final class RetryableOperation<T: Sendable>: Sendable {
    public let maxAttempts: Int
    public let baseDelay: TimeInterval
    private let operation: @Sendable () async throws -> T
    private let logger = Logger(subsystem: ErrorRecoveryConfig.subsystem, category: "RetryableOperation")

    public init(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 1.0,
        operation: @escaping @Sendable () async throws -> T
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.operation = operation
    }

    public func execute() async throws -> T {
        var lastError: Error?
        var delay = baseDelay

        for attempt in 1...maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error

                // Check if error is retryable
                guard isRetryable(error) else { throw error }

                // Log attempt
                logger.warning("Attempt \(attempt)/\(self.maxAttempts) failed: \(error.localizedDescription)")

                // Wait before retry (except on last attempt)
                if attempt < maxAttempts {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    delay = min(delay * 2, 60.0)  // Cap at 60 seconds
                }
            }
        }

        throw lastError!
    }

    private func isRetryable(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotConnectToHost, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }
        return false
    }
}

// MARK: - User Recoverable Error (Z.3)

/// Action that can be performed to recover from an error
public struct UserRecoveryAction: Sendable {
    public let label: String
    public let perform: @Sendable @MainActor () -> Void

    public init(label: String, perform: @escaping @Sendable @MainActor () -> Void) {
        self.label = label
        self.perform = perform
    }
}

/// An error that can potentially be recovered from by user action
/// Named UserRecoverableError to avoid conflict with Foundation.RecoverableError
public struct UserRecoverableError: Sendable {
    public let title: String
    public let message: String
    public let recoveryAction: UserRecoveryAction?

    public init(title: String, message: String, recoveryAction: UserRecoveryAction? = nil) {
        self.title = title
        self.message = message
        self.recoveryAction = recoveryAction
    }
}

// MARK: - Error to UserRecoverableError Mapping (Z.4)

/// Maps a raw error to a user-friendly UserRecoverableError
/// Returns nil if the error is not user-recoverable
public func mapToUserRecoverableError(
    _ error: Error,
    serverURL: String? = nil,
    onReconnect: (@Sendable @MainActor () -> Void)? = nil,
    onOpenSettings: (@Sendable @MainActor () -> Void)? = nil
) -> UserRecoverableError? {
    switch error {
    case let urlError as URLError where urlError.code == .notConnectedToInternet:
        return UserRecoverableError(
            title: "No Internet Connection",
            message: "Check your network connection and try again.",
            recoveryAction: onReconnect.map { UserRecoveryAction(label: "Retry", perform: $0) }
        )

    case let urlError as URLError where urlError.code == .cannotFindHost:
        let serverInfo = serverURL.map { " Cannot reach \($0)." } ?? ""
        return UserRecoverableError(
            title: "Server Not Found",
            message: "Cannot find the server.\(serverInfo) Is the backend running?",
            recoveryAction: onOpenSettings.map { UserRecoveryAction(label: "Open Settings", perform: $0) }
        )

    case let urlError as URLError where urlError.code == .cannotConnectToHost:
        let serverInfo = serverURL.map { " Cannot connect to \($0)." } ?? ""
        return UserRecoverableError(
            title: "Connection Refused",
            message: "Connection was refused.\(serverInfo) Is the backend running?",
            recoveryAction: onReconnect.map { UserRecoveryAction(label: "Retry", perform: $0) }
        )

    case let urlError as URLError where urlError.code == .timedOut:
        return UserRecoverableError(
            title: "Connection Timed Out",
            message: "The server did not respond in time. Please try again.",
            recoveryAction: onReconnect.map { UserRecoveryAction(label: "Retry", perform: $0) }
        )

    case let lockError as SessionLockError:
        return UserRecoverableError(
            title: "Session Busy",
            message: "This session is processing another request. Please wait.",
            recoveryAction: nil  // Auto-clears when session unlocks
        )

    default:
        return nil  // Non-recoverable or unknown
    }
}
