// E2EDeletionWorkflowTests.swift
// End-to-end tests for session deletion workflow (voice-code-100)
//
// Tests deletion stopping replication per-client using REAL backend
// with multi-client scenarios.
//
// PREREQUISITES:
// - Backend running on localhost:8080
// - Claude CLI installed and authenticated

import XCTest
import CoreData
@testable import VoiceCode

final class E2EDeletionWorkflowTests: XCTestCase {

    var client1: VoiceCodeClient!
    var client2: VoiceCodeClient!
    var persistenceController1: PersistenceController!
    var persistenceController2: PersistenceController!
    var context1: NSManagedObjectContext!
    var context2: NSManagedObjectContext!
    var syncManager1: SessionSyncManager!
    var syncManager2: SessionSyncManager!

    let testServerURL = "ws://localhost:8080"
    let testWorkingDir = "/tmp/voice-code-e2e-tests"

    override func setUp() {
        super.setUp()

        // Create test working directory
        try? FileManager.default.createDirectory(atPath: testWorkingDir, withIntermediateDirectories: true)

        // Initialize Client 1
        persistenceController1 = PersistenceController(inMemory: true)
        context1 = persistenceController1.container.viewContext
        syncManager1 = SessionSyncManager(persistenceController: persistenceController1)
        client1 = VoiceCodeClient(serverURL: testServerURL)
        client1.sessionSyncManager = syncManager1

        // Initialize Client 2
        persistenceController2 = PersistenceController(inMemory: true)
        context2 = persistenceController2.container.viewContext
        syncManager2 = SessionSyncManager(persistenceController: persistenceController2)
        client2 = VoiceCodeClient(serverURL: testServerURL)
        client2.sessionSyncManager = syncManager2
    }

    override func tearDown() {
        client1?.disconnect()
        client2?.disconnect()
        Thread.sleep(forTimeInterval: 0.2)

        client1 = nil
        client2 = nil
        syncManager1 = nil
        syncManager2 = nil
        persistenceController1 = nil
        persistenceController2 = nil
        context1 = nil
        context2 = nil

        super.tearDown()
    }

    // MARK: - Helper Functions

    func fetchSession(id: UUID, from context: NSManagedObjectContext) -> CDSession? {
        let fetchRequest = CDSession.fetchSession(id: id)
        return try? context.fetch(fetchRequest).first
    }

    func fetchMessages(sessionId: UUID, from context: NSManagedObjectContext) -> [CDMessage] {
        let fetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
        return (try? context.fetch(fetchRequest)) ?? []
    }

    func markSessionDeleted(sessionId: UUID, in context: NSManagedObjectContext) {
        if let session = fetchSession(id: sessionId, from: context) {
            session.markedDeleted = true
            try? context.save()
            print("🗑️ Marked session as deleted in CoreData: \(sessionId)")
        }
    }

