// PriorityQueueAdmissionSyncTests.swift
// End-to-end coverage of priority-queue admission through the real v0.5.0
// `session_history` delivery path in SessionSyncManager — the path that put
// every watched tmux agent in the queue.
//
// See docs/design/priority-queue-revisit.md.

import XCTest
import CoreData
@testable import VoiceCode

final class PriorityQueueAdmissionSyncTests: XCTestCase {

    private var persistenceController: PersistenceController!
    private var context: NSManagedObjectContext!
    private var manager: SessionSyncManager!
    private var ledger: PendingReplyLedger!
    private var ledgerDefaults: UserDefaults!
    private var ledgerSuiteName: String!

    private let sessionIdString = "77778888-9999-aaaa-bbbb-cccccccccccc"
    private var sessionUUID: UUID { UUID(uuidString: sessionIdString)! }

    override func setUpWithError() throws {
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext

        ledgerSuiteName = "PriorityQueueAdmissionSyncTests.\(UUID().uuidString)"
        ledgerDefaults = UserDefaults(suiteName: ledgerSuiteName)
        ledger = PendingReplyLedger(defaults: ledgerDefaults,
                                    storageKey: "pendingReplySessions",
                                    ttl: PendingReplyLedger.defaultTTL)

        manager = SessionSyncManager(persistenceController: persistenceController,
                                     pendingReplies: ledger)

        // Production reads the feature flag from standard defaults.
        UserDefaults.standard.set(true, forKey: "priorityQueueEnabled")
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: "priorityQueueEnabled")
        ledgerDefaults.removePersistentDomain(forName: ledgerSuiteName)
        ledgerDefaults = nil
        ledgerSuiteName = nil
        ledger = nil
        manager = nil
        context = nil
        persistenceController = nil
    }

    // MARK: - Helpers

    /// Seeds a session with the TTS/live boundary already captured, so messages
    /// at or above `liveFromOffset` are treated as live arrivals rather than
    /// history replay.
    @discardableResult
    private func seedSession(liveFromOffset: Int64 = 1) -> CDBackendSession {
        let session = CDBackendSession(context: context)
        session.id = sessionUUID
        session.backendName = "admission-test"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.provider = "claude"
        session.lastOffsetMerged = liveFromOffset - 1
        session.liveFromOffset = liveFromOffset
        try! context.save()
        return session
    }

    private func assistantPayload(offset: Int64, text: String = "done") -> SessionHistoryPayloadV5 {
        SessionHistoryPayloadV5(
            sessionId: sessionIdString,
            messages: [WireMessageV5(sessionId: sessionIdString,
                                     offset: offset,
                                     role: "assistant",
                                     text: text,
                                     uuid: UUID().uuidString.lowercased(),
                                     timestamp: Date())],
            nextOffset: offset + 1,
            endOfFile: true,
            fileReplaced: nil,
            fileSignature: nil
        )
    }

    /// Deliver a payload and wait for the manager's background upsert + save to
    /// land. The manager posts `sessionHistoryDidUpdate` after the save commits
    /// whenever it inserted rows.
    private func deliverAndWait(_ payload: SessionHistoryPayloadV5,
                                file: StaticString = #filePath,
                                line: UInt = #line) {
        let exp = expectation(forNotification: .sessionHistoryDidUpdate,
                              object: nil,
                              handler: { note in
            (note.userInfo?["sessionId"] as? String) == self.sessionIdString
        })
        manager.handleSessionHistoryPayload(payload)
        wait(for: [exp], timeout: 5.0)
        drainMainQueue()
    }

    private func drainMainQueue(for interval: TimeInterval = 0.3) {
        let deadline = Date().addingTimeInterval(interval)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func fetchSession() -> CDBackendSession? {
        context.refreshAllObjects()
        return try? context.fetch(CDBackendSession.fetchBackendSession(id: sessionUUID)).first
    }

    // MARK: - Tests

    /// The reported bug: an agent the user is watching but never prompted talks,
    /// and lands in the queue. It must not.
    func test_unsolicitedAgentReplyDoesNotEnqueue() {
        seedSession()

        deliverAndWait(assistantPayload(offset: 1, text: "still working on the refactor"))

        XCTAssertFalse(fetchSession()?.isInPriorityQueue ?? true,
                       "A session the user never prompted from this device must not enter the queue, however many turns the agent takes")
    }

    /// A tmux agent under supervision emits many turns per task. None of them
    /// should enqueue, and repetition must not eventually let one through.
    func test_repeatedUnsolicitedRepliesNeverEnqueue() {
        seedSession()

        for offset in Int64(1)...Int64(5) {
            deliverAndWait(assistantPayload(offset: offset, text: "turn \(offset)"))
        }

        XCTAssertFalse(fetchSession()?.isInPriorityQueue ?? true)
    }

    /// The case the queue exists for: the user asked, the agent answered.
    func test_replyToOurOwnPromptEnqueues() {
        seedSession()

        manager.recordOutboundPrompt(sessionId: sessionIdString)
        drainMainQueue()

        deliverAndWait(assistantPayload(offset: 1, text: "here's the answer"))

        let session = fetchSession()
        XCTAssertTrue(session?.isInPriorityQueue ?? false,
                      "A reply to a prompt sent from this device is the user's turn")
        XCTAssertNotNil(session?.priorityQueuedAt)
    }

    /// After the reply is claimed the agent keeps working under tmux. Those
    /// later turns are not the user's turn and must not re-enqueue.
    func test_claimIsConsumedSoLaterTurnsDoNotReenqueue() {
        seedSession()

        manager.recordOutboundPrompt(sessionId: sessionIdString)
        drainMainQueue()
        deliverAndWait(assistantPayload(offset: 1))

        XCTAssertTrue(fetchSession()?.isInPriorityQueue ?? false)

        // User deals with it.
        let session = fetchSession()!
        CDBackendSession.removeFromPriorityQueue(session, context: context)
        XCTAssertFalse(fetchSession()?.isInPriorityQueue ?? true)

        // Agent, still running in tmux, keeps talking.
        deliverAndWait(assistantPayload(offset: 2, text: "and another thing"))

        XCTAssertFalse(fetchSession()?.isInPriorityQueue ?? true,
                       "The claim was one-shot; subsequent agent output is not the user's turn")
    }

    /// Sending the next prompt hands the ball back to the agent, so the session
    /// leaves the queue — keeping the priority the user assigned it.
    func test_outboundPromptDequeuesPreservingPriority() {
        let session = seedSession()
        CDBackendSession.addToPriorityQueue(session, context: context)
        CDBackendSession.changePriority(session, newPriority: 1, context: context)
        XCTAssertTrue(session.isInPriorityQueue)

        manager.recordOutboundPrompt(sessionId: sessionIdString)
        drainMainQueue()

        let afterSend = fetchSession()
        XCTAssertFalse(afterSend?.isInPriorityQueue ?? true,
                       "Once the user replies, the ball is back with the agent")
        XCTAssertEqual(afterSend?.priority, 1,
                       "The user's chosen priority must survive the round trip")

        // …and it comes back, at that priority, when the agent answers.
        deliverAndWait(assistantPayload(offset: 1))

        let afterReply = fetchSession()
        XCTAssertTrue(afterReply?.isInPriorityQueue ?? false)
        XCTAssertEqual(afterReply?.priority, 1)
    }

    /// With the feature off nothing enqueues — and the outstanding claim is not
    /// burned, so turning it back on doesn't silently swallow the pending reply.
    func test_featureDisabledDoesNotEnqueueAndPreservesClaim() {
        UserDefaults.standard.set(false, forKey: "priorityQueueEnabled")
        seedSession()

        manager.recordOutboundPrompt(sessionId: sessionIdString)
        drainMainQueue()
        deliverAndWait(assistantPayload(offset: 1))

        XCTAssertFalse(fetchSession()?.isInPriorityQueue ?? true)
        XCTAssertTrue(ledger.isArmed(sessionId: sessionIdString),
                      "The claim must survive a disabled feature flag")

        UserDefaults.standard.set(true, forKey: "priorityQueueEnabled")
        deliverAndWait(assistantPayload(offset: 2))

        XCTAssertTrue(fetchSession()?.isInPriorityQueue ?? false)
    }

    /// A prompt the user types straight into an agent's tmux pane arrives as a
    /// `user_prompt` frame and must enroll the session exactly like an in-app
    /// send. This is the path that makes "I go prompt it myself, anywhere"
    /// work for agents launched and driven outside the app.
    func test_userPromptFrameEnrollsSessionTypedInPane() {
        seedSession()

        let client = VoiceCodeClient(serverURL: "ws://localhost:8080",
                                     sessionSyncManager: manager,
                                     setupObservers: false)
        client.handleMessage("{\"type\":\"user_prompt\",\"session_id\":\"\(sessionIdString)\"}")
        drainMainQueue()

        XCTAssertTrue(ledger.isArmed(sessionId: sessionIdString),
                      "A pane-typed prompt arms the session just like an in-app send")

        deliverAndWait(assistantPayload(offset: 1, text: "done, here's what I found"))

        XCTAssertTrue(fetchSession()?.isInPriorityQueue ?? false,
                      "The reply to a prompt the user typed in the pane is the user's turn")
    }

    /// The contrast that motivates the whole mechanism: a supervisor- or
    /// recipe-driven turn produces no `user_prompt` frame (the backend
    /// attributes its own injections), so the session stays out.
    func test_noUserPromptFrameMeansNoEnrollment() {
        seedSession()

        deliverAndWait(assistantPayload(offset: 1, text: "supervisor told me to do this"))

        XCTAssertFalse(fetchSession()?.isInPriorityQueue ?? true,
                       "Without a user_prompt frame there is nothing to claim, so the agent stays out of the queue")
    }

    // MARK: - agent_replied (the unsubscribed path)

    /// The workflow from the 2026-08-15 device logs, which the message-arrival
    /// path could not serve: send a prompt, immediately leave the conversation
    /// (which unsubscribes), agent answers while we are not subscribed. No
    /// session_history push ever arrives, so only `agent_replied` can enqueue.
    func test_agentRepliedEnqueuesWithoutAnySessionHistory() {
        seedSession()

        manager.recordOutboundPrompt(sessionId: sessionIdString)
        drainMainQueue()

        // Note: no deliverAndWait — nothing is pushed to an unsubscribed client.
        manager.recordAgentReply(sessionId: sessionIdString)
        drainMainQueue()

        XCTAssertTrue(fetchSession()?.isInPriorityQueue ?? false,
                      "The reply must enqueue even though no session_history push arrived")
    }

    /// Reaching the client is not enough on its own — an agent nobody prompted
    /// finishing a turn must still stay out. `agent_replied` is broadcast for
    /// every session, so the ledger is the only thing keeping supervised agents
    /// out of the queue on this path.
    func test_agentRepliedOnUnpromptedSessionDoesNotEnqueue() {
        seedSession()

        manager.recordAgentReply(sessionId: sessionIdString)
        drainMainQueue()

        XCTAssertFalse(fetchSession()?.isInPriorityQueue ?? true,
                       "A supervised agent finishing a turn is not the user's turn")
    }

    /// Both enqueue paths share one claim, so a live push and the broadcast
    /// racing on the same reply must not produce two entries or leave the
    /// session enqueued after the user deals with it.
    func test_bothPathsShareOneClaim() {
        seedSession()

        manager.recordOutboundPrompt(sessionId: sessionIdString)
        drainMainQueue()

        deliverAndWait(assistantPayload(offset: 1))
        XCTAssertTrue(fetchSession()?.isInPriorityQueue ?? false)

        // The broadcast for the same turn arrives after the push already won.
        manager.recordAgentReply(sessionId: sessionIdString)
        drainMainQueue()

        XCTAssertFalse(ledger.isArmed(sessionId: sessionIdString),
                       "One claim, consumed once")

        // User deals with it; the late broadcast must not resurrect it.
        CDBackendSession.removeFromPriorityQueue(fetchSession()!, context: context)
        manager.recordAgentReply(sessionId: sessionIdString)
        drainMainQueue()

        XCTAssertFalse(fetchSession()?.isInPriorityQueue ?? true,
                       "A second agent_replied with no outstanding claim must not re-enqueue")
    }

    func test_agentRepliedRespectsFeatureFlag() {
        UserDefaults.standard.set(false, forKey: "priorityQueueEnabled")
        seedSession()

        manager.recordOutboundPrompt(sessionId: sessionIdString)
        drainMainQueue()
        manager.recordAgentReply(sessionId: sessionIdString)
        drainMainQueue()

        XCTAssertFalse(fetchSession()?.isInPriorityQueue ?? true)
        XCTAssertTrue(ledger.isArmed(sessionId: sessionIdString),
                      "A disabled feature must not burn the claim")
    }

    /// End-to-end through the wire frame, not just the manager method.
    func test_agentRepliedFrameEnqueues() {
        seedSession()

        let client = VoiceCodeClient(serverURL: "ws://localhost:8080",
                                     sessionSyncManager: manager,
                                     setupObservers: false)
        client.handleMessage("{\"type\":\"user_prompt\",\"session_id\":\"\(sessionIdString)\"}")
        drainMainQueue()
        client.handleMessage("{\"type\":\"agent_replied\",\"session_id\":\"\(sessionIdString)\"}")
        drainMainQueue()

        XCTAssertTrue(fetchSession()?.isInPriorityQueue ?? false,
                      "Pane-typed prompt then agent_replied enqueues with no subscription at all")
    }

    /// `recordOutboundPrompt` runs for every prompt, including for sessions the
    /// local store has never seen (a brand-new session's row is created by the
    /// first payload). It must arm without needing the row to exist.
    func test_outboundPromptOnUnknownSessionStillArms() {
        manager.recordOutboundPrompt(sessionId: sessionIdString)
        drainMainQueue()

        XCTAssertTrue(ledger.isArmed(sessionId: sessionIdString))

        seedSession()
        deliverAndWait(assistantPayload(offset: 1))

        XCTAssertTrue(fetchSession()?.isInPriorityQueue ?? false)
    }
}
