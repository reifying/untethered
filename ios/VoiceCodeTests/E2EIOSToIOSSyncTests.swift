// E2EIOSToIOSSyncTests.swift
// End-to-end tests for iOS-to-iOS session syncing (voice-code-98)
//
// Tests iOS-originated sessions syncing to other iOS clients using
// REAL backend with REAL WebSocket connections.
//
// PREREQUISITES:
// - Backend running on localhost:8080
// - Claude CLI installed and authenticated

import XCTest
import CoreData
@testable import VoiceCode

final class E2EIOSToIOSSyncTests: XCTestCase {

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

    // MARK: - Two Client Connection Tests

    func testTwoClientsConnectAndReceiveSessionList() {
        let connect1Expectation = XCTestExpectation(description: "Client 1 connects")
        let connect2Expectation = XCTestExpectation(description: "Client 2 connects")

        client1.connect()
        client2.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            XCTAssertTrue(self.client1.isConnected, "Client 1 should be connected")
            XCTAssertTrue(self.client2.isConnected, "Client 2 should be connected")

            connect1Expectation.fulfill()
            connect2Expectation.fulfill()

            // Both clients should have received session list
            let fetchRequest1 = CDSession.fetchRequest()
            let fetchRequest2 = CDSession.fetchRequest()

            let sessions1 = try? self.context1.fetch(fetchRequest1)
            let sessions2 = try? self.context2.fetch(fetchRequest2)

            let count1 = sessions1?.count ?? 0
            let count2 = sessions2?.count ?? 0

            print("📊 Client 1 received \(count1) sessions")
            print("📊 Client 2 received \(count2) sessions")

            XCTAssertGreaterThan(count1, 0, "Client 1 should receive sessions")
            XCTAssertGreaterThan(count2, 0, "Client 2 should receive sessions")

            // Both should receive similar session counts (same backend)
            XCTAssertEqual(count1, count2, "Both clients should receive same session list")
        }