    func cleanupTestSession(sessionId: UUID) {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let projectsDir = homeDir.appendingPathComponent(".claude/projects")

        guard let enumerator = FileManager.default.enumerator(at: projectsDir, includingPropertiesForKeys: nil) else {
            return
        }

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent.contains(sessionId.uuidString) {
                try? FileManager.default.removeItem(at: fileURL)
                print("🗑️ Cleaned up test session: \(fileURL.path)")
            }
        }
    }

    func sessionFileExists(sessionId: UUID) -> Bool {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let projectsDir = homeDir.appendingPathComponent(".claude/projects")

        guard let enumerator = FileManager.default.enumerator(at: projectsDir, includingPropertiesForKeys: nil) else {
            return false
        }

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent.contains(sessionId.uuidString) {
                return true
            }
        }

        return false
    }

    // MARK: - Deletion Workflow Tests

    func testDeletionStopsReplicationForClient() {
        let connectExpectation = XCTestExpectation(description: "Both clients connect")
        let sessionCreatedExpectation = XCTestExpectation(description: "Session created")
        let client2UpdateExpectation = XCTestExpectation(description: "Client 2 receives update")
        let client1NoUpdateExpectation = XCTestExpectation(description: "Client 1 does not receive update")
        client1NoUpdateExpectation.isInverted = true  // Should NOT be fulfilled

        let sessionId = UUID()
        var client1UpdateCount = 0
        var client2UpdateCount = 0

        // Track updates for both clients
        let originalHandler1 = syncManager1.handleSessionUpdated
        syncManager1.handleSessionUpdated = { sessionIdString, messages in
            originalHandler1(sessionIdString, messages)
            if sessionIdString == sessionId.uuidString {
                client1UpdateCount += 1
                print("📥 Client 1 received update #\(client1UpdateCount)")
                client1NoUpdateExpectation.fulfill()  // Will fail test if fulfilled
            }
        }

        let originalHandler2 = syncManager2.handleSessionUpdated
        syncManager2.handleSessionUpdated = { sessionIdString, messages in
            originalHandler2(sessionIdString, messages)
            if sessionIdString == sessionId.uuidString {
                client2UpdateCount += 1
                print("📥 Client 2 received update #\(client2UpdateCount)")
                if client2UpdateCount >= 1 {
                    client2UpdateExpectation.fulfill()
                }
            }
        }

        // Connect both clients
        client1.connect()
        client2.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            XCTAssertTrue(self.client1.isConnected)
            XCTAssertTrue(self.client2.isConnected)
            connectExpectation.fulfill()

            print("🚀 Creating test session")

            // Create session via Client 1
            self.client1.subscribe(sessionId: sessionId.uuidString)
            self.client1.sendPrompt(
                "Initial message for deletion test",
                newSessionId: sessionId.uuidString,
                workingDirectory: self.testWorkingDir
            )

            // Wait for session creation
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                sessionCreatedExpectation.fulfill()

                // Both clients subscribe
                self.client2.subscribe(sessionId: sessionId.uuidString)

                // Wait for subscription to settle
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    print("🗑️ Client 1 deleting session locally")

                    // Client 1 deletes session
                    self.client1.sendMessage(["type": "session_deleted", "session_id": sessionId.uuidString])
                    self.client1.unsubscribe(sessionId: sessionId.uuidString)
                    self.markSessionDeleted(sessionId: sessionId, in: self.context1)

                    // Reset update counters
                    client1UpdateCount = 0
                    client2UpdateCount = 0

                    // Wait for deletion to be processed
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        print("📤 Sending prompt from terminal to deleted session")

                        // Send prompt from terminal
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/claude")
                        process.arguments = [
                            "--resume", sessionId.uuidString,
                            "-p",
                            "Message after deletion"
                        ]
                        process.currentDirectoryURL = URL(fileURLWithPath: self.testWorkingDir)

                        try? process.run()
                    }
                }
            }
        }

        wait(for: [connectExpectation, sessionCreatedExpectation, client2UpdateExpectation, client1NoUpdateExpectation],
             timeout: 90.0)

        // Verify Client 1 did NOT receive update
        XCTAssertEqual(client1UpdateCount, 0, "Client 1 should not receive updates after deletion")

        // Verify Client 2 DID receive update
        XCTAssertGreaterThan(client2UpdateCount, 0, "Client 2 should receive updates")

        print("✅ Deletion filtering verified: Client 1 blocked, Client 2 received")

        // Cleanup
        cleanupTestSession(sessionId: sessionId)
    }

    func testBackendFileRemainsAfterClientDeletion() {
        let connectExpectation = XCTestExpectation(description: "Connect")
        let sessionCreatedExpectation = XCTestExpectation(description: "Session created")
        let fileExistsExpectation = XCTestExpectation(description: "File still exists after deletion")

        let sessionId = UUID()

        client1.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            XCTAssertTrue(self.client1.isConnected)
            connectExpectation.fulfill()

            // Create session
            self.client1.subscribe(sessionId: sessionId.uuidString)
            self.client1.sendPrompt(
                "Session for backend file persistence test",
                newSessionId: sessionId.uuidString,
                workingDirectory: self.testWorkingDir
            )

            // Wait for creation
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                sessionCreatedExpectation.fulfill()

                // Verify file exists before deletion
                let fileExistsBefore = self.sessionFileExists(sessionId: sessionId)
                XCTAssertTrue(fileExistsBefore, "Session file should exist before deletion")

                if fileExistsBefore {
                    print("✅ Session file exists before deletion")
                }

                // Client deletes session locally
                self.client1.sendMessage(["type": "session_deleted", "session_id": sessionId.uuidString])
                self.client1.unsubscribe(sessionId: sessionId.uuidString)
                self.markSessionDeleted(sessionId: sessionId, in: self.context1)

                print("🗑️ Client marked session as deleted")

                // Wait briefly
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    // Verify file STILL exists on backend
                    let fileExistsAfter = self.sessionFileExists(sessionId: sessionId)
                    XCTAssertTrue(fileExistsAfter, "Session file should still exist on backend after client deletion")

                    if fileExistsAfter {
                        print("✅ Backend file persists after client deletion")
                    }

                    fileExistsExpectation.fulfill()
                }
            }
        }

        wait(for: [connectExpectation, sessionCreatedExpectation, fileExistsExpectation], timeout: 60.0)

        // Cleanup
        cleanupTestSession(sessionId: sessionId)
    }

    func testDeletedSessionNotVisibleInUIQueries() {
        let connectExpectation = XCTestExpectation(description: "Connect")
        let sessionCreatedExpectation = XCTestExpectation(description: "Session created")
        let queryExpectation = XCTestExpectation(description": "Query verification")

        let sessionId = UUID()

        client1.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            XCTAssertTrue(self.client1.isConnected)
            connectExpectation.fulfill()

            // Create session
            self.client1.subscribe(sessionId: sessionId.uuidString)
            self.client1.sendPrompt(
                "Session for UI query test",
                newSessionId: sessionId.uuidString,
                workingDirectory: self.testWorkingDir
            )

            // Wait for creation
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                sessionCreatedExpectation.fulfill()

                // Query for non-deleted sessions (typical UI query)
                let fetchRequest = CDSession.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "markedDeleted == NO")

                let visibleSessionsBefore = try? self.context1.fetch(fetchRequest)
                let countBefore = visibleSessionsBefore?.count ?? 0
                print("📊 Visible sessions before deletion: \(countBefore)")

                // Find our session
                let ourSessionBefore = visibleSessionsBefore?.first { $0.id == sessionId }
                XCTAssertNotNil(ourSessionBefore, "Session should be visible before deletion")

                // Mark as deleted
                self.markSessionDeleted(sessionId: sessionId, in: self.context1)

                // Query again
                let visibleSessionsAfter = try? self.context1.fetch(fetchRequest)
                let countAfter = visibleSessionsAfter?.count ?? 0
                print("📊 Visible sessions after deletion: \(countAfter)")

                // Should be one less
                XCTAssertEqual(countAfter, countBefore - 1, "Deleted session should not appear in UI query")

                // Find our session (should not exist in results)
                let ourSessionAfter = visibleSessionsAfter?.first { $0.id == sessionId }
                XCTAssertNil(ourSessionAfter, "Deleted session should not be visible in UI query")

                print("✅ Deleted session filtered from UI queries")

                queryExpectation.fulfill()
            }
        }

        wait(for: [connectExpectation, sessionCreatedExpectation, queryExpectation], timeout: 60.0)

        // Cleanup
        cleanupTestSession(sessionId: sessionId)
    }

    func testMultipleClientsDeletionIndependence() {
        let connectExpectation = XCTestExpectation(description: "Both clients connect")
        let sessionCreatedExpectation = XCTestExpectation(description: "Session created")
        let independenceExpectation = XCTestExpectation(description: "Deletion independence verified")

        let sessionId = UUID()

        // Connect both clients
        client1.connect()
        client2.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            XCTAssertTrue(self.client1.isConnected)
            XCTAssertTrue(self.client2.isConnected)
            connectExpectation.fulfill()

            // Create session
            self.client1.subscribe(sessionId: sessionId.uuidString)
            self.client1.sendPrompt(
                "Session for multi-client deletion test",
                newSessionId: sessionId.uuidString,
                workingDirectory: self.testWorkingDir
            )

            // Wait for creation
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                sessionCreatedExpectation.fulfill()

                // Both clients subscribe
                self.client2.subscribe(sessionId: sessionId.uuidString)

                // Wait for subscriptions
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    // Verify both have the session
                    let session1 = self.fetchSession(id: sessionId, from: self.context1)
                    let session2 = self.fetchSession(id: sessionId, from: self.context2)

                    XCTAssertNotNil(session1, "Client 1 should have session")
                    XCTAssertNotNil(session2, "Client 2 should have session")

                    XCTAssertFalse(session1?.markedDeleted ?? true, "Client 1 session not deleted initially")
                    XCTAssertFalse(session2?.markedDeleted ?? true, "Client 2 session not deleted initially")

                    // Client 1 deletes
                    self.markSessionDeleted(sessionId: sessionId, in: self.context1)

                    // Verify Client 1 has it marked deleted
                    self.context1.refresh(session1!, mergeChanges: false)
                    XCTAssertTrue(session1?.markedDeleted ?? false, "Client 1 should mark as deleted")

                    // Verify Client 2 does NOT have it marked deleted (independent CoreData)
                    XCTAssertFalse(session2?.markedDeleted ?? true, "Client 2 should NOT mark as deleted")

                    print("✅ Deletion is independent per client")

                    independenceExpectation.fulfill()
                }
            }
        }

        wait(for: [connectExpectation, sessionCreatedExpectation, independenceExpectation], timeout: 60.0)

        // Cleanup
        cleanupTestSession(sessionId: sessionId)
    }

    func testReconnectionPreservesDeletionState() {
        let connectExpectation = XCTestExpectation(description: "Initial connect")
        let sessionCreatedExpectation = XCTestExpectation(description: "Session created")
        let reconnectExpectation = XCTestExpectation(description: "Reconnect")
        let preservationExpectation = XCTestExpectation(description: "Deletion state preserved")

        let sessionId = UUID()

        // Use persistent store instead of in-memory for this test
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let persistentController = PersistenceController(inMemory: false, storeURL: tempDir.appendingPathComponent("test.sqlite"))
        let persistentContext = persistentController.container.viewContext
        let persistentSyncManager = SessionSyncManager(persistenceController: persistentController)

        let testClient = VoiceCodeClient(serverURL: testServerURL)
        testClient.sessionSyncManager = persistentSyncManager

        testClient.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            XCTAssertTrue(testClient.isConnected)
            connectExpectation.fulfill()

            // Create session
            testClient.subscribe(sessionId: sessionId.uuidString)
            testClient.sendPrompt(
                "Session for reconnection test",
                newSessionId: sessionId.uuidString,
                workingDirectory: self.testWorkingDir
            )

            // Wait for creation
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                sessionCreatedExpectation.fulfill()

                // Mark as deleted
                if let session = self.fetchSession(id: sessionId, from: persistentContext) {
                    session.markedDeleted = true
                    try? persistentContext.save()
                    print("🗑️ Marked session as deleted before disconnect")
                }

                // Disconnect
                testClient.disconnect()

                // Wait briefly
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    // Reconnect
                    testClient.connect()

                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        XCTAssertTrue(testClient.isConnected)
                        reconnectExpectation.fulfill()

                        // Check if deletion state persisted
                        if let session = self.fetchSession(id: sessionId, from: persistentContext) {
                            XCTAssertTrue(session.markedDeleted, "Deletion state should persist across reconnection")
                            print("✅ Deletion state preserved after reconnect")
                        } else {
                            XCTFail("Session should still exist in CoreData")
                        }

                        preservationExpectation.fulfill()

                        // Cleanup
                        testClient.disconnect()
                        try? FileManager.default.removeItem(at: tempDir)
                    }
                }
            }
        }

        wait(for: [connectExpectation, sessionCreatedExpectation, reconnectExpectation, preservationExpectation], timeout: 90.0)

        // Cleanup
        cleanupTestSession(sessionId: sessionId)
    }

    func testDeletionDoesNotAffectOtherSessionsUpdates() {
        let connectExpectation = XCTestExpectation(description: "Connect")
        let session1CreatedExpectation = XCTestExpectation(description: "Session 1 created")
        let session2CreatedExpectation = XCTestExpectation(description: "Session 2 created")
        let session2UpdateExpectation = XCTestExpectation(description: "Session 2 update received")

        let session1Id = UUID()
        let session2Id = UUID()

        client1.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            XCTAssertTrue(self.client1.isConnected)
            connectExpectation.fulfill()

            // Create two sessions
            self.client1.subscribe(sessionId: session1Id.uuidString)
            self.client1.sendPrompt(
                "Session 1 - will be deleted",
                newSessionId: session1Id.uuidString,
                workingDirectory: self.testWorkingDir
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                session1CreatedExpectation.fulfill()

                self.client1.subscribe(sessionId: session2Id.uuidString)
                self.client1.sendPrompt(
                    "Session 2 - will remain active",
                    newSessionId: session2Id.uuidString,
                    workingDirectory: self.testWorkingDir
                )

                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    session2CreatedExpectation.fulfill()

                    // Delete session 1
                    self.client1.sendMessage(["type": "session_deleted", "session_id": session1Id.uuidString])
                    self.markSessionDeleted(sessionId: session1Id, in: self.context1)

                    print("🗑️ Deleted session 1")

                    // Send update to session 2
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        let messages2Before = self.fetchMessages(sessionId: session2Id, from: self.context1)
                        let countBefore = messages2Before.count

                        print("📤 Sending update to session 2")
                        self.client1.sendPrompt(
                            "Update to active session",
                            resumeSessionId: session2Id.uuidString
                        )

                        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                            let messages2After = self.fetchMessages(sessionId: session2Id, from: self.context1)
                            let countAfter = messages2After.count

                            // Session 2 should still receive updates
                            XCTAssertGreaterThan(countAfter, countBefore,
                                                "Session 2 should still receive updates after session 1 deletion")

                            print("✅ Session 2 updates not affected by session 1 deletion")

                            session2UpdateExpectation.fulfill()
                        }
                    }
                }
            }
        }

        wait(for: [connectExpectation, session1CreatedExpectation, session2CreatedExpectation, session2UpdateExpectation],
             timeout: 120.0)

        // Cleanup
        cleanupTestSession(sessionId: session1Id)
        cleanupTestSession(sessionId: session2Id)
    }
}
