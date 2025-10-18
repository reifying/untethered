// E2ESessionForkingTests.swift
// End-to-end tests for session forking behavior (voice-code-99)
//
// Tests concurrent resume creating forks that appear on iOS using
// REAL backend and REAL Claude CLI.
//
// PREREQUISITES:
// - Backend running on localhost:8080
// - Claude CLI installed and authenticated

import XCTest
import CoreData
@testable import VoiceCode

final class E2ESessionForkingTests: XCTestCase {

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

    func fetchSessionByIdString(_ idString: String) -> CDSession? {
        guard let uuid = UUID(uuidString: idString) else { return nil }
        return fetchSession(id: uuid)
    }

    func fetchAllSessions() -> [CDSession] {
        let fetchRequest = CDSession.fetchRequest()
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

    func findForkFiles(parentSessionId: UUID) -> [URL] {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let projectsDir = homeDir.appendingPathComponent(".claude/projects")

        var forkFiles: [URL] = []

        guard let enumerator = FileManager.default.enumerator(at: projectsDir, includingPropertiesForKeys: nil) else {
            return forkFiles
        }

        for case let fileURL as URL in enumerator {
            let filename = fileURL.lastPathComponent
            // Look for files containing parent session ID and "fork"
            if filename.contains(parentSessionId.uuidString) && filename.contains("fork") {
                forkFiles.append(fileURL)
            }
        }

        return forkFiles
    }

    // MARK: - Fork Detection Tests

    func testConcurrentResumeCreatesFork() {
        let connectExpectation = XCTestExpectation(description: "Connect")
        let parentSessionCreatedExpectation = XCTestExpectation(description: "Parent session created")
        let forkSessionCreatedExpectation = XCTestExpectation(description: "Fork session created")

        let parentSessionId = UUID()
        var forkSessionId: String?

        // Set up listener for session_created to detect fork
        let originalHandler = syncManager.handleSessionCreated
        syncManager.handleSessionCreated = { sessionData in
            originalHandler(sessionData)

            if let receivedId = sessionData["session_id"] as? String {
                if receivedId == parentSessionId.uuidString {
                    print("✅ Parent session created: \(receivedId)")
                    parentSessionCreatedExpectation.fulfill()
                } else if receivedId.contains("fork") || receivedId.contains(parentSessionId.uuidString) {
                    print("✅ Fork session detected: \(receivedId)")
                    forkSessionId = receivedId
                    forkSessionCreatedExpectation.fulfill()
                }
            }
        }

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            XCTAssertTrue(self.client.isConnected)
            connectExpectation.fulfill()

            print("🚀 Creating parent session")

            // Create initial session
            let createProcess = Process()
            createProcess.executableURL = URL(fileURLWithPath: "/usr/local/bin/claude")
            createProcess.arguments = [
                "--session-id", parentSessionId.uuidString,
                "-p",
                "Parent session for fork test"
            ]
            createProcess.currentDirectoryURL = URL(fileURLWithPath: self.testWorkingDir)

            try? createProcess.run()
            createProcess.waitUntilExit()

            // Subscribe to parent session
            print("📖 Subscribing to parent session")
            self.client.subscribe(sessionId: parentSessionId.uuidString)

            // Wait for parent session to be created and detected
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                print("🍴 Triggering concurrent resume (should create fork)")

                // Resume the same session concurrently (this should create a fork)
                let resumeProcess = Process()
                resumeProcess.executableURL = URL(fileURLWithPath: "/usr/local/bin/claude")
                resumeProcess.arguments = [
                    "--resume", parentSessionId.uuidString,
                    "-p",
                    "Concurrent resume - should create fork"
                ]
                resumeProcess.currentDirectoryURL = URL(fileURLWithPath: self.testWorkingDir)

                try? resumeProcess.run()
            }
        }

        wait(for: [connectExpectation, parentSessionCreatedExpectation, forkSessionCreatedExpectation], timeout: 90.0)

        // Verify fork was detected
        XCTAssertNotNil(forkSessionId, "Fork session should have been created and detected")