        wait(for: [connect1Expectation, connect2Expectation], timeout: 10.0)
    }

    // MARK: - iOS Session Creation and Sync Tests

    func testIOSSessionCreationSyncsToOtherClient() {
        let connectExpectation = XCTestExpectation(description: "Both clients connect")
        let sessionCreatedExpectation = XCTestExpectation(description: "Client 2 receives session_created")

        let sessionId = UUID()
        var client2ReceivedCreation = false

        // Set up listener on Client 2 for session_created
        let originalHandler = syncManager2.handleSessionCreated
        syncManager2.handleSessionCreated = { sessionData in
            originalHandler(sessionData)

            if let receivedId = sessionData["session_id"] as? String,
               receivedId == sessionId.uuidString {
                client2ReceivedCreation = true
                print("✅ Client 2 received session_created for: \(receivedId)")
                sessionCreatedExpectation.fulfill()
            }
        }

        // Connect both clients
        client1.connect()
        client2.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            XCTAssertTrue(self.client1.isConnected)
            XCTAssertTrue(self.client2.isConnected)
            connectExpectation.fulfill()

            print("🚀 Client 1 creating new iOS session: \(sessionId.uuidString)")

            // Client 1 subscribes first (to enable receiving updates)
            self.client1.subscribe(sessionId: sessionId.uuidString)

            // Client 1 sends prompt with new_session_id
            // Note: This will cost money (real Claude API call)
            self.client1.sendPrompt(
                "E2E test from iOS client. Please respond with 'iOS sync test confirmed'.",
                newSessionId: sessionId.uuidString,
                workingDirectory: self.testWorkingDir
            )

            print("📤 Client 1 sent prompt with new_session_id")
        }

        wait(for: [connectExpectation, sessionCreatedExpectation], timeout: 60.0)

        XCTAssertTrue(client2ReceivedCreation, "Client 2 should receive session_created broadcast")

        // Verify session exists in both CoreData instances
        if let session1 = fetchSession(id: sessionId, from: context1) {
            print("✅ Session exists in Client 1 CoreData: \(session1.backendName)")
            XCTAssertTrue(session1.backendName.contains("Voice:"), "iOS session should be named with Voice: prefix")
        } else {
            XCTFail("Session should exist in Client 1 CoreData")
        }

        // Wait a bit for Client 2 to persist the session
        Thread.sleep(forTimeInterval: 1.0)

        if let session2 = fetchSession(id: sessionId, from: context2) {
            print("✅ Session exists in Client 2 CoreData: \(session2.backendName)")
            XCTAssertTrue(session2.backendName.contains("Voice:"), "iOS session should be named with Voice: prefix")
        } else {
            XCTFail("Session should exist in Client 2 CoreData")
        }

        // Verify .jsonl file was created on backend
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let projectsDir = homeDir.appendingPathComponent(".claude/projects")

        var fileExists = false
        if let enumerator = FileManager.default.enumerator(at: projectsDir, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                if fileURL.lastPathComponent.contains(sessionId.uuidString) {
                    fileExists = true
                    print("✅ Backend created .jsonl file: \(fileURL.path)")
                    break
                }
            }
        }

        XCTAssertTrue(fileExists, "Backend should create .jsonl file for iOS session")

        // Cleanup
        cleanupTestSession(sessionId: sessionId)
    }

    func testIOSSessionUpdatesSyncToOtherClient() {
        let connectExpectation = XCTestExpectation(description: "Both clients connect")
        let initialPromptExpectation = XCTestExpectation(description: "Initial prompt sent")
        let sessionUpdatedExpectation = XCTestExpectation(description: "Client 2 receives session_updated")

        let sessionId = UUID()

        // Connect both clients
        client1.connect()
        client2.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            XCTAssertTrue(self.client1.isConnected)
            XCTAssertTrue(self.client2.isConnected)
            connectExpectation.fulfill()

            print("🚀 Creating initial iOS session")

            // Client 1 creates session
            self.client1.subscribe(sessionId: sessionId.uuidString)
            self.client1.sendPrompt(
                "Initial message",
                newSessionId: sessionId.uuidString,
                workingDirectory: self.testWorkingDir
            )

            // Wait for session to be created
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                initialPromptExpectation.fulfill()

                // Client 2 subscribes to the session
                print("📖 Client 2 subscribing to session")
                self.client2.subscribe(sessionId: sessionId.uuidString)

                // Wait for history to load
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    let messages2Before = self.fetchMessages(sessionId: sessionId, from: self.context2)
                    let countBefore = messages2Before.count
                    print("📊 Client 2 initial message count: \(countBefore)")

                    // Client 1 sends another message
                    print("📤 Client 1 sending resume prompt")
                    self.client1.sendPrompt(
                        "E2E test: This update should appear on Client 2",
                        resumeSessionId: sessionId.uuidString,
                        workingDirectory: self.testWorkingDir
                    )

                    // Wait for session_updated to reach Client 2
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                        let messages2After = self.fetchMessages(sessionId: sessionId, from: self.context2)
                        let countAfter = messages2After.count

                        print("📊 Client 2 updated message count: \(countAfter)")
                        XCTAssertGreaterThan(countAfter, countBefore,
                                            "Client 2 should receive new messages from Client 1")

                        // Find the update message
                        let updateMessage = messages2After.first { $0.text.contains("This update should appear on Client 2") }
                        XCTAssertNotNil(updateMessage, "Should find the update message on Client 2")

                        if let msg = updateMessage {
                            print("✅ Client 2 received update: \(msg.text)")
                        }

                        sessionUpdatedExpectation.fulfill()
                    }
                }
            }
        }

        wait(for: [connectExpectation, initialPromptExpectation, sessionUpdatedExpectation], timeout: 120.0)

        // Cleanup
        cleanupTestSession(sessionId: sessionId)
    }

    // MARK: - Optimistic UI Tests

    func testOptimisticUIWithRealBackend() {
        let connectExpectation = XCTestExpectation(description: "Connect")
        let optimisticReconcileExpectation = XCTestExpectation(description: "Optimistic message reconciled")

        let sessionId = UUID()
        let promptText = "E2E optimistic UI test prompt"

        client1.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            XCTAssertTrue(self.client1.isConnected)
            connectExpectation.fulfill()

            // Create optimistic message locally
            let optimisticMessage = CDMessage(context: self.context1)
            optimisticMessage.id = UUID()
            optimisticMessage.sessionId = sessionId
            optimisticMessage.role = "user"
            optimisticMessage.text = promptText
            optimisticMessage.timestamp = Date()
            optimisticMessage.status = "sending"

            // Create session if needed
            let session = CDSession(context: self.context1)
            session.id = sessionId
            session.backendName = "Optimistic Test Session"
            session.workingDirectory = self.testWorkingDir
            session.lastModified = Date()
            session.messageCount = 1
            session.preview = promptText
            session.markedDeleted = false

            try? self.context1.save()

            print("✅ Created optimistic message with status: sending")

            // Subscribe and send prompt
            self.client1.subscribe(sessionId: sessionId.uuidString)
            self.client1.sendPrompt(
                promptText,
                newSessionId: sessionId.uuidString,
                workingDirectory: self.testWorkingDir
            )

            // Wait for backend to respond
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
                let messages = self.fetchMessages(sessionId: sessionId, from: self.context1)

                // Should have the message (reconciled from optimistic)
                let userMessages = messages.filter { $0.text == promptText && $0.role == "user" }
                XCTAssertEqual(userMessages.count, 1, "Should have exactly one copy of the message (no duplicates)")

                if let reconciledMessage = userMessages.first {
                    // Status should be updated from "sending" to "confirmed"
                    print("✅ Message status after reconciliation: \(reconciledMessage.status)")
                    XCTAssertEqual(reconciledMessage.status, "confirmed",
                                  "Optimistic message should be reconciled to confirmed")
                }

                optimisticReconcileExpectation.fulfill()
            }
        }

        wait(for: [connectExpectation, optimisticReconcileExpectation], timeout: 60.0)

        // Cleanup
        cleanupTestSession(sessionId: sessionId)
    }

    // MARK: - Session Naming Tests

    func testIOSSessionNaming() {
        let connectExpectation = XCTestExpectation(description: "Connect")
        let sessionCreatedExpectation = XCTestExpectation(description: "Session created")

        let sessionId = UUID()

        client1.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            XCTAssertTrue(self.client1.isConnected)
            connectExpectation.fulfill()

            // Create iOS session
            self.client1.subscribe(sessionId: sessionId.uuidString)
            self.client1.sendPrompt(
                "iOS session naming test",
                newSessionId: sessionId.uuidString,
                workingDirectory: self.testWorkingDir
            )

            // Wait for session creation
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                if let session = self.fetchSession(id: sessionId, from: self.context1) {
                    print("📝 Session name: \(session.backendName)")

                    // iOS sessions should have "Voice:" prefix
                    XCTAssertTrue(session.backendName.hasPrefix("Voice:"),
                                 "iOS sessions should be named with 'Voice:' prefix")

                    // Should contain working directory name
                    XCTAssertTrue(session.backendName.contains("e2e-tests") ||
                                session.backendName.contains("tmp"),
                                "Session name should contain working directory")

                    // Should have timestamp
                    XCTAssertTrue(session.backendName.contains("-") || session.backendName.contains(":"),
                                "Session name should contain timestamp separator")
                } else {
                    XCTFail("Session should exist in CoreData")
                }

                sessionCreatedExpectation.fulfill()
            }
        }

        wait(for: [connectExpectation, sessionCreatedExpectation], timeout: 60.0)

        // Cleanup
        cleanupTestSession(sessionId: sessionId)
    }

    // MARK: - Multiple Messages Test

    func testMultipleMessagesSync() {
        let connectExpectation = XCTestExpectation(description: "Connect")
        let allMessagesExpectation = XCTestExpectation(description: "All messages synced")

        let sessionId = UUID()
        let messageCount = 3

        client1.connect()
        client2.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            XCTAssertTrue(self.client1.isConnected)
            XCTAssertTrue(self.client2.isConnected)
            connectExpectation.fulfill()

            // Client 2 will subscribe to see all updates
            self.client2.subscribe(sessionId: sessionId.uuidString)

            // Client 1 creates session and sends multiple messages
            self.client1.subscribe(sessionId: sessionId.uuidString)

            // Send first message
            self.client1.sendPrompt(
                "Message 1",
                newSessionId: sessionId.uuidString,
                workingDirectory: self.testWorkingDir
            )

            // Send subsequent messages with delays
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
                self.client1.sendPrompt("Message 2", resumeSessionId: sessionId.uuidString)

                DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
                    self.client1.sendPrompt("Message 3", resumeSessionId: sessionId.uuidString)

                    // Wait for all to sync
                    DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
                        let messages1 = self.fetchMessages(sessionId: sessionId, from: self.context1)
                        let messages2 = self.fetchMessages(sessionId: sessionId, from: self.context2)

                        print("📊 Client 1 message count: \(messages1.count)")
                        print("📊 Client 2 message count: \(messages2.count)")

                        // Should have multiple messages (user + assistant responses)
                        XCTAssertGreaterThanOrEqual(messages1.count, messageCount,
                                                   "Client 1 should have at least \(messageCount) user messages")
                        XCTAssertGreaterThanOrEqual(messages2.count, messageCount,
                                                   "Client 2 should have at least \(messageCount) user messages")

                        // Both clients should have similar counts
                        XCTAssertEqual(messages1.count, messages2.count,
                                      "Both clients should have same message count")

                        allMessagesExpectation.fulfill()
                    }
                }
            }
        }

        wait(for: [connectExpectation, allMessagesExpectation], timeout: 180.0)

        // Cleanup
        cleanupTestSession(sessionId: sessionId)
    }
}
