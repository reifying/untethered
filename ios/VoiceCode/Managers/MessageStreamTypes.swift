// MessageStreamTypes.swift
// Decoded wire-format types for the append-only message stream.
// v0.4.0 types: WireMessage, SessionHistoryPayload, LenientWireMessage.
// v0.5.0 sibling types: WireMessageV5, SessionHistoryPayloadV5, LenientWireMessageV5.
// Both versions coexist during the dual-protocol rollback window; routing by
// negotiated protocol version lives in VoiceCodeClient.
// See docs/design/append-only-message-stream.md and
// /Users/travisbrown/assist/notes/voice-code-sync-kafka-redesign-2026-05-10.md §3.5.

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

// MARK: - v0.5.0 sibling types (offset protocol)
//
// These mirror the v0.4.0 types above with the field rename `seq` → `offset`
// and an envelope shape that drops `firstSeq`/`lastSeq`/`gap` and adds
// `fileReplaced`/`fileSignature`. The v0.4.0 structs above are untouched so
// both protocols decode cleanly during the dual-protocol rollback window.

/// v0.5.0 wire shape. Identical to `WireMessage` except `seq: Int64`
/// (JSON key `"seq"`) is replaced by `offset: Int64` (JSON key `"offset"`).
/// The custom timestamp decode/encode mirrors `WireMessage`'s line-for-line
/// so the ISO-8601 contract is preserved on both protocols.
struct WireMessageV5: Codable, Equatable {
    let sessionId: String
    let offset: Int64
    let role: String
    let text: String
    let uuid: String
    let timestamp: Date

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case offset
        case role
        case text
        case uuid
        case timestamp
    }

    init(sessionId: String, offset: Int64, role: String, text: String, uuid: String, timestamp: Date) {
        self.sessionId = sessionId
        self.offset = offset
        self.role = role
        self.text = text
        self.uuid = uuid
        self.timestamp = timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        offset = try container.decode(Int64.self, forKey: .offset)
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
        try container.encode(offset, forKey: .offset)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        try container.encode(uuid, forKey: .uuid)
        try container.encode(MessageStreamDateFormat.format(timestamp), forKey: .timestamp)
    }
}

/// v0.5.0 reply shape. Sibling of `SessionHistoryPayload` (v0.4.0), kept
/// separate so both wire formats decode cleanly during the dual-protocol
/// rollback. Drops `first_seq`/`last_seq`/`gap`, adds `file_replaced`/
/// `file_signature` (server signals the R2 recovery path via these).
struct SessionHistoryPayloadV5: Codable, Equatable {
    let sessionId: String
    let messages: [WireMessageV5]
    let nextOffset: Int64
    let endOfFile: Bool
    let fileReplaced: Bool?
    let fileSignature: String?

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case messages
        case nextOffset = "next_offset"
        case endOfFile = "end_of_file"
        case fileReplaced = "file_replaced"
        case fileSignature = "file_signature"
    }

    init(sessionId: String,
         messages: [WireMessageV5],
         nextOffset: Int64,
         endOfFile: Bool,
         fileReplaced: Bool?,
         fileSignature: String?) {
        self.sessionId = sessionId
        self.messages = messages
        self.nextOffset = nextOffset
        self.endOfFile = endOfFile
        self.fileReplaced = fileReplaced
        self.fileSignature = fileSignature
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)

        // Decode messages leniently: a single malformed entry skips just that
        // message rather than dropping the whole batch (mirrors v0.4.0).
        var messagesContainer = try container.nestedUnkeyedContainer(forKey: .messages)
        var decoded: [WireMessageV5] = []
        var skipCount = 0
        var firstFailureReason: String?
        while !messagesContainer.isAtEnd {
            let wrapper = try messagesContainer.decode(LenientWireMessageV5.self)
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

        nextOffset = try container.decode(Int64.self, forKey: .nextOffset)
        endOfFile = try container.decode(Bool.self, forKey: .endOfFile)
        fileReplaced = try container.decodeIfPresent(Bool.self, forKey: .fileReplaced)
        fileSignature = try container.decodeIfPresent(String.self, forKey: .fileSignature)

        if skipCount > 0 {
            let sid = sessionId
            let reason = firstFailureReason ?? "unknown"
            logger.warning("session_history v5 for \(sid, privacy: .public): skipped \(skipCount, privacy: .public) malformed message(s); first reason: \(reason, privacy: .public)")
        }
    }
}

/// v0.5.0 analog of `LenientWireMessage`. Wraps `WireMessageV5` decode in a
/// non-throwing facade so an unkeyed container can advance past a malformed
/// element instead of aborting the whole array.
private struct LenientWireMessageV5: Decodable {
    let value: WireMessageV5?
    let failureReason: String?

    init(from decoder: Decoder) throws {
        do {
            value = try WireMessageV5(from: decoder)
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
