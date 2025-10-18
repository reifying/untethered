// SessionSyncManagerTests.swift
// Unit tests for SessionSyncManager

import XCTest
import CoreData
@testable import VoiceCode

final class SessionSyncManagerTests: XCTestCase {
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!
    var syncManager: SessionSyncManager!
    
    override func setUpWithError() throws {
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
        syncManager = SessionSyncManager(persistenceController: persistenceController)
    }
    
    override func tearDownWithError() throws {
        syncManager = nil
        persistenceController = nil
        context = nil
    }
    
    // MARK: - Session List Tests
    
    func testHandleSessionList() throws {
        let sessions: [[String: Any]] = [
            [
                "session_id": UUID().uuidString,
                "name": "Terminal: voice-code - 2025-10-17 14:30",
                "working_directory": "/Users/test/code/voice-code",
                "last_modified": 1697481456000.0,
                "message_count": 24,
                "preview": "Last message preview"
            ],
            [
                "session_id": UUID().uuidString,
                "name": "Terminal: mono - 2025-10-17 15:00",
                "working_directory": "/Users/test/code/mono",
                "last_modified": 1697483200000.0,
                "message_count": 12,
                "preview": "Another preview"
            ]
        ]
        
        syncManager.handleSessionList(sessions)
        
        // Wait for background save
        let expectation = XCTestExpectation(description: "Wait for save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
        
        // Verify sessions were saved
        let fetchRequest = CDSession.fetchRequest()
        let savedSessions = try context.fetch(fetchRequest)
        
        XCTAssertEqual(savedSessions.count, 2)
        
        let firstSession = savedSessions.first { $0.backendName.contains("voice-code") }
        XCTAssertNotNil(firstSession)
        XCTAssertEqual(firstSession?.messageCount, 24)
        XCTAssertEqual(firstSession?.preview, "Last message preview")
    }
    
    func testHandleSessionListUpdatesExisting() throws {
        let sessionId = UUID()
        
        // Create initial session
        let initialSession = CDSession(context: context)
        initialSession.id = sessionId
        initialSession.backendName = "Old Name"
        initialSession.workingDirectory = "/old/path"
        initialSession.lastModified = Date(timeIntervalSince1970: 1000)
        initialSession.messageCount = 5
        initialSession.preview = "Old preview"
        initialSession.markedDeleted = false
        
        try context.save()
        
        // Handle session list with updated data
        let sessions: [[String: Any]] = [
            [
                "session_id": sessionId.uuidString,
                "name": "Updated Name",
                "working_directory": "/new/path",
                "last_modified": 1697481456000.0,
                "message_count": 10,
                "preview": "New preview"
            ]
        ]
        
        syncManager.handleSessionList(sessions)
        
        // Wait for background save
        let expectation = XCTestExpectation(description: "Wait for save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
        
        // Refetch and verify updates
        context.refreshAllObjects()
        let fetchRequest = CDSession.fetchSession(id: sessionId)
        let updated = try context.fetch(fetchRequest).first
        
        XCTAssertNotNil(updated)
        XCTAssertEqual(updated?.backendName, "Updated Name")
        XCTAssertEqual(updated?.workingDirectory, "/new/path")
        XCTAssertEqual(updated?.messageCount, 10)
        XCTAssertEqual(updated?.preview, "New preview")
    }
    
    // MARK: - Session Created Tests
    
    func testHandleSessionCreated() throws {
        let sessionData: [String: Any] = [
            "session_id": UUID().uuidString,
            "name": "Terminal: new-project - 2025-10-17 16:00",
            "working_directory": "/Users/test/code/new-project",
            "last_modified": 1697485600000.0,
            "message_count": 0,
            "preview": ""
        ]
        
        syncManager.handleSessionCreated(sessionData)
        
        // Wait for background save
        let expectation = XCTestExpectation(description: "Wait for save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
        
        // Verify session was created
        let fetchRequest = CDSession.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "backendName CONTAINS[c] %@", "new-project")
        let sessions = try context.fetch(fetchRequest)
        
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.messageCount, 0)
        XCTAssertEqual(sessions.first?.preview, "")
    }
    
    func testHandleSessionCreatedIgnoresInvalidData() throws {
        let invalidSessionData: [String: Any] = [
            "name": "Missing session_id",
            "working_directory": "/test"
        ]
        
        syncManager.handleSessionCreated(invalidSessionData)
        
        // Wait a bit
        let expectation = XCTestExpectation(description: "Wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 0.5)
        
        // Verify no session was created
        let fetchRequest = CDSession.fetchRequest()
        let sessions = try context.fetch(fetchRequest)
        
        XCTAssertEqual(sessions.count, 0)
    }
    
    // MARK: - Session Updated Tests

    func testHandleSessionUpdatedNonexistentSession() throws {
        let nonexistentId = UUID()
        
        let messages: [[String: Any]] = [
            [
                "role": "user",
                "text": "Test message",
                "timestamp": 1697485000000.0
            ]
        ]
        
        syncManager.handleSessionUpdated(sessionId: nonexistentId.uuidString, messages: messages)
        
        // Wait a bit
        let expectation = XCTestExpectation(description: "Wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 0.5)
        
        // Verify no messages were created
        let messageFetchRequest = CDMessage.fetchMessages(sessionId: nonexistentId)
        let savedMessages = try context.fetch(messageFetchRequest)
        
        XCTAssertEqual(savedMessages.count, 0)
    }
    
    // MARK: - Edge Cases
    
    func testHandleEmptySessionList() throws {
        syncManager.handleSessionList([])
        
        // Wait a bit
        let expectation = XCTestExpectation(description: "Wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 0.5)
        
        let fetchRequest = CDSession.fetchRequest()
        let sessions = try context.fetch(fetchRequest)
        
        XCTAssertEqual(sessions.count, 0)
    }
    
    func testHandleSessionUpdatedWithEmptyMessages() throws {
        let sessionId = UUID()
        
        // Create session
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Test"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.markedDeleted = false
        
        try context.save()
        
        syncManager.handleSessionUpdated(sessionId: sessionId.uuidString, messages: [])
        
        // Wait a bit
        let expectation = XCTestExpectation(description: "Wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 0.5)
        
        // Should still update lastModified even with no messages
        context.refreshAllObjects()
        let fetchRequest = CDSession.fetchSession(id: sessionId)
        let updated = try context.fetch(fetchRequest).first
        
        XCTAssertNotNil(updated)
        XCTAssertEqual(updated?.messageCount, 0)
    }

    // MARK: - Content Extraction Tests

    func testExtractTextFromTextBlock() throws {
        let messageData: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [
                    ["type": "text", "text": "This is a text response"]
                ]
            ]
        ]

        let text = syncManager.extractText(from: messageData)
        XCTAssertEqual(text, "This is a text response")
    }

    func testExtractTextFromMultipleTextBlocks() throws {
        let messageData: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [
                    ["type": "text", "text": "First block"],
                    ["type": "text", "text": "Second block"]
                ]
            ]
        ]

        let text = syncManager.extractText(from: messageData)
        XCTAssertEqual(text, "First block\n\nSecond block")
    }

    func testExtractTextFromToolUseBlock() throws {
        let messageData: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [
                    [
                        "type": "tool_use",
                        "name": "Read",
                        "input": ["file_path": "/path/to/file.swift"]
                    ]
                ]
            ]
        ]

