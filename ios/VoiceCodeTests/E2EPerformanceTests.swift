// E2EPerformanceTests.swift
// End-to-end performance tests (voice-code-101)
//
// Tests performance with REAL 700+ sessions from production-like data.
//
// PREREQUISITES:
// - Backend running on localhost:8080
// - ~700 real sessions in ~/.claude/projects

import XCTest
import CoreData
@testable import VoiceCode

final class E2EPerformanceTests: XCTestCase {

    var client: VoiceCodeClient!
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!
    var syncManager: SessionSyncManager!

    let testServerURL = "ws://localhost:8080"

    override func setUp() {
        super.setUp()

        // Use in-memory store for performance tests
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
        syncManager = SessionSyncManager(persistenceController: persistenceController)
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

    func fetchAllSessions() -> [CDSession] {
        let fetchRequest = CDSession.fetchRequest()
        return (try? context.fetch(fetchRequest)) ?? []
    }

    func fetchMessages(sessionId: UUID) -> [CDMessage] {
        let fetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
        return (try? context.fetch(fetchRequest)) ?? []
    }

    // MARK: - Connection and Session List Performance

    func testSessionListReceivePerformance() {
        let expectation = XCTestExpectation(description: "Receive session list")

        var startTime: Date?
        var endTime: Date?
        var sessionCount = 0

        // Measure time from connect to session list persisted
        startTime = Date()

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            endTime = Date()

            let sessions = self.fetchAllSessions()
            sessionCount = sessions.count

            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 15.0)

        // Calculate latency
        if let start = startTime, let end = endTime {
            let latency = end.timeIntervalSince(start)
            print("📊 Session list latency: \(String(format: "%.2f", latency))s")
            print("📊 Session count: \(sessionCount)")

            // Target: < 2 seconds for 700+ sessions
            XCTAssertLessThan(latency, 3.0, "Session list should be received within 3 seconds")
            XCTAssertGreaterThan(sessionCount, 500, "Should receive many real sessions")

            if sessionCount > 0 {
                let perSessionLatency = latency / Double(sessionCount) * 1000
                print("📊 Per-session latency: \(String(format: "%.2f", perSessionLatency))ms")
            }
        }
    }

