// SessionSyncManager.swift
// Manages session metadata synchronization with backend

import Foundation
import CoreData
import OSLog

/// Thread-safe flag for ensuring single execution across threads
/// Uses os_unfair_lock for atomic test-and-set operation
final class AtomicFlag: @unchecked Sendable {
    private var _value: Bool = false
    private var _lock = os_unfair_lock()

    /// Atomically tests if the flag is false and sets it to true.
    /// Returns true if the flag was successfully set (was false), false otherwise.
    func testAndSet() -> Bool {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        if _value {
            return false
        }
        _value = true
        return true
    }
}

/// Configuration for SessionSyncManager logging
public enum SessionSyncConfig {
    /// The OSLog subsystem for session sync logging
    nonisolated(unsafe) public static var subsystem: String = "com.voicecode.shared"
}

/// Delegate for platform-specific session sync callbacks
///
/// Note: All delegate methods are called on MainActor to ensure safe access to UI state.
@MainActor
public protocol SessionSyncDelegate: AnyObject, Sendable {
    /// Called to check if a session is currently active (being viewed)
    func isSessionActive(_ sessionId: UUID) -> Bool

    /// Called when assistant messages should be spoken
    func speakAssistantMessages(_ messages: [String], workingDirectory: String)

    /// Called when a notification should be posted for background session updates
    func postNotification(text: String, sessionId: String, sessionName: String, workingDirectory: String)

    /// Check if priority queue is enabled
    var isPriorityQueueEnabled: Bool { get }
}

/// Manages synchronization of session metadata between backend and CoreData
public final class SessionSyncManager: @unchecked Sendable {
    private let persistenceController: PersistenceController
    public weak var delegate: SessionSyncDelegate?

    private let logger = Logger(subsystem: SessionSyncConfig.subsystem, category: "SessionSync")

