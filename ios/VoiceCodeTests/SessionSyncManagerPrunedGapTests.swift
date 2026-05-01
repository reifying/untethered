// SessionSyncManagerPrunedGapTests.swift
// Verifies SessionSyncDelegate.didDetectPrunedGap wiring (AC5 of the
// append-only message stream design).

import XCTest
import CoreData
import SwiftUI
@testable import VoiceCode

final class SessionSyncManagerPrunedGapTests: XCTestCase {

    // MARK: - Test doubles

    /// Records delegate invocations so tests can assert the exact payload
    /// that reached the UI layer. Using a class (AnyObject) is required by
    /// the `weak var delegate` contract.
    final class RecordingDelegate: SessionSyncDelegate {
        var received: [(sessionId: String, gap: SessionHistoryPayload.Gap)] = []
        var onInvocation: (() -> Void)?

        func didDetectPrunedGap(_ sessionId: String, gap: SessionHistoryPayload.Gap) {
            received.append((sessionId: sessionId, gap: gap))
            onInvocation?()
        }
    }

    // MARK: - Helpers

    private func makeManager() -> SessionSyncManager {
        SessionSyncManager(persistenceController: PersistenceController(inMemory: true))
    }

    private func prunedPayload(sessionId: String = "abcdef01-2222-3333-4444-555555555555",
                               requested: Int64 = 42,
                               minAvailable: Int64 = 200) -> SessionHistoryPayload {
        SessionHistoryPayload(
            sessionId: sessionId,
            messages: [],
            firstSeq: nil,
            lastSeq: nil,
            nextSeq: minAvailable + 1,
            isComplete: true,
            gap: SessionHistoryPayload.Gap(
                requestedLastSeq: requested,
                minAvailableSeq: minAvailable,
                reason: "pruned"
            )
        )
    }

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

