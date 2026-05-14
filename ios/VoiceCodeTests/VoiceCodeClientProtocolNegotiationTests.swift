// VoiceCodeClientProtocolNegotiationTests.swift
//
// Coverage for tmux-untethered-398.6:
// per-channel `negotiatedProtocolVersion` state and the inbound
// `session_history` deserialization routing it drives.

import XCTest
import CoreData
@testable import VoiceCode

final class VoiceCodeClientProtocolNegotiationTests: XCTestCase {
    var client: VoiceCodeClient!
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!

    override func setUpWithError() throws {
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
        client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
    }

    override func tearDownWithError() throws {
        client?.disconnect()
        client = nil
        persistenceController = nil
        context = nil
    }

    // MARK: - Default state

    /// Before any connect-ack lands the client speaks v0.4.0. This is the
    /// load-bearing safe default — a subscribe issued in the pre-ack window
    /// serializes the legacy wire shape, not the v0.5.0 one, so a v0.4.0-only
    /// server doesn't reject it.
    func testDefaultProtocolVersionIsV040() {
        XCTAssertEqual(client.negotiatedProtocolVersion, .v0_4_0)
    }

    // MARK: - Connect-ack consumption

    func testApplyNegotiatedProtocolVersionUpdatesToV050() {
        XCTAssertEqual(client.negotiatedProtocolVersion, .v0_4_0)

        client.applyNegotiatedProtocolVersion(from: [
            "type": "connect_ack",
            "negotiated_protocol_version": "0.5.0"
        ])

        XCTAssertEqual(client.negotiatedProtocolVersion, .v0_5_0)
    }

    func testApplyNegotiatedProtocolVersionKeepsV040WhenFieldAbsent() {
        // A pre-T7 server (or a frame that doesn't carry the field) must
        // leave the existing value alone — defaulting to `.v0_4_0`.
        client.applyNegotiatedProtocolVersion(from: [
            "type": "connected",
            "message": "ok"
        ])

        XCTAssertEqual(client.negotiatedProtocolVersion, .v0_4_0)
    }

    func testApplyNegotiatedProtocolVersionIgnoresUnknownValue() {
        // After being upgraded to v0.5.0, an unrecognized value must NOT
        // demote the state — the helper is conservative on bad input.
        client.applyNegotiatedProtocolVersion(from: [
            "negotiated_protocol_version": "0.5.0"
        ])
        XCTAssertEqual(client.negotiatedProtocolVersion, .v0_5_0)

        client.applyNegotiatedProtocolVersion(from: [
            "negotiated_protocol_version": "9.9.9"
        ])
        XCTAssertEqual(client.negotiatedProtocolVersion, .v0_5_0)
    }

    func testDisconnectResetsToV040Default() {
        client.applyNegotiatedProtocolVersion(from: [
            "negotiated_protocol_version": "0.5.0"
        ])
        XCTAssertEqual(client.negotiatedProtocolVersion, .v0_5_0)

        client.disconnect()

        // disconnect schedules the reset on main; pump the run loop briefly.
        let exp = expectation(description: "disconnect reset")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(client.negotiatedProtocolVersion, .v0_4_0,
                       "Negotiated version must reset to the safe default on socket loss")
    }

    // MARK: - Subscribe wire-shape safe default

    /// AC: a subscribe issued before the connect-ack lands uses the v0.4.0
    /// wire shape (current subscribe sends `last_seq`, not `from_offset`).
    /// This is the regression guard against a pre-ack subscribe accidentally
    /// announcing the v0.5.0 shape against a v0.4.0-only server.
    func testSubscribeBeforeConnectAckUsesV040WireShape() {
        XCTAssertEqual(client.negotiatedProtocolVersion, .v0_4_0,
                       "Precondition: default version is v0.4.0")
        var sent: [[String: Any]] = []
        client.onMessageSent = { sent.append($0) }
        client.isAuthenticated = true

        let sid = UUID().uuidString.lowercased()
        client.subscribe(sessionId: sid, context: context)

        let subscribes = sent.filter { ($0["type"] as? String) == "subscribe" }
        XCTAssertEqual(subscribes.count, 1)
        let msg = try? XCTUnwrap(subscribes.first)
        // v0.4.0 wire shape carries `last_seq` (the cursor field). v0.5.0
        // will swap to `from_offset` once tmux-untethered-398.12 lands; for
        // T6 we only assert the legacy shape is what goes out by default.
        XCTAssertNotNil(msg?["last_seq"], "Pre-ack subscribe must carry v0.4.0 `last_seq`")
        XCTAssertNil(msg?["from_offset"], "Pre-ack subscribe must NOT carry v0.5.0 `from_offset`")
    }

    /// Post-ack: after the channel is negotiated to v0.5.0, the subscribe
    /// wire shape switches to `from_offset` (and optionally
    /// `file_signature_seen` when one is cached). Shipped in
    /// tmux-untethered-398.12. The v0.4.0 `last_seq` field must not appear.
    func testSubscribeAfterAckUsesV050WireShape() {
        client.applyNegotiatedProtocolVersion(from: [
            "negotiated_protocol_version": "0.5.0"
        ])
        XCTAssertEqual(client.negotiatedProtocolVersion, .v0_5_0)
        var sent: [[String: Any]] = []
        client.onMessageSent = { sent.append($0) }
        client.isAuthenticated = true

        let sid = UUID().uuidString.lowercased()
        client.subscribe(sessionId: sid, context: context)

        let subscribes = sent.filter { ($0["type"] as? String) == "subscribe" }
        XCTAssertEqual(subscribes.count, 1)
        let msg = subscribes.first
        XCTAssertNotNil(msg?["from_offset"],
                        "Post-ack subscribe must carry v0.5.0 `from_offset`")
        XCTAssertNil(msg?["last_seq"],
                     "Post-ack subscribe must NOT carry v0.4.0 `last_seq` after .12")
        // No cached file signature for a fresh session: the optional field
        // is omitted entirely (server treats absence as "client has nothing
        // to verify against").
        XCTAssertNil(msg?["file_signature_seen"],
                     "Fresh session has no cached signature — field must be omitted")
    }

