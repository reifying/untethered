import XCTest
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCode
#endif

/// Tests for LogManager logging functionality
final class LogManagerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        LogManager.shared.clearLogs()
    }

    override func tearDown() {
        LogManager.shared.clearLogs()
        super.tearDown()
    }

    func testBasicLogging() {
        // Log some messages
        LogManager.shared.log("Test message 1", category: "Test")
        LogManager.shared.log("Test message 2", category: "ResourcesManager")
        LogManager.shared.log("Test message 3", category: "VoiceCodeClient")

        // Give async logging time to complete
        Thread.sleep(forTimeInterval: 0.1)

        // Verify logs were captured
        let logs = LogManager.shared.getAllLogs()
        XCTAssertTrue(logs.contains("Test message 1"), "Should contain first message")
        XCTAssertTrue(logs.contains("Test message 2"), "Should contain second message")
        XCTAssertTrue(logs.contains("Test message 3"), "Should contain third message")
        XCTAssertTrue(logs.contains("[Test]"), "Should contain Test category")
        XCTAssertTrue(logs.contains("[ResourcesManager]"), "Should contain ResourcesManager category")
        XCTAssertTrue(logs.contains("[VoiceCodeClient]"), "Should contain VoiceCodeClient category")
    }

    func testLogFormatting() {
        LogManager.shared.log("Upload started", category: "ResourcesManager")

        Thread.sleep(forTimeInterval: 0.1)

        let logs = LogManager.shared.getAllLogs()

        // Verify log format: [timestamp] [category] message
        let lines = logs.components(separatedBy: "\n")
        XCTAssertTrue(lines.first?.contains("[") ?? false, "Should have timestamp in brackets")
        XCTAssertTrue(lines.first?.contains("[ResourcesManager]") ?? false, "Should have category in brackets")
        XCTAssertTrue(lines.first?.contains("Upload started") ?? false, "Should have message")
    }

    func testClearLogs() {
        LogManager.shared.log("Test message", category: "Test")
        Thread.sleep(forTimeInterval: 0.1)

        var logs = LogManager.shared.getAllLogs()
        XCTAssertFalse(logs.isEmpty, "Logs should not be empty before clear")

        LogManager.shared.clearLogs()
        Thread.sleep(forTimeInterval: 0.1)

        logs = LogManager.shared.getAllLogs()
        XCTAssertTrue(logs.isEmpty, "Logs should be empty after clear")
    }

    func testRecentLogsLimit() {
        // Log 100 messages
        for i in 0..<100 {
            LogManager.shared.log("Message \(i)", category: "Test")
        }

        Thread.sleep(forTimeInterval: 0.1)

        // Get recent logs with small limit
        let recentLogs = LogManager.shared.getRecentLogs(maxBytes: 500)
        let allLogs = LogManager.shared.getAllLogs()

        // Recent logs should be smaller than all logs
        XCTAssertLessThan(recentLogs.count, allLogs.count, "Recent logs should be limited")
        XCTAssertLessThanOrEqual(recentLogs.utf8.count, 500, "Recent logs should be under byte limit")
    }

    func testFileUploadLogging() {
        // Simulate upload flow logging
        LogManager.shared.log("Starting upload processing", category: "ResourcesManager")
        LogManager.shared.log("Found 1 pending upload(s)", category: "ResourcesManager")
        LogManager.shared.log("Processing upload: abc123", category: "ResourcesManager")
        LogManager.shared.log("Uploading file: test.txt (1234 bytes)", category: "ResourcesManager")
        LogManager.shared.log("Sending upload_file message for: test.txt to: /tmp/resources", category: "ResourcesManager")

        Thread.sleep(forTimeInterval: 0.1)

        let logs = LogManager.shared.getAllLogs()
        XCTAssertTrue(logs.contains("Starting upload processing"), "Should log upload start")
        XCTAssertTrue(logs.contains("Found 1 pending upload(s)"), "Should log upload count")
        XCTAssertTrue(logs.contains("Processing upload: abc123"), "Should log upload ID")
        XCTAssertTrue(logs.contains("Uploading file: test.txt (1234 bytes)"), "Should log file details")
        XCTAssertTrue(logs.contains("Sending upload_file message"), "Should log message send")
    }

    func testWebSocketLogging() {
        // Simulate WebSocket events
        LogManager.shared.log("Connecting to WebSocket: ws://localhost:8080", category: "VoiceCodeClient")
        LogManager.shared.log("WebSocket task resumed", category: "VoiceCodeClient")
        LogManager.shared.log("Session registered: Welcome", category: "VoiceCodeClient")
        LogManager.shared.log("Sending message type: upload_file", category: "VoiceCodeClient")
        LogManager.shared.log("File uploaded successfully: test.txt", category: "VoiceCodeClient")

        Thread.sleep(forTimeInterval: 0.1)

        let logs = LogManager.shared.getAllLogs()
        XCTAssertTrue(logs.contains("Connecting to WebSocket"), "Should log connection")
        XCTAssertTrue(logs.contains("WebSocket task resumed"), "Should log task resume")
        XCTAssertTrue(logs.contains("Session registered"), "Should log session registration")
        XCTAssertTrue(logs.contains("Sending message type: upload_file"), "Should log message type")
        XCTAssertTrue(logs.contains("File uploaded successfully: test.txt"), "Should log upload success")
    }

    func testBufferHoldsUpTo5000Lines() {
        // Log more than the 5000-line buffer capacity
        for i in 0..<5500 {
            LogManager.shared.log("Buffer #\(i)#", category: "Test")
        }

        // getAllLogs uses queue.sync on the same serial queue as the async log
        // calls above, so all writes are guaranteed to have drained by now.
        let logs = LogManager.shared.getAllLogs()
        let lines = logs.components(separatedBy: "\n")

        // Buffer is capped at 5000 lines
        XCTAssertEqual(lines.count, 5000, "Buffer should retain exactly 5000 lines")

        // Oldest entries are dropped, newest retained (kept range: 500..<5500)
        XCTAssertTrue(logs.contains("Buffer #5499#"), "Should retain the newest line")
        XCTAssertTrue(logs.contains("Buffer #500#"), "Should retain the oldest surviving line")
        XCTAssertFalse(logs.contains("Buffer #499#"), "Should drop lines beyond the 5000-line window")
    }

    func testRecentLogsDefaultsTo100KB() {
        // Each line is well over 100 bytes; log enough to exceed 100KB total
        let padding = String(repeating: "x", count: 200)
        for i in 0..<2000 {
            LogManager.shared.log("Pad \(i) \(padding)", category: "Test")
        }

        // Default call (no maxBytes argument) should cap at the new 100KB limit
        let recent = LogManager.shared.getRecentLogs()

        XCTAssertLessThanOrEqual(recent.utf8.count, 100_000, "Default getRecentLogs should cap at 100KB")
        // Should return substantially more than the old 15KB default
        XCTAssertGreaterThan(recent.utf8.count, 15_000, "Default should now exceed the old 15KB limit")
        // Trimming keeps the newest lines
        XCTAssertTrue(recent.contains("Pad 1999 "), "Should include the most recent line")
    }
}
