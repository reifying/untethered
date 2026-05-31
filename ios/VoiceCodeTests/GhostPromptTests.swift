// GhostPromptTests.swift
// Tests for the iOS ghost-prompt feature (tmux-untethered-5hw.12):
//   - PromptMessageBuilder ghost branch (resume-only, additive `ghost` field)
//   - SessionSyncManager ghost reconciliation (annotate / fallback / fail)
//   - VoiceCodeClient.isGhostError classification + wire-summary tracing
// See docs/plans/2026-05-31-ghost-prompt-design.md §3.3 / §3.5 and
// docs/protocol/websocket-protocol.md (ghost_prompt event).

import XCTest
import CoreData
@testable import VoiceCode

final class GhostPromptTests: XCTestCase {
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!
    var syncManager: SessionSyncManager!

    override func setUp() {
        super.setUp()
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
        syncManager = SessionSyncManager(persistenceController: persistenceController)
    }

    override func tearDown() {
        context = nil
        syncManager = nil
        persistenceController = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeSession(messageCount: Int32 = 1) -> UUID {
        let id = UUID()
        let session = CDBackendSession(context: context)
        session.id = id
        session.backendName = "Ghost Test"
        session.workingDirectory = "/repo"
        session.lastModified = Date()
        session.messageCount = messageCount
        session.preview = ""
        session.provider = "claude"
        try? context.save()
        return id
    }

    /// Run `block`, then wait a beat for SessionSyncManager's background save to
    /// commit before refetching on the view context (mirrors PromptSendingTests).
    private func settle(after timeout: TimeInterval = 0.6) {
        let exp = XCTestExpectation(description: "background save settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { exp.fulfill() }
        wait(for: [exp], timeout: timeout + 1.0)
        context.refreshAllObjects()
    }

    private func userMessages(_ sessionId: UUID) -> [CDMessage] {
        (try? context.fetch(CDMessage.fetchMessages(sessionId: sessionId))) ?? []
    }

    // MARK: - PromptMessageBuilder

    func testBuildGhostResumeIncludesGhostFlag() {
        let msg = PromptMessageBuilder.build(
            text: "add a /healthz endpoint",
            sessionId: "sess-123",
            workingDirectory: "/repo",
            isNewSession: false,
            provider: "claude",
            systemPrompt: "",
            ghost: true
        )
        XCTAssertEqual(msg["type"] as? String, "prompt")
        XCTAssertEqual(msg["resume_session_id"] as? String, "sess-123")
        XCTAssertEqual(msg["ghost"] as? Bool, true)
        XCTAssertNil(msg["new_session_id"], "ghost must never attach new_session_id")
        XCTAssertEqual(msg["text"] as? String, "add a /healthz endpoint")
    }

    func testBuildNonGhostResumeOmitsGhostFlag() {
        let msg = PromptMessageBuilder.build(
            text: "hello",
            sessionId: "sess-123",
            workingDirectory: "/repo",
            isNewSession: false,
            provider: "claude",
            systemPrompt: "",
            ghost: false
        )
        XCTAssertEqual(msg["resume_session_id"] as? String, "sess-123")
        XCTAssertNil(msg["ghost"], "non-ghost sends must not carry the ghost flag")
    }

    func testBuildGhostIgnoredForNewSession() {
        // A stale ghost toggle must never ghost a brand-new session (resume-only).
        let msg = PromptMessageBuilder.build(
            text: "first prompt",
            sessionId: "sess-new",
            workingDirectory: "/repo",
            isNewSession: true,
            provider: "claude",
            systemPrompt: "",
            ghost: true
        )
        XCTAssertEqual(msg["new_session_id"] as? String, "sess-new")
        XCTAssertEqual(msg["provider"] as? String, "claude")
        XCTAssertNil(msg["ghost"], "ghost is meaningless for a new session and must be dropped")
        XCTAssertNil(msg["resume_session_id"])
    }

    func testBuildIncludesSystemPromptWhenNonEmpty() {
        let msg = PromptMessageBuilder.build(
            text: "go", sessionId: "s", workingDirectory: "/r",
            isNewSession: false, provider: "claude", systemPrompt: "be terse", ghost: true)
        XCTAssertEqual(msg["system_prompt"] as? String, "be terse")
    }

    // MARK: - ghostDisplayText

    func testGhostDisplayTextKeepsTaskAndPrompt() {
        let out = SessionSyncManager.ghostDisplayText(
            task: "add a /healthz endpoint",
            effectivePrompt: "Add a GET /healthz route returning 200.")
        XCTAssertTrue(out.contains("add a /healthz endpoint"), out)
        XCTAssertTrue(out.contains("Add a GET /healthz route returning 200."), out)
        XCTAssertTrue(out.hasPrefix("👻"), out)
    }

    func testGhostDisplayTextWithoutTask() {
        let out = SessionSyncManager.ghostDisplayText(task: nil, effectivePrompt: "Do the thing.")
        XCTAssertTrue(out.hasPrefix("👻"), out)
        XCTAssertTrue(out.contains("Do the thing."), out)
    }

    func testGhostDisplayTextIsIdempotent() {
        // A re-delivered ghost_prompt must not double-wrap an already-annotated bubble.
        let once = SessionSyncManager.ghostDisplayText(task: "X", effectivePrompt: "P")
        let twice = SessionSyncManager.ghostDisplayText(task: once, effectivePrompt: "P")
        XCTAssertEqual(once, twice)
    }

    // MARK: - reconcileGhostPrompt (primary)

    func testReconcileAnnotatesOptimisticBubble() {
        let sessionId = makeSession(messageCount: 0)

        let created = XCTestExpectation(description: "optimistic created")
        syncManager.createOptimisticMessage(sessionId: sessionId, text: "make a login screen") { _ in
            created.fulfill()
        }
        wait(for: [created], timeout: 2.0)

        syncManager.reconcileGhostPrompt(sessionId: sessionId,
                                         effectivePrompt: "Build a SwiftUI LoginView with email+password.")
        settle()

        let msgs = userMessages(sessionId).filter { $0.role == "user" }
        XCTAssertEqual(msgs.count, 1, "reconcile must annotate in place, not add a bubble")
        let msg = msgs[0]
        XCTAssertEqual(msg.messageStatus, .confirmed, "ghost bubble must be confirmed, not stuck sending")
        XCTAssertTrue(msg.text.contains("make a login screen"), msg.text)
        XCTAssertTrue(msg.text.contains("Build a SwiftUI LoginView with email+password."), msg.text)
    }

    // MARK: - reconcileGhostPrompt (fallback)

    func testReconcileFallbackCreatesBubbleWhenNoOptimistic() {
        let sessionId = makeSession(messageCount: 3)

        // No optimistic (sending) message exists — P must still surface.
        syncManager.reconcileGhostPrompt(sessionId: sessionId,
                                         effectivePrompt: "Refactor the auth module.")
        settle()

        let msgs = userMessages(sessionId).filter { $0.role == "user" }
        XCTAssertEqual(msgs.count, 1, "fallback must create exactly one bubble carrying P")
        XCTAssertEqual(msgs[0].messageStatus, .confirmed)
        XCTAssertTrue(msgs[0].text.contains("Refactor the auth module."), msgs[0].text)
    }

    func testReconcileUnknownSessionDropsSilently() {
        let unknown = UUID()
        syncManager.reconcileGhostPrompt(sessionId: unknown, effectivePrompt: "nope")
        settle()
        XCTAssertEqual(userMessages(unknown).count, 0)
    }

    // MARK: - failGhostPrompt

    func testFailGhostMarksOptimisticAsError() {
        let sessionId = makeSession(messageCount: 0)

        let created = XCTestExpectation(description: "optimistic created")
        syncManager.createOptimisticMessage(sessionId: sessionId, text: "do a risky thing") { _ in
            created.fulfill()
        }
        wait(for: [created], timeout: 2.0)

        syncManager.failGhostPrompt(sessionId: sessionId)
        settle()

        let msgs = userMessages(sessionId).filter { $0.role == "user" }
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].messageStatus, .error, "failed ghost send must flip the bubble to .error")
        XCTAssertEqual(msgs[0].text, "do a risky thing", "failure must not rewrite the task text")
    }

