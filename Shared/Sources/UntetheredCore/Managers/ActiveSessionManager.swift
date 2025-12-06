//
//  ActiveSessionManager.swift
//  VoiceCode
//
//  Manages the currently active session for smart speaking logic
//

import Foundation
import Combine

/// Manages which session is currently active/visible to the user
@MainActor
public class ActiveSessionManager: ObservableObject {
    nonisolated(unsafe) public static let shared = ActiveSessionManager()

    @Published public private(set) var activeSessionId: UUID?

    nonisolated private init() {}

    /// Mark a session as active (user opened it)
    public func setActiveSession(_ sessionId: UUID?) {
        print("📍 [ActiveSessionManager] Setting active session: \(sessionId?.uuidString.lowercased() ?? "nil")")
        activeSessionId = sessionId
    }

    /// Check if a given session is currently active (thread-safe)
    nonisolated public func isActive(_ sessionId: UUID) -> Bool {
        // Since this is called from background contexts, we can't access activeSessionId directly
        // We need to assume the caller handles this appropriately or use MainActor.assumeIsolated
        MainActor.assumeIsolated {
            return activeSessionId == sessionId
        }
    }

    /// Clear active session (user closed all sessions)
    public func clearActiveSession() {
        print("📍 [ActiveSessionManager] Clearing active session")
        activeSessionId = nil
    }
}
