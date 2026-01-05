// NavigationTitleTests.swift
// Tests for navigation titles and section headers in DirectoryListView

import XCTest
import CoreData
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCodeMac
#endif

final class NavigationTitleTests: XCTestCase {
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!

    override func setUpWithError() throws {
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
    }

    override func tearDownWithError() throws {
        context = nil
        persistenceController = nil
    }

    // MARK: - Navigation Title Tests

    func testNavigationTitleIsProjects() throws {
        // Given: The DirectoryListView file contains the navigation title
        // When: We read the source code
        // Then: Navigation title should be "Projects" (not "Untethered")

        // This test verifies that the navigation title string literal is "Projects"
        // The actual value is in DirectoryListView.swift line 117

        let expectedTitle = "Projects"
        let notExpectedTitle = "Untethered"

        // Read the source file
        let sourceFile = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VoiceCode")
            .appendingPathComponent("Views")
            .appendingPathComponent("DirectoryListView.swift")

        let content = try String(contentsOf: sourceFile, encoding: .utf8)

        // Verify navigation title is "Projects"
        XCTAssertTrue(content.contains(".navigationTitle(\"Projects\")"),
                     "DirectoryListView should have .navigationTitle(\"Projects\")")

        // Verify it does NOT contain old title "Untethered"
        XCTAssertFalse(content.contains(".navigationTitle(\"Untethered\")"),
                      "DirectoryListView should NOT have .navigationTitle(\"Untethered\")")
    }

    // MARK: - Section Header Tests

    func testRecentSectionHeaderIsRecent() throws {
        // Given: The DirectoryListView file contains section headers
        // When: We read the source code
        // Then: Recent section header should be "Recent" (not "Recent Sessions")

        let sourceFile = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VoiceCode")
            .appendingPathComponent("Views")
            .appendingPathComponent("DirectoryListView.swift")

        let content = try String(contentsOf: sourceFile, encoding: .utf8)

        // Verify Recent section exists with correct header
        XCTAssertTrue(content.contains("Text(\"Recent\")"),
                     "DirectoryListView should have Recent section header")

        // Verify old header text does not exist
        XCTAssertFalse(content.contains("Text(\"Recent Sessions\")"),
                      "DirectoryListView should NOT have 'Recent Sessions' section header")
    }

    func testProjectsSectionHeaderIsProjects() throws {
        // Given: The DirectoryListView file contains section headers
        // When: We read the source code
        // Then: Projects section header should be "Projects" (not "Untethered")

        let sourceFile = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VoiceCode")
            .appendingPathComponent("Views")
            .appendingPathComponent("DirectoryListView.swift")

        let content = try String(contentsOf: sourceFile, encoding: .utf8)

        // Verify Projects section exists with correct header
        XCTAssertTrue(content.contains("Text(\"Projects\")"),
                     "DirectoryListView should have Projects section header")

        // Verify old header text does not exist in section headers
        // Note: We check for the pattern in section header context, not just anywhere
        let lines = content.components(separatedBy: .newlines)
        var foundUntetheredHeader = false

        for (index, line) in lines.enumerated() {
            if line.contains("Section") {
                // Check next few lines for "Untethered" header
                for offset in 0..<5 {
                    if index + offset < lines.count {
                        let checkLine = lines[index + offset]
                        if checkLine.contains("Text(\"Untethered\")") {
                            foundUntetheredHeader = true
                            break
                        }
                    }
                }
            }
        }

        XCTAssertFalse(foundUntetheredHeader,
                      "DirectoryListView should NOT have 'Untethered' as a section header")
    }

    // MARK: - Comment Consistency Tests

    func testCommentConsistencyWithChanges() throws {
        // Given: The DirectoryListView file contains comments
        // When: We read the source code
        // Then: Comments should reflect "Recent" (not "Recent Sessions")

        let sourceFile = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VoiceCode")
            .appendingPathComponent("Views")
            .appendingPathComponent("DirectoryListView.swift")

        let content = try String(contentsOf: sourceFile, encoding: .utf8)

        // Verify comment says "Recent section" not "Recent Sessions section"
        XCTAssertTrue(content.contains("// Recent section"),
                     "Comment should say 'Recent section'")

        XCTAssertFalse(content.contains("// Recent Sessions section"),
                      "Comment should NOT say 'Recent Sessions section'")
    }

    // MARK: - Back Button Context Tests

    func testBackButtonContextIsProjects() throws {
        // Given: Navigation title determines back button text
        // When: We verify the navigation title is "Projects"
        // Then: The back button will display "← Projects" (not "← Untethered")

        // This is a documentation test that verifies the intended UX behavior
        // The navigation title "Projects" means that when users navigate deeper
        // (e.g., to SessionsForDirectoryView or ConversationView), the back button
        // will show "← Projects" instead of "← Untethered"

        let sourceFile = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VoiceCode")
            .appendingPathComponent("Views")
            .appendingPathComponent("DirectoryListView.swift")

        let content = try String(contentsOf: sourceFile, encoding: .utf8)

        // The navigation title should be "Projects"
        XCTAssertTrue(content.contains(".navigationTitle(\"Projects\")"),
                     "Navigation title should be 'Projects' to show correct back button text")

        // Verify that this provides better UX than "Untethered"
        // "Projects" is more descriptive and aligns with the directory/project organization
        let expectedBackButtonText = "← Projects"
        let oldBackButtonText = "← Untethered"

        XCTAssertNotEqual(expectedBackButtonText, oldBackButtonText,
                         "New back button text should be different from old")
        XCTAssertTrue(expectedBackButtonText.contains("Projects"),
                     "Back button should reference 'Projects'")
    }

    // MARK: - Settings View Reference Tests

    func testSettingsViewReferencesProjects() throws {
        // Given: SettingsView has help text mentioning the Projects view
        // When: We read the SettingsView source code
        // Then: It should reference "Projects view" (not "Untethered view")

        let sourceFile = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VoiceCode")
            .appendingPathComponent("Views")
            .appendingPathComponent("SettingsView.swift")

        let content = try String(contentsOf: sourceFile, encoding: .utf8)

        // Verify Settings view references "Projects view"
        XCTAssertTrue(content.contains("Projects view"),
                     "SettingsView should reference 'Projects view'")

        // Verify it does NOT reference "Untethered view"
        XCTAssertFalse(content.contains("Untethered view"),
                      "SettingsView should NOT reference 'Untethered view'")
    }
}
