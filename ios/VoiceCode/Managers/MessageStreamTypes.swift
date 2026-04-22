// MessageStreamTypes.swift
// Decoded wire-format types for the append-only message stream (protocol v0.4.0).
// See docs/design/append-only-message-stream.md.

import Foundation

/// Decoded shape of a single message in a `session_history.messages` array.
/// Replaces ad-hoc dictionary access in SessionSyncManager with a typed struct
/// so wire mismatches surface at compile time.
struct WireMessage: Codable, Equatable {
    let sessionId: String
    let seq: Int64
    let role: String
    let text: String
    let uuid: String
    let timestamp: Date

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case seq
        case role
        case text
        case uuid
        case timestamp
    }

    init(sessionId: String, seq: Int64, role: String, text: String, uuid: String, timestamp: Date) {
        self.sessionId = sessionId
        self.seq = seq
        self.role = role
        self.text = text
        self.uuid = uuid
        self.timestamp = timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        seq = try container.decode(Int64.self, forKey: .seq)
        role = try container.decode(String.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        uuid = try container.decode(String.self, forKey: .uuid)

        let timestampString = try container.decode(String.self, forKey: .timestamp)
        guard let date = MessageStreamDateFormat.parse(timestampString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .timestamp,
                in: container,
                debugDescription: "Invalid ISO-8601 timestamp: \(timestampString)"
            )
        }
        timestamp = date
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(seq, forKey: .seq)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        try container.encode(uuid, forKey: .uuid)
        try container.encode(MessageStreamDateFormat.format(timestamp), forKey: .timestamp)
    }
}

/// Decoded shape of the `session_history` envelope — the single reply type
/// for both the initial load path and real-time pushes.
struct SessionHistoryPayload: Codable, Equatable {
    let sessionId: String
    let messages: [WireMessage]
    let firstSeq: Int64?
    let lastSeq: Int64?
    let nextSeq: Int64
    let isComplete: Bool
    let gap: Gap?

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case messages
        case firstSeq = "first_seq"
        case lastSeq = "last_seq"
        case nextSeq = "next_seq"
        case isComplete = "is_complete"
        case gap
    }

    init(sessionId: String,
         messages: [WireMessage],
         firstSeq: Int64?,
         lastSeq: Int64?,
         nextSeq: Int64,
         isComplete: Bool,
         gap: Gap?) {
        self.sessionId = sessionId
        self.messages = messages
        self.firstSeq = firstSeq
        self.lastSeq = lastSeq
        self.nextSeq = nextSeq
        self.isComplete = isComplete
        self.gap = gap
    }

    /// Signal from the server that it cannot satisfy the requested range.
    /// `reason` is one of `"pruned"` or `"client_ahead"`.
    struct Gap: Codable, Equatable {
        let requestedLastSeq: Int64
        let minAvailableSeq: Int64
        let reason: String

        private enum CodingKeys: String, CodingKey {
            case requestedLastSeq = "requested_last_seq"
            case minAvailableSeq = "min_available_seq"
            case reason
        }
    }
}

/// ISO-8601 timestamp handling shared across MessageStream types.
/// The backend may emit timestamps with or without fractional seconds; accept both.
enum MessageStreamDateFormat {
    static func parse(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