    // MARK: - Registered-bubble correlation (review issue 1)

    /// A ghost send registers its bubble; if the user then sends an ordinary
    /// message (a newer .sending row), the ghost_prompt must still annotate the
    /// *registered* ghost bubble — not merely the latest sending message.
    func testReconcileTargetsRegisteredBubbleNotLatestSending() {
        let sessionId = makeSession(messageCount: 0)

        var ghostId: UUID?
        let eGhost = XCTestExpectation(description: "ghost bubble")
        syncManager.createOptimisticMessage(sessionId: sessionId, text: "ghost task A") { id in
            ghostId = id
            self.syncManager.registerPendingGhost(sessionId: sessionId, messageId: id)
            eGhost.fulfill()
        }
        wait(for: [eGhost], timeout: 2.0)

        // Later ordinary send → a newer .sending bubble (not registered).
        let eOrdinary = XCTestExpectation(description: "ordinary bubble")
        syncManager.createOptimisticMessage(sessionId: sessionId, text: "ordinary message B") { _ in
            eOrdinary.fulfill()
        }
        wait(for: [eOrdinary], timeout: 2.0)

        syncManager.reconcileGhostPrompt(sessionId: sessionId, effectivePrompt: "EFFECTIVE-P")
        settle()

        let all = userMessages(sessionId)
        XCTAssertEqual(all.count, 2)
        let ghostBubble = all.first { $0.id == ghostId }
        let ordinaryBubble = all.first { $0.text.contains("ordinary message B") }
        XCTAssertNotNil(ghostBubble)
        XCTAssertNotNil(ordinaryBubble)
        XCTAssertTrue(ghostBubble?.text.contains("EFFECTIVE-P") ?? false, "registered ghost bubble must carry P")
        XCTAssertEqual(ghostBubble?.messageStatus, .confirmed)
        XCTAssertFalse(ordinaryBubble?.text.contains("EFFECTIVE-P") ?? true, "ordinary bubble must be untouched")
        XCTAssertEqual(ordinaryBubble?.messageStatus, .sending, "ordinary bubble stays sending")
    }

