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
}
