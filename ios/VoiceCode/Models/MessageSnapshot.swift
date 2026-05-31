// MessageSnapshot.swift
// Captured snapshot of a message for stable sheet presentation.
//
// Decoupled from CoreData—survives list churn, pruning, and cell recycling.
// Foundation for the "View Full" dialog dismiss fix: the detail sheet holds a
// value-type snapshot taken at tap time, so incoming messages, pruning, and
// List cell recycling can never dismiss the open sheet. See
// docs/design/view-full-dialog-dismiss-fix.md (tmux-untethered-649).

import Foundation

/// Captured snapshot of a message for stable sheet presentation.
/// Decoupled from CoreData—survives list churn, pruning, and cell recycling.
struct MessageSnapshot: Identifiable {
    /// Fresh UUID per presentation—avoids SwiftUI's same-id no-re-present bug
    /// when the user taps "View Full" on the same message twice.
    let id: UUID
    /// The CoreData message UUID (for analytics and live-text @FetchRequest lookup).
    let messageId: UUID
    let role: String
    let timestamp: Date
    let sessionId: UUID
    let workingDirectory: String?
    let text: String

    init(from message: CDMessage) {
        self.id = UUID()
        self.messageId = message.id
        self.role = message.role
        self.timestamp = message.timestamp
        self.sessionId = message.sessionId
        self.workingDirectory = message.session?.workingDirectory
        self.text = message.text
    }
}
