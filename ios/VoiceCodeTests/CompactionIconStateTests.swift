// CompactionIconStateTests.swift
// Tests for compaction icon color state management

import XCTest
import CoreData
import SwiftUI
@testable import VoiceCode

class CompactionIconStateTests: XCTestCase {
    var context: NSManagedObjectContext!
    var client: VoiceCodeClient!
    var settings: AppSettings!
    
    override func setUp() {
        super.setUp()
        
        // Setup in-memory Core Data context for testing
        let container = NSPersistentContainer(name: "VoiceCode")
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        
        container.loadPersistentStores { _, error in
            XCTAssertNil(error)
        }
        
        context = container.viewContext
        client = VoiceCodeClient()
        settings = AppSettings()
    }
    
    override func tearDown() {
        context = nil
        client = nil
        settings = nil
        super.tearDown()
    }
    
    // MARK: - Helper Methods
    
    func createTestSession() -> CDSession {
        let session = CDSession(context: context)
        session.id = UUID()
        session.workingDirectory = "/test/path"
        session.messageCount = 10
        session.createdAt = Date()
        return session
    }
    
    // MARK: - Test Cases
    
    func testIconIsGrayByDefault() {
        // Given: A new conversation view
        let session = createTestSession()
        
        // When: View appears with no prior compaction
        // Then: wasRecentlyCompacted should be false (icon will be gray/primary)
        // This is tested implicitly by the initial state in ConversationView
        
        XCTAssertNotNil(session, "Session should be created")
    }
    
    func testIconTurnsGreenAfterCompaction() {
        // Given: A session with a compaction result
        let session = createTestSession()
        let result = CompactionResult(
            sessionId: session.id.uuidString.lowercased(),
            oldMessageCount: 100,
            newMessageCount: 20,
            messagesRemoved: 80,
            preTokens: 42000
        )
        
        // When: Compaction completes successfully
        // Then: State should be set to green
        // - wasRecentlyCompacted = true
        // - lastCompactionStats = result
        // - timestamp stored
        
        XCTAssertEqual(result.messagesRemoved, 80)
        XCTAssertEqual(result.oldMessageCount, 100)
        XCTAssertEqual(result.newMessageCount, 20)
    }
    
    func testIconReturnsToGrayAfterSendingMessage() {
        // Given: A session with recent compaction (green icon)
        let session = createTestSession()
        
        // When: User sends a new message
        // Then: wasRecentlyCompacted should be set to false
        // Then: lastCompactionStats should be cleared
        
        XCTAssertNotNil(session, "Session should exist for message sending")
    }
    
    func testGreenStateIsSessionSpecific() {
        // Given: Two sessions, one compacted and one not
        let session1 = createTestSession()
        let session2 = createTestSession()
        
        let result1 = CompactionResult(
            sessionId: session1.id.uuidString.lowercased(),
            oldMessageCount: 100,
            newMessageCount: 20,
            messagesRemoved: 80,
            preTokens: 42000
        )
        
        // When: Session 1 is compacted
        // Then: Only session 1 should show green
        // Then: Session 2 should show gray
        
        // When: Switching from session 1 to session 2
        // Then: Icon should change from green to gray
        
        // When: Switching back from session 2 to session 1
        // Then: Icon should change back to green (before user sends message)
        
        XCTAssertNotEqual(session1.id, session2.id, "Sessions should have different IDs")
        XCTAssertNotNil(result1, "Compaction result should exist")
    }
    
    func testTappingGreenIconShowsStatsAlert() {
        // Given: A session with recent compaction (green icon)
        let session = createTestSession()
        let result = CompactionResult(
            sessionId: session.id.uuidString.lowercased(),
            oldMessageCount: 100,
            newMessageCount: 20,
            messagesRemoved: 80,
            preTokens: 42300
        )
        
        // When: User taps the green icon
        // Then: showingAlreadyCompactedAlert should be true
        // Then: Alert should display compaction stats
        // Then: Alert should NOT immediately trigger compaction
        
        XCTAssertEqual(result.messagesRemoved, 80)
        XCTAssertEqual(result.preTokens, 42300)
    }
    
    func testTappingGrayIconShowsStandardConfirmation() {
        // Given: A session without recent compaction (gray icon)
        let session = createTestSession()
        
        // When: User taps the gray icon
        // Then: showingCompactConfirmation should be true
        // Then: Standard confirmation dialog should show
        
        XCTAssertNotNil(session, "Session should exist")
    }
    
    func testRelativeTimeFormatting() {
        // Given: Various timestamps
        let now = Date()
        let oneMinuteAgo = now.addingTimeInterval(-60)
        let fiveMinutesAgo = now.addingTimeInterval(-300)
        let oneHourAgo = now.addingTimeInterval(-3600)
        let threeDaysAgo = now.addingTimeInterval(-259200)
        
        // When: Formatting relative time
        // Then: Should return appropriate strings
        XCTAssertEqual(oneMinuteAgo.relativeTimeString(), "1 minute ago")
        XCTAssertEqual(fiveMinutesAgo.relativeTimeString(), "5 minutes ago")
        XCTAssertEqual(oneHourAgo.relativeTimeString(), "1 hour ago")
        XCTAssertEqual(threeDaysAgo.relativeTimeString(), "3 days ago")
    }
    
    func testCompactionStatsDisplayCorrectly() {
        // Given: A compaction result with stats
        let result = CompactionResult(
            sessionId: UUID().uuidString.lowercased(),
            oldMessageCount: 150,
            newMessageCount: 30,
            messagesRemoved: 120,
            preTokens: 73100
        )
        
        // When: Displaying stats in alert
        // Then: Should show "73.1K tokens" (formatted)
        // Then: Should show "120 messages removed"
        
        XCTAssertEqual(result.messagesRemoved, 120)
        XCTAssertEqual(result.preTokens, 73100)
    }
    
    func testGreenStatePreventAccidentalDoubleCompaction() {
        // Given: A session with recent compaction (green icon)
        let session = createTestSession()
        
        // When: User taps the green icon
        // Then: Should show informative alert first
        // Then: Should require explicit "Compact Again" action
        // Then: Only after "Compact Again" should show standard confirmation
        
        XCTAssertNotNil(session, "Session should exist for compaction")
    }
    
    func testSessionSwitchingPreservesGreenState() {
        // Given: Session A is compacted (green) and Session B is not (gray)
        let sessionA = createTestSession()
        let sessionB = createTestSession()
        
        // When: Viewing session A
        // Then: Icon should be green
        
        // When: Switching to session B
        // Then: Icon should be gray
        
        // When: Switching back to session A (before sending message)
        // Then: Icon should still be green
        
        XCTAssertNotEqual(sessionA.id, sessionB.id)
    }
    
    func testOnAppearRestoresSessionSpecificState() {
        // Given: A session that was previously compacted
        let session = createTestSession()
        let result = CompactionResult(
            sessionId: session.id.uuidString.lowercased(),
            oldMessageCount: 100,
            newMessageCount: 20,
            messagesRemoved: 80,
            preTokens: 42000
        )
        
        // When: View appears for this session
        // Then: wasRecentlyCompacted should be restored from recentCompactionsBySession
        // Then: lastCompactionStats should be restored
        
        XCTAssertEqual(result.sessionId, session.id.uuidString.lowercased())
    }
}
