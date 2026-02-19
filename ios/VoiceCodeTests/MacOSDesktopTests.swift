// MacOSDesktopTests.swift
// Unit tests for macOS desktop components: DesktopDensity, PushToTalkModifier,
// AppSettings directory tracking, and CDMessage platform truncation

import XCTest
import CoreData
import SwiftUI
@testable import VoiceCode

final class MacOSDesktopTests: XCTestCase {

    #if os(macOS)

    override func setUp() {
        super.setUp()
        // Clear macOS-specific UserDefaults keys to prevent test pollution
        UserDefaults.standard.removeObject(forKey: "lastUsedDirectory")
        UserDefaults.standard.removeObject(forKey: "recentDirectories")
        UserDefaults.standard.synchronize()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "lastUsedDirectory")
        UserDefaults.standard.removeObject(forKey: "recentDirectories")
        UserDefaults.standard.synchronize()
        super.tearDown()
    }

    // MARK: - DesktopDensity Constants Tests

    func testSpacingConstants() {
        XCTAssertEqual(DesktopDensity.listRowVerticalPadding, 4)
        XCTAssertEqual(DesktopDensity.listRowHorizontalPadding, 8)
        XCTAssertEqual(DesktopDensity.sectionSpacing, 8)
    }

    func testTypographyConstants() {
        // Verify font constants are defined and accessible
        let body = DesktopDensity.bodyFont
        let caption = DesktopDensity.captionFont
        let message = DesktopDensity.messageFont
        XCTAssertNotNil(body)
        XCTAssertNotNil(caption)
        XCTAssertNotNil(message)
    }

    func testTruncationConstants() {
        XCTAssertEqual(DesktopDensity.messagePreviewLines, 3)
        XCTAssertEqual(DesktopDensity.messageTruncationThreshold, 2000)
    }

    func testSizingConstants() {
        XCTAssertEqual(DesktopDensity.minRowHeight, 28)
        XCTAssertEqual(DesktopDensity.iconSize, 14)
    }

    // MARK: - DesktopDensity View Modifier Tests

    func testDesktopDensityModifierCompiles() {
        struct TestView: View {
            var body: some View {
                Text("Test")
                    .desktopDensity()
            }
        }
        let view = TestView()
        XCTAssertNotNil(view)
    }

    func testDesktopListRowModifierCompiles() {
        struct TestView: View {
            var body: some View {
                Text("Test")
                    .desktopListRow()
            }
        }
        let view = TestView()
        XCTAssertNotNil(view)
    }

    func testBothModifiersCombined() {
        struct TestView: View {
            var body: some View {
                HStack {
                    Text("Label")
                    Spacer()
                    Text("Detail")
                }
                .desktopListRow()
                .desktopDensity()
            }
        }
        let view = TestView()
        XCTAssertNotNil(view)
    }

    // MARK: - PushToTalkModifier Compile Tests
    // Note: .onKeyPress modifier cannot be tested in unit tests.
    // Key press simulation requires UI testing.

    func testPushToTalkModifierCompiles() {
        struct TestView: View {
            @StateObject var voiceInput = VoiceInputManager()

            var body: some View {
                Text("Content")
                    .pushToTalk(voiceInput: voiceInput)
            }
        }
        XCTAssertNotNil(TestView.self)
    }

    func testRecordingIndicatorActive() {
        let indicator = RecordingIndicator(isActive: true)
        XCTAssertNotNil(indicator)
    }

    func testRecordingIndicatorInactive() {
        let indicator = RecordingIndicator(isActive: false)
        XCTAssertNotNil(indicator)
    }

    func testPushToTalkModifierStructure() {
        // Verify PushToTalkModifier can be instantiated with VoiceInputManager
        let voiceInput = VoiceInputManager()
        let modifier = PushToTalkModifier(voiceInput: voiceInput)
        XCTAssertNotNil(modifier)
    }

    // MARK: - AppSettings Directory Tracking Tests

    func testAddToRecentDirectories() {
        let settings = AppSettings()
        settings.addToRecentDirectories("/path/a")
        XCTAssertEqual(settings.recentDirectories, ["/path/a"])
    }

    func testAddToRecentDirectoriesDeduplication() {
        let settings = AppSettings()
        settings.addToRecentDirectories("/path/a")
        settings.addToRecentDirectories("/path/b")
        settings.addToRecentDirectories("/path/a")

        XCTAssertEqual(settings.recentDirectories.count, 2)
        XCTAssertEqual(settings.recentDirectories[0], "/path/a")
        XCTAssertEqual(settings.recentDirectories[1], "/path/b")
    }

    func testAddToRecentDirectoriesLimit() {
        let settings = AppSettings()
        for i in 0..<15 {
            settings.addToRecentDirectories("/path/\(i)")
        }

        XCTAssertEqual(settings.recentDirectories.count, 10)
        // Most recent should be first
        XCTAssertEqual(settings.recentDirectories[0], "/path/14")
    }

    func testAddToRecentDirectoriesOrder() {
        let settings = AppSettings()
        settings.addToRecentDirectories("/path/a")
        settings.addToRecentDirectories("/path/b")
        settings.addToRecentDirectories("/path/c")

        XCTAssertEqual(settings.recentDirectories[0], "/path/c")
        XCTAssertEqual(settings.recentDirectories[1], "/path/b")
        XCTAssertEqual(settings.recentDirectories[2], "/path/a")
    }

    func testLastUsedDirectoryUpdatesRecentDirectories() {
        let settings = AppSettings()
        settings.lastUsedDirectory = "/path/a"

        XCTAssertEqual(settings.lastUsedDirectory, "/path/a")
        XCTAssertTrue(settings.recentDirectories.contains("/path/a"))
    }

    func testTrackDirectoryUsageFullFlow() {
        // Test case from design document
        let settings = AppSettings()
        settings.addToRecentDirectories("/path/a")
        settings.addToRecentDirectories("/path/b")
        settings.addToRecentDirectories("/path/a")

        // /path/a should be first (most recent)
        XCTAssertEqual(settings.recentDirectories, ["/path/a", "/path/b"])
    }

    // MARK: - CDMessage Truncation Tests

    func testShortMessageNotTruncated() {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext

        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = UUID()
        message.role = "assistant"
        message.text = "Short message"
        message.timestamp = Date()
        message.messageStatus = .confirmed

        XCTAssertEqual(message.displayText, "Short message")
        XCTAssertFalse(message.isTruncated)
    }

    func testLongMessageTruncatedOnMacOS() {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext

        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = UUID()
        message.role = "assistant"
        // 2001 chars should trigger truncation on macOS (threshold is 2000)
        message.text = String(repeating: "x", count: 2001)
        message.timestamp = Date()
        message.messageStatus = .confirmed

        XCTAssertTrue(message.isTruncated)
        XCTAssertTrue(message.displayText.contains("characters omitted"))
    }

    func testMessageAt2000CharsNotTruncatedOnMacOS() {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext

        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = UUID()
        message.role = "assistant"
        message.text = String(repeating: "x", count: 2000)
        message.timestamp = Date()
        message.messageStatus = .confirmed

        XCTAssertFalse(message.isTruncated)
        XCTAssertEqual(message.displayText.count, 2000)
    }

    func testMessageAt1500CharsNotTruncatedOnMacOS() {
        // 1500 chars is well under the 2000 macOS threshold
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext

        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = UUID()
        message.role = "assistant"
        message.text = String(repeating: "a", count: 1500)
        message.timestamp = Date()
        message.messageStatus = .confirmed

        XCTAssertFalse(message.isTruncated)
    }

    // MARK: - SessionSidebarRow Density Integration Test

    func testSessionSidebarRowWithDensityModifiers() {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext

        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "test-session"
        session.workingDirectory = "/projects/app"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.isLocallyCreated = true

        // Verify SessionSidebarRow still compiles with density modifiers applied
        let row = SessionSidebarRow(session: session, isLocked: false)
        XCTAssertNotNil(row)
    }

    #endif
}