    public init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController
    }

    // MARK: - Session List Handling

    /// Handle session_list message from backend
    /// - Parameter sessions: Array of session metadata dictionaries
    public func handleSessionList(_ sessions: [[String: Any]]) async {
        let sessionCount = sessions.count
        logger.info("Received session_list with \(sessionCount) sessions")

        // Copy sessions for Sendable compliance
        nonisolated(unsafe) let sessionsCopy = sessions

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            nonisolated(unsafe) var didSaveChanges = false
            // Thread-safe wrapper for single resume
            let resumeOnce = AtomicFlag()

            persistenceController.performBackgroundTaskWithMergeCompletion(
                { [weak self] backgroundContext in
                    guard let self = self else {
                        // Self deallocated - resume continuation to avoid hanging
                        if resumeOnce.testAndSet() {
                            continuation.resume()
                        }
                        return false
                    }

                    for sessionData in sessionsCopy {
                        self.upsertSession(sessionData, in: backgroundContext)
                    }

                    do {
                        if backgroundContext.hasChanges {
                            try backgroundContext.save()
                            self.logger.info("Saved \(sessionCount) sessions to CoreData")
                            didSaveChanges = true
                            return true
                        }
                    } catch {
                        self.logger.error("Failed to save session_list: \(error.localizedDescription)")
                        // Resume continuation on error to prevent hanging
                        if resumeOnce.testAndSet() {
                            continuation.resume()
                        }
                        return false
                    }

                    // No changes to save - resume continuation immediately
                    if resumeOnce.testAndSet() {
                        continuation.resume()
                    }
                    return false
                },
                onMergeComplete: {
                    // Notify observers AFTER changes are merged to view context
                    if didSaveChanges {
                        NotificationCenter.default.post(name: .sessionListDidUpdate, object: nil)
                    }
                    // Only resume if not already resumed (changes were saved)
                    if resumeOnce.testAndSet() {
                        continuation.resume()
                    }
                }
            )
        }
    }

    // MARK: - Session Created Handling

    /// Handle session_created message from backend
    /// - Parameters:
    ///   - sessionData: Session metadata dictionary
    ///   - completion: Optional callback with session ID on successful save
    public func handleSessionCreated(_ sessionData: [String: Any], completion: (@Sendable (String) -> Void)? = nil) {
        guard let sessionId = sessionData["session_id"] as? String else {
            logger.warning("session_created missing session_id, dropping")
            return
        }

        logger.info("Accepting session_created for: \(sessionId)")

        nonisolated(unsafe) let sessionDataCopy = sessionData

        persistenceController.performBackgroundTask { [weak self] backgroundContext in
            guard let self = self else { return }

            self.upsertSession(sessionDataCopy, in: backgroundContext)

            do {
                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                    self.logger.info("Created session: \(sessionId)")

                    if let completion = completion {
                        DispatchQueue.main.async {
                            completion(sessionId)
                        }
                    }
                }
            } catch {
                self.logger.error("Failed to save session_created: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Session History Handling

    /// Handle session_history message from backend (full conversation history)
    /// - Parameters:
    ///   - sessionId: Session UUID string
    ///   - messages: Array of all message dictionaries for the session
    public func handleSessionHistory(sessionId: String, messages: [[String: Any]]) {
        let messageCount = messages.count
        logger.info("handleSessionHistory for \(sessionId.prefix(8))... with \(messageCount) messages")

        nonisolated(unsafe) let messagesCopy = messages

        persistenceController.performBackgroundTask { [weak self] backgroundContext in
            guard let self = self else { return }

            guard let sessionUUID = UUID(uuidString: sessionId) else {
                self.logger.error("Invalid session ID format in handleSessionHistory: \(sessionId)")
                return
            }

            let fetchRequest = CDBackendSession.fetchBackendSession(id: sessionUUID)

            guard let session = try? backgroundContext.fetch(fetchRequest).first else {
                self.logger.warning("Session not found for history: \(sessionId)")
                return
            }

            // Clear existing messages
            if let existingMessages = session.messages?.allObjects as? [CDMessage] {
                for message in existingMessages {
                    backgroundContext.delete(message)
                }
            }

            // Add all messages from history
            for messageData in messagesCopy {
                self.createMessage(messageData, sessionId: sessionId, in: backgroundContext, session: session)
            }

            // Update session metadata
            session.messageCount = Int32(messageCount)

            if let lastMessage = messagesCopy.last,
               let text = self.extractText(from: lastMessage) {
                session.preview = String(text.prefix(100))
            }

            do {
                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                    self.logger.info("Saved session_history for \(sessionId.prefix(8))...")
                }
            } catch {
                self.logger.error("Failed to save session_history: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Optimistic UI

    /// Create an optimistic message immediately when user sends a prompt
    /// - Parameters:
    ///   - sessionId: Session UUID
    ///   - text: User's prompt text
    ///   - completion: Called on main thread with the created message ID
    public func createOptimisticMessage(sessionId: UUID, text: String, completion: @escaping @Sendable (UUID) -> Void) {
        logger.info("Creating optimistic message for session: \(sessionId.lowercasedString)")

        let messageId = UUID()

        persistenceController.performBackgroundTask { [weak self] backgroundContext in
            guard let self = self else { return }

            let fetchRequest = CDBackendSession.fetchBackendSession(id: sessionId)

            guard let session = try? backgroundContext.fetch(fetchRequest).first else {
                self.logger.warning("Session not found for optimistic message: \(sessionId.lowercasedString)")
                return
            }

            let message = CDMessage(context: backgroundContext)
            message.id = messageId
            message.sessionId = sessionId
            message.role = "user"
            message.text = text
            message.timestamp = Date()
            message.messageStatus = .sending
            message.session = session

            session.lastModified = Date()
            session.messageCount += 1
            session.preview = String(text.prefix(100))

            do {
                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                    self.logger.info("Saved optimistic message: \(messageId)")

                    DispatchQueue.main.async {
                        completion(messageId)
                    }
                }
            } catch {
                self.logger.error("Failed to save optimistic message: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Session Updated Handling

    /// Handle session_updated message from backend
    /// - Parameters:
    ///   - sessionId: Session UUID string
    ///   - messages: Array of new message dictionaries
    public func handleSessionUpdated(sessionId: String, messages: [[String: Any]]) {
        logger.info("Received session_updated for: \(sessionId) with \(messages.count) messages")

        guard let sessionUUID = UUID(uuidString: sessionId) else {
            logger.error("Invalid session ID format in handleSessionUpdated: \(sessionId)")
            return
        }

        // Capture delegate and mark messages as sendable before Task
        let delegate = self.delegate
        nonisolated(unsafe) let messagesCopy = messages

        Task { @MainActor [weak self] in
            guard let self = self else { return }

            // Query delegate state on MainActor
            let isActiveSession = delegate?.isSessionActive(sessionUUID) ?? false
            let isPriorityQueueEnabled = delegate?.isPriorityQueueEnabled ?? false

            // Now perform background CoreData work with captured state
            self.performSessionUpdate(
                sessionId: sessionId,
                sessionUUID: sessionUUID,
                messages: messagesCopy,
                isActiveSession: isActiveSession,
                isPriorityQueueEnabled: isPriorityQueueEnabled,
                delegate: delegate
            )
        }
    }

    /// Internal method to perform session update on background context
    private func performSessionUpdate(
        sessionId: String,
        sessionUUID: UUID,
        messages: [[String: Any]],
        isActiveSession: Bool,
        isPriorityQueueEnabled: Bool,
        delegate: SessionSyncDelegate?
    ) {
        // Mark messages as safe for capture in @Sendable closure
        nonisolated(unsafe) let safeMessages = messages

        persistenceController.performBackgroundTask { [weak self] backgroundContext in
            guard let self = self else { return }

            let fetchRequest = CDBackendSession.fetchBackendSession(id: sessionUUID)

            let session: CDBackendSession
            if let existingSession = try? backgroundContext.fetch(fetchRequest).first {
                session = existingSession
            } else {
                self.logger.info("Creating new session from update: \(sessionId)")
                session = CDBackendSession(context: backgroundContext)
                session.id = sessionUUID
                session.backendName = ""
                session.workingDirectory = ""
                session.unreadCount = 0
                session.isLocallyCreated = false
            }

            var newMessageCount = 0
            var assistantMessagesToSpeak: [String] = []

            for messageData in safeMessages {
                guard let role = self.extractRole(from: messageData),
                      let text = self.extractText(from: messageData) else {
                    continue
                }

                // Filter out internal message types
                if role == "summary" || role == "system" || role == "queue-operation" {
                    continue
                }

                let serverTimestamp = self.extractTimestamp(from: messageData)

                // Try to reconcile optimistic message
                let fetchRequest = CDMessage.fetchMessage(sessionId: sessionUUID, role: role, text: text)
                let existingMessage = try? backgroundContext.fetch(fetchRequest).first

                if let existingMessage = existingMessage {
                    existingMessage.messageStatus = .confirmed
                    if let serverTimestamp = serverTimestamp {
                        existingMessage.serverTimestamp = serverTimestamp
                    }
                    if let backendId = self.extractMessageId(from: messageData) {
                        existingMessage.id = backendId
                    }
                } else {
                    self.createMessage(messageData, sessionId: sessionId, in: backgroundContext, session: session)
                    newMessageCount += 1

                    if role == "assistant" {
                        assistantMessagesToSpeak.append(text)
                    }
                }
            }

            session.lastModified = Date()
            session.messageCount += Int32(newMessageCount)

            // Handle active vs background session
            let workingDirectory = session.workingDirectory
            let sessionName = session.displayName(context: backgroundContext)

            if isActiveSession {
                self.logger.info("Active session: will speak \(assistantMessagesToSpeak.count) assistant messages")
            } else {
                if newMessageCount > 0 {
                    session.unreadCount += Int32(newMessageCount)

                    if !assistantMessagesToSpeak.isEmpty {
                        let combinedText = assistantMessagesToSpeak.joined(separator: "\n\n")
                        Task { @MainActor in
                            delegate?.postNotification(
                                text: combinedText,
                                sessionId: sessionId,
                                sessionName: sessionName,
                                workingDirectory: workingDirectory
                            )
                        }
                    }
                }
            }

            if let lastMessage = safeMessages.last,
               let text = self.extractText(from: lastMessage) {
                session.preview = String(text.prefix(100))
            }

            // Auto-add to priority queue
            if !assistantMessagesToSpeak.isEmpty {
                if isPriorityQueueEnabled {
                    CDBackendSession.addToPriorityQueue(session, context: backgroundContext)
                    self.logger.info("Auto-added session to priority queue: \(sessionId)")
                }
            }

            do {
                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                    self.logger.info("Updated session: \(sessionId)")
                }

                // Prune old messages if needed
                if CDMessage.needsPruning(sessionId: sessionUUID, in: backgroundContext) {
                    let deletedCount = CDMessage.pruneOldMessages(sessionId: sessionUUID, in: backgroundContext)
                    if deletedCount > 0 {
                        try? backgroundContext.save()
                        self.logger.info("Pruned \(deletedCount) old messages from session \(sessionId)")
                    }
                }

                // Speak messages for active session
                if isActiveSession && !assistantMessagesToSpeak.isEmpty {
                    Task { @MainActor in
                        let processedMessages = assistantMessagesToSpeak.map { TextProcessor.removeCodeBlocks(from: $0) }
                        delegate?.speakAssistantMessages(processedMessages, workingDirectory: workingDirectory)
                    }
                }
            } catch {
                self.logger.error("Failed to save session_updated: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Name Update Handling

    /// Update a session's custom name
    public func updateSessionLocalName(sessionId: UUID, name: String) {
        logger.info("Updating session custom name: \(sessionId.lowercasedString) -> \(name)")

        persistenceController.performBackgroundTask { [weak self] backgroundContext in
            let fetchRequest = CDUserSession.fetchUserSession(id: sessionId)

            let userSession: CDUserSession
            if let existing = try? backgroundContext.fetch(fetchRequest).first {
                userSession = existing
            } else {
                userSession = CDUserSession(context: backgroundContext)
                userSession.id = sessionId
                userSession.createdAt = Date()
            }

            userSession.customName = name

            do {
                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                    self?.logger.info("Updated session custom name: \(sessionId.lowercasedString)")
                }
            } catch {
                self?.logger.error("Failed to update session custom name: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Server Change Handling

    /// Clear all sessions and messages when changing servers
    public func clearAllSessions() {
        logger.info("Clearing all sessions due to server change")

        persistenceController.performBackgroundTask { [weak self] backgroundContext in
            let sessionFetchRequest: NSFetchRequest<CDBackendSession> = CDBackendSession.fetchRequest()

            do {
                let sessions = try backgroundContext.fetch(sessionFetchRequest)
                self?.logger.info("Deleting \(sessions.count) sessions")

                for session in sessions {
                    backgroundContext.delete(session)
                }

                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                    self?.logger.info("Successfully cleared all sessions")
                }
            } catch {
                self?.logger.error("Failed to clear sessions: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private Helpers

    /// Extract text from Claude Code message format
    internal func extractText(from messageData: [String: Any]) -> String? {
        if let message = messageData["message"] as? [String: Any] {
            if let content = message["content"] as? String {
                return content
            }

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
                        summaries.append("[\(blockType)]")
                    }
                }

                return summaries.isEmpty ? nil : summaries.joined(separator: "\n\n")
            }
        }

        if let content = messageData["content"] as? String {
            return content
        }

        if let summary = messageData["summary"] as? String {
            return summary
        }

        return nil
    }

    /// Extract role from Claude Code message format
    internal func extractRole(from messageData: [String: Any]) -> String? {
        return messageData["type"] as? String
    }

    /// Extract timestamp from Claude Code message format
    internal func extractTimestamp(from messageData: [String: Any]) -> Date? {
        guard let timestampString = messageData["timestamp"] as? String else {
            return nil
        }
        return DateFormatters.parseISO8601(timestampString)
    }

    /// Extract message UUID from Claude Code message format
    internal func extractMessageId(from messageData: [String: Any]) -> UUID? {
        guard let uuidString = messageData["uuid"] as? String else {
            return nil
        }
        return UUID(uuidString: uuidString)
    }

    /// Upsert a session in CoreData
    private func upsertSession(_ sessionData: [String: Any], in context: NSManagedObjectContext) {
        guard let sessionIdString = sessionData["session_id"] as? String else {
            logger.warning("Missing session_id in session data")
            return
        }

        guard let sessionId = UUID(uuidString: sessionIdString) else {
            logger.warning("Invalid session_id format (not a UUID): \(sessionIdString)")
            return
        }

        let fetchRequest = CDBackendSession.fetchBackendSession(id: sessionId)
        let existingSession = try? context.fetch(fetchRequest).first

        let session = existingSession ?? CDBackendSession(context: context)

        session.id = sessionId

        if let name = sessionData["name"] as? String {
            session.backendName = name
        }

        if let workingDir = sessionData["working_directory"] as? String {
            session.workingDirectory = workingDir
        }

        if let lastModified = sessionData["last_modified"] as? TimeInterval {
            session.lastModified = Date(timeIntervalSince1970: lastModified / 1000.0)
        }

        if let messageCount = sessionData["message_count"] as? Int {
            session.messageCount = Int32(messageCount)
        }

        if let preview = sessionData["preview"] as? String {
            session.preview = preview
        }

        session.isLocallyCreated = false

        if existingSession == nil {
            session.unreadCount = 0
        }
    }

    /// Create a message in CoreData
    private func createMessage(_ messageData: [String: Any], sessionId: String, in context: NSManagedObjectContext, session: CDBackendSession) {
        guard let role = extractRole(from: messageData),
              let text = extractText(from: messageData) else {
            return
        }

        guard let sessionUUID = UUID(uuidString: sessionId) else {
            logger.error("Invalid session ID format in createMessage: \(sessionId)")
            return
        }

        let message = CDMessage(context: context)

        message.id = extractMessageId(from: messageData) ?? UUID()
        message.sessionId = sessionUUID
        message.role = role
        message.text = text
        message.messageStatus = .confirmed
        message.session = session

        if let timestamp = extractTimestamp(from: messageData) {
            message.timestamp = timestamp
            message.serverTimestamp = timestamp
        } else {
            message.timestamp = Date()
        }
    }

    // MARK: - Content Summarization

    private func formatContentSize(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) bytes"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1fKB", Double(bytes) / 1024.0)
        } else {
            return String(format: "%.1fMB", Double(bytes) / (1024.0 * 1024.0))
        }
    }

    private func summarizeToolUse(_ block: [String: Any]) -> String {
        guard let toolName = block["name"] as? String else {
            return "Tool call"
        }

        guard let input = block["input"] as? [String: Any], !input.isEmpty else {
            return toolName
        }

        var paramSummary: String = ""

        if let path = input["file_path"] as? String ?? input["path"] as? String {
            paramSummary = (path as NSString).lastPathComponent
        } else if let pattern = input["pattern"] as? String {
            let truncated = pattern.prefix(30)
            paramSummary = "pattern \"\(truncated)\(pattern.count > 30 ? "..." : "")\""
        } else if let command = input["command"] as? String {
            paramSummary = String(command.prefix(40)) + (command.count > 40 ? "..." : "")
        } else if let firstKey = input.keys.first, let value = input[firstKey] {
            let valueStr = String(describing: value)
            paramSummary = "\(firstKey): \(valueStr.prefix(30))\(valueStr.count > 30 ? "..." : "")"
        }

        return paramSummary.isEmpty ? toolName : "\(toolName): \(paramSummary)"
    }

    private func summarizeToolResult(_ block: [String: Any]) -> String {
        if let isError = block["is_error"] as? Bool, isError {
            if let content = block["content"] as? String {
                let errorMessage = content.components(separatedBy: .newlines).first ?? content
                let truncated = String(errorMessage.prefix(60))
                return "Error: \(truncated)\(errorMessage.count > 60 ? "..." : "")"
            }
            return "Error"
        }

        if let content = block["content"] as? String {
            return "Result (\(formatContentSize(content.utf8.count)))"
        } else if let contentArray = block["content"] as? [[String: Any]] {
            return "Result (\(contentArray.count) items)"
        }
        return "Result"
    }

    private func summarizeThinking(_ block: [String: Any]) -> String {
        guard let thinking = block["thinking"] as? String else {
            return "Thinking..."
        }

        if thinking.count <= 60 {
            return thinking
        }

        let truncated = thinking.prefix(60)
        if let lastSpace = truncated.lastIndex(of: " ") {
            return "\(truncated[..<lastSpace])..."
        }
        return "\(truncated)..."
    }
}
