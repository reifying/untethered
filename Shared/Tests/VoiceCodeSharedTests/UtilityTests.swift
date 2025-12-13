import XCTest
@testable import VoiceCodeShared

final class UtilityTests: XCTestCase {

    // MARK: - TextProcessor Tests

    func testRemoveFencedCodeBlocks() {
        let markdown = """
        Here is some code:
        ```swift
        let x = 5
        print(x)
        ```
        And more text.
        """
        let result = TextProcessor.removeCodeBlocks(from: markdown)
        XCTAssertTrue(result.contains("[code block]"))
        XCTAssertFalse(result.contains("let x = 5"))
        XCTAssertTrue(result.contains("And more text."))
    }

    func testRemoveInlineCode() {
        let markdown = "Use the `print()` function to output text."
        let result = TextProcessor.removeCodeBlocks(from: markdown)
        XCTAssertEqual(result, "Use the print() function to output text.")
    }

    func testRemoveMultipleCodeBlocks() {
        let markdown = """
        First block:
        ```
        code1
        ```
        Second block:
        ```python
        code2
        ```
        Done.
        """
        let result = TextProcessor.removeCodeBlocks(from: markdown)
        XCTAssertEqual(result.components(separatedBy: "[code block]").count, 3)
    }

    func testCleanupExcessiveNewlines() {
        let markdown = """
        Before



        After
        """
        let result = TextProcessor.removeCodeBlocks(from: markdown)
        XCTAssertFalse(result.contains("\n\n\n"))
    }

    // MARK: - CommandSorter Tests

    func testCommandSorterMRU() {
        let sorter = CommandSorter(userDefaults: .standard)
        sorter.clearMRU()

        let commands = [
            Command(id: "a", label: "Alpha", type: .command),
            Command(id: "b", label: "Beta", type: .command),
            Command(id: "c", label: "Charlie", type: .command)
        ]

        // Initially sorted alphabetically
        let initial = sorter.sortCommands(commands)
        XCTAssertEqual(initial.map { $0.id }, ["a", "b", "c"])

        // Mark 'c' as used, should come first
        sorter.markCommandUsed(commandId: "c")
        let afterC = sorter.sortCommands(commands)
        XCTAssertEqual(afterC.first?.id, "c")

        // Mark 'a' as used, should come first (most recent)
        sorter.markCommandUsed(commandId: "a")
        let afterA = sorter.sortCommands(commands)
        XCTAssertEqual(afterA.first?.id, "a")
        XCTAssertEqual(afterA[1].id, "c") // Second most recent

        sorter.clearMRU()
    }

    func testCommandSorterRecursiveGroups() {
        let sorter = CommandSorter(userDefaults: .standard)
        sorter.clearMRU()

        let children = [
            Command(id: "child.b", label: "Beta Child", type: .command),
            Command(id: "child.a", label: "Alpha Child", type: .command)
        ]
        let group = Command(id: "group", label: "Group", type: .group, children: children)

        let sorted = sorter.sortCommands([group])
        XCTAssertEqual(sorted.first?.children?.first?.id, "child.a") // Alphabetical

        sorter.clearMRU()
    }

    // MARK: - UUID Extension Tests

    func testUUIDLowercasedString() {
        let uuid = UUID()
        let lowercased = uuid.lowercasedString

        // Should be lowercase
        XCTAssertEqual(lowercased, lowercased.lowercased())
        // Should match original when lowercased
        XCTAssertEqual(lowercased, uuid.uuidString.lowercased())
        // Should have correct format (36 chars with hyphens)
        XCTAssertEqual(lowercased.count, 36)
    }

    func testUUIDLowercasedStringConsistency() {
        // Known UUID to verify exact output
        let uuid = UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!
        XCTAssertEqual(uuid.lowercasedString, "a1b2c3d4-e5f6-7890-abcd-ef1234567890")
    }

    // MARK: - DateFormatters Tests

    func testParseISO8601WithFractionalSeconds() {
        let dateString = "2025-01-15T10:30:00.123Z"
        let date = DateFormatters.parseISO8601(dateString)
        XCTAssertNotNil(date)
    }

    func testParseISO8601WithoutFractionalSeconds() {
        let dateString = "2025-01-15T10:30:00Z"
        let date = DateFormatters.parseISO8601(dateString)
        XCTAssertNotNil(date)
    }

    func testParseISO8601Invalid() {
        let dateString = "not-a-date"
        let date = DateFormatters.parseISO8601(dateString)
        XCTAssertNil(date)
    }

    func testFormatISO8601() {
        let date = Date(timeIntervalSince1970: 0)
        let formatted = DateFormatters.formatISO8601(date)
        XCTAssertTrue(formatted.contains("1970-01-01"))
        XCTAssertTrue(formatted.hasSuffix("Z"))
    }

    func testISO8601RoundTrip() {
        let original = Date()
        let formatted = DateFormatters.formatISO8601(original)
        let parsed = DateFormatters.parseISO8601(formatted)
        XCTAssertNotNil(parsed)
        // Allow 1ms difference due to fractional second precision
        XCTAssertEqual(original.timeIntervalSince1970, parsed!.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - LogManager Tests

    func testLogManagerBasicLogging() {
        let manager = LogManager.shared
        manager.clearLogs()

        manager.log("Test message", category: "Test")

        let logs = manager.getAllLogs()
        XCTAssertTrue(logs.contains("[Test]"))
        XCTAssertTrue(logs.contains("Test message"))
    }

    func testLogManagerDefaultCategory() {
        let manager = LogManager.shared
        manager.clearLogs()

        manager.log("General message")

        let logs = manager.getAllLogs()
        XCTAssertTrue(logs.contains("[General]"))
        XCTAssertTrue(logs.contains("General message"))
    }

    func testLogManagerTimestampFormat() {
        let manager = LogManager.shared
        manager.clearLogs()

        manager.log("Timestamped message")

        let logs = manager.getAllLogs()
        // Timestamp format: HH:mm:ss.SSS
        let timestampPattern = "\\[\\d{2}:\\d{2}:\\d{2}\\.\\d{3}\\]"
        let regex = try! NSRegularExpression(pattern: timestampPattern)
        let range = NSRange(logs.startIndex..., in: logs)
        XCTAssertNotNil(regex.firstMatch(in: logs, range: range))
    }

    func testLogManagerGetRecentLogsUnderLimit() {
        let manager = LogManager.shared
        manager.clearLogs()

        manager.log("Short message")

        let logs = manager.getRecentLogs(maxBytes: 15_000)
        XCTAssertTrue(logs.contains("Short message"))
    }

    func testLogManagerClearLogs() {
        let manager = LogManager.shared
        manager.log("Before clear")
        manager.clearLogs()

        // Wait a moment for async clear to complete
        Thread.sleep(forTimeInterval: 0.1)

        let logs = manager.getAllLogs()
        XCTAssertTrue(logs.isEmpty)
    }

    func testLogManagerConfigSubsystem() {
        // Test that subsystem can be configured
        let originalSubsystem = LogManagerConfig.subsystem
        LogManagerConfig.subsystem = "com.test.app"
        XCTAssertEqual(LogManagerConfig.subsystem, "com.test.app")
        LogManagerConfig.subsystem = originalSubsystem
    }
}
