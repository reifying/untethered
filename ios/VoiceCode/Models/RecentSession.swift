// RecentSession.swift
// Model for recent session data from backend

import Foundation
import CoreData

struct RecentSession: Identifiable, Equatable {
    let sessionId: String
    let workingDirectory: String
    let lastModified: Date
    let displayName: String  // Pre-fetched from CoreData to avoid N+1 queries

    var id: String { sessionId }
    
    // Parse from WebSocket JSON (snake_case keys) with pre-fetched display name
    // This is a private initializer - use parseRecentSessions() for batch parsing
    private init?(json: [String: Any], displayName: String) {
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
        self.displayName = displayName
    }

    // For testing
    init(sessionId: String, workingDirectory: String, lastModified: Date, displayName: String? = nil) {
        self.sessionId = sessionId
        self.workingDirectory = workingDirectory
        self.lastModified = lastModified
        self.displayName = displayName ?? Self.fallbackName(from: workingDirectory, sessionId: sessionId)
    }

    // Batch parse recent sessions with single CoreData query (eliminates N+1 pattern)
    static func parseRecentSessions(_ jsonArray: [[String: Any]], using context: NSManagedObjectContext) -> [RecentSession] {
        // Extract all session IDs
        let sessionIds = jsonArray.compactMap { json -> UUID? in
            guard let sessionId = json["session_id"] as? String else { return nil }
            return UUID(uuidString: sessionId)
        }

        // Single batch fetch for all sessions
        let fetchRequest = CDSession.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id IN %@", sessionIds)

        let displayNameMap: [String: String]
        do {
            let sessions = try context.fetch(fetchRequest)
            displayNameMap = Dictionary(uniqueKeysWithValues: sessions.map {
                ($0.id.uuidString.lowercased(), $0.displayName)
            })
        } catch {
            print("❌ Failed to batch fetch sessions for recent sessions: \(error)")
            displayNameMap = [:]
        }

        // Parse each JSON with pre-fetched display name
        return jsonArray.compactMap { json in
            guard let sessionId = json["session_id"] as? String,
                  let workingDirectory = json["working_directory"] as? String else {
                return nil
            }

            let displayName = displayNameMap[sessionId.lowercased()]
                ?? fallbackName(from: workingDirectory, sessionId: sessionId)

            return RecentSession(json: json, displayName: displayName)
        }
    }

    // Fallback name derived from working directory (last path component)
    private static func fallbackName(from workingDirectory: String, sessionId: String) -> String {
        workingDirectory.split(separator: "/").last.map(String.init) ?? sessionId
    }
}
