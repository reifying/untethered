// MessageStreamTypesTests.swift
// Unit tests for the append-only message stream wire types (protocol v0.4.0).

import XCTest
@testable import VoiceCode

final class MessageStreamTypesTests: XCTestCase {

    // MARK: - WireMessage

    func test_wireMessage_decodesSnakeCaseKeys() throws {
        let json = """
        {
          "session_id": "36895c49-1111-2222-3333-444444444444",
          "seq": 549,
          "role": "assistant",
          "text": "hello",
          "uuid": "8b4472f6-aaaa-bbbb-cccc-dddddddddddd",
          "timestamp": "2026-04-20T18:12:59.123Z"
        }
        """.data(using: .utf8)!

        let msg = try JSONDecoder().decode(WireMessage.self, from: json)

        XCTAssertEqual(msg.sessionId, "36895c49-1111-2222-3333-444444444444")
        XCTAssertEqual(msg.seq, 549)
        XCTAssertEqual(msg.role, "assistant")
        XCTAssertEqual(msg.text, "hello")
        XCTAssertEqual(msg.uuid, "8b4472f6-aaaa-bbbb-cccc-dddddddddddd")
    }

    func test_wireMessage_encodesSnakeCaseKeys() throws {
        let msg = WireMessage(
            sessionId: "36895c49-1111-2222-3333-444444444444",
            seq: 549,
            role: "assistant",
            text: "hello",
            uuid: "8b4472f6-aaaa-bbbb-cccc-dddddddddddd",
            timestamp: Date(timeIntervalSince1970: 1_745_172_779.123)
        )

        let data = try JSONEncoder().encode(msg)
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(dict["session_id"] as? String, "36895c49-1111-2222-3333-444444444444")
        XCTAssertEqual(dict["seq"] as? Int64, 549)
        XCTAssertEqual(dict["role"] as? String, "assistant")
        XCTAssertEqual(dict["text"] as? String, "hello")
        XCTAssertEqual(dict["uuid"] as? String, "8b4472f6-aaaa-bbbb-cccc-dddddddddddd")
        XCTAssertNotNil(dict["timestamp"] as? String)
        // Must NOT contain camelCase keys on the wire.
        XCTAssertNil(dict["sessionId"])
    }