    /// Value guard (not just presence): a v0.5.0 subscribe after recovery
    /// must serialize the persisted `lastOffsetMerged` as the `from_offset`
    /// number and the persisted `lastFileSignature` as the
    /// `file_signature_seen` string. Catches field-name drift or accidental
    /// hardcoding to 0 / nil on the wire.
    func testSubscribeV050SerializesPersistedCursorAndSignature() {
        let sessionUUID = UUID()
        let sid = sessionUUID.uuidString.lowercased()

        let session = CDBackendSession(context: context)
        session.id = sessionUUID
        session.backendName = "test"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.provider = "claude"
        session.lastOffsetMerged = 42
        session.liveFromOffset = 7
        session.lastFileSignature = "1024:deadbeef"
        try? context.save()

        client.applyNegotiatedProtocolVersion(from: [
            "negotiated_protocol_version": "0.5.0"
        ])
        var sent: [[String: Any]] = []
        client.onMessageSent = { sent.append($0) }
        client.isAuthenticated = true

        client.subscribe(sessionId: sid, context: context)

        let subscribes = sent.filter { ($0["type"] as? String) == "subscribe" }
        XCTAssertEqual(subscribes.count, 1)
        let msg = subscribes.first

        let fromOffset = (msg?["from_offset"] as? Int64)
            ?? Int64(msg?["from_offset"] as? Int ?? -1)
        XCTAssertEqual(fromOffset, 42,
                       "from_offset must equal the persisted lastOffsetMerged")
        XCTAssertEqual(msg?["file_signature_seen"] as? String, "1024:deadbeef",
                       "file_signature_seen must equal the persisted lastFileSignature")
        XCTAssertEqual(msg?["session_id"] as? String, sid)
    }

    // MARK: - session_history dispatch routing

    /// Under `.v0_4_0`, an inbound v0.4.0 session_history frame must decode
    /// successfully and dispatch through the existing v0.4.0 sync path
    /// (regression guard — adding the v5 sibling must not break v4 routing).
    func testSessionHistoryRoutesV040PayloadUnderV040() {
        XCTAssertEqual(client.negotiatedProtocolVersion, .v0_4_0)

        let json: [String: Any] = [
            "type": "session_history",
            "session_id": "s-v4",
            "messages": [
                [
                    "session_id": "s-v4",
                    "seq": 1,
                    "role": "user",
                    "text": "hi",
                    "uuid": "u",
                    "timestamp": "2026-04-20T18:12:59Z"
                ]
            ],
            "first_seq": 1,
            "last_seq": 1,
            "next_seq": 2,
            "is_complete": true
        ]

        XCTAssertTrue(client.handleSessionHistoryFrame(json: json),
                      "v0.4.0 payload must decode successfully under v0.4.0 routing")
    }

    /// Under `.v0_5_0`, an inbound v0.5.0 session_history frame must decode
    /// without error. The v5 sync-manager wiring is deferred to
    /// tmux-untethered-398.12; this test pins the decode-routing decision.
    func testSessionHistoryRoutesV050PayloadUnderV050() {
        client.applyNegotiatedProtocolVersion(from: [
            "negotiated_protocol_version": "0.5.0"
        ])
        XCTAssertEqual(client.negotiatedProtocolVersion, .v0_5_0)

        let json: [String: Any] = [
            "type": "session_history",
            "session_id": "s-v5",
            "messages": [
                [
                    "session_id": "s-v5",
                    "offset": 0,
                    "role": "user",
                    "text": "hello-v5",
                    "uuid": "u",
                    "timestamp": "2026-04-20T18:12:59Z"
                ]
            ],
            "next_offset": 1,
            "end_of_file": true,
            "file_signature": "100:abc"
        ]

        XCTAssertTrue(client.handleSessionHistoryFrame(json: json),
                      "v0.5.0 payload must decode successfully under v0.5.0 routing")
    }

    /// Cross-shape: a v0.4.0-shaped payload arriving while the client is
    /// negotiated to v0.5.0 must NOT decode as v5 (no `offset`/`next_offset`/
    /// `end_of_file` keys present). The router falls into the v5 branch and
    /// the decoder rejects the shape — by design, no fallback. This is the
    /// negative side of the routing decision: a misnegotiated payload is
    /// logged as a decode failure, not silently mis-interpreted.
    func testSessionHistoryV040PayloadFailsDecodeUnderV050Routing() {
        client.applyNegotiatedProtocolVersion(from: [
            "negotiated_protocol_version": "0.5.0"
        ])

        let json: [String: Any] = [
            "type": "session_history",
            "session_id": "s",
            "messages": [],
            "first_seq": NSNull(),
            "last_seq": NSNull(),
            "next_seq": 1,
            "is_complete": true
        ]

        XCTAssertFalse(client.handleSessionHistoryFrame(json: json),
                       "v0.4.0-shaped payload must NOT decode under v0.5.0 routing — required v5 keys missing")
    }
}
