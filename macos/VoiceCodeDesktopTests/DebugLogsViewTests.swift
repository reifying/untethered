// DebugLogsViewTests.swift
// Tests for DebugLogsView per Appendix I.6

import XCTest
import SwiftUI
@testable import VoiceCodeDesktop
@testable import VoiceCodeShared

final class DebugLogsViewTests: XCTestCase {

    // MARK: - LogLine Tests

    func testLogLineParsingValidFormat() {
        // Test standard log format: [HH:mm:ss.SSS] [Category] Message
        let line = LogLine(id: 0, text: "[12:34:56.789] [VoiceCodeClient] Connected to server")

        XCTAssertEqual(line.timestamp, "12:34:56.789")
        XCTAssertEqual(line.category, "VoiceCodeClient")
        XCTAssertEqual(line.message, "Connected to server")
        XCTAssertEqual(line.text, "[12:34:56.789] [VoiceCodeClient] Connected to server")
    }

    func testLogLineParsingWithSpecialCharacters() {
        let line = LogLine(id: 1, text: "[09:15:30.123] [ResourcesManager] File uploaded: /path/to/file.txt")

        XCTAssertEqual(line.timestamp, "09:15:30.123")
        XCTAssertEqual(line.category, "ResourcesManager")
        XCTAssertEqual(line.message, "File uploaded: /path/to/file.txt")
    }

    func testLogLineParsingWithEmojis() {
        let line = LogLine(id: 2, text: "[10:00:00.000] [MainWindow] 📍 Session selected: abc123")

        XCTAssertEqual(line.timestamp, "10:00:00.000")
        XCTAssertEqual(line.category, "MainWindow")
        XCTAssertEqual(line.message, "📍 Session selected: abc123")
    }

    func testLogLineParsingInvalidFormat() {
        // Lines that don't match the expected format should use fallback
        let line = LogLine(id: 3, text: "This is an unparseable log line")

        XCTAssertEqual(line.timestamp, "")
        XCTAssertEqual(line.category, "Unknown")
        XCTAssertEqual(line.message, "This is an unparseable log line")
    }

    func testLogLineParsingPartialFormat() {
        // Only timestamp, no category
        let line = LogLine(id: 4, text: "[12:00:00.000] Missing category format")

        XCTAssertEqual(line.timestamp, "")
        XCTAssertEqual(line.category, "Unknown")
        XCTAssertEqual(line.message, "[12:00:00.000] Missing category format")
    }

    func testLogLineId() {
        let line1 = LogLine(id: 0, text: "Line 1")
        let line2 = LogLine(id: 1, text: "Line 2")

        XCTAssertEqual(line1.id, 0)
        XCTAssertEqual(line2.id, 1)
        XCTAssertNotEqual(line1.id, line2.id)
    }

    func testLogLineIdentifiable() {
        let lines = [
            LogLine(id: 0, text: "[00:00:00.000] [A] First"),
            LogLine(id: 1, text: "[00:00:01.000] [B] Second"),
            LogLine(id: 2, text: "[00:00:02.000] [C] Third")
        ]

        // Test that lines can be used in ForEach (Identifiable)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].id, 0)
        XCTAssertEqual(lines[1].id, 1)
        XCTAssertEqual(lines[2].id, 2)
    }

    // MARK: - Log Export Document Tests

    func testLogExportDocumentInit() {
        let content = "Line 1\nLine 2\nLine 3"
        let document = LogExportDocument(content: content)

        XCTAssertEqual(document.content, content)
    }

    func testLogExportDocumentContent() {
        let content = "[12:00:00.000] [Test] Hello World"
        let document = LogExportDocument(content: content)

        // Verify content is stored correctly
        XCTAssertEqual(document.content, content)

        // Verify content can be converted to data
        let data = content.data(using: .utf8)
        XCTAssertNotNil(data)
    }

    func testLogExportDocumentEmptyContent() {
        let document = LogExportDocument(content: "")

        XCTAssertEqual(document.content, "")
        XCTAssertEqual(document.content.data(using: .utf8)?.count, 0)
    }

    func testLogExportDocumentUnicodeContent() {
        let content = "[12:00:00.000] [Test] 日本語テスト 🎉"
        let document = LogExportDocument(content: content)

        XCTAssertEqual(document.content, content)
        let data = content.data(using: .utf8)
        XCTAssertNotNil(data)
        let roundTrip = String(data: data!, encoding: .utf8)
        XCTAssertEqual(roundTrip, content)
    }

    // MARK: - View Instantiation Tests

    func testDebugLogsViewInstantiation() {
        // Verify the view can be instantiated
        let view = DebugLogsView()
        XCTAssertNotNil(view)
    }

    // MARK: - LogLine Category Extraction Tests

    func testLogLineCategoryExtraction() {
        let testCases = [
            ("[10:00:00.000] [VoiceCodeClient] Message", "VoiceCodeClient"),
            ("[10:00:00.000] [ConversationDetailView] Message", "ConversationDetailView"),
            ("[10:00:00.000] [MainWindowView] Message", "MainWindowView"),
            ("[10:00:00.000] [General] Message", "General"),
            ("[10:00:00.000] [A] Short category", "A"),
        ]

        for (input, expectedCategory) in testCases {
            let line = LogLine(id: 0, text: input)
            XCTAssertEqual(line.category, expectedCategory, "Failed for input: \(input)")
        }
    }

