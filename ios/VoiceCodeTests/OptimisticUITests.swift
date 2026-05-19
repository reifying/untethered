//
//  OptimisticUITests.swift
//  VoiceCodeTests
//
//  Tests for optimistic UI pattern (voice-code-91)
//

import XCTest
import CoreData
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCode
#endif

class OptimisticUITests: XCTestCase {
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
    
    // MARK: - Optimistic Message Creation Tests
    
    func testCreateOptimisticMessage() throws {
        // Create session first
        let sessionId = UUID()
        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""

        try context.save()
        
        // Create optimistic message
        let expectation = XCTestExpectation(description: "Optimistic message created")
        var capturedMessageId: UUID?
        
        syncManager.createOptimisticMessage(sessionId: sessionId, text: "Test prompt") { messageId in
            capturedMessageId = messageId
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 2.0)
        
        // Verify message was created
        XCTAssertNotNil(capturedMessageId)
        
        // Wait for background save
        let saveExpectation = XCTestExpectation(description: "Wait for save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            saveExpectation.fulfill()
        }
        wait(for: [saveExpectation], timeout: 1.0)
        
        // Refetch and verify
        context.refreshAllObjects()
        let fetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
        let messages = try context.fetch(fetchRequest)
        
        XCTAssertEqual(messages.count, 1)
        
        let message = messages[0]
        XCTAssertEqual(message.id, capturedMessageId)
        XCTAssertEqual(message.role, "user")
        XCTAssertEqual(message.text, "Test prompt")
        XCTAssertEqual(message.messageStatus, .sending)
        XCTAssertNil(message.serverTimestamp)
        
        // Verify session was updated
        let sessionFetchRequest = CDBackendSession.fetchBackendSession(id: sessionId)
        let updatedSession = try context.fetch(sessionFetchRequest).first
        
        XCTAssertEqual(updatedSession?.messageCount, 1)
        XCTAssertEqual(updatedSession?.preview, "Test prompt")
    }
    
    func testCreateOptimisticMessageForNonexistentSession() throws {
        let nonexistentId = UUID()

        let expectation = XCTestExpectation(description: "Should not call completion")
        expectation.isInverted = true

        syncManager.createOptimisticMessage(sessionId: nonexistentId, text: "Test") { _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)

        // Verify no messages were created
        let fetchRequest = CDMessage.fetchMessages(sessionId: nonexistentId)
        let messages = try context.fetch(fetchRequest)

        XCTAssertEqual(messages.count, 0)
    }

    // MARK: - Optimistic Seq Assignment (tmux-untethered-mgp)

    /// `optimisticSeq(for:)` must be deterministic — same UUID always maps
    /// to the same seq. Without determinism, a row's seq would shift every
    /// process launch and the upsert path could not rely on negative-seq
    /// optimistic rows being stable across context merges.
    func testOptimisticSeqIsDeterministic() {
        let id = UUID()
        let s1 = SessionSyncManager.optimisticSeq(for: id)
        let s2 = SessionSyncManager.optimisticSeq(for: id)
        XCTAssertEqual(s1, s2, "same UUID must always map to the same optimistic seq")
        XCTAssertLessThan(s1, 0, "optimistic seq must be strictly negative — backend uses positive seqs")
    }

    /// Distinct UUIDs map to distinct seqs with overwhelmingly high probability.
    /// The fix's whole point: two rapid prompts produce optimistic rows with
    /// different `(sessionId, seq)` keys instead of colliding on `seq=0`.
    func testOptimisticSeqIsDistinctForDistinctUUIDs() {
        var seen: Set<Int64> = []
        for _ in 0..<100 {
            let s = SessionSyncManager.optimisticSeq(for: UUID())
            XCTAssertLessThan(s, 0, "every optimistic seq must be strictly negative")
            XCTAssertFalse(seen.contains(s),
                           "duplicate optimistic seq across 100 random UUIDs — collision risk too high")
            seen.insert(s)
        }
    }

    /// End-to-end: two consecutive optimistic creates land with different
    /// negative seqs in CoreData, so a subsequent reconciliation fetch keyed
    /// on `(sessionId, seq)` cannot accidentally match the wrong row.
    func testTwoOptimisticMessagesGetDistinctNegativeSeqs() throws {
        let sessionId = UUID()
        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        try context.save()

        let exp1 = XCTestExpectation(description: "first optimistic")
        let exp2 = XCTestExpectation(description: "second optimistic")
        syncManager.createOptimisticMessage(sessionId: sessionId, text: "first") { _ in
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 2.0)

        syncManager.createOptimisticMessage(sessionId: sessionId, text: "second") { _ in
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 2.0)

        let saveExpectation = XCTestExpectation(description: "Wait for saves")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            saveExpectation.fulfill()
        }
        wait(for: [saveExpectation], timeout: 1.0)

