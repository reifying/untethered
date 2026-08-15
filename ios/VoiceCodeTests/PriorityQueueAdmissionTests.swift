// PriorityQueueAdmissionTests.swift
// The admission policy and the pending-reply ledger that backs it.
// See docs/design/priority-queue-revisit.md.

import XCTest
import CoreData
@testable import VoiceCode

final class PriorityQueueAdmissionTests: XCTestCase {

    // MARK: - promptTarget

    func test_promptTarget_resumeSend() {
        let message: [String: Any] = [
            "type": "prompt",
            "text": "hi",
            "resume_session_id": "AAAA1111-2222-3333-4444-555555555555",
            "working_directory": "/tmp"
        ]
        XCTAssertEqual(PriorityQueueAdmission.promptTarget(ofOutgoing: message),
                       "aaaa1111-2222-3333-4444-555555555555",
                       "Resume sends target the resumed session, lowercased")
    }

    func test_promptTarget_newSessionSend() {
        let message: [String: Any] = [
            "type": "prompt",
            "text": "hi",
            "new_session_id": "bbbb1111-2222-3333-4444-555555555555",
            "provider": "claude",
            "working_directory": "/tmp"
        ]
        XCTAssertEqual(PriorityQueueAdmission.promptTarget(ofOutgoing: message),
                       "bbbb1111-2222-3333-4444-555555555555")
    }

    func test_promptTarget_ghostSendCounts() {
        // A ghost send still hands the turn to the agent — the user asked for it,
        // so the reply is still addressed to them.
        let message: [String: Any] = [
            "type": "prompt",
            "text": "do the thing",
            "resume_session_id": "cccc1111-2222-3333-4444-555555555555",
            "ghost": true,
            "working_directory": "/tmp"
        ]
        XCTAssertEqual(PriorityQueueAdmission.promptTarget(ofOutgoing: message),
                       "cccc1111-2222-3333-4444-555555555555")
    }

    func test_promptTarget_startRecipe() {
        let message: [String: Any] = [
            "type": "start_recipe",
            "session_id": "dddd1111-2222-3333-4444-555555555555",
            "recipe_id": "design-break-impl",
            "working_directory": "/tmp",
            "provider": "claude"
        ]
        XCTAssertEqual(PriorityQueueAdmission.promptTarget(ofOutgoing: message),
                       "dddd1111-2222-3333-4444-555555555555",
                       "Launching a recipe from the app is the user asking for it")
    }

    func test_promptTarget_nonPromptTraffic() {
        // Subscribing is exactly what watching a tmux agent does. It must not
        // arm anything — that equivalence is the bug this change removes.
        let subscribe: [String: Any] = [
            "type": "subscribe",
            "session_id": "eeee1111-2222-3333-4444-555555555555",
            "from_offset": 0
        ]
        XCTAssertNil(PriorityQueueAdmission.promptTarget(ofOutgoing: subscribe))

        XCTAssertNil(PriorityQueueAdmission.promptTarget(ofOutgoing: ["type": "ping"]))
        XCTAssertNil(PriorityQueueAdmission.promptTarget(ofOutgoing: [
            "type": "unsubscribe",
            "session_id": "eeee1111-2222-3333-4444-555555555555"
        ]))
        XCTAssertNil(PriorityQueueAdmission.promptTarget(ofOutgoing: ["no_type": "at_all"]))
    }

    func test_promptTarget_emptySessionIdIsNil() {
        let message: [String: Any] = ["type": "prompt", "text": "hi", "resume_session_id": ""]
        XCTAssertNil(PriorityQueueAdmission.promptTarget(ofOutgoing: message))
    }

    // MARK: - shouldEnqueue

    func test_shouldEnqueue_replyToOurPrompt() {
        XCTAssertTrue(PriorityQueueAdmission.shouldEnqueue(
            featureEnabled: true,
            hasLiveAssistantMessages: true,
            claimAwaitedReply: { true }))
    }

    func test_shouldEnqueue_unsolicitedAgentOutputDoesNotEnqueue() {
        // The tmux-supervision case: an agent the user is merely watching talks.
        XCTAssertFalse(PriorityQueueAdmission.shouldEnqueue(
            featureEnabled: true,
            hasLiveAssistantMessages: true,
            claimAwaitedReply: { false }))
    }

    func test_shouldEnqueue_featureDisabledDoesNotConsumeClaim() {
        var claimed = false
        let result = PriorityQueueAdmission.shouldEnqueue(
            featureEnabled: false,
            hasLiveAssistantMessages: true,
            claimAwaitedReply: { claimed = true; return true })

        XCTAssertFalse(result)
        XCTAssertFalse(claimed,
                       "Claiming is destructive — it must not fire when the feature is off, or turning the queue back on would find the claim already burned")
    }

    func test_shouldEnqueue_noLiveAssistantMessagesDoesNotConsumeClaim() {
        var claimed = false
        let result = PriorityQueueAdmission.shouldEnqueue(
            featureEnabled: true,
            hasLiveAssistantMessages: false,
            claimAwaitedReply: { claimed = true; return true })

        XCTAssertFalse(result)
        XCTAssertFalse(claimed,
                       "A payload with no new live assistant rows must leave the outstanding prompt armed for the real reply")
    }