    func testLogLineMessageExtraction() {
        let testCases = [
            ("[10:00:00.000] [Cat] Simple message", "Simple message"),
            ("[10:00:00.000] [Cat] Message with: colons", "Message with: colons"),
            ("[10:00:00.000] [Cat] [Nested] brackets", "[Nested] brackets"),
            // Note: Leading whitespace after category is trimmed by the parser
            ("[10:00:00.000] [Cat]    Trimmed message", "Trimmed message"),
        ]

        for (input, expectedMessage) in testCases {
            let line = LogLine(id: 0, text: input)
            XCTAssertEqual(line.message, expectedMessage, "Failed for input: \(input)")
        }
    }

    // MARK: - Multiple Lines Processing Tests

    func testMultipleLinesProcessing() {
        let rawLines = [
            "[10:00:00.000] [A] First",
            "[10:00:01.000] [B] Second",
            "[10:00:02.000] [A] Third",
            "[10:00:03.000] [C] Fourth",
        ]

        let logLines = rawLines.enumerated().map { index, text in
            LogLine(id: index, text: text)
        }

        // Test category filtering logic (as would be used in view)
        let categoryA = logLines.filter { $0.category == "A" }
        XCTAssertEqual(categoryA.count, 2)

        let categoryB = logLines.filter { $0.category == "B" }
        XCTAssertEqual(categoryB.count, 1)

        let categoryC = logLines.filter { $0.category == "C" }
        XCTAssertEqual(categoryC.count, 1)
    }

    func testSearchFiltering() {
        let rawLines = [
            "[10:00:00.000] [Client] Connected to server",
            "[10:00:01.000] [Client] Received message",
            "[10:00:02.000] [Manager] Session created",
            "[10:00:03.000] [Client] Connection lost",
        ]

        let logLines = rawLines.enumerated().map { index, text in
            LogLine(id: index, text: text)
        }

        // Simulate search for "connect" (case insensitive)
        let searchResults = logLines.filter {
            $0.text.localizedCaseInsensitiveContains("connect")
        }

        XCTAssertEqual(searchResults.count, 2)
        XCTAssertTrue(searchResults[0].message.contains("Connected"))
        XCTAssertTrue(searchResults[1].message.contains("Connection"))
    }

    func testCombinedFiltering() {
        let rawLines = [
            "[10:00:00.000] [Client] Connected to server",
            "[10:00:01.000] [Client] Received message",
            "[10:00:02.000] [Manager] Session connected",
            "[10:00:03.000] [Client] Connection lost",
        ]

        let logLines = rawLines.enumerated().map { index, text in
            LogLine(id: index, text: text)
        }

        // Filter by category AND search text
        let selectedCategories: Set<String> = ["Client"]
        let searchText = "connect"

        let filtered = logLines.filter { line in
            let categoryMatch = selectedCategories.isEmpty || selectedCategories.contains(line.category)
            let searchMatch = searchText.isEmpty || line.text.localizedCaseInsensitiveContains(searchText)
            return categoryMatch && searchMatch
        }

        XCTAssertEqual(filtered.count, 2)
        XCTAssertEqual(filtered[0].category, "Client")
        XCTAssertEqual(filtered[1].category, "Client")
    }

    // MARK: - Category Collection Tests

    func testCategoryCollection() {
        let rawLines = [
            "[10:00:00.000] [A] First",
            "[10:00:01.000] [B] Second",
            "[10:00:02.000] [A] Third",
            "[10:00:03.000] [C] Fourth",
            "[10:00:04.000] [B] Fifth",
        ]

        let logLines = rawLines.enumerated().map { index, text in
            LogLine(id: index, text: text)
        }

        let categories = Set(logLines.map { $0.category })

        XCTAssertEqual(categories.count, 3)
        XCTAssertTrue(categories.contains("A"))
        XCTAssertTrue(categories.contains("B"))
        XCTAssertTrue(categories.contains("C"))
    }

    // MARK: - Empty State Tests

    func testEmptyLogLines() {
        let logLines: [LogLine] = []

        XCTAssertTrue(logLines.isEmpty)
        XCTAssertEqual(Set(logLines.map { $0.category }).count, 0)
    }

    // MARK: - Log Content Joining Tests

    func testLogContentJoining() {
        let logLines = [
            LogLine(id: 0, text: "[10:00:00.000] [A] First"),
            LogLine(id: 1, text: "[10:00:01.000] [B] Second"),
            LogLine(id: 2, text: "[10:00:02.000] [C] Third"),
        ]

        let joined = logLines.map { $0.text }.joined(separator: "\n")

        XCTAssertTrue(joined.contains("[A] First"))
        XCTAssertTrue(joined.contains("[B] Second"))
        XCTAssertTrue(joined.contains("[C] Third"))
        XCTAssertEqual(joined.components(separatedBy: "\n").count, 3)
    }

    // MARK: - Help Menu Commands Tests

    func testHelpMenuNotificationNames() {
        // Verify notification names are correctly defined
        XCTAssertEqual(Notification.Name.showDebugLogs.rawValue, "showDebugLogs")
        XCTAssertEqual(Notification.Name.revealLogsInFinder.rawValue, "revealLogsInFinder")
    }

    // MARK: - LogManager Integration Tests

    func testLogManagerLogDirectory() {
        // Test that LogManager provides a valid log directory
        let logDir = LogManager.shared.logDirectory

        XCTAssertTrue(logDir.path.contains("Library/Logs/VoiceCode"))
    }
}
