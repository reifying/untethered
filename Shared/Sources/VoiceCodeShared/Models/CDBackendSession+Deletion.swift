// CDBackendSession+Deletion.swift
// Soft delete functionality for sessions

import Foundation
import CoreData
import OSLog

extension CDBackendSession {

    // MARK: - Soft Delete

    /// Soft delete a session by marking CDUserSession.isUserDeleted = true
    /// Returns true if the session was successfully marked as deleted
    @discardableResult
    public static func softDeleteSession(_ session: CDBackendSession, context: NSManagedObjectContext) -> Bool {
        // Find or create CDUserSession for this session
        let request = CDUserSession.fetchUserSession(id: session.id)
        let userSession: CDUserSession

        do {
            if let existing = try context.fetch(request).first {
                userSession = existing
            } else {
                // Create new CDUserSession if it doesn't exist
                userSession = CDUserSession(context: context)
                userSession.id = session.id
                userSession.createdAt = Date()
                userSession.customName = nil
            }

            userSession.isUserDeleted = true

            // Also remove from priority queue if present
            if session.isInPriorityQueue {
                session.isInPriorityQueue = false
                session.priority = 10  // Reset to default
                session.priorityOrder = 0.0
                session.priorityQueuedAt = nil
            }

            try context.save()
            Logger.sessionDeletion.info("✅ [SessionDeletion] Soft deleted session: \(session.id.uuidString.lowercased())")

            // Post notification for cross-view synchronization
            NotificationCenter.default.post(
                name: .sessionDeleted,
                object: nil,
                userInfo: ["sessionId": session.id.uuidString.lowercased()]
            )

            return true
        } catch {
            Logger.sessionDeletion.error("❌ [SessionDeletion] Failed to soft delete session: \(error.localizedDescription), sessionId=\(session.id.uuidString.lowercased())")
            return false
        }
    }

    /// Restore a soft-deleted session
    /// Returns true if the session was successfully restored
    @discardableResult
    public static func restoreSession(_ session: CDBackendSession, context: NSManagedObjectContext) -> Bool {
        let request = CDUserSession.fetchUserSession(id: session.id)

        do {
            guard let userSession = try context.fetch(request).first else {
                Logger.sessionDeletion.warning("⚠️ [SessionDeletion] No CDUserSession found for session: \(session.id.uuidString.lowercased())")
                return false
            }

            userSession.isUserDeleted = false
            try context.save()
            Logger.sessionDeletion.info("✅ [SessionDeletion] Restored session: \(session.id.uuidString.lowercased())")

            // Post notification for cross-view synchronization
            NotificationCenter.default.post(
                name: .sessionListDidUpdate,
                object: nil,
                userInfo: ["sessionId": session.id.uuidString.lowercased()]
            )

            return true
        } catch {
            Logger.sessionDeletion.error("❌ [SessionDeletion] Failed to restore session: \(error.localizedDescription), sessionId=\(session.id.uuidString.lowercased())")
            return false
        }
    }
}

// MARK: - Logger Extension

extension Logger {
    /// Logger for session deletion operations
    public static var sessionDeletion: Logger {
        Logger(subsystem: LoggingConfig.subsystem, category: "SessionDeletion")
    }
}
