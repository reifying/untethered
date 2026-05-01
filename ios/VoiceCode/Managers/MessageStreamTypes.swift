// MessageStreamTypes.swift
// Decoded wire-format types for the append-only message stream (protocol v0.4.0).
// See docs/design/append-only-message-stream.md.

import Foundation
import os.log

private let logger = Logger(subsystem: "dev.910labs.voice-code", category: "MessageStreamTypes")

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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)

        // Decode messages leniently. A single malformed entry (missing seq,
        // wrong type, bad timestamp) skips just that message instead of
        // dropping the entire batch — without this, one bad message causes
        // every other message in the same payload to be lost silently.
        var messagesContainer = try container.nestedUnkeyedContainer(forKey: .messages)
        var decoded: [WireMessage] = []
        var skipCount = 0
        var firstFailureReason: String?
        while !messagesContainer.isAtEnd {
            let wrapper = try messagesContainer.decode(LenientWireMessage.self)
            if let msg = wrapper.value {
                decoded.append(msg)
            } else {
                skipCount += 1
                if firstFailureReason == nil {
                    firstFailureReason = wrapper.failureReason
                }
            }
        }
        messages = decoded

        firstSeq = try container.decodeIfPresent(Int64.self, forKey: .firstSeq)
        lastSeq = try container.decodeIfPresent(Int64.self, forKey: .lastSeq)
        nextSeq = try container.decode(Int64.self, forKey: .nextSeq)
        isComplete = try container.decode(Bool.self, forKey: .isComplete)
        gap = try container.decodeIfPresent(Gap.self, forKey: .gap)

        if skipCount > 0 {
            // Bind locals so the os.log autoclosures don't capture `self`
            // mid-init (which would be a mutating-self capture error).
            let sid = sessionId
            let reason = firstFailureReason ?? "unknown"
            logger.warning("session_history for \(sid, privacy: .public): skipped \(skipCount, privacy: .public) malformed message(s); first reason: \(reason, privacy: .public)")
        }
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

/// Wraps `WireMessage` decode in a non-throwing facade so that an unkeyed
/// container can advance past a malformed element instead of aborting the
/// whole array. Used only by `SessionHistoryPayload`'s lenient decode path.
private struct LenientWireMessage: Decodable {
    let value: WireMessage?
    let failureReason: String?

    init(from decoder: Decoder) throws {
        do {
            value = try WireMessage(from: decoder)
            failureReason = nil
        } catch {
            value = nil
            failureReason = String(describing: error)
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
