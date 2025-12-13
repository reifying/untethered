import XCTest
import Combine
@testable import VoiceCodeShared

/// Mock implementation of VoiceCodeClientProtocol for testing
final class MockVoiceCodeClient: VoiceCodeClientProtocol, @unchecked Sendable {
    @Published var isConnected: Bool = false
    @Published var lockedSessions: Set<String> = []
    @Published var availableCommands: AvailableCommands?
    @Published var runningCommands: [String: CommandExecution] = [:]
    @Published var commandHistory: [CommandHistorySession] = []
    @Published var commandOutputFull: CommandOutputFull?
    @Published var fileUploadResponse: (filename: String, success: Bool)?
    @Published var resourcesList: [Resource] = []
    @Published var currentError: String?
    @Published var isProcessing: Bool = false

    // Track method calls for verification
    var connectCalled = false
    var connectSessionId: String?
    var disconnectCalled = false
    var sendPromptCalls: [(text: String, iosSessionId: String, sessionId: String?, workingDirectory: String?, systemPrompt: String?)] = []
    var subscribeCalls: [String] = []
    var unsubscribeCalls: [String] = []
    var sentMessages: [[String: Any]] = []

    func connect(sessionId: String?) {
        connectCalled = true
        connectSessionId = sessionId
        isConnected = true
    }

    func disconnect() {
        disconnectCalled = true
        isConnected = false
    }

    func updateServerURL(_ url: String) {
        disconnect()
        connect(sessionId: nil)
    }

    func sendPrompt(_ text: String, iosSessionId: String, sessionId: String?, workingDirectory: String?, systemPrompt: String?) {
        sendPromptCalls.append((text, iosSessionId, sessionId, workingDirectory, systemPrompt))
        if let sessionId = sessionId {
            lockedSessions.insert(sessionId)
        }
    }

    func subscribe(sessionId: String) {
        subscribeCalls.append(sessionId)
    }

    func unsubscribe(sessionId: String) {
        unsubscribeCalls.append(sessionId)
    }

    func requestSessionList() async {
        // Mock implementation
    }

    func requestSessionRefresh(sessionId: String) {
        unsubscribe(sessionId: sessionId)
        subscribe(sessionId: sessionId)
    }

    func compactSession(sessionId: String) async throws -> CompactionResult {
        return CompactionResult(sessionId: sessionId)
    }

    func killSession(sessionId: String) {
        lockedSessions.remove(sessionId)
    }

    func requestInferredName(sessionId: String, messageText: String) {
        // Mock implementation
    }

    func executeCommand(commandId: String, workingDirectory: String) async -> String {
        return "cmd-\(UUID().uuidString)"
    }

    func getCommandHistory(workingDirectory: String?, limit: Int) {
        // Mock implementation
    }

    func getCommandOutput(commandSessionId: String) {
        // Mock implementation
    }

    func setWorkingDirectory(_ path: String) {
        sendMessage(["type": "set_directory", "path": path])
    }

    func listResources(storageLocation: String) {
        // Mock implementation
    }

    func deleteResource(filename: String, storageLocation: String) {
        resourcesList.removeAll { $0.filename == filename }
    }

    func ping() {
        sendMessage(["type": "ping"])
    }

    func sendMessage(_ message: [String: Any]) {
        sentMessages.append(message)
    }
}

final class VoiceCodeClientProtocolTests: XCTestCase {

    // MARK: - Protocol Conformance Tests

    func testMockClientConformsToProtocol() {
        let client: any VoiceCodeClientProtocol = MockVoiceCodeClient()
        XCTAssertNotNil(client)
    }

    // MARK: - Connection Tests

    func testConnect() {
        let client = MockVoiceCodeClient()
        XCTAssertFalse(client.isConnected)

        client.connect(sessionId: "test-session")

        XCTAssertTrue(client.connectCalled)
        XCTAssertEqual(client.connectSessionId, "test-session")
        XCTAssertTrue(client.isConnected)
    }

    func testConnectWithoutSessionId() {
        let client = MockVoiceCodeClient()

        client.connect(sessionId: nil)

        XCTAssertTrue(client.connectCalled)
        XCTAssertNil(client.connectSessionId)
        XCTAssertTrue(client.isConnected)
    }

    func testDisconnect() {
        let client = MockVoiceCodeClient()
        client.connect(sessionId: nil)
        XCTAssertTrue(client.isConnected)

        client.disconnect()

        XCTAssertTrue(client.disconnectCalled)
        XCTAssertFalse(client.isConnected)
    }

    // MARK: - Prompt Tests

    func testSendPrompt() {
        let client = MockVoiceCodeClient()

        client.sendPrompt("Hello", iosSessionId: "ios-123", sessionId: "claude-456", workingDirectory: "/test", systemPrompt: nil)

        XCTAssertEqual(client.sendPromptCalls.count, 1)
        XCTAssertEqual(client.sendPromptCalls[0].text, "Hello")
        XCTAssertEqual(client.sendPromptCalls[0].iosSessionId, "ios-123")
        XCTAssertEqual(client.sendPromptCalls[0].sessionId, "claude-456")
        XCTAssertEqual(client.sendPromptCalls[0].workingDirectory, "/test")
    }

