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

    // Optional metadata
    var usage: Usage?
    var cost: Double?
    var error: String?

    init(id: UUID = UUID(), role: MessageRole, text: String, timestamp: Date = Date(), usage: Usage? = nil, cost: Double? = nil, error: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.usage = usage
        self.cost = cost
        self.error = error
    }
}

struct Usage: Codable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadTokens: Int?
    let cacheWriteTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadTokens = "cache_read_input_tokens"
        case cacheWriteTokens = "cache_creation_input_tokens"
    }
}
