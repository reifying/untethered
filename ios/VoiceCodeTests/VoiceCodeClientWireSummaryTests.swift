// VoiceCodeClientWireSummaryTests.swift
// Pins the format of the inbound/outbound LogManager lines emitted from
// VoiceCodeClient. These lines are the primary signal we read off-device
// (the iOS log copy buffer is ~15K chars), so a regression that drops
// session ids, seq numbers, or message types would make wire bugs
// invisible. If a new message type is added or an existing one grows a
// field worth tracing, extend `wireSummaryFields` and add a case here.

import XCTest
@testable import VoiceCode

final class VoiceCodeClientWireSummaryTests: XCTestCase {

    // MARK: - Outgoing

    func testSubscribeOutgoingHasSessionAndLastSeq() {
        let s = VoiceCodeClient.summarizeOutgoing([
            "type": "subscribe",
            "session_id": "abcdef0123456789",
            "last_seq": Int64(549)
        ])
        XCTAssertTrue(s.hasPrefix("subscribe "), s)
        XCTAssertTrue(s.contains("sess=abcdef01"), s)
        XCTAssertTrue(s.contains("last_seq=549"), s)
    }

    func testPromptOutgoingNewSession() {
        let s = VoiceCodeClient.summarizeOutgoing([
            "type": "prompt",
            "new_session_id": "12345678abcdef",
            "provider": "claude",
            "text": "Hello"
        ])
        XCTAssertTrue(s.hasPrefix("prompt "), s)
        XCTAssertTrue(s.contains("prov=claude"), s)
        XCTAssertTrue(s.contains("len=5"), s)
    }

    func testPromptOutgoingResume() {
        let s = VoiceCodeClient.summarizeOutgoing([
            "type": "prompt",
            "resume_session_id": "deadbeef1234",
            "text": "go"
        ])
        XCTAssertTrue(s.contains("len=2"), s)
    }

    func testUnsubscribeOutgoing() {
        let s = VoiceCodeClient.summarizeOutgoing([
            "type": "unsubscribe",
            "session_id": "abcdef0123456789"
        ])
        XCTAssertTrue(s.hasPrefix("unsubscribe "), s)
        XCTAssertTrue(s.contains("sess=abcdef01"), s)
    }

    func testUnknownTypeStillLogsType() {
        let s = VoiceCodeClient.summarizeOutgoing(["type": "made_up_type"])
        XCTAssertEqual(s, "made_up_type")
    }

    func testMissingTypeRendersQuestionMark() {
        let s = VoiceCodeClient.summarizeOutgoing([:])
        XCTAssertEqual(s, "?")
    }

    // MARK: - Incoming

    func testSessionHistoryIncomingShape() {
        let json: [String: Any] = [
            "type": "session_history",
            "session_id": "abcdef0123456789",
            "first_seq": 550,
            "last_seq": 552,
            "next_seq": 553,
            "is_complete": true,
            "messages": [["seq": 550], ["seq": 551], ["seq": 552]]
        ]
        let s = VoiceCodeClient.summarizeIncoming(type: "session_history", json: json)
        XCTAssertTrue(s.hasPrefix("session_history "), s)
        XCTAssertTrue(s.contains("sess=abcdef01"), s)
        XCTAssertTrue(s.contains("first=550"), s)
        XCTAssertTrue(s.contains("last=552"), s)
        XCTAssertTrue(s.contains("next=553"), s)
        XCTAssertTrue(s.contains("complete=true"), s)
        XCTAssertTrue(s.contains("msgs=3"), s)
    }

    func testSessionHistoryWithGap() {
        let json: [String: Any] = [
            "type": "session_history",
            "session_id": "abcdef0123456789",
            "next_seq": 200,
            "is_complete": true,
            "messages": [],
            "gap": ["reason": "pruned", "min_available_seq": 200, "requested_last_seq": 42]
        ]
        let s = VoiceCodeClient.summarizeIncoming(type: "session_history", json: json)
        XCTAssertTrue(s.contains("gap=pruned"), s)
    }

    func testTurnCompleteIncoming() {
        let s = VoiceCodeClient.summarizeIncoming(type: "turn_complete", json: [
            "type": "turn_complete",
            "session_id": "abcdef0123456789"
        ])
        XCTAssertTrue(s.hasPrefix("turn_complete "), s)
        XCTAssertTrue(s.contains("sess=abcdef01"), s)
        // aborted=false is suppressed (no value), aborted=true would show
        XCTAssertFalse(s.contains("aborted"), s)
    }

    func testTurnCompleteAbortedShowsFlag() {
        let s = VoiceCodeClient.summarizeIncoming(type: "turn_complete", json: [
            "type": "turn_complete",
            "session_id": "abcdef0123456789",
            "aborted": true
        ])
        XCTAssertTrue(s.contains("aborted=true"), s)
    }

    func testErrorIncomingHasCodeAndMessage() {
        let s = VoiceCodeClient.summarizeIncoming(type: "error", json: [
            "type": "error",
            "code": "unsupported_protocol_version",
            "message": "Client is too old; upgrade required"
        ])
        XCTAssertTrue(s.contains("code=unsupported_protocol_version"), s)
        XCTAssertTrue(s.contains("msg=Client is too old"), s)
    }

    func testHelloShowsVersion() {
        let s = VoiceCodeClient.summarizeIncoming(type: "hello", json: [
            "type": "hello",
            "version": "0.4.0"
        ])
        XCTAssertTrue(s.contains("ver=0.4.0"), s)
    }

    // MARK: - Silencing

    func testHighFrequencyTypesAreSilenced() {
        XCTAssertTrue(VoiceCodeClient.wireLogSilenced(type: "pong"))
        XCTAssertTrue(VoiceCodeClient.wireLogSilenced(type: "ping"))
        XCTAssertTrue(VoiceCodeClient.wireLogSilenced(type: "command_output"))
    }

    func testNormalTypesAreNotSilenced() {
        XCTAssertFalse(VoiceCodeClient.wireLogSilenced(type: "subscribe"))
        XCTAssertFalse(VoiceCodeClient.wireLogSilenced(type: "session_history"))
        XCTAssertFalse(VoiceCodeClient.wireLogSilenced(type: "turn_complete"))
        XCTAssertFalse(VoiceCodeClient.wireLogSilenced(type: "error"))
    }

    // MARK: - Length budget

    /// Hard ceiling on the longest plausible summary line. The iOS log
    /// copy buffer is ~15K chars; if these ever exceed ~120 chars the
    /// effective window of the buffer drops below ~125 messages.
    func testTypicalLinesStayUnder120Chars() {
        let cases: [(String, [String: Any])] = [
            ("subscribe", ["type": "subscribe", "session_id": "abcdef0123456789abcdef", "last_seq": Int64(99999)]),
            ("session_history", ["type": "session_history", "session_id": "abcdef0123456789", "first_seq": 99999, "last_seq": 99999, "next_seq": 100000, "is_complete": true, "messages": [["seq": 99999]]]),
            ("prompt", ["type": "prompt", "new_session_id": "abcdef0123456789", "provider": "claude", "text": String(repeating: "x", count: 5000)])
        ]
        for (label, dict) in cases {
            let s = VoiceCodeClient.summarizeOutgoing(dict)
            XCTAssertLessThan(s.count, 120, "\(label) too long: \(s.count) chars: \(s)")
        }
    }
}
