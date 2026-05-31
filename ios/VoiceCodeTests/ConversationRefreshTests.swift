// ConversationRefreshTests.swift
//
// Regression coverage for tmux-untethered-bae.3. Verifies that:
//   - CDMessage.pruneOldMessages does not fire when count == maxMessagesPerSession (Fix 2, AC4)
//   - handleSessionHistoryPayload (v0.5.0 path) still prunes when count exceeds the threshold (Fix 2, AC4)
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
        // maxMessagesPerSession messages — pruneOldMessages must not delete any
        // because count == keepCount (not strictly greater).
        let sessionId = UUID()
        let max = CDMessage.maxMessagesPerSession
        let bgCtx = persistenceController.container.newBackgroundContext()
        bgCtx.performAndWait {
            for i in 0..<max {
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
                "pruneOldMessages must not fire when count == keepCount (\(max))")

            let count = try! bgCtx.count(for: CDMessage.fetchMessages(sessionId: sessionId))
            XCTAssertEqual(count, max)
        }
    }

    // MARK: - Fix 2: handleSessionHistoryPayload still prunes

    func testHandleSessionHistoryStillPrunesAfterNewData() {
        // Arrange: seed maxMessagesPerSession + pruneThreshold - 1 existing messages
        // (just below the prune trigger). Payload adds pruneThreshold + 1 new messages
        // so the total crosses the threshold and pruning fires, reducing to maxMessagesPerSession.
        let max = CDMessage.maxMessagesPerSession
        let threshold = CDMessage.pruneThreshold
        let seedCount = max + threshold - 1   // just below trigger
        let newCount = threshold + 1          // enough to cross trigger
        let totalBefore = seedCount + newCount
        // sanity: totalBefore > max + threshold (prune fires)
        // and totalBefore > max (there is something to delete)

        let sessionId = UUID()
        let sessionIdString = sessionId.uuidString.lowercased()

        let backendSession = CDBackendSession(context: context)
        backendSession.id = sessionId
        backendSession.backendName = "test"
        backendSession.workingDirectory = "/tmp"
        backendSession.lastModified = Date()
        backendSession.messageCount = Int32(seedCount)
        backendSession.preview = ""
        backendSession.provider = "claude"
        backendSession.lastOffsetMerged = 0
        backendSession.liveFromOffset = 0

        for i in 0..<seedCount {
            let msg = CDMessage(context: context)
            msg.id = UUID()
            msg.sessionId = sessionId
            msg.timestamp = Date(timeIntervalSince1970: Double(i))
            msg.offset = Int64(i)
            msg.text = "existing \(i)"
            msg.role = "user"
        }
        try! context.save()

        // Act: deliver a payload carrying newCount new messages.
        let payload = SessionHistoryPayloadV5(
            sessionId: sessionIdString,
            messages: (seedCount..<(seedCount + newCount)).map { i in
                WireMessageV5(
                    sessionId: sessionIdString,
                    offset: Int64(i),
                    role: "user",
                    text: "new \(i)",
                    uuid: UUID().uuidString.lowercased(),
                    timestamp: Date()
                )
            },
            nextOffset: Int64(totalBefore),
            endOfFile: true,
            fileReplaced: false,
            fileSignature: "sig1"
        )
        manager.handleSessionHistoryPayload(payload)

        // Assert: count reduced to maxMessagesPerSession.
        // handleSessionHistoryPayload runs on a serial background queue;
        // allow it to drain before checking the persistent store.
        let expectation = XCTestExpectation(description: "prune completes")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            let verifyCtx = self.persistenceController.container.newBackgroundContext()
            verifyCtx.performAndWait {
                let count = try! verifyCtx.count(for: CDMessage.fetchMessages(sessionId: sessionId))
                XCTAssertEqual(count, max,
                    "session_history prune must fire when count (\(totalBefore)) exceeds needsPruning threshold (\(max + threshold))")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }
}
