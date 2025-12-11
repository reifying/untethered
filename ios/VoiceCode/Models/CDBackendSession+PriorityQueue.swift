// CDBackendSession+PriorityQueue.swift
// Shared priority queue management functions

import Foundation
import CoreData
import OSLog

extension CDBackendSession {

    // MARK: - Priority Queue Management

    /// Add session to priority queue, or move to end of priority level if already in queue
    /// This implements queue semantics: newly active sessions go to the back of the line
    static func addToPriorityQueue(_ session: CDBackendSession, context: NSManagedObjectContext) {
        let wasAlreadyInQueue = session.isInPriorityQueue

        // Calculate new order - always move to end of priority level
        let maxOrder = fetchMaxPriorityOrder(priority: session.priority, context: context, excluding: session)
        let newOrder = maxOrder + 1.0

        // Skip if already at end (no change needed)
        if wasAlreadyInQueue && session.priorityOrder == newOrder {
            Logger.priorityQueue.debug("⏭️ [PriorityQueue] Session already at end of priority level: \(session.id.uuidString.lowercased())")
            return
        }

        session.isInPriorityQueue = true
        session.priorityOrder = newOrder

        // Only set queuedAt on initial add, not on reorder
        if !wasAlreadyInQueue {
            session.priorityQueuedAt = Date()
        }

        do {
            try context.save()
            if wasAlreadyInQueue {
                Logger.priorityQueue.info("🔄 [PriorityQueue] Moved session to end of priority level: \(session.id.uuidString.lowercased()), priority=\(session.priority), order=\(session.priorityOrder)")
            } else {
                Logger.priorityQueue.info("✅ [PriorityQueue] Added session to priority queue: \(session.id.uuidString.lowercased()), priority=\(session.priority), order=\(session.priorityOrder)")
            }

            // Post notification for cross-view synchronization
            NotificationCenter.default.post(
                name: .priorityQueueChanged,
                object: nil,
                userInfo: ["sessionId": session.id.uuidString.lowercased()]
            )
        } catch {
            Logger.priorityQueue.error("❌ [PriorityQueue] Failed to add/move session in queue: \(error.localizedDescription)")
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
        // Exclude current session to avoid race condition if priority is already changed in memory
        let maxOrder = fetchMaxPriorityOrder(priority: newPriority, context: context, excluding: session)

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

    /// Reorder session within priority queue based on drag destination
    /// Calculates new priority and priorityOrder based on neighbors
    /// - Parameters:
    ///   - session: Session being moved
    ///   - above: Session above the drop position (nil if dropped at top)
    ///   - below: Session below the drop position (nil if dropped at bottom)
    ///   - context: NSManagedObjectContext for the save
    static func reorderSession(_ session: CDBackendSession, between above: CDBackendSession?, and below: CDBackendSession?, context: NSManagedObjectContext) {
        guard session.isInPriorityQueue else {
            Logger.priorityQueue.warning("⚠️ [PriorityQueue] Cannot reorder - session not in queue: \(session.id.uuidString.lowercased())")
            return
        }

        // Save old values for rollback
        let oldPriority = session.priority
        let oldOrder = session.priorityOrder

        if let above = above, let below = below {
            if above.priority == below.priority {
                // Same priority: calculate midpoint for priorityOrder
                session.priority = above.priority
                session.priorityOrder = (above.priorityOrder + below.priorityOrder) / 2.0
                Logger.priorityQueue.debug("📍 [Reorder] Same priority - midpoint: \(session.priorityOrder)")
            } else {
                // Different priorities: adopt BELOW session's priority, position at end
                session.priority = below.priority
                let maxOrder = fetchMaxPriorityOrder(priority: below.priority, context: context, excluding: session)
                session.priorityOrder = maxOrder + 1.0
                Logger.priorityQueue.debug("📍 [Reorder] Different priorities - adopting P\(below.priority), order: \(session.priorityOrder)")
            }
        } else if let above = above {
            // Dropped at bottom: same priority as above, order = above + 1
            session.priority = above.priority
            session.priorityOrder = above.priorityOrder + 1.0
            Logger.priorityQueue.debug("📍 [Reorder] Dropped at bottom - P\(above.priority), order: \(session.priorityOrder)")
        } else if let below = below {
            // Dropped at top: same priority as below, order = below - 1
            session.priority = below.priority
            session.priorityOrder = below.priorityOrder - 1.0
            Logger.priorityQueue.debug("📍 [Reorder] Dropped at top - P\(below.priority), order: \(session.priorityOrder)")
        } else {
            // No neighbors (single item in queue) - nothing to do
            Logger.priorityQueue.debug("📍 [Reorder] Single item in queue - no change needed")
            return
        }

        do {
            try context.save()
            Logger.priorityQueue.info("✅ [PriorityQueue] Reordered session: P\(oldPriority)/\(oldOrder) → P\(session.priority)/\(session.priorityOrder)")

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
            Logger.priorityQueue.error("❌ [PriorityQueue] Failed to reorder session: \(error.localizedDescription)")
        }
    }

    // MARK: - Helper Functions

    /// Fetch maximum priorityOrder for sessions with given priority level
    /// Returns 0.0 if no sessions found at this priority level
    /// - Parameters:
    ///   - priority: Priority level to query
    ///   - context: NSManagedObjectContext for the fetch
    ///   - excluding: Optional session to exclude from the query (for changePriority race condition safety)
    private static func fetchMaxPriorityOrder(priority: Int32, context: NSManagedObjectContext, excluding: CDBackendSession? = nil) -> Double {
        let request: NSFetchRequest<CDBackendSession> = CDBackendSession.fetchRequest()

        if let excludeSession = excluding {
            // Exclude the specified session to avoid race conditions during priority changes
            request.predicate = NSPredicate(format: "isInPriorityQueue == YES AND priority == %d AND SELF != %@", priority, excludeSession)
        } else {
            request.predicate = NSPredicate(format: "isInPriorityQueue == YES AND priority == %d", priority)
        }

        request.fetchLimit = 100  // Limit to prevent full table scan

        do {
            let sessions = try context.fetch(request)
            let maxOrder = sessions.map { $0.priorityOrder }.max() ?? 0.0
            Logger.priorityQueue.debug("📊 [PriorityQueue] Max order for priority \(priority): \(maxOrder) (from \(sessions.count) sessions\(excluding != nil ? ", excluding current session" : ""))")
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
