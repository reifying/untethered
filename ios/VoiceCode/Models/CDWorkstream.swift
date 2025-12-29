// CDWorkstream.swift
// CoreData entity for workstream storage (logical unit of work)

import Foundation
import CoreData

@objc(CDWorkstream)
public class CDWorkstream: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var name: String
    @NSManaged public var workingDirectory: String
    @NSManaged public var activeClaudeSessionId: UUID?
    @NSManaged public var queuePriority: String      // "high", "normal", "low"
    @NSManaged public var priorityOrder: Double
    @NSManaged public var createdAt: Date
    @NSManaged public var lastModified: Date

    // Cached from active Claude session for display
    @NSManaged public var messageCount: Int32
    @NSManaged public var preview: String?
    @NSManaged public var unreadCount: Int32

    // Queue membership
    @NSManaged public var isInPriorityQueue: Bool
    @NSManaged public var priorityQueuedAt: Date?
}

// MARK: - Computed Properties
extension CDWorkstream {
    /// Whether workstream has an active Claude session
    var hasActiveSession: Bool {
        activeClaudeSessionId != nil
    }

    /// Whether workstream is in "cleared" state (no active session)
    var isCleared: Bool {
        activeClaudeSessionId == nil
    }
}

// MARK: - Fetch Requests
extension CDWorkstream {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDWorkstream> {
        return NSFetchRequest<CDWorkstream>(entityName: "CDWorkstream")
    }

    /// Fetch all workstreams sorted by last modified
    static func fetchAllWorkstreams() -> NSFetchRequest<CDWorkstream> {
        let request = fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \CDWorkstream.lastModified, ascending: false)
        ]
        return request
    }

    /// Fetch workstreams for a specific working directory
    static func fetchWorkstreams(workingDirectory: String) -> NSFetchRequest<CDWorkstream> {
        let request = fetchRequest()
        request.predicate = NSPredicate(format: "workingDirectory == %@", workingDirectory)
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \CDWorkstream.lastModified, ascending: false)
        ]
        return request
    }

    /// Fetch workstream by ID
    static func fetchWorkstream(id: UUID) -> NSFetchRequest<CDWorkstream> {
        let request = fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return request
    }

    /// Fetch workstreams in priority queue, sorted by priority
    static func fetchQueuedWorkstreams() -> NSFetchRequest<CDWorkstream> {
        let request = fetchRequest()
        request.predicate = NSPredicate(format: "isInPriorityQueue == YES")
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \CDWorkstream.queuePriority, ascending: true),
            NSSortDescriptor(keyPath: \CDWorkstream.priorityOrder, ascending: true)
        ]
        return request
    }
}

extension CDWorkstream: Identifiable {}
