// Message.swift
// Model for conversation messages

import Foundation

enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

struct Message: Identifiable, Codable {
    let id: UUID
    let role: MessageRole
    let text: String
    let timestamp: Date

    var error: String?

    init(id: UUID = UUID(), role: MessageRole, text: String, timestamp: Date = Date(), error: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.error = error
    }
}