    /// When two ghosts are in flight on one session and their `ghost_prompt`
    /// events arrive in send order, the registry correlates each P to its own
    /// bubble (oldest-first). Out-of-order arrival for concurrent same-session
    /// ghosts is a documented best-effort limitation (the protocol carries no
    /// per-send correlation id — see `pendingGhostMessageIds`) and is not asserted.
    func testTwoConcurrentGhostsReconcileInArrivalOrder() {
        let sessionId = makeSession(messageCount: 0)

        var idA: UUID?
        let eA = XCTestExpectation(description: "A")
        syncManager.createOptimisticMessage(sessionId: sessionId, text: "task A") { id in
            idA = id
            self.syncManager.registerPendingGhost(sessionId: sessionId, messageId: id)
            eA.fulfill()
        }
        wait(for: [eA], timeout: 2.0)

        var idB: UUID?
        let eB = XCTestExpectation(description: "B")
        syncManager.createOptimisticMessage(sessionId: sessionId, text: "task B") { id in
            idB = id
            self.syncManager.registerPendingGhost(sessionId: sessionId, messageId: id)
            eB.fulfill()
        }
        wait(for: [eB], timeout: 2.0)

        // Events arrive in send order: P for A first, then P for B.
        syncManager.reconcileGhostPrompt(sessionId: sessionId, effectivePrompt: "PROMPT-FOR-A")
        settle()
        syncManager.reconcileGhostPrompt(sessionId: sessionId, effectivePrompt: "PROMPT-FOR-B")
        settle()

        let all = userMessages(sessionId)
        XCTAssertEqual(all.count, 2, "no extra bubbles created")
        let a = all.first { $0.id == idA }
        let b = all.first { $0.id == idB }
        XCTAssertTrue(a?.text.contains("PROMPT-FOR-A") ?? false, "A must get its own P")
        XCTAssertTrue(b?.text.contains("PROMPT-FOR-B") ?? false, "B must get its own P")
    }

