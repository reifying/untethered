// CDBackendSession.swift
// CoreData entity for backend session storage (ephemeral, synced from WebSocket)

import Foundation
import CoreData

@objc(CDBackendSession)
public class CDBackendSession: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var backendName: String
    @NSManaged public var workingDirectory: String
    @NSManaged public var lastModified: Date
    @NSManaged public var messageCount: Int32
    @NSManaged public var preview: String
    @NSManaged public var unreadCount: Int32
    @NSManaged public var isLocallyCreated: Bool
    @NSManaged public var messages: NSSet?

    /// Server-reported `next_seq` from the most recent `session_history`
    /// payload — the seq the backend will assign to the next new message.
    /// Persisted on the session (not on messages) so the resubscribe cursor
    /// survives local message pruning. `0` is the sentinel for "never
    /// received a payload"; real values from the wire start at `1`.
    @NSManaged public var nextSeq: Int64

    /// TTS gate cursor: the `seq` at-or-above which assistant messages are
    /// considered live (produced after the user opened this session in the
    /// current app launch). Captured once per app-session per CDBackendSession
    /// from the FIRST `session_history` reply's `nextSeq` after subscribe.
    /// Messages below this cursor were already on the backend when the user
    /// opened the session and must not be read aloud (tmux-untethered-i2n).
    /// `0` is the sentinel for "no boundary captured yet — suppress all TTS".
    /// Reset to `0` on app launch (PersistenceController) and on `unsubscribe`
    /// so a fresh open re-captures the boundary.
    @NSManaged public var liveFromSeq: Int64

    /// Provider identifier (e.g., "claude", "copilot")
    /// Defaults to "claude" for backward compatibility
    @NSManaged public var provider: String

    // Queue management properties
    @NSManaged public var isInQueue: Bool
    @NSManaged public var queuePosition: Int32
    @NSManaged public var queuedAt: Date?

    // Priority queue management properties
    @NSManaged public var isInPriorityQueue: Bool
    @NSManaged public var priority: Int32
    @NSManaged public var priorityOrder: Double
    @NSManaged public var priorityQueuedAt: Date?
}

// MARK: - User Customization Enrichment
extension CDBackendSession {
    /// Display name: user's custom name if set, otherwise backend name
    func displayName(context: NSManagedObjectContext) -> String {
        let request = CDUserSession.fetchUserSession(id: id)
        if let userSession = try? context.fetch(request).first,
           let customName = userSession.customName {
            return customName
        }
        return backendName
    }

    /// Check if user has marked this session as deleted
    func isUserDeleted(context: NSManagedObjectContext) -> Bool {
        let request = CDUserSession.fetchUserSession(id: id)
        if let userSession = try? context.fetch(request).first {
            return userSession.isUserDeleted
        }
        return false
    }
}


// MARK: - Fetch Requests
extension CDBackendSession {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDBackendSession> {
        return NSFetchRequest<CDBackendSession>(entityName: "CDBackendSession")
    }

    /// Fetch all backend sessions, sorted by last modified date
    static func fetchAllBackendSessions() -> NSFetchRequest<CDBackendSession> {
        let request = fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDBackendSession.lastModified, ascending: false)]
        return request
    }

    /// Fetch active sessions (not marked deleted by user)
    static func fetchActiveSessions(context: NSManagedObjectContext) throws -> [CDBackendSession] {
        let request = fetchAllBackendSessions()
        let allSessions = try context.fetch(request)
        return allSessions.filter { session in
            !session.isUserDeleted(context: context)
        }
    }

    /// Fetch active sessions for a specific working directory
    static func fetchActiveSessions(workingDirectory: String, context: NSManagedObjectContext) throws -> [CDBackendSession] {
        let request = fetchAllBackendSessions()
        request.predicate = NSPredicate(format: "workingDirectory == %@", workingDirectory)
        let allSessions = try context.fetch(request)
        return allSessions.filter { session in
            !session.isUserDeleted(context: context)
        }
    }

    /// Fetch a specific session by ID
    static func fetchBackendSession(id: UUID) -> NSFetchRequest<CDBackendSession> {
        let request = fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return request
    }

    /// Fetch a specific session by backend name (Claude session ID)
    static func fetchBackendSession(backendName: String) -> NSFetchRequest<CDBackendSession> {
        let request = fetchRequest()
        request.predicate = NSPredicate(format: "backendName == %@", backendName)
        request.fetchLimit = 1
        return request
    }
}

// MARK: - Generated accessors for messages
extension CDBackendSession {
    @objc(addMessagesObject:)
    @NSManaged public func addToMessages(_ value: CDMessage)

    @objc(removeMessagesObject:)
    @NSManaged public func removeFromMessages(_ value: CDMessage)

    @objc(addMessages:)
    @NSManaged public func addToMessages(_ values: NSSet)

    @objc(removeMessages:)
    @NSManaged public func removeFromMessages(_ values: NSSet)
}

extension CDBackendSession: Identifiable {}
