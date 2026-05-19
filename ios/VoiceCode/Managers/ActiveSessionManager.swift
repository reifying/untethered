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

    /// Observable property for SwiftUI. Updated on the main thread only.
    @Published private(set) var activeSessionId: UUID?

    /// Lock-protected backing for cross-thread reads from background queues.
    /// SessionSyncManager calls isActive() from its per-session upsert queues,
    /// while setActiveSession / clearActiveSession are always called on main.
    /// Using a separate backing avoids unsafe cross-thread access to the
    /// @Published storage. tmux-untethered-2kp.
    private let lock = NSLock()
    private var lockedId: UUID?

    init() {}

    /// Mark a session as active (user opened it). Call from main thread.
    func setActiveSession(_ sessionId: UUID?) {
        print("📍 [ActiveSessionManager] Setting active session: \(sessionId?.uuidString.lowercased() ?? "nil")")
        lock.lock()
        lockedId = sessionId
        lock.unlock()
        activeSessionId = sessionId
    }

    /// Check if a given session is currently active. Thread-safe.
    func isActive(_ sessionId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lockedId == sessionId
    }

    /// Clear active session (user closed all sessions). Call from main thread.
    func clearActiveSession() {
        print("📍 [ActiveSessionManager] Clearing active session")
        lock.lock()
        lockedId = nil
        lock.unlock()
        activeSessionId = nil
    }
}
