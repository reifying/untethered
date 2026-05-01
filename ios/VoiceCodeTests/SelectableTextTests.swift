// SelectableTextTests.swift
// Tests for SelectableText cross-platform component

import XCTest
import SwiftUI
@testable import VoiceCode

final class SelectableTextTests: XCTestCase {

    // MARK: - Instantiation Tests

    func testDefaultInitialization() {
        let view = SelectableText(text: "Hello, world!")
        XCTAssertNotNil(view)
    }

    func testMonospacedInitialization() {
        let view = SelectableText(text: "code output", isMonospaced: true)
        XCTAssertNotNil(view)
    }

    func testCustomFontSize() {
        let view = SelectableText(text: "small text", fontSize: 10)
        XCTAssertNotNil(view)
    }

    func testCustomTextColor() {
        let view = SelectableText(text: "colored", textColor: .red)
        XCTAssertNotNil(view)
    }

    func testAllParameters() {
        let view = SelectableText(
            text: "full config",
            isMonospaced: true,
            fontSize: 14,
            textColor: .blue
        )
        XCTAssertNotNil(view)
    }

    // MARK: - Empty / Edge Case Tests

    func testEmptyText() {
        let view = SelectableText(text: "")
        XCTAssertNotNil(view)
    }

    func testVeryLongText() {
        let longText = String(repeating: "Lorem ipsum dolor sit amet. ", count: 1000)
        let view = SelectableText(text: longText)
        XCTAssertNotNil(view)
    }

    func testMultilineText() {
        let multiline = "Line 1\nLine 2\nLine 3\n\nLine 5"
        let view = SelectableText(text: multiline)
        XCTAssertNotNil(view)
    }

    func testUnicodeText() {
        let view = SelectableText(text: "Hello 🌍 你好 مرحبا")
        XCTAssertNotNil(view)
    }

    // MARK: - SwiftUI Integration Tests

    func testUsableInScrollView() {
        let view = ScrollView {
            SelectableText(text: "Scrollable content")
                .padding()
        }
        XCTAssertNotNil(view)
    }

    func testUsableInVStack() {
        let view = VStack {
            SelectableText(text: "First")
            SelectableText(text: "Second", isMonospaced: true)
        }
        XCTAssertNotNil(view)
    }

    func testUsableWithBackground() {
        let view = SelectableText(text: "With background", isMonospaced: true)
            .padding(12)
            .background(Color.gray)
            .cornerRadius(8)
        XCTAssertNotNil(view)
    }

    func testUsableWithFrame() {
        let view = SelectableText(text: "Framed", isMonospaced: true, fontSize: 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        XCTAssertNotNil(view)
    }

    // MARK: - Migration Parity Tests

    func testMessageDetailViewPattern() {
        // Matches the usage in MessageDetailView
        let view = ScrollView {
            SelectableText(text: "Message content here")
                .padding()
        }
        XCTAssertNotNil(view)
    }

    func testCommandOutputDetailViewPattern() {
        // Matches the usage in CommandOutputDetailView
        let view = SelectableText(text: "command output", isMonospaced: true)
            .padding(12)
            .background(Color.secondarySystemBackground)
            .cornerRadius(8)
        XCTAssertNotNil(view)
    }

    func testDebugLogsViewPattern() {
        // Matches the usage in DebugLogsView
        let view = SelectableText(text: "debug logs", isMonospaced: true, fontSize: 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        XCTAssertNotNil(view)
    }

}
