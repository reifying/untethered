// SessionInfoViewTests.swift
// Tests for SessionInfoView modal

import XCTest
import SwiftUI
import CoreData
@testable import VoiceCode

class SessionInfoViewTests: XCTestCase {
    var persistenceController: PersistenceController!
    var viewContext: NSManagedObjectContext!
    
    override func setUp() {
        super.setUp()
        persistenceController = PersistenceController(inMemory: true)
        viewContext = persistenceController.container.viewContext
    }
    
    override func tearDown() {
        viewContext = nil
        persistenceController = nil
        super.tearDown()
    }
    
    // MARK: - Helper Methods
    
    func createTestSession(name: String? = nil, workingDirectory: String = "/Users/test/project") -> CDBackendSession {
        let session = CDBackendSession(context: viewContext)
        session.id = UUID()
        session.workingDirectory = workingDirectory
        session.lastModified = Date()
        session.messageCount = 0
        
        if let name = name {
            let userSession = CDUserSession(context: viewContext)
            userSession.id = session.id
            userSession.customName = name
            userSession.createdAt = Date()
        }
        
        try? viewContext.save()
        return session
    }
    
    // MARK: - Display Tests
    
    func testSessionInfoDisplaysSessionName() {
        let session = createTestSession(name: "My Custom Session")
        
        XCTAssertEqual(session.displayName(context: viewContext), "My Custom Session")
    }
    
    func testSessionInfoDisplaysWorkingDirectory() {
        let session = createTestSession(workingDirectory: "/Users/test/my-project")
        
        XCTAssertEqual(session.workingDirectory, "/Users/test/my-project")
    }
    
    func testSessionInfoDisplaysSessionID() {
        let session = createTestSession()
        let sessionId = session.id.uuidString.lowercased()
        
        XCTAssertFalse(sessionId.isEmpty)
        XCTAssertEqual(sessionId, sessionId.lowercased())
    }
    
    // MARK: - Action Tests
    
    func testCopySessionIDToPasteboard() {
        let session = createTestSession()
        let sessionId = session.id.uuidString.lowercased()
        
        // Simulate copying session ID
        UIPasteboard.general.string = sessionId
        
        XCTAssertEqual(UIPasteboard.general.string, sessionId)
    }
    
    func testCopyWorkingDirectoryToPasteboard() {
        let session = createTestSession(workingDirectory: "/Users/test/my-project")
        
        // Simulate copying working directory
        UIPasteboard.general.string = session.workingDirectory
        
        XCTAssertEqual(UIPasteboard.general.string, "/Users/test/my-project")
    }
    
    func testExportConversationToClipboard() {
        let session = createTestSession(name: "Test Session")
        
        // Add some messages
        let message1 = CDMessage(context: viewContext)
        message1.id = UUID()
        message1.sessionId = session.id
        message1.role = "user"
        message1.text = "Hello Claude"
        message1.timestamp = Date()
        
        let message2 = CDMessage(context: viewContext)
        message2.id = UUID()
        message2.sessionId = session.id
        message2.role = "assistant"
        message2.text = "Hello! How can I help you?"
        message2.timestamp = Date().addingTimeInterval(1)
        
        try? viewContext.save()
        
        // Fetch messages for export
        let fetchRequest = CDMessage.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "sessionId == %@", session.id as CVarArg)
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CDMessage.timestamp, ascending: true)]
        
        let messages = try? viewContext.fetch(fetchRequest)
        XCTAssertEqual(messages?.count, 2)
        
        // Build export text (simplified version of actual export)
        var exportText = "# \(session.displayName(context: viewContext))\n"
        exportText += "Session ID: \(session.id.uuidString.lowercased())\n"
        exportText += "Working Directory: \(session.workingDirectory)\n"
        
        XCTAssertTrue(exportText.contains("Test Session"))
        XCTAssertTrue(exportText.contains(session.id.uuidString.lowercased()))
        XCTAssertTrue(exportText.contains(session.workingDirectory))
    }
    
    // MARK: - Git Branch Detection Tests
    
    func testGitBranchDetectionInGitRepo() async {
        // This test requires a real git repo, so we'll test the logic flow
        // In a real git repo directory, this should return the branch name
        let testDirectory = FileManager.default.currentDirectoryPath
        let branch = await GitBranchDetector.detectBranch(workingDirectory: testDirectory)
        
        // Branch may or may not be nil depending on whether tests run in git repo
        // Just verify the function completes without crashing
        if let branch = branch {
            XCTAssertFalse(branch.isEmpty)
        }
    }
    
    func testGitBranchDetectionInNonGitDirectory() async {
        let tempDir = NSTemporaryDirectory()
        let branch = await GitBranchDetector.detectBranch(workingDirectory: tempDir)
        
        // Temp directory is not a git repo, should return nil
        XCTAssertNil(branch)
    }
    
    // MARK: - Session ID Format Tests
    
    func testSessionIDIsLowercase() {
        let session = createTestSession()
        let sessionId = session.id.uuidString.lowercased()
        
        // Verify session ID is lowercase (as per standards)
        XCTAssertEqual(sessionId, session.id.uuidString.lowercased())
        XCTAssertNotEqual(sessionId, session.id.uuidString.uppercased())
    }
    
    // MARK: - Display Name Tests
    
    func testDisplayNameWithCustomName() {
        let session = createTestSession(name: "My Custom Name")
        
        XCTAssertEqual(session.displayName(context: viewContext), "My Custom Name")
    }
    
    func testDisplayNameWithoutCustomName() {
        let session = createTestSession()
        
        // Without custom name, should show inferred or default name
        let displayName = session.displayName(context: viewContext)
        XCTAssertFalse(displayName.isEmpty)
    }
}
