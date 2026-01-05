// SessionRowDisplayTests.swift
// Tests for CDSessionRowContent display logic

import XCTest
import CoreData
import SwiftUI
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCodeMac
#endif

final class SessionRowDisplayTests: XCTestCase {
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!

    override func setUpWithError() throws {
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
    }

    override func tearDownWithError() throws {
        persistenceController = nil
        context = nil
    }

    // MARK: - Working Directory Display Tests

    func testWorkingDirectoryShowsOnlyLastComponent() throws {
        // Given: A session with a multi-level directory path
        let session = createTestSession(
            name: "Test Session",
            workingDirectory: "/Users/username/projects/my-app/backend"
        )

        // When: Extracting the last path component
        let displayPath = URL(fileURLWithPath: session.workingDirectory).lastPathComponent

        // Then: Should show only "backend"
        XCTAssertEqual(displayPath, "backend")
    }

    func testWorkingDirectoryWithSingleComponent() throws {
        // Given: A session with a root-level directory
        let session = createTestSession(
            name: "Test Session",
            workingDirectory: "/tmp"
        )

        // When: Extracting the last path component
        let displayPath = URL(fileURLWithPath: session.workingDirectory).lastPathComponent

        // Then: Should show "tmp"
        XCTAssertEqual(displayPath, "tmp")
    }

    func testWorkingDirectoryWithTrailingSlash() throws {
        // Given: A session with a directory path ending in slash
        let session = createTestSession(
            name: "Test Session",
            workingDirectory: "/Users/username/projects/my-app/"
        )

        // When: Extracting the last path component
        let displayPath = URL(fileURLWithPath: session.workingDirectory).lastPathComponent

        // Then: Should show "my-app"
        XCTAssertEqual(displayPath, "my-app")
    }

    func testWorkingDirectoryWithTilde() throws {
        // Given: A session with a tilde-based path
        let session = createTestSession(
            name: "Test Session",
            workingDirectory: "~/code/voice-code"
        )

        // When: Extracting the last path component
        let displayPath = URL(fileURLWithPath: session.workingDirectory).lastPathComponent

        // Then: Should show "voice-code"
        XCTAssertEqual(displayPath, "voice-code")
    }

    func testWorkingDirectoryEmpty() throws {
        // Given: A session with an empty working directory
        let session = createTestSession(
            name: "Test Session",
            workingDirectory: ""
        )

        // When: Extracting the last path component
        let displayPath = URL(fileURLWithPath: session.workingDirectory).lastPathComponent

        // Then: Empty path resolves to "/" (root)
        XCTAssertEqual(displayPath, "/")
    }

    func testWorkingDirectoryComplex() throws {
        // Given: A session with a complex nested path
        let session = createTestSession(
            name: "Test Session",
            workingDirectory: "/Users/travis/code/mono/active/voice-code-queue-project"
        )

        // When: Extracting the last path component
        let displayPath = URL(fileURLWithPath: session.workingDirectory).lastPathComponent

        // Then: Should show only the most relevant part
        XCTAssertEqual(displayPath, "voice-code-queue-project")
    }

    // MARK: - Session Row Content Integration Tests

    func testSessionRowContentDisplaysRequiredFields() throws {
        // Given: A session with all required fields
        let session = createTestSession(
            name: "My Session",
            workingDirectory: "/Users/username/projects/app"
        )
        session.messageCount = 5
        session.preview = "This is a preview message"
        session.unreadCount = 2

        // Then: Verify all fields are accessible for display
        XCTAssertEqual(session.displayName(context: context), "My Session")
        XCTAssertEqual(session.messageCount, 5)
        XCTAssertEqual(session.preview, "This is a preview message")
        XCTAssertEqual(session.unreadCount, 2)
        XCTAssertEqual(URL(fileURLWithPath: session.workingDirectory).lastPathComponent, "app")
    }

    func testSessionRowContentWithNoPreview() throws {
        // Given: A session with no preview
        let session = createTestSession(
            name: "Empty Session",
            workingDirectory: "/test/path"
        )
        session.messageCount = 0
        session.preview = ""

        // Then: Preview should be empty string
        XCTAssertEqual(session.preview, "")
        XCTAssertTrue(session.preview.isEmpty)
    }

    func testSessionRowContentWithNoUnreadMessages() throws {
        // Given: A session with no unread messages
        let session = createTestSession(
            name: "Read Session",
            workingDirectory: "/test/path"
        )
        session.unreadCount = 0

        // Then: Unread count should be 0
        XCTAssertEqual(session.unreadCount, 0)
    }

    func testMultipleSessionsShowDifferentDirectories() throws {
        // Given: Multiple sessions with different working directories
        let session1 = createTestSession(
            name: "Session 1",
            workingDirectory: "/Users/username/projects/backend"
        )
        let session2 = createTestSession(
            name: "Session 2",
            workingDirectory: "/Users/username/projects/frontend"
        )
        let session3 = createTestSession(
            name: "Session 3",
            workingDirectory: "/tmp/scratch"
        )

        // When: Extracting last path components
        let path1 = URL(fileURLWithPath: session1.workingDirectory).lastPathComponent
        let path2 = URL(fileURLWithPath: session2.workingDirectory).lastPathComponent
        let path3 = URL(fileURLWithPath: session3.workingDirectory).lastPathComponent

        // Then: Each should show its unique directory name
        XCTAssertEqual(path1, "backend")
        XCTAssertEqual(path2, "frontend")
        XCTAssertEqual(path3, "scratch")
    }

    // MARK: - Helper Methods

    private func createTestSession(name: String, workingDirectory: String) -> CDBackendSession {
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = name
        session.workingDirectory = workingDirectory
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.isLocallyCreated = false
        session.unreadCount = 0
        session.isInQueue = false
        session.queuePosition = Int32(0)
        session.queuedAt = nil

        return session
    }
}