        let text = syncManager.extractText(from: messageData)
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("🔧 Read"))
        XCTAssertTrue(text!.contains("file.swift"))
    }

    func testExtractTextFromToolUseWithPattern() throws {
        let messageData: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [
                    [
                        "type": "tool_use",
                        "name": "Grep",
                        "input": ["pattern": "VPN|vpn"]
                    ]
                ]
            ]
        ]

        let text = syncManager.extractText(from: messageData)
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("🔧 Grep"))
        XCTAssertTrue(text!.contains("pattern"))
        XCTAssertTrue(text!.contains("VPN|vpn"))
    }

    func testExtractTextFromToolUseWithCommand() throws {
        let messageData: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [
                    [
                        "type": "tool_use",
                        "name": "Bash",
                        "input": ["command": "clj -M:test"]
                    ]
                ]
            ]
        ]

        let text = syncManager.extractText(from: messageData)
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("🔧 Bash"))
        XCTAssertTrue(text!.contains("clj -M:test"))
    }

    func testExtractTextFromToolResultSuccess() throws {
        let messageData: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [
                    [
                        "type": "tool_result",
                        "content": String(repeating: "x", count: 6000)
                    ]
                ]
            ]
        ]

        let text = syncManager.extractText(from: messageData)
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("✓ Result"))
        XCTAssertTrue(text!.contains("KB"))
    }

    func testExtractTextFromToolResultError() throws {
        let messageData: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [
                    [
                        "type": "tool_result",
                        "is_error": true,
                        "content": "File not found: /path/to/missing.file"
                    ]
                ]
            ]
        ]

        let text = syncManager.extractText(from: messageData)
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("✗ Error"))
        XCTAssertTrue(text!.contains("File not found"))
    }

    func testExtractTextFromThinkingBlock() throws {
        let messageData: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [
                    [
                        "type": "thinking",
                        "thinking": "The user is asking about VPN setup. I should search the codebase for VPN-related documentation."
                    ]
                ]
            ]
        ]

        let text = syncManager.extractText(from: messageData)
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.hasPrefix("💭"))
        XCTAssertTrue(text!.contains("VPN setup"))
    }

    func testExtractTextFromThinkingBlockTruncated() throws {
        let longThinking = String(repeating: "This is a very long thinking process. ", count: 10)
        let messageData: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [
                    [
                        "type": "thinking",
                        "thinking": longThinking
                    ]
                ]
            ]
        ]

        let text = syncManager.extractText(from: messageData)
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.hasPrefix("💭"))
        XCTAssertTrue(text!.hasSuffix("..."))
        XCTAssertLessThan(text!.count, 80) // Should be truncated
    }

    func testExtractTextFromMixedContentBlocks() throws {
        let messageData: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [
                    ["type": "thinking", "thinking": "I need to search for VPN config"],
                    ["type": "text", "text": "Let me search for VPN configuration."],
                    [
                        "type": "tool_use",
                        "name": "Grep",
                        "input": ["pattern": "VPN"]
                    ],
                    [
                        "type": "tool_result",
                        "content": "No matches found"
                    ]
                ]
            ]
        ]

        let text = syncManager.extractText(from: messageData)
        XCTAssertNotNil(text)

        // Verify all parts are present
        XCTAssertTrue(text!.contains("💭"))
        XCTAssertTrue(text!.contains("Let me search for VPN configuration."))
        XCTAssertTrue(text!.contains("🔧 Grep"))
        XCTAssertTrue(text!.contains("✓ Result"))

        // Verify they're separated
        let parts = text!.components(separatedBy: "\n\n")
        XCTAssertEqual(parts.count, 4)
    }

    func testExtractTextFromOnlyToolCalls() throws {
        let messageData: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [
                    [
                        "type": "tool_use",
                        "name": "Read",
                        "input": ["file_path": "/test.swift"]
                    ]
                ]
            ]
        ]

        let text = syncManager.extractText(from: messageData)
        XCTAssertNotNil(text, "Should extract tool call summary even without text blocks")
        XCTAssertTrue(text!.contains("🔧 Read"))
    }

    func testExtractTextFromUserMessage() throws {
        let messageData: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": "Help me fix this bug"
            ]
        ]

        let text = syncManager.extractText(from: messageData)
        XCTAssertEqual(text, "Help me fix this bug")
    }

    func testExtractTextWithUnknownBlockType() throws {
        let messageData: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [
                    ["type": "unknown_type", "data": "something"],
                    ["type": "text", "text": "Normal text"]
                ]
            ]
        ]

        let text = syncManager.extractText(from: messageData)
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("[unknown_type]"))
        XCTAssertTrue(text!.contains("Normal text"))
    }

    func testExtractTextFromEmptyContentArray() throws {
        let messageData: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": []
            ]
        ]

        let text = syncManager.extractText(from: messageData)
        XCTAssertNil(text, "Should return nil for empty content array")
    }

    func testExtractTextFromMissingMessage() throws {
        let messageData: [String: Any] = [
            "type": "assistant"
        ]

        let text = syncManager.extractText(from: messageData)
        XCTAssertNil(text, "Should return nil when message field is missing")
    }

    func testFormatContentSize() throws {
        // Test small sizes (bytes)
        let messageData1: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [
                    [
                        "type": "tool_result",
                        "content": "test"  // 4 bytes
                    ]
                ]
            ]
        ]
        let text1 = syncManager.extractText(from: messageData1)
        XCTAssertNotNil(text1)
        XCTAssertTrue(text1!.contains("bytes"))

        // Test KB sizes
        let messageData2: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [
                    [
                        "type": "tool_result",
                        "content": String(repeating: "x", count: 5000)  // ~5KB
                    ]
                ]
            ]
        ]
        let text2 = syncManager.extractText(from: messageData2)
        XCTAssertNotNil(text2)
        XCTAssertTrue(text2!.contains("KB"))
    }
}
