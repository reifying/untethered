// RecentSession.swift
// Model for recent session data from backend

import Foundation

struct RecentSession: Identifiable, Equatable {
    let sessionId: String
    let name: String
    let workingDirectory: String
    let lastModified: Date
    
    var id: String { sessionId }
    
    // Parse from WebSocket JSON (snake_case keys)
    init?(json: [String: Any]) {
        guard let sessionId = json["session_id"] as? String,
              let name = json["name"] as? String,
              let workingDirectory = json["working_directory"] as? String,
              let lastModifiedString = json["last_modified"] as? String else {
            print("❌ RecentSession parse failed - missing fields. Keys: \(json.keys.sorted())")
            print("   session_id: \(json["session_id"] as? String ?? "MISSING")")
            print("   name: \(json["name"] as? String ?? "MISSING")")
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
        self.name = name
        self.workingDirectory = workingDirectory
        self.lastModified = lastModified
    }
    
    // For testing
    init(sessionId: String, name: String, workingDirectory: String, lastModified: Date) {
        self.sessionId = sessionId
        self.name = name
        self.workingDirectory = workingDirectory
        self.lastModified = lastModified
    }
}