        context.refreshAllObjects()
        let messages = try context.fetch(CDMessage.fetchMessages(sessionId: sessionId))
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages.allSatisfy { $0.seq < 0 },
                      "both optimistic rows must carry negative seqs (backend assigns positive)")
        let seqs = Set(messages.map(\.seq))
        XCTAssertEqual(seqs.count, 2,
                       "two optimistic rows must have distinct seqs — no seq=0 collision")
    }

    // MARK: - v0.5.0 Optimistic Offset (tmux-untethered-mqo)

    /// Optimistic messages must carry a negative `offset` so the v0.5.0
    /// (sessionId, offset) upsert lookup never confuses them with the first
    /// confirmed message in a session (which has offset=0). Without this,
    /// a session_history payload whose first message has offset=0 could
    /// overwrite the pending prompt with historical content.
    func testOptimisticMessageCarriesNegativeOffset() throws {
        let sessionId = UUID()
        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        try context.save()

        let exp = XCTestExpectation(description: "optimistic created")
        syncManager.createOptimisticMessage(sessionId: sessionId, text: "my prompt") { _ in
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        let saveExp = XCTestExpectation(description: "wait for save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { saveExp.fulfill() }
        wait(for: [saveExp], timeout: 1.0)

        context.refreshAllObjects()
        let messages = try context.fetch(CDMessage.fetchMessages(sessionId: sessionId))
        XCTAssertEqual(messages.count, 1)
        XCTAssertLessThan(messages[0].offset, 0,
                          "optimistic offset must be strictly negative to avoid offset=0 collision with first confirmed message (tmux-untethered-mqo)")
    }

    /// Two optimistic messages must get distinct negative offsets so that the
    /// v0.5.0 (sessionId, offset) lookup still uniquely identifies each row,
    /// mirroring the distinct-negative-seq guarantee for v0.4.0.
    func testTwoOptimisticMessagesGetDistinctNegativeOffsets() throws {
        let sessionId = UUID()
        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        try context.save()

        let exp1 = XCTestExpectation(description: "first optimistic")
        let exp2 = XCTestExpectation(description: "second optimistic")
        syncManager.createOptimisticMessage(sessionId: sessionId, text: "first prompt") { _ in exp1.fulfill() }
        wait(for: [exp1], timeout: 2.0)
        syncManager.createOptimisticMessage(sessionId: sessionId, text: "second prompt") { _ in exp2.fulfill() }
        wait(for: [exp2], timeout: 2.0)

        let saveExp = XCTestExpectation(description: "wait for saves")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { saveExp.fulfill() }
        wait(for: [saveExp], timeout: 1.0)

        context.refreshAllObjects()
        let messages = try context.fetch(CDMessage.fetchMessages(sessionId: sessionId))
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages.allSatisfy { $0.offset < 0 },
                      "both optimistic rows must carry negative offsets")
        let offsets = Set(messages.map(\.offset))
        XCTAssertEqual(offsets.count, 2,
                       "two optimistic rows must have distinct offsets — no offset=0 collision")
    }

    /// A v0.5.0 payload whose first message has offset=0 must NOT corrupt an
    /// in-flight optimistic message. The confirmed message at offset=0 is
    /// inserted; the optimistic row (now carrying a negative offset) is
    /// untouched and remains with its original text and status=sending.
    func testV5UpsertWithOffset0DoesNotMatchOptimisticRow() throws {
        let sessionIdString = "aaaabbbb-cccc-dddd-eeee-ffffffffffff"
        let sessionUUID = UUID(uuidString: sessionIdString)!

        let session = CDBackendSession(context: context)
        session.id = sessionUUID
        session.backendName = "Test"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        try context.save()

        // Create an optimistic message for the user's new prompt
        let optExp = XCTestExpectation(description: "optimistic created")
        syncManager.createOptimisticMessage(sessionId: sessionUUID, text: "my new prompt") { _ in
            optExp.fulfill()
        }
        wait(for: [optExp], timeout: 2.0)
        let saveExp1 = XCTestExpectation(description: "wait 1")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { saveExp1.fulfill() }
        wait(for: [saveExp1], timeout: 1.0)

        // Simulate a v0.5.0 session_history payload whose first message has offset=0
        let historicalMessage = WireMessageV5(
            sessionId: sessionIdString,
            offset: 0,
            role: "user",
            text: "original first prompt",
            uuid: UUID().uuidString.lowercased(),
            timestamp: Date().addingTimeInterval(-60)
        )
        let payload = SessionHistoryPayloadV5(
            sessionId: sessionIdString,
            messages: [historicalMessage],
            nextOffset: 1,
            endOfFile: true,
            fileReplaced: nil,
            fileSignature: nil
        )

        let upsertExp = XCTestExpectation(description: "payload handled")
        syncManager.handleSessionHistoryPayload(payload)
        // Give the serial upsert queue time to finish
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { upsertExp.fulfill() }
        wait(for: [upsertExp], timeout: 2.0)

        context.refreshAllObjects()
        let messages = try context.fetch(CDMessage.fetchMessages(sessionId: sessionUUID))

        // Should have exactly 2 rows: the confirmed historical message + the optimistic
        XCTAssertEqual(messages.count, 2,
                       "confirmed historical message and optimistic should both exist")

        let confirmedRows = messages.filter { $0.messageStatus == .confirmed }
        let pendingRows = messages.filter { $0.messageStatus == .sending }

        XCTAssertEqual(confirmedRows.count, 1, "exactly one confirmed row")
        XCTAssertEqual(pendingRows.count, 1, "exactly one pending/sending row")

        XCTAssertEqual(confirmedRows.first?.text, "original first prompt",
                       "confirmed row must hold historical content")
        XCTAssertEqual(pendingRows.first?.text, "my new prompt",
                       "optimistic row must preserve the user's pending prompt")
        XCTAssertEqual(confirmedRows.first?.offset, 0, "confirmed row has offset=0")
        XCTAssertLessThan(pendingRows.first?.offset ?? 0, 0,
                          "optimistic row must keep its negative offset")
    }
}
