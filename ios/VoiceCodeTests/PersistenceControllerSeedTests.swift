// PersistenceControllerSeedTests.swift
// Unit tests for the debug-only UI-test large-session seed hook used by
// AutoScrollCrashUITests. See docs/design/conversation-autoscroll-crash-fix.md
// (Verification Strategy).

import XCTest
import CoreData
@testable import VoiceCode

#if DEBUG
final class PersistenceControllerSeedTests: XCTestCase {
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!

    override func setUpWithError() throws {
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
    }

    override func tearDownWithError() throws {
        persistenceController = nil
        context = nil
    }

    // MARK: - seedLargeSession (pure)

    func testSeedCreatesOneSessionWithRequestedMessageCount() throws {
        let workingDirectory = "/uitest/Seed"
        let count = 120

        let sessionId = try PersistenceController.seedLargeSession(
            in: context,
            workingDirectory: workingDirectory,
            messageCount: count
        )
        try context.save()

        let sessions = try context.fetch(CDBackendSession.fetchRequest())
        XCTAssertEqual(sessions.count, 1, "Seed should create exactly one session")

        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.id, sessionId)
        XCTAssertEqual(session.workingDirectory, workingDirectory)
        XCTAssertEqual(session.messageCount, Int32(count))
        XCTAssertFalse(session.isLocallyCreated, "Seed session should be backend-known so ConversationView treats it as real")

        let messages = try context.fetch(CDMessage.fetchMessages(sessionId: sessionId))
        XCTAssertEqual(messages.count, count, "Seed should create messageCount messages for the session")
    }

    func testSeedExceedsLocalPruneWindow() throws {
        // The point of the seed is a backlog large enough to scroll through, so
        // it must be well above the local message window cap.
        let count = PersistenceController.uiTestSeedMessageCount
        XCTAssertGreaterThan(count, CDMessage.maxMessagesPerSession + CDMessage.pruneThreshold,
                             "Seed count must exceed the local prune window to be a meaningful scroll target")

        let sessionId = try PersistenceController.seedLargeSession(
            in: context,
            workingDirectory: "/uitest/Seed",
            messageCount: count
        )
        try context.save()

        let messages = try context.fetch(CDMessage.fetchMessages(sessionId: sessionId))
        XCTAssertEqual(messages.count, count)
        XCTAssertTrue(CDMessage.needsPruning(sessionId: sessionId, in: context),
                      "A seeded session should look like a large session that would prune under normal sync")
    }

    func testSeedMessagesAreChronologicalAndAlternateRoles() throws {
        let count = 10
        let sessionId = try PersistenceController.seedLargeSession(
            in: context,
            workingDirectory: "/uitest/Seed",
            messageCount: count
        )
        try context.save()

        // fetchMessages sorts ascending (oldest first); the seed assigns 0-based
        // offsets and 1s-apart ascending timestamps, so order is stable.
        let messages = try context.fetch(CDMessage.fetchMessages(sessionId: sessionId))
        XCTAssertEqual(messages.count, count)

        for (i, message) in messages.enumerated() {
            XCTAssertEqual(message.offset, Int64(i), "offset should be the 0-based index")
            XCTAssertEqual(message.role, i % 2 == 0 ? "user" : "assistant", "roles should alternate user/assistant")
            XCTAssertEqual(message.messageStatus, .confirmed)
            XCTAssertEqual(message.sessionId, sessionId)
            if i > 0 {
                XCTAssertGreaterThan(message.timestamp, messages[i - 1].timestamp,
                                     "timestamps must be strictly increasing")
            }
        }
    }

    func testSeedRejectsNonPositiveMessageCount() {
        // messageCount <= 0 is degenerate (and a negative value would trap the
        // 0..<messageCount loop), so the seed must reject it before staging
        // anything.
        for badCount in [0, -5] {
            XCTAssertThrowsError(
                try PersistenceController.seedLargeSession(
                    in: context,
                    workingDirectory: "/uitest/Seed",
                    messageCount: badCount
                ),
                "messageCount \(badCount) should be rejected"
            ) { error in
                guard case PersistenceController.SeedError.nonPositiveMessageCount(let count) = error else {
                    return XCTFail("Expected SeedError.nonPositiveMessageCount, got \(error)")
                }
                XCTAssertEqual(count, badCount, "Error should carry the offending count")
            }
        }
        XCTAssertFalse(context.hasChanges, "A rejected seed must not stage any objects")
    }

    func testSeedDoesNotSaveContext() throws {
        // The pure seed leaves the save to the caller; verify it stages changes
        // without committing them.
        _ = try PersistenceController.seedLargeSession(
            in: context,
            workingDirectory: "/uitest/Seed",
            messageCount: 5
        )
        XCTAssertTrue(context.hasChanges, "seedLargeSession should stage but not save")
    }

    // MARK: - seedLargeSessionForUITesting (launch hook wrapper)

    func testSeedLargeSessionForUITestingPopulatesViewContextWithDefaults() throws {
        persistenceController.seedLargeSessionForUITesting()

        let sessions = try CDBackendSession.fetchActiveSessions(context: context)
        XCTAssertEqual(sessions.count, 1)

        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.workingDirectory, PersistenceController.uiTestSeedWorkingDirectory)

        let messages = try context.fetch(CDMessage.fetchMessages(sessionId: session.id))
        XCTAssertEqual(messages.count, PersistenceController.uiTestSeedMessageCount,
                       "Launch hook should seed the default message count")
        XCTAssertFalse(context.hasChanges, "Launch hook should have saved the seeded data")
    }
}
#endif