    /// Drains the main run loop for a fixed interval without asserting.
    /// Use when you want to verify that *no* async delegate call ever fires.
    private func drainMainQueue(for interval: TimeInterval = 0.2) {
        let deadline = Date().addingTimeInterval(interval)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: - Delegate wiring

    func test_handleSessionHistoryPayload_prunedGap_firesDelegateWithSessionIdAndGap() {
        let manager = makeManager()
        let delegate = RecordingDelegate()
        manager.delegate = delegate

        let payload = prunedPayload(sessionId: "aaaabbbb-1111-2222-3333-444444444444",
                                    requested: 7,
                                    minAvailable: 100)

        let fired = expectation(description: "delegate fires")
        delegate.onInvocation = { fired.fulfill() }

        manager.handleSessionHistoryPayload(payload)

        wait(for: [fired], timeout: 1.0)
        XCTAssertEqual(delegate.received.count, 1)
        XCTAssertEqual(delegate.received.first?.sessionId, "aaaabbbb-1111-2222-3333-444444444444")
        XCTAssertEqual(delegate.received.first?.gap.requestedLastSeq, 7)
        XCTAssertEqual(delegate.received.first?.gap.minAvailableSeq, 100)
        XCTAssertEqual(delegate.received.first?.gap.reason, "pruned")
    }

    func test_handleSessionHistoryPayload_clientAheadGap_doesNotFirePrunedDelegate() {
        let manager = makeManager()
        let delegate = RecordingDelegate()
        manager.delegate = delegate

        let payload = SessionHistoryPayload(
            sessionId: "abcdef01-2222-3333-4444-555555555555",
            messages: [],
            firstSeq: nil,
            lastSeq: nil,
            nextSeq: 1,
            isComplete: true,
            gap: SessionHistoryPayload.Gap(
                requestedLastSeq: 612,
                minAvailableSeq: 1,
                reason: "client_ahead"
            )
        )

        manager.handleSessionHistoryPayload(payload)

        // Nothing scheduled to main; give the main queue a brief tick and
        // assert we never fired — `client_ahead` is explicitly not the
        // pruned-gap surface.
        drainMainQueue()
        XCTAssertTrue(delegate.received.isEmpty,
                      "client_ahead must not surface as a pruned-gap warning")
    }

    func test_handleSessionHistoryPayload_noGap_doesNotFireDelegate() {
        let manager = makeManager()
        let delegate = RecordingDelegate()
        manager.delegate = delegate

        let payload = SessionHistoryPayload(
            sessionId: "abcdef01-2222-3333-4444-555555555555",
            messages: [],
            firstSeq: nil,
            lastSeq: nil,
            nextSeq: 550,
            isComplete: true,
            gap: nil
        )

        manager.handleSessionHistoryPayload(payload)

        drainMainQueue()
        XCTAssertTrue(delegate.received.isEmpty)
    }

    func test_delegate_isWeakReference() {
        let manager = makeManager()
        var delegate: RecordingDelegate? = RecordingDelegate()
        manager.delegate = delegate

        XCTAssertNotNil(manager.delegate)
        delegate = nil
        XCTAssertNil(manager.delegate, "delegate must be weak so owners control lifetime")
    }

    // MARK: - UI surface (VoiceCodeClient)

    func test_voiceCodeClient_conformsToDelegate_andPublishesGap() {
        let client = VoiceCodeClient(serverURL: "ws://localhost", setupObservers: false)
        let sessionId = "AAAABBBB-1111-2222-3333-444444444444"
        let gap = SessionHistoryPayload.Gap(
            requestedLastSeq: 5,
            minAvailableSeq: 42,
            reason: "pruned"
        )

        // Call as the delegate method would be invoked (on main).
        client.didDetectPrunedGap(sessionId, gap: gap)

        // Stored lowercased so the view lookup is case-insensitive.
        XCTAssertEqual(client.prunedGaps[sessionId.lowercased()]?.minAvailableSeq, 42)
        XCTAssertEqual(client.prunedGaps[sessionId.lowercased()]?.requestedLastSeq, 5)
        XCTAssertEqual(client.prunedGaps[sessionId.lowercased()]?.reason, "pruned")
        XCTAssertNil(client.prunedGaps[sessionId], "uppercased lookup must not leak past normalization")
    }

    func test_voiceCodeClient_dismissPrunedGap_removesEntry() {
        let client = VoiceCodeClient(serverURL: "ws://localhost", setupObservers: false)
        let sessionId = "aabbccdd-1111-2222-3333-444444444444"
        let gap = SessionHistoryPayload.Gap(
            requestedLastSeq: 1,
            minAvailableSeq: 10,
            reason: "pruned"
        )

        client.didDetectPrunedGap(sessionId, gap: gap)
        XCTAssertNotNil(client.prunedGaps[sessionId])

        client.dismissPrunedGap(sessionId: sessionId)
        XCTAssertNil(client.prunedGaps[sessionId])
    }

    func test_voiceCodeClient_dismissPrunedGap_normalizesMixedCase() {
        // Exercises the case-normalization path on dismiss: the caller
        // (e.g. a view that grabs session.id.uuidString) may hand in either
        // casing, but storage is always lowercased per STANDARDS.md.
        let client = VoiceCodeClient(serverURL: "ws://localhost", setupObservers: false)
        let mixedCase = "AaBbCcDd-1111-2222-3333-444444444444"
        let lower = mixedCase.lowercased()
        let gap = SessionHistoryPayload.Gap(
            requestedLastSeq: 1,
            minAvailableSeq: 10,
            reason: "pruned"
        )

        client.didDetectPrunedGap(mixedCase, gap: gap)
        XCTAssertNotNil(client.prunedGaps[lower])

        // Dismiss with the original mixed-case input — must still clear the
        // lowercased entry.
        client.dismissPrunedGap(sessionId: mixedCase)
        XCTAssertNil(client.prunedGaps[lower])
    }

    // MARK: - Banner view

    func test_prunedGapBanner_invokesDismissCallback() {
        var dismissed = 0
        let gap = SessionHistoryPayload.Gap(
            requestedLastSeq: 1,
            minAvailableSeq: 42,
            reason: "pruned"
        )
        let banner = PrunedGapBanner(gap: gap) { dismissed += 1 }

        // The banner's body is pure SwiftUI; we can't introspect without a
        // host, but we can at least verify the view is constructible with
        // the data it renders, and that the closure is routed to the
        // dismiss-button action when invoked directly.
        banner.onDismiss()
        XCTAssertEqual(dismissed, 1)
        XCTAssertEqual(banner.gap.minAvailableSeq, 42)
    }

    func test_voiceCodeClient_receivesPrunedGap_whenManagerDispatches() {
        let client = VoiceCodeClient(serverURL: "ws://localhost", setupObservers: false)
        let sessionId = "11112222-3333-4444-5555-666666666666"
        let payload = prunedPayload(sessionId: sessionId,
                                    requested: 9,
                                    minAvailable: 50)

        client.sessionSyncManager.handleSessionHistoryPayload(payload)

        waitForMainQueue(timeout: 1.0) {
            client.prunedGaps[sessionId.lowercased()] != nil
        }
        XCTAssertEqual(client.prunedGaps[sessionId.lowercased()]?.minAvailableSeq, 50)
    }

    // MARK: - Full recovery flow (pruned gap → dismiss → refresh)

    /// End-to-end pruned-gap recovery (tmux-untethered-09a):
    ///
    /// 1. A pruned-gap `session_history` lands. The published `prunedGaps`
    ///    entry is set on the client AND no rows are merged into CoreData
    ///    (the manager returns before touching the upsert path).
    /// 2. The user dismisses the warning via `VoiceCodeClient.dismissPrunedGap`.
    ///    The flag is cleared.
    /// 3. A fresh non-gap `session_history` arrives (the post-refresh subscribe
    ///    reply). It must merge normally — the manager has no persistent
    ///    "blocked" state past the single pruned payload — and the gap flag
    ///    must stay clear.
    func test_prunedGap_thenDismiss_thenRefresh_clearsFlagAndMergesNewPayload() {
        let persistenceController = PersistenceController(inMemory: true)
        let manager = SessionSyncManager(persistenceController: persistenceController)
        let client = VoiceCodeClient(serverURL: "ws://localhost",
                                     sessionSyncManager: manager,
                                     setupObservers: false)

        let sessionId = "11112222-3333-4444-5555-666666666666"
        let sessionUUID = UUID(uuidString: sessionId)!
        let lowerKey = sessionId.lowercased()

        // 1. Inject pruned gap. Server has min_available_seq=200; client asked
        //    for last_seq=5 (way behind). Payload carries no messages per the
        //    design contract.
        let pruned = prunedPayload(sessionId: sessionId,
                                   requested: 5,
                                   minAvailable: 200)

        manager.handleSessionHistoryPayload(pruned)

        waitForMainQueue(timeout: 2.0) {
            client.prunedGaps[lowerKey] != nil
        }
        XCTAssertEqual(client.prunedGaps[lowerKey]?.requestedLastSeq, 5)
        XCTAssertEqual(client.prunedGaps[lowerKey]?.minAvailableSeq, 200)
        XCTAssertEqual(client.prunedGaps[lowerKey]?.reason, "pruned")

        // Drain to make sure no background merge sneaks in after the delegate
        // hop — pruned must short-circuit before the persistence task runs.
        drainMainQueue(for: 0.3)

        let viewContext = persistenceController.container.viewContext
        XCTAssertEqual(messagesForSession(sessionUUID, in: viewContext).count, 0,
                       "pruned-gap payload must NOT merge any messages")

        // 2. User dismisses the banner.
        client.dismissPrunedGap(sessionId: sessionId)
        XCTAssertNil(client.prunedGaps[lowerKey],
                     "dismiss must clear the published gap entry")

        // 3. Refresh: a fresh session_history arrives carrying messages from
        //    the new server-side range (seqs 200..201, contiguous from
        //    min_available_seq). It must merge normally.
        let refresh = SessionHistoryPayload(
            sessionId: sessionId,
            messages: [
                WireMessage(sessionId: sessionId,
                            seq: 200,
                            role: "assistant",
                            text: "after-refresh-200",
                            uuid: UUID().uuidString.lowercased(),
                            timestamp: Date(timeIntervalSince1970: 200)),
                WireMessage(sessionId: sessionId,
                            seq: 201,
                            role: "user",
                            text: "after-refresh-201",
                            uuid: UUID().uuidString.lowercased(),
                            timestamp: Date(timeIntervalSince1970: 201))
            ],
            firstSeq: 200,
            lastSeq: 201,
            nextSeq: 202,
            isComplete: true,
            gap: nil
        )

        let merged = expectation(forNotification: .sessionHistoryDidUpdate,
                                 object: nil,
                                 handler: { note in
            (note.userInfo?["sessionId"] as? String) == sessionId
        })

        manager.handleSessionHistoryPayload(refresh)
        wait(for: [merged], timeout: 2.0)
        drainMainQueue(for: 0.2)

        // Gap flag stays cleared — a clean payload must not re-introduce it.
        XCTAssertNil(client.prunedGaps[lowerKey],
                     "non-gap payload after dismiss must not re-set prunedGaps")

        // Messages now in the store with the right seq ordering.
        let rows = messagesForSession(sessionUUID, in: viewContext)
        XCTAssertEqual(rows.map(\.seq), [200, 201],
                       "post-dismiss refresh payload must merge normally")
        XCTAssertEqual(rows.first(where: { $0.seq == 200 })?.text, "after-refresh-200")
        XCTAssertEqual(rows.first(where: { $0.seq == 201 })?.text, "after-refresh-201")
    }

    private func messagesForSession(_ sessionId: UUID,
                                    in context: NSManagedObjectContext) -> [CDMessage] {
        context.refreshAllObjects()
        let request = CDMessage.fetchRequest()
        request.predicate = NSPredicate(format: "sessionId == %@", sessionId as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDMessage.seq, ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    // MARK: - Pruned-flag merge guard (tmux-untethered-8i4)

    /// The bug: a non-gap `session_history` push for the same session can
    /// arrive between `handleSessionHistoryPayload`'s pruned-gap branch and
    /// the async delegate hop. Without a synchronous flag, that push gets
    /// merged normally — mixing stale and post-gap messages with no visual
    /// break. The fix sets `prunedSessions` synchronously inside the pruned
    /// branch and refuses subsequent merges until explicitly cleared.
    func test_prunedGap_blocksSubsequentNonGapMerge_beforeDelegateFires() {
        let persistenceController = PersistenceController(inMemory: true)
        let manager = SessionSyncManager(persistenceController: persistenceController)
        // Intentionally no delegate set — we want to assert the synchronous
        // flag, not the delegate dispatch.

        let sessionId = "deadbeef-0000-1111-2222-333344445555"
        let sessionUUID = UUID(uuidString: sessionId)!

        // 1. Pruned gap arrives; flag must be set synchronously.
        manager.handleSessionHistoryPayload(prunedPayload(sessionId: sessionId,
                                                          requested: 5,
                                                          minAvailable: 200))
        XCTAssertTrue(manager.prunedSessions.contains(sessionId.lowercased()),
                      "pruned flag must be populated synchronously, before any async hop")

        // 2. Immediately on the same call site (no run-loop tick), a fresh
        //    non-gap payload arrives. This is the race the bug describes —
        //    in production the WebSocket pump dispatches both calls to main
        //    serially, so there is no opportunity for an async delegate to
        //    have run between them.
        let stalePush = SessionHistoryPayload(
            sessionId: sessionId,
            messages: [
                WireMessage(sessionId: sessionId,
                            seq: 6,
                            role: "assistant",
                            text: "stale-pre-gap-content",
                            uuid: UUID().uuidString.lowercased(),
                            timestamp: Date(timeIntervalSince1970: 6))
            ],
            firstSeq: 6,
            lastSeq: 6,
            nextSeq: 7,
            isComplete: true,
            gap: nil
        )
        manager.handleSessionHistoryPayload(stalePush)

        // Drain to make sure no background task ran the merge.
        drainMainQueue(for: 0.3)

        // Nothing must have been written.
        let rows = messagesForSession(sessionUUID, in: persistenceController.container.viewContext)
        XCTAssertTrue(rows.isEmpty,
                      "non-gap payload must NOT merge while pruned flag is set; got \(rows.count) row(s)")

        // Flag still set — only the user can clear it.
        XCTAssertTrue(manager.prunedSessions.contains(sessionId.lowercased()))
    }

    /// `clearPrunedFlag` is the manager-side reset that lets future payloads
    /// merge again. Once cleared, the same payload that was previously
    /// refused must merge normally.
    func test_clearPrunedFlag_allowsSubsequentMerge() {
        let persistenceController = PersistenceController(inMemory: true)
        let manager = SessionSyncManager(persistenceController: persistenceController)

        let sessionId = "feedface-0000-1111-2222-333344445555"
        let sessionUUID = UUID(uuidString: sessionId)!

        manager.handleSessionHistoryPayload(prunedPayload(sessionId: sessionId,
                                                          requested: 5,
                                                          minAvailable: 200))
        XCTAssertTrue(manager.prunedSessions.contains(sessionId.lowercased()))

        // Try a refresh while still flagged → blocked.
        let refresh = SessionHistoryPayload(
            sessionId: sessionId,
            messages: [
                WireMessage(sessionId: sessionId,
                            seq: 200,
                            role: "assistant",
                            text: "after-refresh-200",
                            uuid: UUID().uuidString.lowercased(),
                            timestamp: Date(timeIntervalSince1970: 200))
            ],
            firstSeq: 200,
            lastSeq: 200,
            nextSeq: 201,
            isComplete: true,
            gap: nil
        )
        manager.handleSessionHistoryPayload(refresh)
        drainMainQueue(for: 0.2)
        XCTAssertEqual(messagesForSession(sessionUUID,
                                          in: persistenceController.container.viewContext).count,
                       0,
                       "merge should still be blocked before clearPrunedFlag")

        // Clear the flag and re-deliver the same payload → merges.
        manager.clearPrunedFlag(sessionId: sessionId)
        XCTAssertFalse(manager.prunedSessions.contains(sessionId.lowercased()))

        let merged = expectation(forNotification: .sessionHistoryDidUpdate,
                                 object: nil,
                                 handler: { note in
            (note.userInfo?["sessionId"] as? String) == sessionId
        })
        manager.handleSessionHistoryPayload(refresh)
        wait(for: [merged], timeout: 2.0)
        drainMainQueue(for: 0.2)

        let rows = messagesForSession(sessionUUID,
                                      in: persistenceController.container.viewContext)
        XCTAssertEqual(rows.map(\.seq), [200],
                       "merge must succeed once the pruned flag is cleared")
    }

    /// `clearPrunedFlag` normalizes case the same way the publish path does.
    func test_clearPrunedFlag_normalizesMixedCase() {
        let manager = makeManager()
        let mixedCase = "AaBbCcDd-1111-2222-3333-444444444444"
        let lower = mixedCase.lowercased()

        manager.handleSessionHistoryPayload(prunedPayload(sessionId: mixedCase,
                                                          requested: 1,
                                                          minAvailable: 10))
        XCTAssertTrue(manager.prunedSessions.contains(lower))

        manager.clearPrunedFlag(sessionId: mixedCase)
        XCTAssertFalse(manager.prunedSessions.contains(lower))
    }

    /// `VoiceCodeClient.dismissPrunedGap` must clear both the published gap
    /// (UI banner) AND the sync-manager flag (merge guard). Otherwise the
    /// banner disappears while the manager keeps refusing merges.
    func test_voiceCodeClient_dismissPrunedGap_clearsManagerFlag() {
        let persistenceController = PersistenceController(inMemory: true)
        let manager = SessionSyncManager(persistenceController: persistenceController)
        let client = VoiceCodeClient(serverURL: "ws://localhost",
                                     sessionSyncManager: manager,
                                     setupObservers: false)
        let sessionId = "11112222-3333-4444-5555-666666666666"

        manager.handleSessionHistoryPayload(prunedPayload(sessionId: sessionId,
                                                          requested: 5,
                                                          minAvailable: 200))
        XCTAssertTrue(manager.prunedSessions.contains(sessionId.lowercased()))

        // Wait for the published banner state too, so the dismiss is realistic.
        waitForMainQueue(timeout: 2.0) {
            client.prunedGaps[sessionId.lowercased()] != nil
        }

        client.dismissPrunedGap(sessionId: sessionId)

        XCTAssertNil(client.prunedGaps[sessionId.lowercased()],
                     "dismiss must clear the published gap")
        XCTAssertFalse(manager.prunedSessions.contains(sessionId.lowercased()),
                       "dismiss must also clear the sync-manager merge guard")
    }

    // MARK: - ConversationView banner-dismissal lifecycle (tmux-untethered-9t9)

    /// Seeds 50 messages (seqs 1..50) for a session, lands a pruned gap (so the
    /// banner shows for the user), dismisses, then injects a new push at
    /// seq 205. Asserts the data the rendered list reads from:
    ///
    /// - The seq discontinuity (1..50 → 205) is preserved verbatim in CoreData.
    ///   The new message is NOT auto-filled with synthesized 51..204 rows;
    ///   ConversationView's `List(messages)` will render the gap as a visible
    ///   jump between 50 and 205.
    /// - Dismissing the banner clears `prunedGaps[sessionId]` and the manager
    ///   flag so the next push merges normally.
    /// - The post-dismiss push at seq 205 must NOT re-introduce a `prunedGaps`
    ///   entry — i.e. dismissing the banner does not silently re-show it for
    ///   any subsequent non-gap window.
    ///
    /// Note: the actual scroll position after `messages.count` change is owned
    /// by `ScrollViewProxy` inside ConversationView and can only be observed
    /// via XCUITest with a UI host, which is out of scope for this unit test.
    /// The data-level continuity asserted here is what the SwiftUI list
    /// renders, so a visible discontinuity at the gap is implied by the store
    /// state.
    func test_conversationView_prunedGapDismiss_preservesSeqDiscontinuityOnNewPush() throws {
        let persistenceController = PersistenceController(inMemory: true)
        let manager = SessionSyncManager(persistenceController: persistenceController)
        let client = VoiceCodeClient(serverURL: "ws://localhost",
                                     sessionSyncManager: manager,
                                     setupObservers: false)

        let sessionId = "9999aaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let sessionUUID = try XCTUnwrap(UUID(uuidString: sessionId))
        let lowerKey = sessionId.lowercased()
        let viewContext = persistenceController.container.viewContext

        // 1. Seed seqs 1..50 directly so the conversation has a substantial
        //    history before the gap arrives. Mirrors the production state
        //    where a user has been chatting and then the server prunes
        //    older history out from under them.
        for i: Int64 in 1...50 {
            let m = CDMessage(context: viewContext)
            m.id = UUID()
            m.sessionId = sessionUUID
            m.role = (i.isMultiple(of: 2)) ? "assistant" : "user"
            m.text = "seed-\(i)"
            m.timestamp = Date(timeIntervalSince1970: TimeInterval(i))
            m.messageStatus = .confirmed
            m.seq = i
        }
        try viewContext.save()
        XCTAssertEqual(messagesForSession(sessionUUID, in: viewContext).count, 50,
                       "seeding precondition: 50 rows in store")

        // 2. Pruned gap arrives. min_available_seq=200 means the server has
        //    forgotten everything up to and including seq 199; the user's
        //    requested cursor (last_seq=51) is far below the retained range.
        //    Banner state must publish for the UI; no rows must merge.
        let pruned = prunedPayload(sessionId: sessionId,
                                   requested: 51,
                                   minAvailable: 200)
        manager.handleSessionHistoryPayload(pruned)

        waitForMainQueue(timeout: 2.0) { client.prunedGaps[lowerKey] != nil }
        XCTAssertEqual(client.prunedGaps[lowerKey]?.minAvailableSeq, 200,
                       "banner data is the gap object the view binds to")
        XCTAssertEqual(client.prunedGaps[lowerKey]?.requestedLastSeq, 51)

        // Sanity: the pruned payload itself must not have written rows.
        drainMainQueue(for: 0.2)
        XCTAssertEqual(messagesForSession(sessionUUID, in: viewContext).count, 50,
                       "pruned payload must not merge anything; seeded rows untouched")

        // 3. User taps the banner's dismiss button. In production this maps
        //    to `client.dismissPrunedGap(sessionId:)` (see ConversationView
        //    PrunedGapBanner action wiring). After this call:
        //      - The banner is hidden (prunedGaps entry gone).
        //      - The manager merge-guard flag is cleared so subsequent
        //        non-gap pushes merge again.
        client.dismissPrunedGap(sessionId: sessionId)
        XCTAssertNil(client.prunedGaps[lowerKey],
                     "banner must be hidden post-dismiss (UI binding goes nil)")
        XCTAssertFalse(manager.prunedSessions.contains(lowerKey),
                       "merge guard must clear so the next push is not silently dropped")

        // 4. New push lands at seq 205 — a fresh assistant turn after the
        //    server's retained range. This is the moment ConversationView's
        //    `onChange(of: messages.count)` fires and triggers the auto-scroll
        //    to the new last message. We assert the underlying data so the
        //    list renders the gap visibly between seq 50 and seq 205.
        let postDismissPush = SessionHistoryPayload(
            sessionId: sessionId,
            messages: [
                WireMessage(sessionId: sessionId,
                            seq: 205,
                            role: "assistant",
                            text: "post-dismiss-205",
                            uuid: UUID().uuidString.lowercased(),
                            timestamp: Date(timeIntervalSince1970: 205))
            ],
            firstSeq: 205,
            lastSeq: 205,
            nextSeq: 206,
            isComplete: true,
            gap: nil
        )

        let merged = expectation(forNotification: .sessionHistoryDidUpdate,
                                 object: nil,
                                 handler: { note in
            (note.userInfo?["sessionId"] as? String) == sessionId
        })
        manager.handleSessionHistoryPayload(postDismissPush)
        wait(for: [merged], timeout: 2.0)
        drainMainQueue(for: 0.2)

        // 5a. Discontinuity preserved in the data. Seqs 51..204 are NOT
        //     auto-filled; the list reads exactly [1..50, 205].
        let rows = messagesForSession(sessionUUID, in: viewContext)
        let observedSeqs = rows.map(\.seq)
        let expectedSeqs: [Int64] = Array(Int64(1)...Int64(50)) + [205]
        XCTAssertEqual(observedSeqs, expectedSeqs,
                       "store must contain seqs [1..50, 205] only — no auto-fill of the pruned range")
        XCTAssertEqual(rows.last?.text, "post-dismiss-205",
                       "newest row is the post-dismiss push at seq 205")
        XCTAssertEqual(rows.last?.seq, 205,
                       "last-message seq is what ConversationView's auto-scroll targets via proxy.scrollTo")

        // 5b. Banner stays dismissed. A non-gap window must not silently
        //     re-show the warning to the user — once they've acknowledged the
        //     prune, the banner is gone until a fresh pruned payload arrives.
        XCTAssertNil(client.prunedGaps[lowerKey],
                     "post-dismiss non-gap push must not re-set prunedGaps; banner must stay hidden")
        XCTAssertFalse(manager.prunedSessions.contains(lowerKey),
                       "merge guard must remain cleared after the non-gap push")
    }
}
