// DraftManager.swift
// Manages draft prompt text persistence across app lifecycle

import Foundation
import Combine

class DraftManager: ObservableObject {
    @Published private var drafts: [String: String] {
        didSet {
            // Defer UserDefaults write to avoid SwiftUI update conflicts
            DispatchQueue.main.async { [drafts] in
                UserDefaults.standard.set(drafts, forKey: "sessionDrafts")
            }
        }
    }

    init() {
        self.drafts = UserDefaults.standard.dictionary(forKey: "sessionDrafts") as? [String: String] ?? [:]
        print("📝 [DraftManager] Loaded \(drafts.count) drafts from storage")
    }

    /// Save draft text for a session. Removes entry if text is empty.
    func saveDraft(sessionID: String, text: String) {
        if text.isEmpty {
            drafts.removeValue(forKey: sessionID)
        } else {
            drafts[sessionID] = text
        }
    }

    /// Get draft text for a session. Returns empty string if no draft exists.
    func getDraft(sessionID: String) -> String {
        return drafts[sessionID] ?? ""
    }

    /// Clear draft for a session (e.g., after sending prompt)
    func clearDraft(sessionID: String) {
        drafts.removeValue(forKey: sessionID)
    }

    /// Remove draft for a deleted session (cleanup)
    func cleanupDraft(sessionID: String) {
        drafts.removeValue(forKey: sessionID)
    }
}
