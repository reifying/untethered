// E2ETerminalToIOSSyncTests.swift
// End-to-end tests for terminal session syncing to iOS (voice-code-97)
//
// Tests terminal sessions appearing on iOS via WebSocket broadcasts using
// REAL backend and REAL session data (~700 sessions).
//
// PREREQUISITES:
// - Backend running on localhost:8080
// - Claude CLI installed and authenticated
// - ~700 real sessions in ~/.claude/projects

import XCTest
import CoreData
@testable import VoiceCode

final class E2ETerminalToIOSSyncTests: XCTestCase {

    var client: VoiceCodeClient!
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!
    var syncManager: SessionSyncManager!

    let testServerURL = "ws://localhost:8080"
    let testWorkingDir = "/tmp/voice-code-e2e-tests"

    override func setUp() {
        super.setUp()

        // Create test working directory
        try? FileManager.default.createDirectory(atPath: testWorkingDir, withIntermediateDirectories: true)

        // Initialize CoreData with in-memory store
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext

        // Initialize sync manager
        syncManager = SessionSyncManager(persistenceController: persistenceController)

        // Initialize client
        client = VoiceCodeClient(serverURL: testServerURL)
        client.sessionSyncManager = syncManager
    }

    override func tearDown() {
        client?.disconnect()
        Thread.sleep(forTimeInterval: 0.2)
        client = nil
        syncManager = nil
        persistenceController = nil
        context = nil

        super.tearDown()
    }

    // MARK: - Helper Functions

    func fetchSession(id: UUID) -> CDSession? {
        let fetchRequest = CDSession.fetchSession(id: id)
        return try? context.fetch(fetchRequest).first
    }

    func fetchMessages(sessionId: UUID) -> [CDMessage] {
        let fetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
        return (try? context.fetch(fetchRequest)) ?? []
    }

    func cleanupTestSession(sessionId: UUID) {
        // Find and delete test session file
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

    // MARK: - Connection and Session List Tests

    func testReceiveRealSessionList() {
        let connectExpectation = XCTestExpectation(description: "Connect to backend")
        let sessionListExpectation = XCTestExpectation(description: "Receive session list")

        var receivedSessionCount = 0

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            XCTAssertTrue(self.client.isConnected, "Should connect to real backend")
            connectExpectation.fulfill()

            // Give time for session_list to be processed by syncManager
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                // Query CoreData for persisted sessions
                let fetchRequest = CDSession.fetchRequest()
                let sessions = try? self.context.fetch(fetchRequest)
                receivedSessionCount = sessions?.count ?? 0

                print("📊 Received \(receivedSessionCount) sessions from real backend")

                // Should have many real sessions (at least 500, ideally ~700)
                XCTAssertGreaterThan(receivedSessionCount, 500, "Should receive many real sessions")

                // Verify session metadata is populated
                if let firstSession = sessions?.first {
                    XCTAssertNotNil(firstSession.backendName, "Session should have name")
                    XCTAssertNotNil(firstSession.workingDirectory, "Session should have working directory")
                    XCTAssertGreaterThan(firstSession.messageCount, 0, "Session should have message count")

                    print("✅ Sample session: \(firstSession.backendName) - \(firstSession.messageCount) messages")
                }

                sessionListExpectation.fulfill()
            }
        }

