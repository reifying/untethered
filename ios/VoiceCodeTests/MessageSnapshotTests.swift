// MessageSnapshotTests.swift
// Tests for MessageSnapshot — the value-type capture of a CDMessage used to
// keep the "View Full" detail sheet stable across CoreData churn (pruning,
// list cell recycling, incoming messages). Covers tmux-untethered-649.

import XCTest
import CoreData
@testable import VoiceCode

final class MessageSnapshotTests: XCTestCase {
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

    private func makeMessage(
        text: String,
        role: String = "assistant",
        session: CDBackendSession? = nil
    ) -> CDMessage {
        let msg = CDMessage(context: context)
        msg.id = UUID()
        msg.sessionId = UUID()
        msg.role = role
        msg.text = text
        msg.timestamp = Date()
        msg.messageStatus = .confirmed
        msg.session = session
        return msg
    }

    private func makeSession(workingDirectory: String) -> CDBackendSession {
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "test-backend"
        session.workingDirectory = workingDirectory
        session.lastModified = Date()
        session.preview = ""
        return session
    }

    // MARK: - Field capture

    func testSnapshotCapturesAllFields() {
        let message = makeMessage(text: "Hello world")

        let snapshot = MessageSnapshot(from: message)

        XCTAssertEqual(snapshot.messageId, message.id)
        XCTAssertEqual(snapshot.role, message.role)
        XCTAssertEqual(snapshot.text, message.text)
        XCTAssertEqual(snapshot.timestamp, message.timestamp)
        XCTAssertEqual(snapshot.sessionId, message.sessionId)
    }

    func testSnapshotCapturesWorkingDirectoryFromSession() {
        let session = makeSession(workingDirectory: "/Users/test/project")
        let message = makeMessage(text: "with session", session: session)

        let snapshot = MessageSnapshot(from: message)

        XCTAssertEqual(snapshot.workingDirectory, "/Users/test/project")
    }

    func testSnapshotWorkingDirectoryIsNilWithoutSession() {
        let message = makeMessage(text: "no session", session: nil)

        let snapshot = MessageSnapshot(from: message)

        XCTAssertNil(snapshot.workingDirectory)
    }

    // MARK: - Identity

    // The id must be a freshly minted UUID per presentation, NOT the message
    // UUID. SwiftUI's .sheet(item:) refuses to re-present when the new item has
    // the same id as the previous one — minting a fresh id lets the user tap
    // "View Full" on the same message twice and get the sheet both times.
    func testSnapshotMintsUniqueId() {
        let message = makeMessage(text: "test", role: "user")

        let snapshot1 = MessageSnapshot(from: message)
        let snapshot2 = MessageSnapshot(from: message)

        XCTAssertNotEqual(snapshot1.id, snapshot2.id,
                          "Each snapshot must mint a fresh id for SwiftUI re-presentation")
        XCTAssertEqual(snapshot1.messageId, snapshot2.messageId,
                       "messageId must stay stable — it points at the same CDMessage")
    }

    func testSnapshotIdDiffersFromMessageId() {
        let message = makeMessage(text: "distinct ids")

        let snapshot = MessageSnapshot(from: message)

        XCTAssertNotEqual(snapshot.id, snapshot.messageId,
                          "snapshot.id must be a fresh UUID, not the message UUID")
    }

    // MARK: - Value semantics

    // The snapshot is a value copy: mutating the CDMessage after capture (e.g.
    // pruning, server text updates) must not retroactively change the snapshot.
    func testSnapshotTextIsValueCopy() {
        let message = makeMessage(text: "original text")

        let snapshot = MessageSnapshot(from: message)
        message.text = "modified text"

        XCTAssertEqual(snapshot.text, "original text")
    }

    func testSnapshotFieldsAreValueCopies() {
        let message = makeMessage(text: "body", role: "assistant")
        let originalRole = message.role
        let originalSessionId = message.sessionId

        let snapshot = MessageSnapshot(from: message)
        message.role = "user"
        message.sessionId = UUID()

        XCTAssertEqual(snapshot.role, originalRole)
        XCTAssertEqual(snapshot.sessionId, originalSessionId)
    }

    // MARK: - Survives CoreData deletion (integration)

    // The whole point of the snapshot: once captured it is fully decoupled from
    // CoreData. Tearing down the object graph it was taken from — the source
    // CDMessage (pruning / file_replaced purge) and its session (the
    // workingDirectory source) — must leave every snapshot field intact and
    // accessible so the open "View Full" sheet keeps rendering its content.
    func testSnapshotSurvivesCoreDataDeletion() throws {
        let session = makeSession(workingDirectory: "/Users/test/survives")
        let message = makeMessage(text: "read me after deletion", session: session)
        try context.save()

        let snapshot = MessageSnapshot(from: message)
        let expectedId = snapshot.id
        let expectedMessageId = snapshot.messageId
        let expectedTimestamp = snapshot.timestamp
        let expectedSessionId = snapshot.sessionId

        // Delete the message (pruning / purge) and its session (working-dir source).
        context.delete(message)
        context.delete(session)
        try context.save()

        // The source CDMessage is gone from CoreData...
        let live = try context.fetch(CDMessage.fetchMessage(id: expectedMessageId)).first
        XCTAssertNil(live, "source CDMessage must be deleted")

        // ...but every snapshot field — including workingDirectory, derived from
        // the now-deleted session relationship — is a value copy and survives.
        XCTAssertEqual(snapshot.id, expectedId)
        XCTAssertEqual(snapshot.messageId, expectedMessageId)
        XCTAssertEqual(snapshot.role, "assistant")
        XCTAssertEqual(snapshot.text, "read me after deletion")
        XCTAssertEqual(snapshot.timestamp, expectedTimestamp)
        XCTAssertEqual(snapshot.sessionId, expectedSessionId)
        XCTAssertEqual(snapshot.workingDirectory, "/Users/test/survives")
    }
}