    func testSendPromptLocksSession() {
        let client = MockVoiceCodeClient()
        XCTAssertTrue(client.lockedSessions.isEmpty)

        client.sendPrompt("Test", iosSessionId: "ios-123", sessionId: "claude-456", workingDirectory: nil, systemPrompt: nil)

        XCTAssertTrue(client.lockedSessions.contains("claude-456"))
    }

    func testSendPromptWithSystemPrompt() {
        let client = MockVoiceCodeClient()

        client.sendPrompt("Hello", iosSessionId: "ios-123", sessionId: nil, workingDirectory: nil, systemPrompt: "Custom prompt")

        XCTAssertEqual(client.sendPromptCalls[0].systemPrompt, "Custom prompt")
    }

    // MARK: - Session Management Tests

    func testSubscribe() {
        let client = MockVoiceCodeClient()

        client.subscribe(sessionId: "session-1")
        client.subscribe(sessionId: "session-2")

        XCTAssertEqual(client.subscribeCalls, ["session-1", "session-2"])
    }

    func testUnsubscribe() {
        let client = MockVoiceCodeClient()

        client.unsubscribe(sessionId: "session-1")

        XCTAssertEqual(client.unsubscribeCalls, ["session-1"])
    }

    func testRequestSessionRefresh() {
        let client = MockVoiceCodeClient()

        client.requestSessionRefresh(sessionId: "session-1")

        XCTAssertEqual(client.unsubscribeCalls, ["session-1"])
        XCTAssertEqual(client.subscribeCalls, ["session-1"])
    }

    func testKillSession() {
        let client = MockVoiceCodeClient()
        client.lockedSessions.insert("session-1")
        XCTAssertTrue(client.lockedSessions.contains("session-1"))

        client.killSession(sessionId: "session-1")

        XCTAssertFalse(client.lockedSessions.contains("session-1"))
    }

    // MARK: - Compaction Tests

    func testCompactSession() async throws {
        let client = MockVoiceCodeClient()

        let result = try await client.compactSession(sessionId: "session-1")

        XCTAssertEqual(result.sessionId, "session-1")
    }

    // MARK: - Command Tests

    func testExecuteCommand() async {
        let client = MockVoiceCodeClient()

        let sessionId = await client.executeCommand(commandId: "build", workingDirectory: "/project")

        XCTAssertTrue(sessionId.hasPrefix("cmd-"))
    }

    // MARK: - Utility Tests

    func testPing() {
        let client = MockVoiceCodeClient()

        client.ping()

        XCTAssertEqual(client.sentMessages.count, 1)
        XCTAssertEqual(client.sentMessages[0]["type"] as? String, "ping")
    }

    func testSetWorkingDirectory() {
        let client = MockVoiceCodeClient()

        client.setWorkingDirectory("/test/path")

        XCTAssertEqual(client.sentMessages.count, 1)
        XCTAssertEqual(client.sentMessages[0]["type"] as? String, "set_directory")
        XCTAssertEqual(client.sentMessages[0]["path"] as? String, "/test/path")
    }

    func testDeleteResource() {
        let client = MockVoiceCodeClient()
        client.resourcesList = [
            Resource(filename: "file1.txt", path: "/storage/file1.txt", size: 100, timestamp: Date()),
            Resource(filename: "file2.txt", path: "/storage/file2.txt", size: 200, timestamp: Date())
        ]

        client.deleteResource(filename: "file1.txt", storageLocation: "/storage")

        XCTAssertEqual(client.resourcesList.count, 1)
        XCTAssertEqual(client.resourcesList[0].filename, "file2.txt")
    }

    // MARK: - Published Properties Tests

    func testLockedSessionsProperty() {
        let client = MockVoiceCodeClient()

        client.lockedSessions.insert("session-1")
        client.lockedSessions.insert("session-2")

        XCTAssertEqual(client.lockedSessions.count, 2)
        XCTAssertTrue(client.lockedSessions.contains("session-1"))
        XCTAssertTrue(client.lockedSessions.contains("session-2"))
    }

    func testAvailableCommandsProperty() {
        let client = MockVoiceCodeClient()
        XCTAssertNil(client.availableCommands)

        client.availableCommands = AvailableCommands(
            workingDirectory: "/test",
            projectCommands: [Command(id: "build", label: "Build", type: .command)],
            generalCommands: []
        )

        XCTAssertNotNil(client.availableCommands)
        XCTAssertEqual(client.availableCommands?.workingDirectory, "/test")
        XCTAssertEqual(client.availableCommands?.projectCommands.count, 1)
    }

    func testCurrentErrorProperty() {
        let client = MockVoiceCodeClient()
        XCTAssertNil(client.currentError)

        client.currentError = "Connection failed"

        XCTAssertEqual(client.currentError, "Connection failed")
    }

    func testIsProcessingProperty() {
        let client = MockVoiceCodeClient()
        XCTAssertFalse(client.isProcessing)

        client.isProcessing = true

        XCTAssertTrue(client.isProcessing)
    }
}

// MARK: - CompactionResult Tests

final class CompactionResultTests: XCTestCase {

    func testCompactionResultCreation() {
        let result = CompactionResult(sessionId: "test-session")
        XCTAssertEqual(result.sessionId, "test-session")
    }

    func testCompactionResultIsSendable() {
        // This test verifies Sendable conformance compiles
        let result = CompactionResult(sessionId: "test")
        Task {
            let _ = result.sessionId
        }
    }
}
