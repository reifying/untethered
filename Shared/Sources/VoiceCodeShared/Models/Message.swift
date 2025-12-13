// Message.swift
// Model for conversation messages

import Foundation

public enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

public struct Message: Identifiable, Codable, Sendable {
    public let id: UUID
    public let role: MessageRole
    public let text: String
    public let timestamp: Date

    // Optional metadata
    public var usage: Usage?
    public var cost: Double?
    public var error: String?

    public init(id: UUID = UUID(), role: MessageRole, text: String, timestamp: Date = Date(), usage: Usage? = nil, cost: Double? = nil, error: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.usage = usage
        self.cost = cost
        self.error = error
    }
}

public struct Usage: Codable, Sendable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheWriteTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadTokens = "cache_read_input_tokens"
        case cacheWriteTokens = "cache_creation_input_tokens"
    }

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, cacheReadTokens: Int? = nil, cacheWriteTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }
}
