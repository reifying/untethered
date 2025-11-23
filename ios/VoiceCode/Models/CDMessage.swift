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
    @NSManaged public var session: CDBackendSession?
    
    /// Typed status accessor
    var messageStatus: MessageStatus {
        get {
            MessageStatus(rawValue: status) ?? .confirmed
        }
        set {
            status = newValue.rawValue
        }
    }

    // MARK: - Display Properties

    /// Truncation length for visual display (first N + last N chars)
    private static let truncationHalfLength = 250

    /// Cached display text with truncation applied
    /// Computed once and cached to avoid recalculation on every layout pass
    private var _displayTextCache: String?
    private var _displayTextCacheKey: Int?

    /// Display text with truncation for UI rendering
    /// Returns first 250 + last 250 chars if text exceeds 500 chars
    /// Cached based on text.count to avoid recomputation during layout
    var displayText: String {
        // Check cache validity (keyed by text length)
        let cacheKey = text.count
        if let cached = _displayTextCache, _displayTextCacheKey == cacheKey {
            return cached
        }

        // Compute truncated text
        let truncationLength = Self.truncationHalfLength * 2
        let result: String

        if text.count <= truncationLength {
            result = text
        } else {
            let head = String(text.prefix(Self.truncationHalfLength))
            let tail = String(text.suffix(Self.truncationHalfLength))
            let omittedCount = text.count - truncationLength
            result = "\(head)\n\n[... \(omittedCount) characters omitted ...]\n\n\(tail)"
        }

        // Cache result
        _displayTextCache = result
        _displayTextCacheKey = cacheKey

        return result
    }

    /// Whether this message's text is truncated in display
    var isTruncated: Bool {
        text.count > (Self.truncationHalfLength * 2)
    }
}

// MARK: - Fetch Request
extension CDMessage {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDMessage> {
        return NSFetchRequest<CDMessage>(entityName: "CDMessage")
    }
    
    /// Fetch all messages for a session, sorted chronologically (oldest first)
    /// No fetchLimit - hangs prevented by animation:nil and removed withAnimation wrappers
    static func fetchMessages(sessionId: UUID) -> NSFetchRequest<CDMessage> {
        let request = fetchRequest()
        request.predicate = NSPredicate(format: "sessionId == %@", sessionId as CVarArg)
        // Sort ascending for chronological display (oldest first, newest at bottom)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDMessage.timestamp, ascending: true)]

        // Ensure all properties are loaded to prevent faulting during view updates
        // This prevents CoreData from deallocating objects mid-update
        request.includesPropertyValues = true
        request.returnsObjectsAsFaults = false

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