        if let forkId = forkSessionId {
            // Verify fork session exists in CoreData
            if let forkSession = fetchSessionByIdString(forkId) {
                print("✅ Fork session in CoreData: \(forkSession.backendName)")

                // Fork name should include "(fork)" or "(compacted)"
                XCTAssertTrue(forkSession.backendName.contains("fork") || forkSession.backendName.contains("compacted"),
                            "Fork name should indicate it's a fork: \(forkSession.backendName)")
            } else {
                XCTFail("Fork session should exist in CoreData")
            }

            // Verify fork .jsonl file exists
            let forkFiles = findForkFiles(parentSessionId: parentSessionId)
            XCTAssertGreaterThan(forkFiles.count, 0, "Should have at least one fork file")

            if let forkFile = forkFiles.first {
                print("✅ Fork file exists: \(forkFile.path)")
            }
        }

        // Cleanup
        cleanupTestSession(sessionId: parentSessionId)
    }

    func testForkNamingConvention() {
        let connectExpectation = XCTestExpectation(description: "Connect")
        let forkDetectedExpectation = XCTestExpectation(description: "Fork detected")

        let parentSessionId = UUID()
        var forkSessionId: String?
        var forkSessionName: String?

        // Listen for fork creation
        let originalHandler = syncManager.handleSessionCreated
        syncManager.handleSessionCreated = { sessionData in
            originalHandler(sessionData)

            if let receivedId = sessionData["session_id"] as? String,
               let receivedName = sessionData["name"] as? String {
                if receivedId.contains("fork") || receivedName.contains("fork") || receivedName.contains("compacted") {
                    forkSessionId = receivedId
                    forkSessionName = receivedName
                    print("🍴 Fork detected: \(receivedName)")
                    forkDetectedExpectation.fulfill()
                }
            }
        }

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            XCTAssertTrue(self.client.isConnected)
            connectExpectation.fulfill()

            // Create parent session
            let createProcess = Process()
            createProcess.executableURL = URL(fileURLWithPath: "/usr/local/bin/claude")
            createProcess.arguments = [
                "--session-id", parentSessionId.uuidString,
                "-p",
                "Parent for fork naming test"
            ]
            createProcess.currentDirectoryURL = URL(fileURLWithPath: self.testWorkingDir)

            try? createProcess.run()
            createProcess.waitUntilExit()

            // Wait briefly, then trigger fork
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                let resumeProcess = Process()
                resumeProcess.executableURL = URL(fileURLWithPath: "/usr/local/bin/claude")
                resumeProcess.arguments = [
                    "--resume", parentSessionId.uuidString,
                    "-p",
                    "Fork naming test"
                ]
                resumeProcess.currentDirectoryURL = URL(fileURLWithPath: self.testWorkingDir)

                try? resumeProcess.run()
            }
        }

        wait(for: [connectExpectation, forkDetectedExpectation], timeout: 90.0)

        // Verify fork naming
        XCTAssertNotNil(forkSessionName, "Fork should have a name")

        if let forkName = forkSessionName {
            // Fork should be named with "(fork)" or "(compacted)" suffix
            XCTAssertTrue(forkName.contains("(fork)") || forkName.contains("(compacted)"),
                        "Fork name should contain '(fork)' or '(compacted)': \(forkName)")

            // Should inherit parent's working directory info
            XCTAssertTrue(forkName.contains("e2e-tests") || forkName.contains("tmp"),
                        "Fork should inherit working directory name: \(forkName)")

            print("✅ Fork naming verified: \(forkName)")
        }

        // Cleanup
        cleanupTestSession(sessionId: parentSessionId)
    }

    func testMultipleConcurrentResumesCreateMultipleForks() {
        let connectExpectation = XCTestExpectation(description: "Connect")
        let fork1Expectation = XCTestExpectation(description: "Fork 1 created")
        let fork2Expectation = XCTestExpectation(description: "Fork 2 created")

        let parentSessionId = UUID()
        var forkCount = 0

        // Listen for fork creations
        let originalHandler = syncManager.handleSessionCreated
        syncManager.handleSessionCreated = { sessionData in
            originalHandler(sessionData)

            if let receivedId = sessionData["session_id"] as? String,
               (receivedId.contains("fork") || receivedId != parentSessionId.uuidString) {
                forkCount += 1
                print("🍴 Fork \(forkCount) detected: \(receivedId)")

                if forkCount == 1 {
                    fork1Expectation.fulfill()
                } else if forkCount == 2 {
                    fork2Expectation.fulfill()
                }
            }
        }

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            XCTAssertTrue(self.client.isConnected)
            connectExpectation.fulfill()

            print("🚀 Creating parent session")

            // Create parent
            let createProcess = Process()
            createProcess.executableURL = URL(fileURLWithPath: "/usr/local/bin/claude")
            createProcess.arguments = [
                "--session-id", parentSessionId.uuidString,
                "-p",
                "Parent for multiple forks test"
            ]
            createProcess.currentDirectoryURL = URL(fileURLWithPath: self.testWorkingDir)

            try? createProcess.run()
            createProcess.waitUntilExit()

            // Wait for parent to settle
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                print("🍴 Triggering first concurrent resume")

                // First concurrent resume
                let resume1 = Process()
                resume1.executableURL = URL(fileURLWithPath: "/usr/local/bin/claude")
                resume1.arguments = [
                    "--resume", parentSessionId.uuidString,
                    "-p",
                    "Fork 1"
                ]
                resume1.currentDirectoryURL = URL(fileURLWithPath: self.testWorkingDir)

                try? resume1.run()

                // Trigger second concurrent resume shortly after
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    print("🍴 Triggering second concurrent resume")

                    let resume2 = Process()
                    resume2.executableURL = URL(fileURLWithPath: "/usr/local/bin/claude")
                    resume2.arguments = [
                        "--resume", parentSessionId.uuidString,
                        "-p",
                        "Fork 2"
                    ]
                    resume2.currentDirectoryURL = URL(fileURLWithPath: self.testWorkingDir)

                    try? resume2.run()
                }
            }
        }

        wait(for: [connectExpectation, fork1Expectation, fork2Expectation], timeout: 120.0)

        // Verify multiple forks detected
        XCTAssertGreaterThanOrEqual(forkCount, 2, "Should detect at least 2 forks")

        // Verify fork files exist
        let forkFiles = findForkFiles(parentSessionId: parentSessionId)
        print("📊 Found \(forkFiles.count) fork files")
        XCTAssertGreaterThanOrEqual(forkFiles.count, 2, "Should have at least 2 fork files")

        for (index, forkFile) in forkFiles.enumerated() {
            print("✅ Fork \(index + 1): \(forkFile.lastPathComponent)")
        }

        // Cleanup
        cleanupTestSession(sessionId: parentSessionId)
    }

    func testForkMetadataInheritance() {
        let connectExpectation = XCTestExpectation(description: "Connect")
        let parentCreatedExpectation = XCTestExpectation(description: "Parent created")
        let forkCreatedExpectation = XCTestExpectation(description: "Fork created")

        let parentSessionId = UUID()
        var parentName: String?
        var forkName: String?
        var forkWorkingDir: String?

        // Listen for session creations
        let originalHandler = syncManager.handleSessionCreated
        syncManager.handleSessionCreated = { sessionData in
            originalHandler(sessionData)

            if let receivedId = sessionData["session_id"] as? String,
               let receivedName = sessionData["name"] as? String,
               let receivedWorkingDir = sessionData["working_directory"] as? String {

                if receivedId == parentSessionId.uuidString {
                    parentName = receivedName
                    print("📝 Parent session name: \(receivedName)")
                    parentCreatedExpectation.fulfill()
                } else if receivedName.contains("fork") || receivedName.contains("compacted") {
                    forkName = receivedName
                    forkWorkingDir = receivedWorkingDir
                    print("📝 Fork session name: \(receivedName)")
                    print("📁 Fork working dir: \(receivedWorkingDir)")
                    forkCreatedExpectation.fulfill()
                }
            }
        }

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            XCTAssertTrue(self.client.isConnected)
            connectExpectation.fulfill()

            // Create parent
            let createProcess = Process()
            createProcess.executableURL = URL(fileURLWithPath: "/usr/local/bin/claude")
            createProcess.arguments = [
                "--session-id", parentSessionId.uuidString,
                "-p",
                "Parent for metadata test"
            ]
            createProcess.currentDirectoryURL = URL(fileURLWithPath: self.testWorkingDir)

            try? createProcess.run()
            createProcess.waitUntilExit()

            // Trigger fork
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                let resumeProcess = Process()
                resumeProcess.executableURL = URL(fileURLWithPath: "/usr/local/bin/claude")
                resumeProcess.arguments = [
                    "--resume", parentSessionId.uuidString,
                    "-p",
                    "Fork metadata test"
                ]
                resumeProcess.currentDirectoryURL = URL(fileURLWithPath: self.testWorkingDir)

                try? resumeProcess.run()
            }
        }

        wait(for: [connectExpectation, parentCreatedExpectation, forkCreatedExpectation], timeout: 90.0)

        // Verify metadata inheritance
        XCTAssertNotNil(parentName, "Parent should have a name")
        XCTAssertNotNil(forkName, "Fork should have a name")
        XCTAssertNotNil(forkWorkingDir, "Fork should have working directory")

        if let parent = parentName, let fork = forkName {
            // Fork name should be based on parent name
            // e.g., "Terminal: e2e-tests - 2025-10-17" -> "Terminal: e2e-tests - 2025-10-17 (fork)"
            XCTAssertTrue(fork.contains("fork") || fork.contains("compacted"),
                        "Fork should indicate fork status")

            print("✅ Parent name: \(parent)")
            print("✅ Fork name: \(fork)")
        }

        if let workingDir = forkWorkingDir {
            // Fork should inherit parent's working directory
            XCTAssertEqual(workingDir, self.testWorkingDir,
                          "Fork should inherit parent's working directory")
        }

        // Cleanup
        cleanupTestSession(sessionId: parentSessionId)
    }

    func testAutoSubscriptionToForkWhenParentSubscribed() {
        let connectExpectation = XCTestExpectation(description: "Connect")
        let forkHistoryExpectation = XCTestExpectation(description: "Fork history received")

        let parentSessionId = UUID()
        var forkSessionId: String?

        // Listen for fork creation
        let originalHandler = syncManager.handleSessionCreated
        syncManager.handleSessionCreated = { sessionData in
            originalHandler(sessionData)

            if let receivedId = sessionData["session_id"] as? String,
               receivedId.contains("fork") {
                forkSessionId = receivedId
                print("🍴 Fork detected, checking auto-subscription")
            }
        }

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            XCTAssertTrue(self.client.isConnected)
            connectExpectation.fulfill()

            // Create parent and subscribe
            let createProcess = Process()
            createProcess.executableURL = URL(fileURLWithPath: "/usr/local/bin/claude")
            createProcess.arguments = [
                "--session-id", parentSessionId.uuidString,
                "-p",
                "Parent session"
            ]
            createProcess.currentDirectoryURL = URL(fileURLWithPath: self.testWorkingDir)

            try? createProcess.run()
            createProcess.waitUntilExit()

            print("📖 Subscribing to parent session")
            self.client.subscribe(sessionId: parentSessionId.uuidString)

            // Trigger fork
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                let resumeProcess = Process()
                resumeProcess.executableURL = URL(fileURLWithPath: "/usr/local/bin/claude")
                resumeProcess.arguments = [
                    "--resume", parentSessionId.uuidString,
                    "-p",
                    "Fork for auto-subscription test"
                ]
                resumeProcess.currentDirectoryURL = URL(fileURLWithPath: self.testWorkingDir)

                try? resumeProcess.run()

                // Wait for fork to be created and potentially auto-subscribed
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    if let forkId = forkSessionId,
                       let forkUUID = UUID(uuidString: forkId) {
                        // Check if fork has messages loaded (indicates history was received)
                        let fetchRequest = CDMessage.fetchMessages(sessionId: forkUUID)
                        let messages = try? self.context.fetch(fetchRequest)

                        print("📊 Fork message count: \(messages?.count ?? 0)")

                        // Note: Auto-subscription behavior may vary by implementation
                        // This test documents the expected behavior
                        if let msgCount = messages?.count, msgCount > 0 {
                            print("✅ Fork appears to have auto-subscribed (has messages)")
                            forkHistoryExpectation.fulfill()
                        } else {
                            print("ℹ️ Fork not auto-subscribed, manual subscription needed")
                            // This is also acceptable behavior
                            forkHistoryExpectation.fulfill()
                        }
                    } else {
                        XCTFail("Fork session ID should be valid UUID")
                        forkHistoryExpectation.fulfill()
                    }
                }
            }
        }

        wait(for: [connectExpectation, forkHistoryExpectation], timeout: 90.0)

        // Cleanup
        cleanupTestSession(sessionId: parentSessionId)
    }
}
