// RecentReplies.swift
// The last few agent replies of a session, newest first: what "say that again"
// reads. Used by the headset's repeat gesture (HeadsetRemoteCommandManager) and
// by the driving-mode replay tiles (DrivingModeController), so both replay the
// same thing.

import Foundation
import CoreData

/// One agent reply that can be read again.
struct RecentReply: Identifiable, Equatable {
    let id: UUID
    /// The reply as stored, for display.
    let text: String
    /// The reply prepared for speech (code blocks removed, CamelCase split).
    let spokenText: String
    let timestamp: Date
}

enum RecentReplies {
    /// Rows fetched per reply wanted. A reply that is only a code block prepares
    /// down to nothing sayable and is skipped, so a few spares are fetched.
    private static let overfetchFactor = 3

    /// The newest `limit` replies of `sessionId` that have something to say,
    /// newest first. Tool calls and thinking never reach the client (the backend
    /// filters them), so every assistant row here is prose.
    static func fetch(sessionId: UUID, limit: Int, in context: NSManagedObjectContext) -> [RecentReply] {
        guard limit > 0 else { return [] }
        let request = CDMessage.fetchRequest()
        request.predicate = NSPredicate(format: "sessionId == %@ AND role == %@",
                                        sessionId as CVarArg, "assistant")
        // Same order as the conversation list, reversed.
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \CDMessage.timestamp, ascending: false),
            NSSortDescriptor(keyPath: \CDMessage.offset, ascending: false)
        ]
        request.fetchLimit = limit * overfetchFactor
        let rows: [CDMessage]
        do {
            rows = try context.fetch(request)
        } catch {
            LogManager.shared.log("Failed to fetch recent replies for session \(sessionId.uuidString.lowercased()): \(error.localizedDescription)", category: "RecentReplies")
            return []
        }
        var replies: [RecentReply] = []
        for row in rows {
            let spoken = TextProcessor.prepareForSpeech(from: row.text)
            guard isSayable(spoken) else { continue }
            replies.append(RecentReply(id: row.id, text: row.text, spokenText: spoken, timestamp: row.timestamp))
            if replies.count == limit { break }
        }
        return replies
    }

    /// Whether there is at least one letter or digit to read. A reply that
    /// prepares down to punctuation or nothing is not worth a replay slot.
    static func isSayable(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}
