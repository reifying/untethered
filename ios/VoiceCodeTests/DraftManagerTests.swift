//
//  DraftManagerTests.swift
//  VoiceCodeTests
//
//  Tests for DraftManager persistence
//

import Testing
import Foundation
@testable import VoiceCode

struct DraftManagerTests {

    @Test func testSaveAndGetDraft() async throws {
        // Clear any existing data
        UserDefaults.standard.removeObject(forKey: "sessionDrafts")

        let manager = DraftManager()
        let sessionID = "test-session-123"
        let draftText = "This is a test draft"

        // Save draft
        manager.saveDraft(sessionID: sessionID, text: draftText)

        // Retrieve draft
        let retrieved = manager.getDraft(sessionID: sessionID)
        #expect(retrieved == draftText)
    }

    @Test func testEmptyDraftRemovesEntry() async throws {
        UserDefaults.standard.removeObject(forKey: "sessionDrafts")

        let manager = DraftManager()
        let sessionID = "test-session-456"

        // Save then clear with empty string
        manager.saveDraft(sessionID: sessionID, text: "Some text")
        manager.saveDraft(sessionID: sessionID, text: "")

        // Should return empty string (entry removed)
        let retrieved = manager.getDraft(sessionID: sessionID)
        #expect(retrieved == "")
    }

    @Test func testClearDraft() async throws {
        UserDefaults.standard.removeObject(forKey: "sessionDrafts")

        let manager = DraftManager()
        let sessionID = "test-session-789"

        // Save and clear
        manager.saveDraft(sessionID: sessionID, text: "Draft to clear")
        manager.clearDraft(sessionID: sessionID)

        // Should be empty
        let retrieved = manager.getDraft(sessionID: sessionID)
        #expect(retrieved == "")
    }

    @Test func testPersistenceAcrossInstances() async throws {
        UserDefaults.standard.removeObject(forKey: "sessionDrafts")

        let sessionID = "test-session-persist"
        let draftText = "Persistent draft"

        // Save with first instance
        let manager1 = DraftManager()
        manager1.saveDraft(sessionID: sessionID, text: draftText)

        // Force UserDefaults to synchronize
        UserDefaults.standard.synchronize()

        // Load with second instance (simulates app restart)
        let manager2 = DraftManager()
        let retrieved = manager2.getDraft(sessionID: sessionID)

        #expect(retrieved == draftText)
    }

    @Test func testMultipleDrafts() async throws {
        UserDefaults.standard.removeObject(forKey: "sessionDrafts")

        let manager = DraftManager()

        // Save multiple drafts
        manager.saveDraft(sessionID: "session-1", text: "Draft 1")
        manager.saveDraft(sessionID: "session-2", text: "Draft 2")
        manager.saveDraft(sessionID: "session-3", text: "Draft 3")

        // Verify each is independent
        #expect(manager.getDraft(sessionID: "session-1") == "Draft 1")
        #expect(manager.getDraft(sessionID: "session-2") == "Draft 2")
        #expect(manager.getDraft(sessionID: "session-3") == "Draft 3")
    }

    @Test func testCleanupDraft() async throws {
        UserDefaults.standard.removeObject(forKey: "sessionDrafts")

        let manager = DraftManager()
        let sessionID = "test-session-cleanup"

        // Save and cleanup
        manager.saveDraft(sessionID: sessionID, text: "Draft to cleanup")
        manager.cleanupDraft(sessionID: sessionID)

        // Should be empty
        let retrieved = manager.getDraft(sessionID: sessionID)
        #expect(retrieved == "")
    }
}