    func test_wireMessage_roundTrip_preservesAllFields() throws {
        let original = WireMessage(
            sessionId: "36895c49-1111-2222-3333-444444444444",
            seq: 12345,
            role: "user",
            text: "round trip",
            uuid: "8b4472f6-aaaa-bbbb-cccc-dddddddddddd",
            timestamp: Date(timeIntervalSince1970: 1_745_172_779.456)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: data)

        XCTAssertEqual(decoded.sessionId, original.sessionId)
        XCTAssertEqual(decoded.seq, original.seq)
        XCTAssertEqual(decoded.role, original.role)
        XCTAssertEqual(decoded.text, original.text)
        XCTAssertEqual(decoded.uuid, original.uuid)
        XCTAssertEqual(decoded.timestamp.timeIntervalSince1970,
                       original.timestamp.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    func test_wireMessage_acceptsNonFractionalTimestamp() throws {
        let json = """
        {
          "session_id": "s",
          "seq": 1,
          "role": "user",
          "text": "t",
          "uuid": "u",
          "timestamp": "2026-04-20T18:12:59Z"
        }
        """.data(using: .utf8)!

        let msg = try JSONDecoder().decode(WireMessage.self, from: json)
        XCTAssertEqual(msg.seq, 1)
        XCTAssertNotNil(msg.timestamp)
    }

    func test_wireMessage_invalidTimestamp_throwsDecodingError() {
        let json = """
        {
          "session_id": "s",
          "seq": 1,
          "role": "user",
          "text": "t",
          "uuid": "u",
          "timestamp": "not-a-date"
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(WireMessage.self, from: json)) { error in
            guard case DecodingError.dataCorrupted = error else {
                XCTFail("expected DecodingError.dataCorrupted, got \(error)")
                return
            }
        }
    }

    // MARK: - SessionHistoryPayload

    func test_sessionHistoryPayload_decodesFullEnvelope() throws {
        let json = """
        {
          "type": "session_history",
          "session_id": "36895c49-1111-2222-3333-444444444444",
          "messages": [
            {
              "session_id": "36895c49-1111-2222-3333-444444444444",
              "seq": 549,
              "role": "assistant",
              "text": "m1",
              "uuid": "8b4472f6-aaaa-bbbb-cccc-dddddddddddd",
              "timestamp": "2026-04-20T18:12:59Z"
            }
          ],
          "first_seq": 549,
          "last_seq": 549,
          "next_seq": 550,
          "is_complete": true,
          "gap": null
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(SessionHistoryPayload.self, from: json)
        XCTAssertEqual(payload.sessionId, "36895c49-1111-2222-3333-444444444444")
        XCTAssertEqual(payload.messages.count, 1)
        XCTAssertEqual(payload.firstSeq, 549)
        XCTAssertEqual(payload.lastSeq, 549)
        XCTAssertEqual(payload.nextSeq, 550)
        XCTAssertTrue(payload.isComplete)
        XCTAssertNil(payload.gap)
    }

    func test_sessionHistoryPayload_decodesEmptyCaughtUpReply() throws {
        let json = """
        {
          "session_id": "s",
          "messages": [],
          "first_seq": null,
          "last_seq": null,
          "next_seq": 550,
          "is_complete": true,
          "gap": null
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(SessionHistoryPayload.self, from: json)
        XCTAssertTrue(payload.messages.isEmpty)
        XCTAssertNil(payload.firstSeq)
        XCTAssertNil(payload.lastSeq)
        XCTAssertEqual(payload.nextSeq, 550)
        XCTAssertTrue(payload.isComplete)
        XCTAssertNil(payload.gap)
    }

    func test_sessionHistoryPayload_decodesIsCompleteFalse() throws {
        let json = """
        {
          "session_id": "s",
          "messages": [],
          "first_seq": null,
          "last_seq": null,
          "next_seq": 5,
          "is_complete": false,
          "gap": null
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(SessionHistoryPayload.self, from: json)
        XCTAssertFalse(payload.isComplete)
    }

    func test_sessionHistoryPayload_encodesSnakeCaseKeys() throws {
        let payload = SessionHistoryPayload(
            sessionId: "s",
            messages: [],
            firstSeq: nil,
            lastSeq: nil,
            nextSeq: 1,
            isComplete: true,
            gap: nil
        )

        let data = try JSONEncoder().encode(payload)
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(dict["session_id"] as? String, "s")
        XCTAssertEqual(dict["next_seq"] as? Int64, 1)
        XCTAssertEqual(dict["is_complete"] as? Bool, true)
        XCTAssertNil(dict["sessionId"])
        XCTAssertNil(dict["nextSeq"])
        XCTAssertNil(dict["isComplete"])
    }

    func test_sessionHistoryPayload_roundTrip_preservesAllFields() throws {
        let msg = WireMessage(
            sessionId: "s",
            seq: 10,
            role: "assistant",
            text: "t",
            uuid: "u",
            timestamp: Date(timeIntervalSince1970: 1_745_172_779.5)
        )
        let original = SessionHistoryPayload(
            sessionId: "s",
            messages: [msg],
            firstSeq: 10,
            lastSeq: 10,
            nextSeq: 11,
            isComplete: false,
            gap: nil
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionHistoryPayload.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Gap

    func test_gap_decodesPrunedReason() throws {
        let json = """
        {
          "requested_last_seq": 42,
          "min_available_seq": 200,
          "reason": "pruned"
        }
        """.data(using: .utf8)!

        let gap = try JSONDecoder().decode(SessionHistoryPayload.Gap.self, from: json)
        XCTAssertEqual(gap.requestedLastSeq, 42)
        XCTAssertEqual(gap.minAvailableSeq, 200)
        XCTAssertEqual(gap.reason, "pruned")
    }

    func test_gap_decodesClientAheadReason() throws {
        let json = """
        {
          "requested_last_seq": 612,
          "min_available_seq": 1,
          "reason": "client_ahead"
        }
        """.data(using: .utf8)!

        let gap = try JSONDecoder().decode(SessionHistoryPayload.Gap.self, from: json)
        XCTAssertEqual(gap.requestedLastSeq, 612)
        XCTAssertEqual(gap.minAvailableSeq, 1)
        XCTAssertEqual(gap.reason, "client_ahead")
    }

    func test_gap_encodesSnakeCaseKeys() throws {
        let gap = SessionHistoryPayload.Gap(
            requestedLastSeq: 42,
            minAvailableSeq: 200,
            reason: "pruned"
        )

        let data = try JSONEncoder().encode(gap)
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(dict["requested_last_seq"] as? Int64, 42)
        XCTAssertEqual(dict["min_available_seq"] as? Int64, 200)
        XCTAssertEqual(dict["reason"] as? String, "pruned")
        XCTAssertNil(dict["requestedLastSeq"])
        XCTAssertNil(dict["minAvailableSeq"])
    }

    func test_payloadWithGap_roundTrip() throws {
        let gap = SessionHistoryPayload.Gap(
            requestedLastSeq: 42,
            minAvailableSeq: 200,
            reason: "pruned"
        )
        let original = SessionHistoryPayload(
            sessionId: "s",
            messages: [],
            firstSeq: nil,
            lastSeq: nil,
            nextSeq: 300,
            isComplete: true,
            gap: gap
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionHistoryPayload.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
