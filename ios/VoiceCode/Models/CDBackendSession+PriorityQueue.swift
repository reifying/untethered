// CDBackendSession+PriorityQueue.swift
// Shared priority queue management functions

import Foundation
import CoreData
import OSLog

extension CDBackendSession {

    // MARK: - Priority Queue Management

    /// Add session to priority queue with FIFO ordering within priority level
    static func addToPriorityQueue(_ session: CDBackendSession, context: NSManagedObjectContext) {
        guard !session.isInPriorityQueue else {
            Logger.priorityQueue.info("⚠️ [PriorityQueue] Session already in queue: \(session.id.uuidString.lowercased())")
            return
        }

        session.isInPriorityQueue = true
        let maxOrder = fetchMaxPriorityOrder(priority: session.priority, context: context)
        session.priorityOrder = maxOrder + 1.0
        session.priorityQueuedAt = Date()

        do {
            try context.save()
            Logger.priorityQueue.info("✅ [PriorityQueue] Added session to priority queue: \(session.id.uuidString.lowercased()), priority=\(session.priority), order=\(session.priorityOrder)")

            // Post notification for cross-view synchronization
            NotificationCenter.default.post(
                name: .priorityQueueChanged,
                object: nil,
                userInfo: ["sessionId": session.id.uuidString.lowercased()]
            )
        } catch {
            Logger.priorityQueue.error("❌ [PriorityQueue] Failed to add session to queue: \(error.localizedDescription)")
        }
    }

    /// Remove session from priority queue and reset properties
    static func removeFromPriorityQueue(_ session: CDBackendSession, context: NSManagedObjectContext) {
        guard session.isInPriorityQueue else {
            Logger.priorityQueue.info("⚠️ [PriorityQueue] Session not in queue: \(session.id.uuidString.lowercased())")
            return
        }

        // Save old values for rollback
        let oldIsInQueue = session.isInPriorityQueue
        let oldPriority = session.priority
        let oldOrder = session.priorityOrder
        let oldQueuedAt = session.priorityQueuedAt

        session.isInPriorityQueue = false
        session.priority = 10  // Reset to default
        session.priorityOrder = 0.0
        session.priorityQueuedAt = nil

        do {
            try context.save()
            Logger.priorityQueue.info("✅ [PriorityQueue] Removed session from priority queue: \(session.id.uuidString.lowercased())")

            // Post notification for cross-view synchronization
            NotificationCenter.default.post(
                name: .priorityQueueChanged,
                object: nil,
                userInfo: ["sessionId": session.id.uuidString.lowercased()]
            )
        } catch {
            // Rollback on failure
            session.isInPriorityQueue = oldIsInQueue
            session.priority = oldPriority
            session.priorityOrder = oldOrder
            session.priorityQueuedAt = oldQueuedAt
            Logger.priorityQueue.error("❌ [PriorityQueue] Failed to remove session from queue: \(error.localizedDescription)")
        }
    }

    /// Change session priority and reorder within new priority level
    static func changePriority(_ session: CDBackendSession, newPriority: Int32, context: NSManagedObjectContext) {
        guard session.isInPriorityQueue else {
            Logger.priorityQueue.warning("⚠️ [PriorityQueue] Cannot change priority - session not in queue: \(session.id.uuidString.lowercased())")
            return
        }

        let oldPriority = session.priority
        guard oldPriority != newPriority else {
            Logger.priorityQueue.info("🔄 [PriorityQueue] Priority unchanged: \(newPriority)")
            return
        }

        // Save old values for rollback
        let oldOrder = session.priorityOrder

        // Fetch max order for NEW priority BEFORE changing this session's priority
        let maxOrder = fetchMaxPriorityOrder(priority: newPriority, context: context)

        // Now set new priority and recalculate priorityOrder
        session.priority = newPriority
        session.priorityOrder = maxOrder + 1.0

        do {
            try context.save()
            Logger.priorityQueue.info("✅ [PriorityQueue] Changed priority: \(oldPriority) → \(newPriority), order=\(session.priorityOrder)")

            // Post notification for cross-view synchronization
            NotificationCenter.default.post(
                name: .priorityQueueChanged,
                object: nil,
                userInfo: ["sessionId": session.id.uuidString.lowercased()]
            )
        } catch {
            // Rollback on failure
            session.priority = oldPriority
            session.priorityOrder = oldOrder
            Logger.priorityQueue.error("❌ [PriorityQueue] Failed to change priority: \(error.localizedDescription)")
        }
    }

    // MARK: - Helper Functions

    /// Fetch maximum priorityOrder for sessions with given priority level
    /// Returns 0.0 if no sessions found at this priority level
    private static func fetchMaxPriorityOrder(priority: Int32, context: NSManagedObjectContext) -> Double {
        let request: NSFetchRequest<CDBackendSession> = CDBackendSession.fetchRequest()
        request.predicate = NSPredicate(format: "isInPriorityQueue == YES AND priority == %d", priority)
        request.fetchLimit = 100  // Limit to prevent full table scan

        do {
            let sessions = try context.fetch(request)
            let maxOrder = sessions.map { $0.priorityOrder }.max() ?? 0.0
            Logger.priorityQueue.debug("📊 [PriorityQueue] Max order for priority \(priority): \(maxOrder) (from \(sessions.count) sessions)")
            return maxOrder
        } catch {
            Logger.priorityQueue.error("❌ [PriorityQueue] Failed to fetch max priority order: \(error.localizedDescription), priority=\(priority)")
            return 0.0
        }
    }
}

// MARK: - NotificationCenter Names

extension Notification.Name {
    static let priorityQueueChanged = Notification.Name("priorityQueueChanged")
}

// MARK: - OSLog Logger

extension Logger {
    private static var subsystem = Bundle.main.bundleIdentifier!

    static let priorityQueue = Logger(subsystem: subsystem, category: "PriorityQueue")
}
