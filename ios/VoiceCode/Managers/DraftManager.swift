// DraftManager.swift
// Manages draft prompt text persistence across app lifecycle

import Foundation
import Combine

class DraftManager: ObservableObject {
    // CRITICAL: NOT @Published - drafts is internal state only
    // Publishing this causes SwiftUI re-evaluation on every keystroke,
    // triggering AttributeGraph crashes when TextField binding updates
    private var drafts: [String: String] = [:]

    private var saveWorkItem: DispatchWorkItem?

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

        // Debounce UserDefaults writes to avoid conflicts during rapid typing
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            UserDefaults.standard.set(self.drafts, forKey: "sessionDrafts")
        }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
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
