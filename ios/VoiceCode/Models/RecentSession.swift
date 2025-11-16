// RecentSession.swift
// Model for recent session data from backend

import Foundation
import CoreData

struct RecentSession: Identifiable, Equatable {
    let sessionId: String
    let workingDirectory: String
    let lastModified: Date
    
    var id: String { sessionId }
    
    // Parse from WebSocket JSON (snake_case keys)
    // Backend no longer sends 'name' - we derive it from CoreData or working directory
    init?(json: [String: Any]) {
        guard let sessionId = json["session_id"] as? String,
              let workingDirectory = json["working_directory"] as? String,
              let lastModifiedString = json["last_modified"] as? String else {
            print("❌ RecentSession parse failed - missing fields. Keys: \(json.keys.sorted())")
            print("   session_id: \(json["session_id"] as? String ?? "MISSING")")
            print("   working_directory: \(json["working_directory"] as? String ?? "MISSING")")
            print("   last_modified: \(json["last_modified"] as? String ?? "MISSING")")
            return nil
        }

        // Parse ISO-8601 timestamp (with fractional seconds)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let lastModified = formatter.date(from: lastModifiedString) else {
            print("❌ RecentSession parse failed - invalid ISO-8601 date: '\(lastModifiedString)'")
            return nil
        }

        self.sessionId = sessionId
        self.workingDirectory = workingDirectory
        self.lastModified = lastModified
    }
    
    // For testing
    init(sessionId: String, workingDirectory: String, lastModified: Date) {
        self.sessionId = sessionId
        self.workingDirectory = workingDirectory
        self.lastModified = lastModified
    }
    
    // Get display name by looking up in CoreData, with fallback to directory name
    func displayName(using context: NSManagedObjectContext) -> String {
        guard let uuid = UUID(uuidString: sessionId) else {
            return fallbackName
        }

        let request = CDBackendSession.fetchBackendSession(id: uuid)
        guard let session = try? context.fetch(request).first else {
            return fallbackName
        }

        return session.displayName(context: context)
    }
    
    // Fallback name derived from working directory (last path component)
    private var fallbackName: String {
        workingDirectory.split(separator: "/").last.map(String.init) ?? sessionId
    }
}
