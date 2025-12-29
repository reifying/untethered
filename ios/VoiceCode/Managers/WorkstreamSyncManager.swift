// WorkstreamSyncManager.swift
// Manages workstream metadata synchronization with backend

import Foundation
import CoreData
import os.log

private let logger = Logger(subsystem: "com.travisbrown.VoiceCode", category: "WorkstreamSync")

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when workstream list is updated from backend
    static let workstreamListDidUpdate = Notification.Name("workstreamListDidUpdate")
}

/// Manages synchronization of workstream metadata between backend and CoreData.
/// Replaces SessionSyncManager for workstream-based UI.
class WorkstreamSyncManager: ObservableObject {
    private let persistenceController: PersistenceController
    private let context: NSManagedObjectContext

    init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController
        self.context = persistenceController.container.viewContext
    }

    // MARK: - Workstream List Handling

    /// Handle workstream_list message from backend
    /// - Parameter workstreams: Array of workstream metadata dictionaries
    func handleWorkstreamList(_ workstreams: [[String: Any]]) async {
        logger.info("📥 Received workstream_list with \(workstreams.count) workstreams")

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            persistenceController.performBackgroundTask { [weak self] backgroundContext in
                guard let self = self else {
                    continuation.resume()
                    return
                }

                for data in workstreams {
                    guard let idString = data["workstream_id"] as? String,
                          let id = UUID(uuidString: idString) else {
                        logger.warning("⚠️ Skipping workstream with invalid or missing workstream_id")
                        continue
                    }
                    self.upsertWorkstream(id: id, data: data, in: backgroundContext)
                }

                do {
                    if backgroundContext.hasChanges {
                        try backgroundContext.save()
                        logger.info("✅ Saved \(workstreams.count) workstreams to CoreData")

                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .workstreamListDidUpdate, object: nil)
                        }
                    }
                } catch {
                    logger.error("❌ Failed to save workstream_list: \(error.localizedDescription)")
                }

                continuation.resume()
            }
        }
    }

    // MARK: - Workstream Updated Handling

    /// Handle workstream_updated message from backend
    func handleWorkstreamUpdated(_ data: [String: Any]) async {
        guard let idString = data["workstream_id"] as? String,
              let id = UUID(uuidString: idString) else {
            logger.warning("⚠️ workstream_updated missing valid workstream_id")
            return
        }

        logger.info("📨 workstream_updated received: \(idString.prefix(8))...")

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            persistenceController.performBackgroundTask { [weak self] backgroundContext in
                guard let self = self else {
                    continuation.resume()
                    return
                }

                self.upsertWorkstream(id: id, data: data, in: backgroundContext)

                do {
                    if backgroundContext.hasChanges {
                        try backgroundContext.save()
                        logger.info("✅ Updated workstream: \(idString.prefix(8))...")
                    }
                } catch {
                    logger.error("❌ Failed to save workstream_updated: \(error.localizedDescription)")
                }

                continuation.resume()
            }
        }
    }

    // MARK: - Context Cleared Handling

    /// Handle context_cleared message - clears active session and associated messages
    /// - Parameters:
    ///   - workstreamId: The workstream UUID
    ///   - previousClaudeSessionId: The previous Claude session ID (may be nil if workstream had no active session)
    func handleContextCleared(workstreamId: UUID, previousClaudeSessionId: UUID?) async {
        logger.info("🧹 context_cleared for workstream: \(workstreamId.uuidString.prefix(8))..., previousSession: \(previousClaudeSessionId?.uuidString.prefix(8) ?? "nil")")

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            persistenceController.performBackgroundTask { backgroundContext in
                // Update workstream
                let workstreamRequest = CDWorkstream.fetchWorkstream(id: workstreamId)
                if let workstream = try? backgroundContext.fetch(workstreamRequest).first {
                    workstream.activeClaudeSessionId = nil
                    workstream.messageCount = 0
                    workstream.preview = nil
                    workstream.lastModified = Date()
                    logger.info("✅ Cleared workstream active session")
                } else {
                    logger.warning("⚠️ Workstream not found for context_cleared: \(workstreamId.uuidString.prefix(8))...")
                }

                // Delete messages associated with the previous Claude session
                if let previousSessionId = previousClaudeSessionId {
                    let messageRequest: NSFetchRequest<NSFetchRequestResult> = CDMessage.fetchRequest()
                    messageRequest.predicate = NSPredicate(format: "sessionId == %@", previousSessionId as CVarArg)
                    let deleteRequest = NSBatchDeleteRequest(fetchRequest: messageRequest)
                    deleteRequest.resultType = .resultTypeCount

                    do {
                        let result = try backgroundContext.execute(deleteRequest) as? NSBatchDeleteResult
                        let deletedCount = result?.result as? Int ?? 0
                        logger.info("✅ Deleted \(deletedCount) messages for cleared session: \(previousSessionId.uuidString.prefix(8))...")
                    } catch {
                        logger.error("❌ Failed to delete messages: \(error.localizedDescription)")
                    }
                }

                do {
                    if backgroundContext.hasChanges {
                        try backgroundContext.save()
                    }
                } catch {
                    logger.error("❌ Failed to save context_cleared: \(error.localizedDescription)")
                }

                continuation.resume()
            }
        }
    }

    // MARK: - Local Workstream Creation

    /// Create a new workstream locally (before sending to backend)
    /// Use this for optimistic UI - create locally first, then send to backend
    /// - Parameters:
    ///   - workingDirectory: The working directory path
    ///   - name: Optional custom name (defaults to "New Workstream")
    /// - Returns: The created CDWorkstream entity
    func createWorkstream(workingDirectory: String, name: String? = nil) -> CDWorkstream {
        let workstream = CDWorkstream(context: context)
        workstream.id = UUID()
        workstream.name = name ?? "New Workstream"
        workstream.workingDirectory = workingDirectory
        workstream.queuePriority = "normal"
        workstream.priorityOrder = 0
        workstream.createdAt = Date()
        workstream.lastModified = Date()
        workstream.messageCount = 0
        workstream.unreadCount = 0
        workstream.isInPriorityQueue = false

        do {
            try context.save()
            logger.info("✅ Created local workstream: \(workstream.id.uuidString.prefix(8))...")
        } catch {
            logger.error("❌ Failed to create local workstream: \(error.localizedDescription)")
        }

        return workstream
    }

    // MARK: - Private Helpers

    private func upsertWorkstream(id: UUID, data: [String: Any], in context: NSManagedObjectContext) {
        let request = CDWorkstream.fetchWorkstream(id: id)
        let workstream: CDWorkstream
        let isNew: Bool

        if let existing = try? context.fetch(request).first {
            workstream = existing
            isNew = false
        } else {
            workstream = CDWorkstream(context: context)
            workstream.id = id
            workstream.createdAt = Date()
            workstream.lastModified = Date()
            workstream.isInPriorityQueue = false
            workstream.unreadCount = 0
            workstream.messageCount = 0
            workstream.queuePriority = "normal"
            workstream.priorityOrder = 0.0
            workstream.name = "New Workstream"  // Default, may be overwritten below
            workstream.workingDirectory = ""    // Default, may be overwritten below
            isNew = true
        }

        if let name = data["name"] as? String {
            workstream.name = name
        }
        if let workingDirectory = data["working_directory"] as? String {
            workstream.workingDirectory = workingDirectory
        } else if isNew {
            // Log warning if working directory is missing for new workstream
            logger.warning("⚠️ workstream \(id.uuidString.prefix(8))... missing working_directory")
        }

        // Handle active_claude_session_id - only update if key is present in data
        // If key is missing entirely, preserve existing value (partial update scenario)
        // If key is present with string value, set the UUID
        // If key is present with NSNull or nil, clear the session
        if let activeSessionIdString = data["active_claude_session_id"] as? String {
            workstream.activeClaudeSessionId = UUID(uuidString: activeSessionIdString)
        } else if data.keys.contains("active_claude_session_id") {
            // Key is present but not a valid string (NSNull, nil, or invalid type) - clear the session
            workstream.activeClaudeSessionId = nil
        }
        // If key is not present at all, preserve existing value

        if let priority = data["queue_priority"] as? String {
            workstream.queuePriority = priority
        }
        if let priorityOrder = data["priority_order"] as? Double {
            workstream.priorityOrder = priorityOrder
        }
        if let messageCount = data["message_count"] as? Int {
            workstream.messageCount = Int32(messageCount)
        }
        if let preview = data["preview"] as? String {
            workstream.preview = preview
        }

        // Parse last_modified timestamp
        if let lastModifiedString = data["last_modified"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: lastModifiedString) {
                workstream.lastModified = date
            }
        } else if let lastModifiedMs = data["last_modified"] as? TimeInterval {
            // Support milliseconds timestamp format
            workstream.lastModified = Date(timeIntervalSince1970: lastModifiedMs / 1000.0)
        }

        // Parse created_at timestamp
        if let createdAtString = data["created_at"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: createdAtString) {
                workstream.createdAt = date
            }
        }
    }
}