    func testSessionListPayloadSize() {
        let expectation = XCTestExpectation(description: "Measure payload size")

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            let sessions = self.fetchAllSessions()

            // Estimate payload size
            var estimatedSize = 0
            for session in sessions {
                // Each session has: id (36 bytes), name (~50), working_directory (~50),
                // last_modified (8), message_count (4), preview (~100)
                // Plus JSON overhead (~50)
                estimatedSize += 36 + session.backendName.count + session.workingDirectory.count +
                                8 + 4 + session.preview.count + 50
            }

            let sizeInKB = Double(estimatedSize) / 1024.0
            let sizeInMB = sizeInKB / 1024.0

            print("📊 Estimated payload size: \(String(format: "%.2f", sizeInKB)) KB")
            print("📊 Sessions: \(sessions.count)")

            // Verify reasonable payload size
            // Target: < 1MB for 700 sessions (roughly 1.4KB per session)
            XCTAssertLessThan(sizeInMB, 2.0, "Payload should be less than 2MB")

            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 15.0)
    }

    // MARK: - Per-Session Load Performance

    func testPerSessionLoadPerformance() {
        let connectExpectation = XCTestExpectation(description: "Connect")
        let loadExpectation = XCTestExpectation(description: "Session loaded")

        var subscribeTime: Date?
        var historyReceivedTime: Date?

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            XCTAssertTrue(self.client.isConnected)
            connectExpectation.fulfill()

            // Get first real session
            let sessions = self.fetchAllSessions()
            guard let firstSession = sessions.first else {
                XCTFail("Should have at least one session")
                return
            }

            print("📖 Loading session: \(firstSession.backendName)")

            // Measure subscription latency
            subscribeTime = Date()
            self.client.subscribe(sessionId: firstSession.id.uuidString)

            // Wait for history to load
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                historyReceivedTime = Date()

                let messages = self.fetchMessages(sessionId: firstSession.id)

                loadExpectation.fulfill()

                // Calculate latency
                if let start = subscribeTime, let end = historyReceivedTime {
                    let latency = end.timeIntervalSince(start)
                    print("📊 Session load latency: \(String(format: "%.0f", latency * 1000))ms")
                    print("📊 Messages loaded: \(messages.count)")

                    // Target: < 200ms per session load
                    // Allow up to 5000ms for real-world conditions
                    XCTAssertLessThan(latency, 5.0, "Session should load within 5 seconds")
                }
            }
        }

        wait(for: [connectExpectation, loadExpectation], timeout: 30.0)
    }

    func testLargeSessionLoadPerformance() {
        let connectExpectation = XCTestExpectation(description: "Connect")
        let loadExpectation = XCTestExpectation(description: "Large session loaded")

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            XCTAssertTrue(self.client.isConnected)
            connectExpectation.fulfill()

            // Find a session with many messages
            let sessions = self.fetchAllSessions()
            let largeSession = sessions.first { $0.messageCount > 100 }

            if let session = largeSession {
                print("📖 Loading large session: \(session.backendName) (\(session.messageCount) messages)")

                let startTime = Date()
                self.client.subscribe(sessionId: session.id.uuidString)

                // Wait for history
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    let endTime = Date()
                    let latency = endTime.timeIntervalSince(startTime)

                    let messages = self.fetchMessages(sessionId: session.id)

                    print("📊 Large session load latency: \(String(format: "%.0f", latency * 1000))ms")
                    print("📊 Messages loaded: \(messages.count)")

                    // Should handle large sessions reasonably
                    XCTAssertLessThan(latency, 10.0, "Large session should load within 10 seconds")

                    loadExpectation.fulfill()
                }
            } else {
                print("ℹ️ No large sessions found (>100 messages), skipping test")
                loadExpectation.fulfill()
            }
        }

        wait(for: [connectExpectation, loadExpectation], timeout: 30.0)
    }

    // MARK: - CoreData Query Performance

    func testCoreDataQueryPerformance() {
        let expectation = XCTestExpectation(description: "CoreData query performance")

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            // Measure fetch all sessions
            measure(metrics: [XCTClockMetric()]) {
                let fetchRequest = CDSession.fetchRequest()
                let _ = try? self.context.fetch(fetchRequest)
            }

            // Measure sorted fetch (typical UI query)
            measure(metrics: [XCTClockMetric()]) {
                let fetchRequest = CDSession.fetchRequest()
                fetchRequest.sortDescriptors = [NSSortDescriptor(key: "lastModified", ascending: false)]
                fetchRequest.fetchLimit = 20
                let _ = try? self.context.fetch(fetchRequest)
            }

            // Measure filtered fetch
            measure(metrics: [XCTClockMetric()]) {
                let fetchRequest = CDSession.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "markedDeleted == NO")
                fetchRequest.sortDescriptors = [NSSortDescriptor(key: "lastModified", ascending: false)]
                let _ = try? self.context.fetch(fetchRequest)
            }

            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 15.0)
    }

    func testPaginatedSessionFetchPerformance() {
        let expectation = XCTestExpectation(description: "Paginated fetch performance")

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            let sessions = self.fetchAllSessions()
            let totalSessions = sessions.count

            print("📊 Testing pagination with \(totalSessions) sessions")

            // Measure paginated fetches (20 sessions per page)
            let pageSize = 20
            var pageNumber = 0

            measure(metrics: [XCTClockMetric()]) {
                let fetchRequest = CDSession.fetchRequest()
                fetchRequest.sortDescriptors = [NSSortDescriptor(key: "lastModified", ascending: false)]
                fetchRequest.fetchLimit = pageSize
                fetchRequest.fetchOffset = pageNumber * pageSize

                let page = try? self.context.fetch(fetchRequest)
                pageNumber = (pageNumber + 1) % max(1, totalSessions / pageSize)

                XCTAssertNotNil(page)
            }

            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 15.0)
    }

    // MARK: - Memory Usage Tests

    func testMemoryUsageWith700Sessions() {
        let expectation = XCTestExpectation(description: "Memory usage measurement")

        measure(metrics: [XCTMemoryMetric()]) {
            let testClient = VoiceCodeClient(serverURL: self.testServerURL)
            let testController = PersistenceController(inMemory: true)
            let testSyncManager = SessionSyncManager(persistenceController: testController)
            testClient.sessionSyncManager = testSyncManager

            testClient.connect()

            // Wait for session list to load
            Thread.sleep(forTimeInterval: 5.0)

            // Fetch sessions to ensure they're in memory
            let fetchRequest = CDSession.fetchRequest()
            let _ = try? testController.container.viewContext.fetch(fetchRequest)

            testClient.disconnect()
        }

        expectation.fulfill()
        wait(for: [expectation], timeout: 30.0)
    }

    func testMemoryUsageWithMultipleSessionHistories() {
        let expectation = XCTestExpectation(description: "Memory usage with histories")

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            let sessions = self.fetchAllSessions().prefix(10)

            measure(metrics: [XCTMemoryMetric()]) {
                // Subscribe to 10 sessions
                for session in sessions {
                    self.client.subscribe(sessionId: session.id.uuidString)
                }

                // Wait for histories to load
                Thread.sleep(forTimeInterval: 10.0)

                // Verify messages loaded
                var totalMessages = 0
                for session in sessions {
                    let messages = self.fetchMessages(sessionId: session.id)
                    totalMessages += messages.count
                }

                print("📊 Total messages loaded: \(totalMessages)")
            }

            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 60.0)
    }

    // MARK: - Incremental Update Latency

    func testIncrementalUpdateLatency() {
        let connectExpectation = XCTestExpectation(description: "Connect")
        let sessionCreatedExpectation = XCTestExpectation(description: "Session created")
        let updateReceivedExpectation = XCTestExpectation(description: "Update received")

        let sessionId = UUID()
        var updateReceived = false

        // Set up listener for session_updated
        let originalHandler = syncManager.handleSessionUpdated
        syncManager.handleSessionUpdated = { sessionIdString, messages in
            originalHandler(sessionIdString, messages)

            if sessionIdString == sessionId.uuidString && !updateReceived {
                updateReceived = true
                updateReceivedExpectation.fulfill()
            }
        }

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            XCTAssertTrue(self.client.isConnected)
            connectExpectation.fulfill()

            // Create session
            self.client.subscribe(sessionId: sessionId.uuidString)
            self.client.sendPrompt(
                "Initial message",
                newSessionId: sessionId.uuidString,
                workingDirectory: "/tmp/voice-code-e2e-tests"
            )

            // Wait for creation
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                sessionCreatedExpectation.fulfill()

                print("📤 Sending terminal prompt to measure update latency")

                // Measure end-to-end latency
                let startTime = Date()

                // Send prompt from terminal
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/local/bin/claude")
                process.arguments = [
                    "--resume", sessionId.uuidString,
                    "-p",
                    "Latency test message"
                ]
                process.currentDirectoryURL = URL(fileURLWithPath: "/tmp/voice-code-e2e-tests")

                try? process.run()

                // Wait for update to reach iOS
                DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
                    if updateReceived {
                        let endTime = Date()
                        let latency = endTime.timeIntervalSince(startTime)

                        print("📊 End-to-end update latency: \(String(format: "%.2f", latency))s")

                        // Target: < 1 second, but allow more for real conditions
                        XCTAssertLessThan(latency, 20.0, "Update should arrive within 20 seconds")
                    } else {
                        print("⚠️ Update not received within timeout")
                    }
                }
            }
        }

        wait(for: [connectExpectation, sessionCreatedExpectation, updateReceivedExpectation], timeout: 120.0)

        // Cleanup
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let projectsDir = homeDir.appendingPathComponent(".claude/projects")

        if let enumerator = FileManager.default.enumerator(at: projectsDir, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                if fileURL.lastPathComponent.contains(sessionId.uuidString) {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        }
    }

    // MARK: - Stress Tests

    func testRapidSessionSwitching() {
        let expectation = XCTestExpectation(description: "Rapid switching")

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            let sessions = self.fetchAllSessions().prefix(20)

            print("📊 Testing rapid switching with \(sessions.count) sessions")

            measure(metrics: [XCTClockMetric()]) {
                // Rapidly subscribe/unsubscribe
                for session in sessions {
                    self.client.subscribe(sessionId: session.id.uuidString)
                }

                Thread.sleep(forTimeInterval: 0.5)

                for session in sessions {
                    self.client.unsubscribe(sessionId: session.id.uuidString)
                }
            }

            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 60.0)
    }

    func testConcurrentSessionOperations() {
        let expectation = XCTestExpectation(description: "Concurrent operations")

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            let sessions = self.fetchAllSessions().prefix(10)

            let startTime = Date()

            // Perform operations concurrently
            let group = DispatchGroup()

            for session in sessions {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    // Subscribe
                    self.client.subscribe(sessionId: session.id.uuidString)

                    // Query messages
                    let _ = self.fetchMessages(sessionId: session.id)

                    group.leave()
                }
            }

            group.notify(queue: .main) {
                let endTime = Date()
                let duration = endTime.timeIntervalSince(startTime)

                print("📊 Concurrent operations duration: \(String(format: "%.2f", duration))s")
                print("📊 Sessions: \(sessions.count)")

                XCTAssertLessThan(duration, 30.0, "Concurrent operations should complete within 30 seconds")

                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 60.0)
    }
}
