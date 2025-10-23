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
            return nil
        }
        
        // Parse ISO-8601 timestamp
        let formatter = ISO8601DateFormatter()
        guard let lastModified = formatter.date(from: lastModifiedString) else {
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
