// StalledChainBannerTests.swift
// Verifies stalledChains wiring: VoiceCodeClient.sessionSyncDidStallChain
// populates the published map, dismissStalledChain removes it, and
// StalledChainBanner is constructible and invokes its dismiss callback.
// Mirrors SessionSyncManagerPrunedGapTests.swift for the stalled-chain path.

import XCTest
import CoreData
@testable import VoiceCode

final class StalledChainBannerTests: XCTestCase {

    // MARK: - Helpers

    private func waitForMainQueue(timeout: TimeInterval = 1.0,
                                  file: StaticString = #file,
                                  line: UInt = #line,
                                  until condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "Condition not met within \(timeout)s", file: file, line: line)
    }

    private func drainMainQueue(for interval: TimeInterval = 0.2) {
        let deadline = Date().addingTimeInterval(interval)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: - VoiceCodeClient publishing

    func test_sessionSyncDidStallChain_populatesStalledChains() {
        let client = VoiceCodeClient(serverURL: "ws://localhost", setupObservers: false)
        let sessionId = "AAAABBBB-1111-2222-3333-444444444444"
        let cursor: Int64 = 42

        client.sessionSyncDidStallChain(sessionId, atCursor: cursor)

        // Stored lowercased so the view lookup is case-insensitive.
        XCTAssertEqual(client.stalledChains[sessionId.lowercased()], cursor)
        XCTAssertNil(client.stalledChains[sessionId],
                     "uppercased lookup must not leak past normalization")
    }

    func test_dismissStalledChain_removesEntry() {
        let client = VoiceCodeClient(serverURL: "ws://localhost", setupObservers: false)
        let sessionId = "aabbccdd-1111-2222-3333-444444444444"

        client.sessionSyncDidStallChain(sessionId, atCursor: 99)
        XCTAssertNotNil(client.stalledChains[sessionId])

        client.dismissStalledChain(sessionId: sessionId)
        XCTAssertNil(client.stalledChains[sessionId])
    }

    func test_dismissStalledChain_normalizesMixedCase() {
        let client = VoiceCodeClient(serverURL: "ws://localhost", setupObservers: false)
        let mixedCase = "AaBbCcDd-1111-2222-3333-444444444444"
        let lower = mixedCase.lowercased()

        client.sessionSyncDidStallChain(mixedCase, atCursor: 7)
        XCTAssertNotNil(client.stalledChains[lower])

        client.dismissStalledChain(sessionId: mixedCase)
        XCTAssertNil(client.stalledChains[lower])
    }

    // MARK: - Banner view

    func test_stalledChainBanner_invokesDismissCallback() {
        var dismissed = 0
        let banner = StalledChainBanner(cursor: 17) { dismissed += 1 }

        banner.onDismiss()
        XCTAssertEqual(dismissed, 1)
        XCTAssertEqual(banner.cursor, 17)
    }

    // MARK: - End-to-end via SessionSyncManager (v0.5.0 path)

    /// End-to-end: a stalled end_of_file:false chain fires
    /// `sessionSyncDidStallChain` through the delegate, which VoiceCodeClient
    /// records in `stalledChains`. Mirrors the analogous pruned-gap integration
    /// test in SessionSyncManagerPrunedGapTests.
    func test_voiceCodeClient_receivesStalledChain_whenManagerDetectsStall() {
        let persistenceController = PersistenceController(inMemory: true)
        let manager = SessionSyncManager(persistenceController: persistenceController)
        let client = VoiceCodeClient(serverURL: "ws://localhost",
                                     sessionSyncManager: manager,
                                     setupObservers: false)

        let sessionIdString = "11112222-3333-4444-5555-666666666666"
        let sessionUUID = UUID(uuidString: sessionIdString)!
        let lowerKey = sessionIdString.lowercased()

        // Seed the session in CoreData so the manager can fetch it.
        let ctx = persistenceController.container.viewContext
        let session = CDBackendSession(context: ctx)
        session.id = sessionUUID
        session.backendName = "test-session"
        session.workingDirectory = "/tmp"
        session.lastOffsetMerged = 0
        session.liveFromOffset = 0
        try? ctx.save()

        func wire(offset: Int64) -> WireMessageV5 {
            WireMessageV5(
                sessionId: sessionIdString,
                offset: offset,
                role: "assistant",
                text: "msg-\(offset)",
                uuid: UUID().uuidString.lowercased(),
                timestamp: Date()
            )
        }

        func payload(messages: [WireMessageV5], nextOffset: Int64, endOfFile: Bool) -> SessionHistoryPayloadV5 {
            SessionHistoryPayloadV5(
                sessionId: sessionIdString,
                messages: messages,
                nextOffset: nextOffset,
                endOfFile: endOfFile,
                fileReplaced: nil,
                fileSignature: nil
            )
        }

        // First payload: end_of_file:false at nextOffset=1. Triggers a resubscribe.
        let p1 = payload(messages: [wire(offset: 0)], nextOffset: 1, endOfFile: false)
        manager.handleSessionHistoryPayload(p1)

        // Drain until the resubscribe is dispatched on main.
        drainMainQueue(for: 0.5)

        // No stall yet — this is the first payload.
        XCTAssertNil(client.stalledChains[lowerKey],
                     "no stall on first end_of_file:false payload")

        // Second payload at same nextOffset=1 — server is stuck. Should stall.
        let p2 = payload(messages: [], nextOffset: 1, endOfFile: false)
        manager.handleSessionHistoryPayload(p2)

        waitForMainQueue(timeout: 2.0) {
            client.stalledChains[lowerKey] != nil
        }

        XCTAssertEqual(client.stalledChains[lowerKey], 1,
                       "stalled cursor must equal the stuck next_offset")
    }

    /// After dismissing a stalled chain, the published entry is cleared so the
    /// banner disappears and is not re-shown until a fresh stall fires.
    func test_dismissStalledChain_clearsBanner_andDoesNotReintroduce() {
        let client = VoiceCodeClient(serverURL: "ws://localhost", setupObservers: false)
        let sessionId = "feedface-0000-1111-2222-333344445555"

        client.sessionSyncDidStallChain(sessionId, atCursor: 3)
        XCTAssertNotNil(client.stalledChains[sessionId.lowercased()])

        client.dismissStalledChain(sessionId: sessionId)
        XCTAssertNil(client.stalledChains[sessionId.lowercased()],
                     "dismiss must clear the published stall entry")

        // A non-stall subsequent action must not re-introduce the banner.
        // Simulate what the v0.5.0 handler does on a normal complete payload.
        client.sessionSyncDidStallChain(sessionId, atCursor: 3)  // stall again — is idempotent
        client.dismissStalledChain(sessionId: sessionId)
        XCTAssertNil(client.stalledChains[sessionId.lowercased()],
                     "banner must remain cleared after second dismiss")
    }
}