    // MARK: - Priority-preserving dequeue

    func test_autoDequeuePreservesPriority_manualRemoveResetsIt() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "prio"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.provider = "claude"
        try context.save()

        CDBackendSession.addToPriorityQueue(session, context: context)
        CDBackendSession.changePriority(session, newPriority: 1, context: context)
        XCTAssertEqual(session.priority, 1)

        // Auto-dequeue on outbound prompt: the session is coming right back.
        CDBackendSession.removeFromPriorityQueue(session, context: context, resetPriority: false)
        XCTAssertFalse(session.isInPriorityQueue)
        XCTAssertEqual(session.priority, 1,
                       "A P1 session must not silently become P10 on every round trip")

        // It returns at the priority the user chose.
        CDBackendSession.addToPriorityQueue(session, context: context)
        XCTAssertTrue(session.isInPriorityQueue)
        XCTAssertEqual(session.priority, 1)

        // Manual removal is a deliberate "I'm done with this" and still resets.
        CDBackendSession.removeFromPriorityQueue(session, context: context)
        XCTAssertFalse(session.isInPriorityQueue)
        XCTAssertEqual(session.priority, 10)
    }
}

// MARK: - Ledger

final class PendingReplyLedgerTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "PendingReplyLedgerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    private func makeLedger(ttl: TimeInterval = PendingReplyLedger.defaultTTL) -> PendingReplyLedger {
        PendingReplyLedger(defaults: defaults, storageKey: "pendingReplySessions", ttl: ttl)
    }

    func test_armThenClaim() {
        let ledger = makeLedger()
        XCTAssertFalse(ledger.claim(sessionId: "s1"), "Nothing armed → no claim")

        ledger.arm(sessionId: "s1")
        XCTAssertTrue(ledger.isArmed(sessionId: "s1"))
        XCTAssertTrue(ledger.claim(sessionId: "s1"))
    }

    func test_claimIsOneShot() {
        let ledger = makeLedger()
        ledger.arm(sessionId: "s1")

        XCTAssertTrue(ledger.claim(sessionId: "s1"))
        XCTAssertFalse(ledger.claim(sessionId: "s1"),
                       "Later messages in the same turn must not re-enqueue")
        XCTAssertFalse(ledger.isArmed(sessionId: "s1"))
    }

    func test_claimIsPerSession() {
        let ledger = makeLedger()
        ledger.arm(sessionId: "mine")

        XCTAssertFalse(ledger.claim(sessionId: "someone-elses"),
                       "An agent the user never prompted must not consume another session's claim")
        XCTAssertTrue(ledger.claim(sessionId: "mine"))
    }

    func test_caseInsensitiveKeys() {
        let ledger = makeLedger()
        ledger.arm(sessionId: "AAAA1111-2222-3333-4444-555555555555")
        XCTAssertTrue(ledger.claim(sessionId: "aaaa1111-2222-3333-4444-555555555555"),
                      "Wire ids arrive lowercased; the send path may not be")
    }

    func test_disarm() {
        let ledger = makeLedger()
        ledger.arm(sessionId: "s1")
        ledger.disarm(sessionId: "s1")
        XCTAssertFalse(ledger.claim(sessionId: "s1"))
    }

    func test_survivesProcessRestart() {
        // A phone-locked send whose agent works for 20 minutes must still be
        // recognized after the app is killed and relaunched.
        makeLedger().arm(sessionId: "s1")

        let afterRelaunch = makeLedger()
        XCTAssertTrue(afterRelaunch.claim(sessionId: "s1"))
    }

    func test_expiredClaimDoesNotFire() {
        let ledger = makeLedger(ttl: 60)
        let sendTime = Date(timeIntervalSince1970: 1_000_000)
        ledger.arm(sessionId: "s1", at: sendTime)

        XCTAssertFalse(ledger.claim(sessionId: "s1", at: sendTime.addingTimeInterval(61)),
                       "An agent that died without replying must not enqueue on some unrelated later reply")
        XCTAssertTrue(ledger.armedSessionIds(at: sendTime.addingTimeInterval(61)).isEmpty)
    }

    func test_claimWithinTTLFires() {
        let ledger = makeLedger(ttl: 60)
        let sendTime = Date(timeIntervalSince1970: 1_000_000)
        ledger.arm(sessionId: "s1", at: sendTime)

        XCTAssertTrue(ledger.claim(sessionId: "s1", at: sendTime.addingTimeInterval(59)))
    }

    func test_rearmRefreshesRatherThanStacks() {
        let ledger = makeLedger(ttl: 60)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        ledger.arm(sessionId: "s1", at: t0)
        ledger.arm(sessionId: "s1", at: t0.addingTimeInterval(50))

        XCTAssertTrue(ledger.claim(sessionId: "s1", at: t0.addingTimeInterval(100)),
                      "The second send refreshes the deadline")
        XCTAssertFalse(ledger.claim(sessionId: "s1", at: t0.addingTimeInterval(101)),
                       "Two sends still yield one claim — the queue is a set, not a counter")
    }
}
