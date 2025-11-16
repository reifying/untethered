// CDUserSession.swift
// CoreData entity for user session customizations (persistent)

import Foundation
import CoreData

@objc(CDUserSession)
public class CDUserSession: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var customName: String?
    @NSManaged public var isUserDeleted: Bool
    @NSManaged public var createdAt: Date
}

// MARK: - Fetch Requests
extension CDUserSession {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDUserSession> {
        return NSFetchRequest<CDUserSession>(entityName: "CDUserSession")
    }

    /// Fetch a specific user session by ID
    static func fetchUserSession(id: UUID) -> NSFetchRequest<CDUserSession> {
        let request = fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return request
    }
}

extension CDUserSession: Identifiable {}
