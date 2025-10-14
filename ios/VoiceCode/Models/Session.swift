// Session.swift
// Model for conversation sessions

import Foundation

struct Session: Identifiable, Codable {
    let id: UUID
    var name: String
    var workingDirectory: String?
    var claudeSessionId: String?
    var messages: [Message]
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, workingDirectory: String? = nil, claudeSessionId: String? = nil, messages: [Message] = [], createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.workingDirectory = workingDirectory
        self.claudeSessionId = claudeSessionId
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    mutating func addMessage(_ message: Message) {
        messages.append(message)
        updatedAt = Date()
    }

    mutating func updateClaudeSessionId(_ sessionId: String) {
        claudeSessionId = sessionId
        updatedAt = Date()
    }
}
