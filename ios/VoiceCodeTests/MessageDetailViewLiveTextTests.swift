// MessageDetailViewLiveTextTests.swift
// Tests for the live-text plumbing behind MessageDetailView's "View Full" sheet
// (tmux-untethered-2ln). MessageDetailView is a SwiftUI view whose internals
// (@FetchRequest, currentText) aren't directly inspectable, so these tests
// exercise the underlying mechanism the view depends on:
//   1. CDMessage.fetchMessage(id:) is safe to drive a SwiftUI @FetchRequest
//      (it carries a sort descriptor — NSFetchedResultsController crashes without one).
//   2. The currentText fallback rule: live CoreData text while the message
//      exists, snapshot.text once it's pruned/deleted.

import XCTest
import CoreData
@testable import VoiceCode

final class MessageDetailViewLiveTextTests: XCTestCase {
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

    @discardableResult
    private func makeMessage(text: String, role: String = "assistant") -> CDMessage {
        let msg = CDMessage(context: context)
        msg.id = UUID()
        msg.sessionId = UUID()
        msg.role = role
        msg.text = text
        msg.timestamp = Date()
        msg.messageStatus = .confirmed
        return msg
    }

    /// Mirrors MessageDetailView.currentText: prefer live text, fall back to snapshot.
    private func currentText(live: CDMessage?, snapshot: MessageSnapshot) -> String {
        live?.text ?? snapshot.text
    }

    // MARK: - @FetchRequest safety

    // MessageDetailView builds its @FetchRequest from CDMessage.fetchMessage(id:).
    // SwiftUI's @FetchRequest is backed by NSFetchedResultsController, which raises
    // an exception when the request has no sort descriptor. This guards the fix.
    func testFetchMessageByIdHasSortDescriptor() {
        let message = makeMessage(text: "needs a sort descriptor")

        let request = CDMessage.fetchMessage(id: message.id)

        XCTAssertFalse(request.sortDescriptors?.isEmpty ?? true,
                       "fetchMessage(id:) must carry a sort descriptor to be @FetchRequest-safe")
    }

    func testFetchMessageByIdReturnsMatchingMessage() throws {
        let target = makeMessage(text: "target")
        _ = makeMessage(text: "other")
        try context.save()

        let result = try context.fetch(CDMessage.fetchMessage(id: target.id))

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, target.id)
        XCTAssertEqual(result.first?.text, "target")
    }

    // MARK: - currentText fallback rule

    func testCurrentTextPrefersLiveMessageText() throws {
        let message = makeMessage(text: "snapshot-time text")
        let snapshot = MessageSnapshot(from: message)

        // Live message text changes (e.g. streaming update) after snapshot capture.
        message.text = "live streamed text"
        try context.save()

        let live = try context.fetch(CDMessage.fetchMessage(id: snapshot.messageId)).first
        XCTAssertEqual(currentText(live: live, snapshot: snapshot), "live streamed text",
                       "currentText must reflect live CoreData text, not the stale snapshot")
    }

    func testCurrentTextFallsBackToSnapshotWhenMessageDeleted() throws {
        let message = makeMessage(text: "captured before pruning")
        let snapshot = MessageSnapshot(from: message)
        try context.save()

        // Simulate pruning: the underlying CDMessage is deleted.
        context.delete(message)
        try context.save()

        let live = try context.fetch(CDMessage.fetchMessage(id: snapshot.messageId)).first
        XCTAssertNil(live, "deleted message must not be fetchable")
        XCTAssertEqual(currentText(live: live, snapshot: snapshot), "captured before pruning",
                       "currentText must fall back to snapshot text once the message is pruned")
    }

    func testCurrentTextFreezesAtFinalLiveValue() throws {
        // A streaming message completes: server stops updating, the row keeps its
        // final text, and currentText keeps reading live (now-frozen) text.
        let message = makeMessage(text: "partial...")
        let snapshot = MessageSnapshot(from: message)

        message.text = "partial response complete."
        message.messageStatus = .confirmed
        try context.save()

        let live = try context.fetch(CDMessage.fetchMessage(id: snapshot.messageId)).first
        XCTAssertEqual(currentText(live: live, snapshot: snapshot), "partial response complete.")
    }
}