        wait(for: [connectExpectation, sessionListExpectation], timeout: 10.0)
    }

    func testSubscribeToExistingRealSession() {
        let connectExpectation = XCTestExpectation(description: "Connect")
        let sessionListExpectation = XCTestExpectation(description: "Receive session list")
        let historyExpectation = XCTestExpectation(description: "Receive session history")

        var testSessionId: UUID?

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            XCTAssertTrue(self.client.isConnected)
            connectExpectation.fulfill()

            // Wait for session list to be persisted
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                sessionListExpectation.fulfill()

                // Get first real session from CoreData
                let fetchRequest = CDSession.fetchRequest()
                fetchRequest.sortDescriptors = [NSSortDescriptor(key: "lastModified", ascending: false)]
                fetchRequest.fetchLimit = 1

                guard let session = try? self.context.fetch(fetchRequest).first else {
                    XCTFail("Should have at least one session")
                    return
                }

                testSessionId = session.id
                print("📖 Subscribing to real session: \(session.backendName)")

                // Subscribe to get full history
                self.client.subscribe(sessionId: session.id.uuidString)

                // Wait for session_history
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    // Verify messages were loaded
                    let messages = self.fetchMessages(sessionId: session.id)

                    print("📚 Received \(messages.count) messages for session")
                    XCTAssertGreaterThan(messages.count, 0, "Should have messages from real session")

                    // Verify message structure
                    if let firstMessage = messages.first {
                        XCTAssertFalse(firstMessage.text.isEmpty, "Message should have text")
                        XCTAssertTrue(firstMessage.role == "user" || firstMessage.role == "assistant")
                        print("✅ Sample message: [\(firstMessage.role)] \(firstMessage.text.prefix(50))...")
                    }

                    historyExpectation.fulfill()
                }
            }
        }

        wait(for: [connectExpectation, sessionListExpectation, historyExpectation], timeout: 15.0)
    }

    // MARK: - New Session Creation Tests

    func testCreateNewTerminalSession() {
        let connectExpectation = XCTestExpectation(description: "Connect")
        let sessionCreatedExpectation = XCTestExpectation(description: "Session created broadcast")

        let sessionId = UUID()
        var sessionCreated = false

        // Set up listener for session_created
        let originalHandler = client.sessionSyncManager.handleSessionCreated
        client.sessionSyncManager.handleSessionCreated = { sessionData in
            originalHandler(sessionData)

            if let receivedId = sessionData["session_id"] as? String,
               receivedId == sessionId.uuidString {
                sessionCreated = true
                sessionCreatedExpectation.fulfill()
            }
        }

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            XCTAssertTrue(self.client.isConnected)
            connectExpectation.fulfill()

            print("🚀 Creating new terminal session: \(sessionId.uuidString)")

            // Run real Claude CLI to create session
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/local/bin/claude")
            process.arguments = [
                "--session-id", sessionId.uuidString,
                "-p",  // Print mode (non-interactive)
                "This is an E2E test session from E2ETerminalToIOSSyncTests. Please respond with 'E2E test confirmed' and nothing else."
            ]
            process.currentDirectoryURL = URL(fileURLWithPath: self.testWorkingDir)

            do {
                try process.run()
                print("✅ Claude CLI process started")

                // Note: This will cost money (Claude API call)
            } catch {
                XCTFail("Failed to run claude CLI: \(error)")
            }
        }

        wait(for: [connectExpectation, sessionCreatedExpectation], timeout: 60.0)

        // Verify session was created
        XCTAssertTrue(sessionCreated, "Should receive session_created broadcast")

        // Verify session exists in CoreData
        if let session = fetchSession(id: sessionId) {
            print("✅ Session persisted in CoreData: \(session.backendName)")
            XCTAssertTrue(session.backendName.contains("Terminal:"), "Should be named as terminal session")
            XCTAssertGreaterThan(session.messageCount, 0, "Should have at least one message")
        } else {
            XCTFail("Session should exist in CoreData")
        }

        // Cleanup
        cleanupTestSession(sessionId: sessionId)
    }

    func testTerminalPromptAppearsOnIOS() {
        let connectExpectation = XCTestExpectation(description: "Connect")
        let sessionUpdatedExpectation = XCTestExpectation(description: "Session updated")

        // Create initial session
        let sessionId = UUID()

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            XCTAssertTrue(self.client.isConnected)
            connectExpectation.fulfill()

            print("🚀 Creating initial session")

            // Create initial session via Claude CLI
            let createProcess = Process()
            createProcess.executableURL = URL(fileURLWithPath: "/usr/local/bin/claude")
            createProcess.arguments = [
                "--session-id", sessionId.uuidString,
                "-p",
                "Initial message"
            ]
            createProcess.currentDirectoryURL = URL(fileURLWithPath: self.testWorkingDir)

            try? createProcess.run()
            createProcess.waitUntilExit()

            // Subscribe to session
            print("📖 Subscribing to session")
            self.client.subscribe(sessionId: sessionId.uuidString)

            // Wait for subscription to complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                let initialMessages = self.fetchMessages(sessionId: sessionId)
                let initialCount = initialMessages.count
                print("📊 Initial message count: \(initialCount)")

                // Send another prompt from terminal
                print("📤 Sending resume prompt from terminal")
                let resumeProcess = Process()
                resumeProcess.executableURL = URL(fileURLWithPath: "/usr/local/bin/claude")
                resumeProcess.arguments = [
                    "--resume", sessionId.uuidString,
                    "-p",
                    "E2E test: This prompt should appear on iOS"
                ]
                resumeProcess.currentDirectoryURL = URL(fileURLWithPath: self.testWorkingDir)

                try? resumeProcess.run()

                // Wait for session_updated message
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    let updatedMessages = self.fetchMessages(sessionId: sessionId)

                    print("📊 Updated message count: \(updatedMessages.count)")
                    XCTAssertGreaterThan(updatedMessages.count, initialCount,
                                        "Should have new messages from terminal prompt")

                    // Find the new user message
                    let newMessages = updatedMessages.filter { $0.text.contains("E2E test: This prompt should appear on iOS") }
                    XCTAssertGreaterThan(newMessages.count, 0, "Should find the new terminal message")

                    if let newMessage = newMessages.first {
                        print("✅ Found new message: \(newMessage.text)")
                        XCTAssertEqual(newMessage.role, "user")
                    }

                    sessionUpdatedExpectation.fulfill()
                }
            }
        }

        wait(for: [connectExpectation, sessionUpdatedExpectation], timeout: 90.0)

        // Cleanup
        cleanupTestSession(sessionId: sessionId)
    }

    // MARK: - Session Metadata Tests

    func testSessionNamingConvention() {
        let expectation = XCTestExpectation(description: "Verify session names")

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            // Fetch all sessions
            let fetchRequest = CDSession.fetchRequest()
            guard let sessions = try? self.context.fetch(fetchRequest), !sessions.isEmpty else {
                XCTFail("Should have sessions")
                return
            }

            print("📊 Analyzing \(sessions.count) session names")

            // Count terminal vs voice sessions
            let terminalSessions = sessions.filter { $0.backendName.hasPrefix("Terminal:") }
            let voiceSessions = sessions.filter { $0.backendName.hasPrefix("Voice:") }

            print("📊 Terminal sessions: \(terminalSessions.count)")
            print("📊 Voice sessions: \(voiceSessions.count)")

            // All sessions should have proper naming
            for session in sessions {
                XCTAssertFalse(session.backendName.isEmpty, "Session should have a name")
                XCTAssertTrue(session.backendName.contains(":") || session.backendName.contains("fork"),
                            "Session name should follow convention: \(session.backendName)")
            }

            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10.0)
    }

    func testSessionMetadataAccuracy() {
        let expectation = XCTestExpectation(description: "Verify metadata accuracy")

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            let fetchRequest = CDSession.fetchRequest()
            fetchRequest.fetchLimit = 10
            guard let sessions = try? self.context.fetch(fetchRequest) else {
                XCTFail("Should be able to fetch sessions")
                return
            }

            for session in sessions {
                // All sessions should have required fields
                XCTAssertNotNil(session.id, "Should have ID")
                XCTAssertFalse(session.backendName.isEmpty, "Should have name")
                XCTAssertFalse(session.workingDirectory.isEmpty, "Should have working directory")
                XCTAssertNotNil(session.lastModified, "Should have last modified date")
                XCTAssertGreaterThanOrEqual(session.messageCount, 0, "Should have valid message count")

                // Preview can be empty for new sessions
                // But should not be nil
                XCTAssertNotNil(session.preview)

                print("✅ Session metadata valid: \(session.backendName)")
            }

            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10.0)
    }
}
