//
//  ActiveSessionManager.swift
//  VoiceCode
//
//  Manages the currently active session for smart speaking logic
//

import Foundation
import Combine

/// Manages which session is currently active/visible to the user
class ActiveSessionManager: ObservableObject {
    static let shared = ActiveSessionManager()

    @Published private(set) var activeSessionId: UUID?

    private init() {}

    /// Mark a session as active (user opened it)
    func setActiveSession(_ sessionId: UUID?) {
        print("📍 [ActiveSessionManager] Setting active session: \(sessionId?.uuidString ?? "nil")")
        activeSessionId = sessionId
    }

    /// Check if a given session is currently active
    func isActive(_ sessionId: UUID) -> Bool {
        return activeSessionId == sessionId
    }

    /// Clear active session (user closed all sessions)
    func clearActiveSession() {
        print("📍 [ActiveSessionManager] Clearing active session")
        activeSessionId = nil
    }
}
