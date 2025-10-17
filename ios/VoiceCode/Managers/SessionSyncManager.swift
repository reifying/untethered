// SessionSyncManager.swift
// Manages session metadata synchronization with backend

import Foundation
import CoreData
import os.log

private let logger = Logger(subsystem: "com.travisbrown.VoiceCode", category: "SessionSync")

/// Manages synchronization of session metadata between backend and CoreData
class SessionSyncManager {
    private let persistenceController: PersistenceController
    private let context: NSManagedObjectContext
    
    init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController
        self.context = persistenceController.container.viewContext
    }
    
    // MARK: - Session List Handling
    
    /// Handle session_list message from backend
    /// - Parameter sessions: Array of session metadata dictionaries
    func handleSessionList(_ sessions: [[String: Any]]) {
        logger.info("Received session_list with \(sessions.count) sessions")
        
        persistenceController.performBackgroundTask { [weak self] backgroundContext in
            guard let self = self else { return }
            
            for sessionData in sessions {
                self.upsertSession(sessionData, in: backgroundContext)
            }
            
            do {
                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                    logger.info("Saved \(sessions.count) sessions to CoreData")
                }
            } catch {
                logger.error("Failed to save session_list: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Session Created Handling
    
    /// Handle session_created message from backend
    /// - Parameter sessionData: Session metadata dictionary
    func handleSessionCreated(_ sessionData: [String: Any]) {
        guard let sessionId = sessionData["session_id"] as? String else {
            logger.warning("session_created missing session_id")
            return
        }
        
        logger.info("Received session_created for: \(sessionId)")
        
        persistenceController.performBackgroundTask { [weak self] backgroundContext in
            guard let self = self else { return }
            
            self.upsertSession(sessionData, in: backgroundContext)
            
            do {
                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                    logger.info("Created session: \(sessionId)")
                }
            } catch {
                logger.error("Failed to save session_created: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Session Updated Handling
    
    /// Handle session_updated message from backend
    /// - Parameters:
    ///   - sessionId: Session UUID
    ///   - messages: Array of new message dictionaries
    func handleSessionUpdated(sessionId: String, messages: [[String: Any]]) {
        logger.info("Received session_updated for: \(sessionId) with \(messages.count) messages")
        
        persistenceController.performBackgroundTask { [weak self] backgroundContext in
            guard let self = self else { return }
            
            // Fetch the session
            let fetchRequest = CDSession.fetchSession(id: UUID(uuidString: sessionId)!)
            
            guard let session = try? backgroundContext.fetch(fetchRequest).first else {
                logger.warning("Session not found for update: \(sessionId)")
                return
            }
            
            // Update session metadata
            session.lastModified = Date()
            session.messageCount += Int32(messages.count)
            
            // Update preview with last message text
            if let lastMessage = messages.last,
               let text = lastMessage["text"] as? String {
                session.preview = String(text.prefix(100))
            }
            
            // Add new messages
            for messageData in messages {
                self.createMessage(messageData, sessionId: sessionId, in: backgroundContext, session: session)
            }
            
            do {
                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                    logger.info("Updated session: \(sessionId)")
                }
            } catch {
                logger.error("Failed to save session_updated: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Private Helpers
    
    /// Upsert (update or insert) a session in CoreData
    private func upsertSession(_ sessionData: [String: Any], in context: NSManagedObjectContext) {
        guard let sessionIdString = sessionData["session_id"] as? String,
              let sessionId = UUID(uuidString: sessionIdString) else {
            logger.warning("Invalid or missing session_id in session data")
            return
        }
        
        // Try to fetch existing session
        let fetchRequest = CDSession.fetchSession(id: sessionId)
        let existingSession = try? context.fetch(fetchRequest).first
        
        let session = existingSession ?? CDSession(context: context)
        
        // Update fields
        session.id = sessionId
        
        if let name = sessionData["name"] as? String {
            session.backendName = name
        }
        
        if let workingDir = sessionData["working_directory"] as? String {
            session.workingDirectory = workingDir
        }
        
        if let lastModified = sessionData["last_modified"] as? TimeInterval {
            session.lastModified = Date(timeIntervalSince1970: lastModified / 1000.0) // Convert from milliseconds
        }
        
        if let messageCount = sessionData["message_count"] as? Int {
            session.messageCount = Int32(messageCount)
        }
        
        if let preview = sessionData["preview"] as? String {
            session.preview = preview
        }
        
        // Don't override local deletion status
        if existingSession == nil {
            session.markedDeleted = false
        }
    }
    
    /// Create a message in CoreData
    private func createMessage(_ messageData: [String: Any], sessionId: String, in context: NSManagedObjectContext, session: CDSession) {
        guard let role = messageData["role"] as? String,
              let text = messageData["text"] as? String else {
            logger.warning("Invalid message data, missing role or text")
            return
        }
        
        let message = CDMessage(context: context)
        message.id = UUID()  // Generate new UUID for messages without explicit ID
        message.sessionId = UUID(uuidString: sessionId)!
        message.role = role
        message.text = text
        message.messageStatus = .confirmed
        message.session = session
        
        // Timestamp
        if let timestamp = messageData["timestamp"] as? TimeInterval {
            message.timestamp = Date(timeIntervalSince1970: timestamp / 1000.0)
            message.serverTimestamp = message.timestamp
        } else {
            message.timestamp = Date()
        }
    }
}
