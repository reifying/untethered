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
    private weak var voiceOutputManager: VoiceOutputManager?

    init(persistenceController: PersistenceController = .shared, voiceOutputManager: VoiceOutputManager? = nil) {
        self.persistenceController = persistenceController
        self.context = persistenceController.container.viewContext
        self.voiceOutputManager = voiceOutputManager
    }
    
    // MARK: - Session List Handling
    
    /// Handle session_list message from backend
    /// - Parameter sessions: Array of session metadata dictionaries
    func handleSessionList(_ sessions: [[String: Any]]) async {
        logger.info("📥 Received session_list with \(sessions.count) sessions")

        // Log all received sessions with their details
        logger.info("📋 Sessions received from backend:")
        for (index, sessionData) in sessions.enumerated() {
            let sessionId = sessionData["session_id"] as? String ?? "unknown"
            let name = sessionData["name"] as? String ?? "unknown"
            let workingDir = sessionData["working_directory"] as? String ?? "unknown"
            let messageCount = sessionData["message_count"] as? Int ?? 0
            logger.info("  [\(index + 1)] \(sessionId) | \(messageCount) msgs | \(name) | \(workingDir)")
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            persistenceController.performBackgroundTask { [weak self] backgroundContext in
                guard let self = self else {
                    continuation.resume()
                    return
                }

                for sessionData in sessions {
                    self.upsertSession(sessionData, in: backgroundContext)
                }

                do {
                    if backgroundContext.hasChanges {
                        try backgroundContext.save()
                        logger.info("✅ Saved \(sessions.count) sessions to CoreData")

                        // Log what's actually in CoreData after save
                        let fetchRequest = CDSession.fetchActiveSessions()
                        if let allSessions = try? backgroundContext.fetch(fetchRequest) {
                            logger.info("💾 CoreData now contains \(allSessions.count) total active sessions")
                            let hunt910Sessions = allSessions.filter { $0.workingDirectory.contains("hunt910") }
                            logger.info("🎯 hunt910 sessions in CoreData: \(hunt910Sessions.count)")
                            for session in hunt910Sessions.sorted(by: { $0.lastModified > $1.lastModified }).prefix(10) {
                                logger.info("  - \(session.id.uuidString.lowercased()) | \(session.messageCount) msgs | markedDeleted=\(session.markedDeleted)")
                            }
                        }
                    }
                } catch {
                    logger.error("❌ Failed to save session_list: \(error.localizedDescription)")
                }

                continuation.resume()
            }
        }
    }
    
    // MARK: - Session Created Handling
    
    /// Handle session_created message from backend
    /// - Parameter sessionData: Session metadata dictionary
    func handleSessionCreated(_ sessionData: [String: Any]) {
        let sessionId = sessionData["session_id"] as? String ?? "unknown"
        let name = sessionData["name"] as? String ?? "unknown"
        let workingDir = sessionData["working_directory"] as? String ?? "unknown"
        let messageCount = sessionData["message_count"] as? Int ?? 0
        let hasPreview = (sessionData["preview"] as? String)?.isEmpty == false

        logger.info("📨 session_created received: \(sessionId)")
        logger.info("  Name: \(name)")
        logger.info("  Working dir: \(workingDir)")
        logger.info("  Message count: \(messageCount)")
        logger.info("  Has preview: \(hasPreview)")

        guard sessionData["session_id"] as? String != nil else {
            logger.warning("⚠️ session_created missing session_id, dropping")
            return
        }

        // Backend guarantees all notified sessions have messages via delayed notification pattern
        // Just log for observability if we receive a 0-message session
        if messageCount == 0 {
            logger.info("📝 Note: Received session with 0 messages (may update soon): \(sessionId)")
        }

        logger.info("✅ Accepting session_created for: \(sessionId)")

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
    
    // MARK: - Session History Handling
    
    /// Handle session_history message from backend (full conversation history)
    /// - Parameters:
    ///   - sessionId: Session UUID
    ///   - messages: Array of all message dictionaries for the session
    func handleSessionHistory(sessionId: String, messages: [[String: Any]]) {
        logger.info("Received session_history for: \(sessionId) with \(messages.count) messages")

        persistenceController.performBackgroundTask { [weak self] backgroundContext in
            guard let self = self else { return }

            // Validate UUID format
            guard let sessionUUID = UUID(uuidString: sessionId) else {
                logger.error("Invalid session ID format in handleSessionHistory: \(sessionId)")
                return
            }

            // Fetch the session
            let fetchRequest = CDSession.fetchSession(id: sessionUUID)

            guard let session = try? backgroundContext.fetch(fetchRequest).first else {
                logger.warning("Session not found for history: \(sessionId)")
                return
            }
            
            // Clear existing messages (if any) and add all from history
            if let existingMessages = session.messages?.allObjects as? [CDMessage] {
                for message in existingMessages {
                    backgroundContext.delete(message)
                }
            }
            
            // Add all messages from history
            for messageData in messages {
                self.createMessage(messageData, sessionId: sessionId, in: backgroundContext, session: session)
            }
            
            // Update session metadata
            session.messageCount = Int32(messages.count)
            // Note: Do NOT update lastModified here - we're replaying existing history.
            // The correct lastModified timestamp was already set from the backend's session_list message.
            // Only handleSessionUpdated() should update lastModified for truly NEW messages.

            if let lastMessage = messages.last,
               let text = self.extractText(from: lastMessage) {
                session.preview = String(text.prefix(100))
            }
            
            do {
                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                    logger.info("Loaded session history: \(sessionId) (\(messages.count) messages)")
                }
            } catch {
                logger.error("Failed to save session_history: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Optimistic UI
    
    /// Create an optimistic message immediately when user sends a prompt
    /// - Parameters:
    ///   - sessionId: Session UUID
    ///   - text: User's prompt text
    ///   - completion: Called on main thread with the created message ID
    func createOptimisticMessage(sessionId: UUID, text: String, completion: @escaping (UUID) -> Void) {
        logger.info("Creating optimistic message for session: \(sessionId.uuidString.lowercased())")

        let messageId = UUID()

        persistenceController.performBackgroundTask { [weak self] backgroundContext in
            guard let self = self else { return }

            // Fetch the session
            let fetchRequest = CDSession.fetchSession(id: sessionId)

            guard let session = try? backgroundContext.fetch(fetchRequest).first else {
                logger.warning("Session not found for optimistic message: \(sessionId.uuidString.lowercased())")
                return
            }
            
            // Create optimistic message
            let message = CDMessage(context: backgroundContext)
            message.id = messageId
            message.sessionId = sessionId
            message.role = "user"
            message.text = text
            message.timestamp = Date()
            message.messageStatus = .sending
            message.session = session
            
            logger.info("📝 Optimistic message prepared: id=\(messageId) sessionId=\(sessionId.uuidString.lowercased()) role=user text_length=\(text.count) status=sending")
            
            // Update session metadata optimistically
            session.lastModified = Date()
            session.messageCount += 1
            session.preview = String(text.prefix(100))
            
            do {
                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                    logger.info("📝 Saved optimistic message: \(messageId)")
                    
                    DispatchQueue.main.async {
                        completion(messageId)
                    }
                }
            } catch {
                logger.error("Failed to save optimistic message: \(error.localizedDescription)")
            }
        }
    }
    
    /// Reconcile an optimistic message with server confirmation
    /// - Parameters:
    ///   - sessionId: Session UUID
    ///   - role: Message role (should be "user" for optimistic messages)
    ///   - text: Message text to match
    ///   - serverTimestamp: Server-provided timestamp
    private func reconcileMessage(sessionId: UUID, role: String, text: String, serverTimestamp: Date?, in context: NSManagedObjectContext) {
        // Find optimistic message by session, role, and text
        let fetchRequest = CDMessage.fetchMessage(sessionId: sessionId, role: role, text: text)
        
        guard let message = try? context.fetch(fetchRequest).first else {
            logger.info("No optimistic message found to reconcile (backend-originated message)")
            return
        }
        
        // Update status and server timestamp
        message.messageStatus = .confirmed
        if let serverTimestamp = serverTimestamp {
            message.serverTimestamp = serverTimestamp
        }
        
        logger.info("Reconciled optimistic message: \(message.id)")
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

            // Validate UUID format
            guard let sessionUUID = UUID(uuidString: sessionId) else {
                logger.error("Invalid session ID format in handleSessionUpdated: \(sessionId)")
                return
            }

            // Fetch or create the session
            let fetchRequest = CDSession.fetchSession(id: sessionUUID)

            let session: CDSession
            if let existingSession = try? backgroundContext.fetch(fetchRequest).first {
                session = existingSession
            } else {
                // Session not in our list yet - create it from the update
                logger.info("Creating new session from update: \(sessionId)")
                session = CDSession(context: backgroundContext)
                session.id = sessionUUID
                session.backendName = "" // Will be updated on next session_list
                session.workingDirectory = "" // Will be updated on next session_list
                session.markedDeleted = false
                session.unreadCount = 0
                session.isLocallyCreated = false
            }

            // Check if this session is currently active
            let isActiveSession = ActiveSessionManager.shared.isActive(sessionUUID)

            // Process each message - reconcile optimistic ones, create new ones
            var newMessageCount = 0
            var assistantMessagesToSpeak: [String] = []

            for messageData in messages {
                // Extract fields from raw .jsonl format
                guard let role = self.extractRole(from: messageData),
                      let text = self.extractText(from: messageData) else {
                    logger.warning("Failed to extract role or text from message")
                    continue
                }

                // Filter out internal Claude Code messages
                // - "summary" messages are error summaries and internal state
                // - "system" messages are local command notifications
                if role == "summary" || role == "system" {
                    logger.debug("Filtering out internal message type: \(role, privacy: .public)")
                    continue
                }

                // Extract server timestamp
                let serverTimestamp = self.extractTimestamp(from: messageData)

                // Try to reconcile optimistic message first
                let fetchRequest = CDMessage.fetchMessage(sessionId: sessionUUID, role: role, text: text)

                logger.info("🔍 Looking for optimistic message to reconcile: role=\(role) text_length=\(text.count) session=\(sessionId)")
                
                if let existingMessage = try? backgroundContext.fetch(fetchRequest).first {
                    // Reconcile optimistic message
                    logger.info("✅ Found optimistic message to reconcile: id=\(existingMessage.id) current_status=\(existingMessage.messageStatus.rawValue)")
                    existingMessage.messageStatus = .confirmed
                    if let serverTimestamp = serverTimestamp {
                        existingMessage.serverTimestamp = serverTimestamp
                    }
                    // Update ID to match backend's UUID
                    if let backendId = self.extractMessageId(from: messageData) {
                        existingMessage.id = backendId
                    }
                    logger.info("✅ Reconciled optimistic message to confirmed")
                } else {
                    // Create new message (backend-originated or not found)
                    logger.info("❌ No optimistic message found - creating new message: role=\(role) text_length=\(text.count)")
                    self.createMessage(messageData, sessionId: sessionId, in: backgroundContext, session: session)
                    newMessageCount += 1

                    // Collect assistant messages for speaking (if active session)
                    if role == "assistant" {
                        assistantMessagesToSpeak.append(text)
                    }
                }
            }
            
            // Update session metadata (only count truly new messages)
            // Update lastModified to current time because these are NEW messages arriving now
            session.lastModified = Date()
            session.messageCount += Int32(newMessageCount)

            // Update unread count and speaking logic
            if isActiveSession {
                // Active session: speak assistant messages, don't increment unread count
                logger.info("Active session: will speak \(assistantMessagesToSpeak.count) assistant messages")
            } else {
                // Background session: increment unread count, don't speak, post notification
                if newMessageCount > 0 {
                    session.unreadCount += Int32(newMessageCount)
                    logger.info("Background session: incremented unread count to \(session.unreadCount)")
                    
                    // Post notification for assistant messages when app is backgrounded
                    if !assistantMessagesToSpeak.isEmpty {
                        let sessionName = session.localName ?? session.backendName
                        logger.info("📬 Posting notification for \(assistantMessagesToSpeak.count) assistant messages")
                        
                        // Post notification on main thread
                        // Combine multiple messages into one notification
                        let combinedText = assistantMessagesToSpeak.joined(separator: "\n\n")
                        DispatchQueue.main.async {
                            Task {
                                await NotificationManager.shared.postResponseNotification(
                                    text: combinedText,
                                    sessionName: sessionName
                                )
                            }
                        }
                    }
                }
            }

            // Update preview with last message text
            if let lastMessage = messages.last,
               let text = self.extractText(from: lastMessage) {
                session.preview = String(text.prefix(100))
            }

            do {
                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                    logger.info("Updated session: \(sessionId)")
                }

                // Speak assistant messages on main thread (only for active session)
                // VoiceOutputManager automatically uses configured voice from AppSettings
                // Remove code blocks from text before speaking for better listening experience
                if isActiveSession && !assistantMessagesToSpeak.isEmpty {
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        for text in assistantMessagesToSpeak {
                            let processedText = TextProcessor.removeCodeBlocks(from: text)
                            self.voiceOutputManager?.speak(processedText)
                        }
                    }
                }
            } catch {
                logger.error("Failed to save session_updated: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Private Helpers

    /// Format content size in human-readable format
    /// - Parameter bytes: Size in bytes
    /// - Returns: Formatted string (e.g., "1.2KB", "345 bytes")
    private func formatContentSize(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) bytes"
        } else if bytes < 1024 * 1024 {
            let kb = Double(bytes) / 1024.0
            return String(format: "%.1fKB", kb)
        } else {
            let mb = Double(bytes) / (1024.0 * 1024.0)
            return String(format: "%.1fMB", mb)
        }
    }

    /// Summarize a tool_use content block
    /// - Parameter block: Content block dictionary
    /// - Returns: Abbreviated summary string
    private func summarizeToolUse(_ block: [String: Any]) -> String {
        guard let toolName = block["name"] as? String else {
            return "🔧 Tool call"
        }

        // Get input parameters
        guard let input = block["input"] as? [String: Any], !input.isEmpty else {
            return "🔧 \(toolName)"
        }

        // Format abbreviated parameters
        var paramSummary: String = ""

        // Common parameter patterns
        if let path = input["file_path"] as? String ?? input["path"] as? String {
            let fileName = (path as NSString).lastPathComponent
            paramSummary = fileName
        } else if let pattern = input["pattern"] as? String {
            paramSummary = "pattern \"\(pattern.prefix(30))\(pattern.count > 30 ? "..." : "")\""
        } else if let command = input["command"] as? String {
            paramSummary = command.prefix(40) + (command.count > 40 ? "..." : "")
        } else if let code = input["code"] as? String {
            paramSummary = code.prefix(40) + (code.count > 40 ? "..." : "")
        } else {
            // Generic: show first key-value pair
            if let firstKey = input.keys.first, let value = input[firstKey] {
                let valueStr = String(describing: value)
                paramSummary = "\(firstKey): \(valueStr.prefix(30))\(valueStr.count > 30 ? "..." : "")"
            }
        }

        if paramSummary.isEmpty {
            return "🔧 \(toolName)"
        } else {
            return "🔧 \(toolName): \(paramSummary)"
        }
    }

    /// Summarize a tool_result content block
    /// - Parameter block: Content block dictionary
    /// - Returns: Abbreviated summary string
    private func summarizeToolResult(_ block: [String: Any]) -> String {
        // Check for error
        if let isError = block["is_error"] as? Bool, isError {
            if let content = block["content"] as? String {
                // Extract error message (first line or first 60 chars)
                let errorMessage = content.components(separatedBy: .newlines).first ?? content
                let truncated = errorMessage.prefix(60)
                return "✗ Error: \(truncated)\(errorMessage.count > 60 ? "..." : "")"
            } else {
                return "✗ Error"
            }
        }

        // Success - show size
        if let content = block["content"] as? String {
            let size = content.utf8.count
            return "✓ Result (\(formatContentSize(size)))"
        } else if let contentArray = block["content"] as? [[String: Any]] {
            // Some results might be structured
            return "✓ Result (\(contentArray.count) items)"
        } else {
            return "✓ Result"
        }
    }

    /// Summarize a thinking content block
    /// - Parameter block: Content block dictionary
    /// - Returns: Abbreviated summary string
    private func summarizeThinking(_ block: [String: Any]) -> String {
        guard let thinking = block["thinking"] as? String else {
            return "💭 Thinking..."
        }

        // Take first ~60 chars and find a good break point
        let maxLength = 60
        if thinking.count <= maxLength {
            return "💭 \(thinking)"
        }

        let truncated = thinking.prefix(maxLength)
        // Try to break at a sentence or word boundary
        if let lastSpace = truncated.lastIndex(of: " ") {
            let breakPoint = truncated[..<lastSpace]
            return "💭 \(breakPoint)..."
        } else {
            return "💭 \(truncated)..."
        }
    }

    /// Extract text from Claude Code message format
    /// - Parameter messageData: Raw .jsonl message data
    /// - Returns: Extracted text string, or nil if extraction fails
    internal func extractText(from messageData: [String: Any]) -> String? {
        // Try nested message.content first (user/assistant messages)
        if let message = messageData["message"] as? [String: Any] {
            // User messages have simple string content
            if let content = message["content"] as? String {
                return content
            }

            // Assistant messages have array of content blocks
            if let contentArray = message["content"] as? [[String: Any]] {
                var summaries: [String] = []

                for block in contentArray {
                    guard let blockType = block["type"] as? String else { continue }

                    switch blockType {
                    case "text":
                        if let text = block["text"] as? String {
                            summaries.append(text)
                        }
                    case "tool_use":
                        summaries.append(summarizeToolUse(block))
                    case "tool_result":
                        summaries.append(summarizeToolResult(block))
                    case "thinking":
                        summaries.append(summarizeThinking(block))
                    default:
                        // Unknown block type - show placeholder
                        summaries.append("[\(blockType)]")
                    }
                }

                return summaries.isEmpty ? nil : summaries.joined(separator: "\n\n")
            }
        }

        // Fall back to top-level content (system messages)
        if let content = messageData["content"] as? String {
            return content
        }

        // Fall back to summary field (summary messages)
        if let summary = messageData["summary"] as? String {
            return summary
        }

        return nil
    }

    /// Extract role from Claude Code message format
    /// - Parameter messageData: Raw .jsonl message data
    /// - Returns: Role string ("user" or "assistant"), or nil if extraction fails
    internal func extractRole(from messageData: [String: Any]) -> String? {
        return messageData["type"] as? String
    }

    /// Extract timestamp from Claude Code message format
    /// - Parameter messageData: Raw .jsonl message data
    /// - Returns: Date object, or nil if extraction fails
    internal func extractTimestamp(from messageData: [String: Any]) -> Date? {
        guard let timestampString = messageData["timestamp"] as? String else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: timestampString)
    }

    /// Extract message UUID from Claude Code message format
    /// - Parameter messageData: Raw .jsonl message data
    /// - Returns: UUID, or nil if extraction fails
    internal func extractMessageId(from messageData: [String: Any]) -> UUID? {
        guard let uuidString = messageData["uuid"] as? String else {
            return nil
        }
        return UUID(uuidString: uuidString)
    }

    /// Upsert (update or insert) a session in CoreData
    private func upsertSession(_ sessionData: [String: Any], in context: NSManagedObjectContext) {
        // Check if session_id is present
        guard let sessionIdString = sessionData["session_id"] as? String else {
            let sessionName = String(describing: sessionData["name"] ?? "unknown")
            let workingDir = String(describing: sessionData["working_directory"] ?? "unknown")
            logger.warning("Missing session_id in session data - name: \(sessionName, privacy: .public), working_directory: \(workingDir, privacy: .public)")
            return
        }

        // Validate that session_id is a valid UUID
        guard let sessionId = UUID(uuidString: sessionIdString) else {
            let sessionName = String(describing: sessionData["name"] ?? "unknown")
            let workingDir = String(describing: sessionData["working_directory"] ?? "unknown")
            logger.warning("Invalid session_id format (not a UUID) - session_id: \(sessionIdString, privacy: .public), name: \(sessionName, privacy: .public), working_directory: \(workingDir, privacy: .public)")
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

        // Clear isLocallyCreated flag since session is now synced from backend
        session.isLocallyCreated = false

        // Don't override local deletion status or unread count
        if existingSession == nil {
            session.markedDeleted = false
            session.unreadCount = 0
        }
    }
    
    /// Create a message in CoreData
    private func createMessage(_ messageData: [String: Any], sessionId: String, in context: NSManagedObjectContext, session: CDSession) {
        // Extract fields from raw .jsonl format
        guard let role = extractRole(from: messageData),
              let text = extractText(from: messageData) else {
            logger.warning("Invalid message data, missing role or text")
            return
        }

        // Validate UUID format
        guard let sessionUUID = UUID(uuidString: sessionId) else {
            logger.error("Invalid session ID format in createMessage: \(sessionId)")
            return
        }

        let message = CDMessage(context: context)

        // Use backend's UUID if available, otherwise generate new one
        message.id = extractMessageId(from: messageData) ?? UUID()
        message.sessionId = sessionUUID
        message.role = role
        message.text = text
        message.messageStatus = .confirmed
        message.session = session

        // Extract and parse timestamp
        if let timestamp = extractTimestamp(from: messageData) {
            message.timestamp = timestamp
            message.serverTimestamp = timestamp
        } else {
            message.timestamp = Date()
        }
    }
    
    // MARK: - Name Update Handling

    /// Update a session's localName (user's custom name)
    /// - Parameters:
    ///   - sessionId: Session UUID
    ///   - name: New name to set
    func updateSessionLocalName(sessionId: UUID, name: String) {
        logger.info("Updating session localName: \(sessionId.uuidString.lowercased()) -> \(name)")

        persistenceController.performBackgroundTask { backgroundContext in
            let fetchRequest = CDSession.fetchSession(id: sessionId)

            guard let session = try? backgroundContext.fetch(fetchRequest).first else {
                logger.warning("Session not found for name update: \(sessionId.uuidString.lowercased())")
                return
            }

            session.localName = name

            do {
                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                    logger.info("Updated session localName: \(sessionId.uuidString.lowercased())")
                }
            } catch {
                logger.error("Failed to update session localName: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Server Change Handling

    /// Clear all sessions and messages when changing servers
    /// This ensures we don't show sessions from the old server
    func clearAllSessions() {
        logger.info("Clearing all sessions due to server change")
        
        persistenceController.performBackgroundTask { backgroundContext in
            // Fetch all sessions
            let sessionFetchRequest: NSFetchRequest<CDSession> = CDSession.fetchRequest()
            
            do {
                let sessions = try backgroundContext.fetch(sessionFetchRequest)
                logger.info("Deleting \(sessions.count) sessions")
                
                // Delete all sessions (cascade will delete messages)
                for session in sessions {
                    backgroundContext.delete(session)
                }
                
                // Save context
                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                    logger.info("Successfully cleared all sessions")
                }
            } catch {
                logger.error("Failed to clear sessions: \(error.localizedDescription)")
            }
        }
    }
}
