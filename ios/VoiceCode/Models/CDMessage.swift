// CDMessage.swift
// CoreData entity for Message storage

import Foundation
import CoreData

/// Message delivery status
public enum MessageStatus: String, Codable {
    case sending    // Optimistic, not yet confirmed by server
    case confirmed  // Received from server
    case error      // Failed to send
}

@objc(CDMessage)
public class CDMessage: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var sessionId: UUID
    @NSManaged public var role: String
    @NSManaged public var text: String
    @NSManaged public var timestamp: Date
    @NSManaged private var status: String
    @NSManaged public var serverTimestamp: Date?
    @NSManaged public var session: CDSession?
    
    /// Typed status accessor
    var messageStatus: MessageStatus {
        get {
            MessageStatus(rawValue: status) ?? .confirmed
        }
        set {
            status = newValue.rawValue
        }
    }
}

// MARK: - Fetch Request
extension CDMessage {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDMessage> {
        return NSFetchRequest<CDMessage>(entityName: "CDMessage")
    }
    
    /// Fetch all messages for a session, sorted by timestamp
    static func fetchMessages(sessionId: UUID) -> NSFetchRequest<CDMessage> {
        let request = fetchRequest()
        request.predicate = NSPredicate(format: "sessionId == %@", sessionId as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDMessage.timestamp, ascending: true)]
        return request
    }
    
    /// Fetch a specific message by ID
    static func fetchMessage(id: UUID) -> NSFetchRequest<CDMessage> {
        let request = fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return request
    }
    
    /// Find message by text and role for reconciliation
    static func fetchMessage(sessionId: UUID, role: String, text: String) -> NSFetchRequest<CDMessage> {
        let request = fetchRequest()
        request.predicate = NSPredicate(format: "sessionId == %@ AND role == %@ AND text == %@",
                                       sessionId as CVarArg, role, text)
        request.fetchLimit = 1
        return request
    }
}

extension CDMessage: Identifiable {}
