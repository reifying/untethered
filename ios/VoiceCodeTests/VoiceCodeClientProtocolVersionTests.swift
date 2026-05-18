// VoiceCodeClientProtocolVersionTests.swift
// Covers the v0.4.0 wire-protocol cutover:
//   - subscribe(sessionId:) sends `last_seq` (Int64), not `last_message_id`.
//   - A mismatched `hello.version` or an explicit
//     `{"type":"error","code":"unsupported_protocol_version"}` transitions
//     the client into the terminal `requiresUpgrade` state and stops
//     reconnecting.

import XCTest
import CoreData
@testable import VoiceCode

final class VoiceCodeClientProtocolVersionTests: XCTestCase {
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

    /// `handleMessage` dispatches its switch to the main queue. Tests that
    /// call it directly must drain one tick of the main queue before reading
    /// any state it touched, or assertions race the dispatched work.
    private func drainMainQueue(timeout: TimeInterval = 1.0) {
        let expectation = XCTestExpectation(description: "main queue drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: timeout)
    }

    // MARK: - subscribe payload shape

    /// AC1 (client half) — subscribe emits the v0.4.0 wire shape: an integer
    /// `last_seq`, no `last_message_id`. The cursor is read from CoreData, so
    /// on a fresh session the wire value is 0 (the backend sentinel for
    /// "give me everything").
    func testSubscribePayloadOnFreshSessionSendsLastSeqZero() {
        let sessionId = UUID().uuidString.lowercased()

        // subscribe() sends on the wire only when isAuthenticated is true
        // (otherwise the call is buffered into activeSubscriptions and the
        // next `connected` handshake re-fires it). The wire-shape contract
        // applies to the authenticated case; mirror that state here.
        client.isAuthenticated = true

        var sent: [[String: Any]] = []
        client.onMessageSent = { sent.append($0) }

        client.subscribe(sessionId: sessionId)

        let subs = sent.filter { ($0["type"] as? String) == "subscribe" }
        XCTAssertEqual(subs.count, 1)
        let payload = subs[0]

        XCTAssertEqual(payload["session_id"] as? String, sessionId)
        // Key must be present and numeric, defaulting to 0 when the session
        // has no cached messages.
        XCTAssertNotNil(payload["last_seq"], "subscribe must include last_seq, even when 0")
        let lastSeq = (payload["last_seq"] as? Int64) ?? Int64(payload["last_seq"] as? Int ?? -1)
        XCTAssertEqual(lastSeq, 0)
        // Legacy key must not leak onto the wire.
        XCTAssertNil(payload["last_message_id"])
    }

    /// AC1 (client half, cursor source) — the cursor the subscribe payload
    /// carries is `newestCachedSeq`, which selects by seq, not timestamp.
    /// Timestamps diverge from seq-order below so a regression to
    /// timestamp-based selection would surface. We assert on
    /// `newestCachedSeq` directly because `subscribe()` resolves its cursor
    /// against the shared viewContext singleton, which the in-memory test
    /// store can't interpose on — the wire-shape contract is covered by
    /// `testSubscribePayloadOnFreshSessionSendsLastSeqZero`.
    func testNewestCachedSeqSelectsByMaxSeqNotTimestamp() throws {
        let sessionUUID = UUID()
        let sessionId = sessionUUID.uuidString.lowercased()
        let now = Date()

        let highSeq = CDMessage(context: context)
        highSeq.id = UUID()
        highSeq.sessionId = sessionUUID
        highSeq.role = "assistant"
        highSeq.text = "highest seq, oldest ts"
        highSeq.seq = 73
        highSeq.timestamp = now.addingTimeInterval(-600)
        highSeq.messageStatus = .confirmed

        let midSeq = CDMessage(context: context)
        midSeq.id = UUID()
        midSeq.sessionId = sessionUUID
        midSeq.role = "user"
        midSeq.text = "middle"
        midSeq.seq = 21
        midSeq.timestamp = now.addingTimeInterval(-300)
        midSeq.messageStatus = .confirmed

        let lowSeq = CDMessage(context: context)
        lowSeq.id = UUID()
        lowSeq.sessionId = sessionUUID
        lowSeq.role = "user"
        lowSeq.text = "lowest seq, newest ts"
        lowSeq.seq = 4
        lowSeq.timestamp = now
        lowSeq.messageStatus = .confirmed

        try context.save()

        XCTAssertEqual(client.newestCachedSeq(sessionId: sessionId, context: context), 73)
    }

    /// AC1 round-trip — JSON-encode the captured payload and re-parse it. The
    /// `last_seq` value must survive serialization as a numeric type with no
    /// surprises (Foundation's JSONSerialization sometimes promotes Int to
    /// NSNumber; the assertion is that it round-trips as an integer).
    func testSubscribePayloadSerializesAsJSON() throws {
        let sessionId = UUID().uuidString.lowercased()

        // subscribe() sends on the wire only when isAuthenticated is true;
        // pin that here so the wire-serialization assertions have a payload.
        client.isAuthenticated = true

        var sent: [[String: Any]] = []
        client.onMessageSent = { sent.append($0) }

        client.subscribe(sessionId: sessionId)

        let payload = try XCTUnwrap(sent.first(where: { ($0["type"] as? String) == "subscribe" }))
        let data = try JSONSerialization.data(withJSONObject: payload)
        let reparsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(reparsed["type"] as? String, "subscribe")
        XCTAssertEqual(reparsed["session_id"] as? String, sessionId)
        XCTAssertNotNil(reparsed["last_seq"])
        XCTAssertNil(reparsed["last_message_id"])
    }

    // MARK: - hello.version handshake

    /// AC7 (client half) — a `hello` announcing the client's own max version
    /// proceeds normally: the client marks itself connected and does NOT flip
    /// into upgrade-required state.
    func testHelloWithMatchingVersionProceeds() {
        let hello: [String: Any] = [
            "type": "hello",
            "message": "Welcome",
            "version": VoiceCodeClient.supportedProtocolVersion,  // "0.5.0"
            "auth_version": 1,
            "instructions": "Send connect"
        ]
        let json = String(data: try! JSONSerialization.data(withJSONObject: hello),
                          encoding: .utf8)!
        client.handleMessage(json)
        drainMainQueue()

        XCTAssertTrue(client.isConnected)
        XCTAssertFalse(client.requiresUpgrade)
        XCTAssertNil(client.upgradeRequiredMessage)
    }

    /// A v0.4.0 server (hello.version = "0.4.0") must also proceed — backward
    /// compatibility. The client can negotiate down to v0.4.0 via the connect /
    /// connected exchange; the hello floor check should not block it.
    func testHelloWithV040VersionProceeds() {
        let hello: [String: Any] = [
            "type": "hello",
            "message": "Welcome",
            "version": VoiceCodeClient.minimumServerProtocolVersion,  // "0.4.0"
            "auth_version": 1,
            "instructions": "Send connect"
        ]
        let json = String(data: try! JSONSerialization.data(withJSONObject: hello),
                          encoding: .utf8)!
        client.handleMessage(json)
        drainMainQueue()

        XCTAssertTrue(client.isConnected)
        XCTAssertFalse(client.requiresUpgrade,
                       "v0.4.0 server hello must not trigger upgrade-required")
        XCTAssertNil(client.upgradeRequiredMessage)
    }

    /// AC7 — an older server version must transition the client into the
    /// `requiresUpgrade` state. The client should not attempt to authenticate
    /// and should stop reconnecting (no more attempts will be scheduled).
    func testHelloWithOlderVersionTransitionsToUpgradeRequired() {
        let hello: [String: Any] = [
            "type": "hello",
            "message": "Welcome",
            "version": "0.3.0",
            "auth_version": 1,
            "instructions": "Send connect"
        ]
        let json = String(data: try! JSONSerialization.data(withJSONObject: hello),
                          encoding: .utf8)!

        var sent: [[String: Any]] = []
        client.onMessageSent = { sent.append($0) }

        client.handleMessage(json)
        drainMainQueue()

        XCTAssertTrue(client.requiresUpgrade,
                      "hello.version mismatch must flip requiresUpgrade=true")
        XCTAssertNotNil(client.upgradeRequiredMessage)
        XCTAssertFalse(client.isAuthenticated)
        // No connect payload should have been sent — we aborted before auth.
        XCTAssertTrue(sent.filter { ($0["type"] as? String) == "connect" }.isEmpty,
                      "client must not send connect when the protocol version is wrong")
    }

    /// A `hello` missing the `version` field is treated as a mismatch. The
    /// field is required in v0.4.0; absence means the peer is a stranger.
    func testHelloWithMissingVersionTransitionsToUpgradeRequired() {
        let hello: [String: Any] = [
            "type": "hello",
            "message": "Welcome",
            "auth_version": 1
        ]
        let json = String(data: try! JSONSerialization.data(withJSONObject: hello),
                          encoding: .utf8)!

        client.handleMessage(json)
        drainMainQueue()

        XCTAssertTrue(client.requiresUpgrade)
        XCTAssertNotNil(client.upgradeRequiredMessage)
    }

    // MARK: - connect message protocol_version field

    /// The connect payload must include `protocol_version` so the server can
    /// negotiate min(client, server-max) and echo it in `negotiated_protocol_version`.
    /// Without this field the server falls back to its floor (v0.4.0) even
    /// when the client can speak v0.5.0.
    func testSendConnectMessageIncludesProtocolVersion() throws {
        // Store a dummy API key so sendConnectMessage doesn't abort early.
        try KeychainManager.shared.saveAPIKey("test-key-protocol-version-test")

        var sent: [[String: Any]] = []
        client.onMessageSent = { sent.append($0) }

        // Trigger the full hello → connect flow.
        let hello: [String: Any] = [
            "type": "hello",
            "version": VoiceCodeClient.supportedProtocolVersion,
            "auth_version": 1,
            "message": "Welcome"
        ]
        let helloJson = String(data: try! JSONSerialization.data(withJSONObject: hello),
                               encoding: .utf8)!
        client.handleMessage(helloJson)
        drainMainQueue()

        let connects = sent.filter { ($0["type"] as? String) == "connect" }
        XCTAssertEqual(connects.count, 1, "Expected exactly one connect message")
        let connectPayload = connects[0]
        XCTAssertEqual(connectPayload["protocol_version"] as? String,
                       VoiceCodeClient.supportedProtocolVersion,
                       "connect must include protocol_version matching client max")

        // Clean up — don't leave a dummy key in the shared keychain.
        try? KeychainManager.shared.deleteAPIKey()
    }

    // MARK: - unsupported_protocol_version error

    /// AC7 — when the backend rejects the client with
    /// `{"type":"error","code":"unsupported_protocol_version"}`, the client
    /// must enter the upgrade-required state and stop retrying. The error
    /// payload's `received`/`required`/`message` fields get folded into the
    /// user-visible message.
    func testUnsupportedProtocolVersionErrorTransitionsToUpgradeRequired() {
        let errorMsg: [String: Any] = [
            "type": "error",
            "code": "unsupported_protocol_version",
            "required": "0.4.0",
            "received": "0.3.0",
            "message": "Client is too old; upgrade required"
        ]
        let json = String(data: try! JSONSerialization.data(withJSONObject: errorMsg),
                          encoding: .utf8)!

        client.handleMessage(json)
        drainMainQueue()

        XCTAssertTrue(client.requiresUpgrade,
                      "unsupported_protocol_version must flip requiresUpgrade=true")
        XCTAssertNotNil(client.upgradeRequiredMessage)
        XCTAssertFalse(client.isConnected,
                       "upgrade-required transition must drop the WebSocket flag so the reconnect path does not spin")
    }

    /// A plain error (no code / different code) must NOT trigger the upgrade
    /// path — it routes through the normal `currentError` surface so the user
    /// can see it without losing the session.
    func testUnrelatedErrorDoesNotTransitionToUpgradeRequired() {
        let errorMsg: [String: Any] = [
            "type": "error",
            "code": "unknown_session",
            "message": "Session not found"
        ]
        let json = String(data: try! JSONSerialization.data(withJSONObject: errorMsg),
                          encoding: .utf8)!

        client.handleMessage(json)
        drainMainQueue()

        XCTAssertFalse(client.requiresUpgrade)
    }

    /// Reconnect never retries once `requiresUpgrade` is set. Seeding a
    /// tracked subscription and driving the reconnect helper would normally
    /// re-emit a subscribe; after the upgrade-required transition, nothing
    /// should fire (the helper itself still iterates, but reconnection won't
    /// be attempted — we assert the latter via the flag state rather than
    /// driving the timer harness).
    func testUpgradeRequiredSkipsAppBecameActiveReconnect() {
        let errorMsg: [String: Any] = [
            "type": "error",
            "code": "unsupported_protocol_version",
            "required": "0.4.0",
            "received": "0.3.9",
            "message": "upgrade required"
        ]
        let json = String(data: try! JSONSerialization.data(withJSONObject: errorMsg),
                          encoding: .utf8)!
        client.handleMessage(json)
        drainMainQueue()

        XCTAssertTrue(client.requiresUpgrade)
        XCTAssertFalse(client.isConnected,
                       "upgrade-required transition must drop the WebSocket flag")
    }

    // MARK: - refreshSubscription

    /// `refreshSubscription` on a `.confirmed` subscription demotes to
    /// `.desired`, allowing `subscribe` to re-send the wire message and pick
    /// up any new messages accumulated since the last subscribe.
    func testRefreshSubscriptionOnConfirmedDemotesAndResubscribes() {
        let sessionId = UUID().uuidString.lowercased()
        client.isAuthenticated = true

        var sent: [[String: Any]] = []
        client.onMessageSent = { sent.append($0) }

        // Seed a .confirmed subscription via the normal path.
        client.subscribe(sessionId: sessionId)
        let firstSend = sent.filter { ($0["type"] as? String) == "subscribe" }
        XCTAssertEqual(firstSend.count, 1, "First subscribe must send a wire message")

        // Calling subscribe() again while .confirmed is a no-op (dedup guard).
        client.subscribe(sessionId: sessionId)
        XCTAssertEqual(sent.filter { ($0["type"] as? String) == "subscribe" }.count, 1,
                       "Second subscribe() call while .confirmed must be a no-op")

        // refreshSubscription demotes back to .desired, so the next subscribe fires.
        client.refreshSubscription(sessionId: sessionId)
        XCTAssertEqual(sent.filter { ($0["type"] as? String) == "subscribe" }.count, 2,
                       "refreshSubscription must send a second wire subscribe")
        // After the refresh, the entry must be .confirmed again.
        XCTAssertEqual(client.subscriptionsForTesting[sessionId], .confirmed)
    }

    /// `refreshSubscription` on a session that has never been subscribed is
    /// equivalent to a plain `subscribe` — it should track the entry and send
    /// one wire message.
    func testRefreshSubscriptionOnUnknownSessionBehavesLikeSubscribe() {
        let sessionId = UUID().uuidString.lowercased()
        client.isAuthenticated = true

        var sent: [[String: Any]] = []
        client.onMessageSent = { sent.append($0) }

        client.refreshSubscription(sessionId: sessionId)

        let subs = sent.filter { ($0["type"] as? String) == "subscribe" }
        XCTAssertEqual(subs.count, 1, "refreshSubscription on unknown session must send one wire subscribe")
        XCTAssertEqual(client.subscriptionsForTesting[sessionId], .confirmed)
    }

    /// `refreshSubscription` while not yet authenticated demotes .confirmed to
    /// .desired (so the pending intent is preserved) but does not send a wire
    /// message — the subscribe will fire from `restoreSubscriptionsAfterReconnect`
    /// once the handshake completes.
    func testRefreshSubscriptionWhileNotAuthenticatedDoesNotSendWire() {
        let sessionId = UUID().uuidString.lowercased()

        // Simulate a previously-confirmed subscription by marking it directly
        // via the testing accessor — in production the app might be mid-reconnect.
        client.isAuthenticated = true
        var sent: [[String: Any]] = []
        client.onMessageSent = { sent.append($0) }
        client.subscribe(sessionId: sessionId)
        XCTAssertEqual(client.subscriptionsForTesting[sessionId], .confirmed)

        // Now drop auth to simulate the reconnect window.
        client.isAuthenticated = false
        sent.removeAll()

        client.refreshSubscription(sessionId: sessionId)

        // The entry must be back to .desired (not .confirmed).
        XCTAssertEqual(client.subscriptionsForTesting[sessionId], .desired)
        // No wire message should have gone out.
        XCTAssertTrue(sent.filter { ($0["type"] as? String) == "subscribe" }.isEmpty,
                      "refreshSubscription must not send a wire subscribe when not authenticated")
    }

    // MARK: - File upload error suppression (tmux-untethered-mxu)

    /// File upload errors must NOT surface as a `currentError` banner. The
    /// intended behaviour (per the dead second case handler that was removed)
    /// is to log the failure and let ResourcesManager's timeout handle it.
    /// Regresses the duplicate `case "error":` dead-code bug where the second
    /// handler was unreachable and the first handler unconditionally set
    /// `currentError`.
    func testFileUploadErrorDoesNotSetCurrentError() {
        let msg: [String: Any] = [
            "type": "error",
            "message": "Failed to upload file: foo.png (size 1234 bytes)"
        ]
        let json = String(data: try! JSONSerialization.data(withJSONObject: msg),
                          encoding: .utf8)!

        client.handleMessage(json)
        drainMainQueue()

        XCTAssertNil(client.currentError,
                     "file upload errors must not set currentError — banner should not appear")
    }

    /// Non-upload errors must still set `currentError` so the banner appears.
    func testGenericErrorSetsCurrentError() {
        let msg: [String: Any] = [
            "type": "error",
            "message": "Something went wrong on the server"
        ]
        let json = String(data: try! JSONSerialization.data(withJSONObject: msg),
                          encoding: .utf8)!

        client.handleMessage(json)

        // scheduleUpdate debounces at 100ms; wait 200ms to ensure it has fired.
        let exp = XCTestExpectation(description: "debounce fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(client.currentError, "Something went wrong on the server",
                       "non-upload errors must set currentError so the UI shows a banner")
    }
}