    /// A re-delivered ghost_prompt (registry already drained) must not create a
    /// duplicate bubble — the effective prompt is already present (review issue 2).
    func testReconcileIsIdempotentOnRedelivery() {
        let sessionId = makeSession(messageCount: 0)

        let created = XCTestExpectation(description: "optimistic created")
        syncManager.createOptimisticMessage(sessionId: sessionId, text: "do the thing") { id in
            self.syncManager.registerPendingGhost(sessionId: sessionId, messageId: id)
            created.fulfill()
        }
        wait(for: [created], timeout: 2.0)

        syncManager.reconcileGhostPrompt(sessionId: sessionId, effectivePrompt: "UNIQUE-EFFECTIVE-PROMPT")
        settle()
        // Redelivery of the same event — registry is now drained.
        syncManager.reconcileGhostPrompt(sessionId: sessionId, effectivePrompt: "UNIQUE-EFFECTIVE-PROMPT")
        settle()

        let msgs = userMessages(sessionId).filter { $0.role == "user" }
        XCTAssertEqual(msgs.count, 1, "redelivered ghost_prompt must not create a duplicate bubble")
        XCTAssertTrue(msgs[0].text.contains("UNIQUE-EFFECTIVE-PROMPT"))
    }

    /// A ghost failure marks the *registered* bubble as .error even when a newer
    /// ordinary message is the latest .sending row.
    func testFailGhostTargetsRegisteredBubble() {
        let sessionId = makeSession(messageCount: 0)

        var ghostId: UUID?
        let eGhost = XCTestExpectation(description: "ghost bubble")
        syncManager.createOptimisticMessage(sessionId: sessionId, text: "risky ghost task") { id in
            ghostId = id
            self.syncManager.registerPendingGhost(sessionId: sessionId, messageId: id)
            eGhost.fulfill()
        }
        wait(for: [eGhost], timeout: 2.0)

        let eOrdinary = XCTestExpectation(description: "ordinary bubble")
        syncManager.createOptimisticMessage(sessionId: sessionId, text: "later ordinary") { _ in
            eOrdinary.fulfill()
        }
        wait(for: [eOrdinary], timeout: 2.0)

        syncManager.failGhostPrompt(sessionId: sessionId)
        settle()

        let all = userMessages(sessionId)
        let ghostBubble = all.first { $0.id == ghostId }
        let ordinaryBubble = all.first { $0.text.contains("later ordinary") }
        XCTAssertEqual(ghostBubble?.messageStatus, .error, "registered ghost bubble must be marked .error")
        XCTAssertEqual(ordinaryBubble?.messageStatus, .sending, "ordinary bubble must be untouched")
    }

    // MARK: - isGhostError classification

    func testIsGhostErrorMatchesGhostMessages() {
        XCTAssertTrue(VoiceCodeClient.isGhostError("Ghost prompt generation failed: timeout"))
        XCTAssertTrue(VoiceCodeClient.isGhostError("ghost prompts require resume_session_id"))
        XCTAssertTrue(VoiceCodeClient.isGhostError("ghost prompts are only supported for the claude provider"))
        XCTAssertTrue(VoiceCodeClient.isGhostError("Unknown session for ghost prompt"))
    }

    func testIsGhostErrorRejectsOrdinaryErrors() {
        XCTAssertFalse(VoiceCodeClient.isGhostError("Compaction in progress for this session"))
        XCTAssertFalse(VoiceCodeClient.isGhostError("Failed to dispatch prompt: boom"))
    }

    // MARK: - Wire summary tracing

    func testPromptOutgoingTracesGhost() {
        let s = VoiceCodeClient.summarizeOutgoing([
            "type": "prompt",
            "resume_session_id": "deadbeef1234",
            "ghost": true,
            "text": "ship it"
        ])
        XCTAssertTrue(s.contains("ghost=true"), s)
        XCTAssertTrue(s.contains("resume=deadbeef"), s)
    }

    func testGhostPromptIncomingTraced() {
        let s = VoiceCodeClient.summarizeIncoming(type: "ghost_prompt", json: [
            "type": "ghost_prompt",
            "session_id": "abcdef0123456789",
            "text": "the effective prompt"
        ])
        XCTAssertTrue(s.hasPrefix("ghost_prompt "), s)
        XCTAssertTrue(s.contains("sess=abcdef01"), s)
        XCTAssertTrue(s.contains("len=20"), s)
    }
}
