// ConversationRefreshTests.swift
//
// Regression coverage for tmux-untethered-bae.3. Verifies that:
//   - CDMessage.pruneOldMessages does not fire when count == maxMessagesPerSession (Fix 2, AC4)
//   - handleSessionHistoryPayload (v0.5.0 path) still prunes when count exceeds 60 (Fix 2, AC4)
//
// ScenePhaseSubscriptionGuardTests (Fix 1, AC1/AC6/AC7) live in
// ScenePhaseSubscriptionGuardTests.swift, created as part of tmux-untethered-bae.1.

import XCTest
import CoreData
@testable import VoiceCode

final class PruneOnOpenRegressionTests: XCTestCase {

    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!
    var manager: SessionSyncManager!

    override func setUpWithError() throws {
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
        manager = SessionSyncManager(persistenceController: persistenceController)
    }

    override func tearDownWithError() throws {
        manager = nil
        context = nil
        persistenceController = nil
    }

    // MARK: - Fix 2: prune threshold boundary

    func testPruneOldMessagesOnlyFiresAboveThreshold() {
        // 50 messages — pruneOldMessages must not delete any (50 > 50 is false).
        let sessionId = UUID()
        let bgCtx = persistenceController.container.newBackgroundContext()
        bgCtx.performAndWait {
            for i in 0..<50 {
                let msg = CDMessage(context: bgCtx)
                msg.id = UUID()
                msg.sessionId = sessionId
                msg.timestamp = Date(timeIntervalSince1970: Double(i))
                msg.offset = Int64(i)
                msg.text = "message \(i)"
                msg.role = "assistant"
            }
            try! bgCtx.save()

            let deleted = CDMessage.pruneOldMessages(sessionId: sessionId, in: bgCtx)
            XCTAssertEqual(deleted, 0,
                "pruneOldMessages must not fire when count == keepCount (50)")

            let count = try! bgCtx.count(for: CDMessage.fetchMessages(sessionId: sessionId))
            XCTAssertEqual(count, 50)
        }
    }

    // MARK: - Fix 2: handleSessionHistoryPayload still prunes

    func testHandleSessionHistoryStillPrunesAfterNewData() {
        // Arrange: 55 existing messages; payload adds 10 more → 65 total → prune to 50.
        let sessionId = UUID()
        let sessionIdString = sessionId.uuidString.lowercased()

        let backendSession = CDBackendSession(context: context)
        backendSession.id = sessionId
        backendSession.backendName = "test"
        backendSession.workingDirectory = "/tmp"
        backendSession.lastModified = Date()
        backendSession.messageCount = 55
        backendSession.preview = ""
        backendSession.provider = "claude"
        backendSession.lastOffsetMerged = 0
        backendSession.liveFromOffset = 0

        for i in 0..<55 {
            let msg = CDMessage(context: context)
            msg.id = UUID()
            msg.sessionId = sessionId
            msg.timestamp = Date(timeIntervalSince1970: Double(i))
            msg.offset = Int64(i)
            msg.text = "existing \(i)"
            msg.role = "user"
        }
        try! context.save()

        // Act: deliver a payload carrying 10 new messages (offsets 55–64).
        let payload = SessionHistoryPayloadV5(
            sessionId: sessionIdString,
            messages: (55..<65).map { i in
                WireMessageV5(
                    sessionId: sessionIdString,
                    offset: Int64(i),
                    role: "user",
                    text: "new \(i)",
                    uuid: UUID().uuidString.lowercased(),
                    timestamp: Date()
                )
            },
            nextOffset: 65,
            endOfFile: true,
            fileReplaced: false,
            fileSignature: "sig1"
        )
        manager.handleSessionHistoryPayload(payload)

        // Assert: count reduced to 50 (oldest 15 deleted).
        // handleSessionHistoryPayload runs on a serial background queue;
        // allow it to drain before checking the persistent store.
        let expectation = XCTestExpectation(description: "prune completes")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            let verifyCtx = self.persistenceController.container.newBackgroundContext()
            verifyCtx.performAndWait {
                let count = try! verifyCtx.count(for: CDMessage.fetchMessages(sessionId: sessionId))
                XCTAssertEqual(count, 50,
                    "session_history prune must fire when count (65) exceeds needsPruning threshold (60)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }
}
