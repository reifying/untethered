// CDSession.swift
// CoreData entity for Session storage

import Foundation
import CoreData

@objc(CDSession)
public class CDSession: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var backendName: String
    @NSManaged public var localName: String?
    @NSManaged public var workingDirectory: String
    @NSManaged public var lastModified: Date
    @NSManaged public var messageCount: Int32
    @NSManaged public var preview: String
    @NSManaged public var unreadCount: Int32
    @NSManaged public var markedDeleted: Bool
    @NSManaged public var messages: NSSet?

    /// Display name: local custom name if set, otherwise backend name
    var displayName: String {
        localName ?? backendName
    }
}

// MARK: - Fetch Request
extension CDSession {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDSession> {
        return NSFetchRequest<CDSession>(entityName: "CDSession")
    }
    
    /// Fetch all non-deleted sessions, sorted by last modified date
    static func fetchActiveSessions() -> NSFetchRequest<CDSession> {
        let request = fetchRequest()
        request.predicate = NSPredicate(format: "markedDeleted == NO")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDSession.lastModified, ascending: false)]
        return request
    }
    
    /// Fetch a specific session by ID
    static func fetchSession(id: UUID) -> NSFetchRequest<CDSession> {
        let request = fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return request
    }
}

// MARK: - Generated accessors for messages
extension CDSession {
    @objc(addMessagesObject:)
    @NSManaged public func addToMessages(_ value: CDMessage)

    @objc(removeMessagesObject:)
    @NSManaged public func removeFromMessages(_ value: CDMessage)

    @objc(addMessages:)
    @NSManaged public func addToMessages(_ values: NSSet)

    @objc(removeMessages:)
    @NSManaged public func removeFromMessages(_ values: NSSet)
}

extension CDSession: Identifiable {}
