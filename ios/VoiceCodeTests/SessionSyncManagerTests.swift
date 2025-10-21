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
        initialSession.isLocallyCreated = false

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

    func testHandleSessionListClearsLocallyCreatedFlag() throws {
        let sessionId = UUID()

        // Create locally created session (user created it in iOS app)
        let localSession = CDSession(context: context)
        localSession.id = sessionId
        localSession.backendName = "Local Session"
        localSession.workingDirectory = "/test"
        localSession.lastModified = Date()
        localSession.messageCount = 0
        localSession.preview = ""
        localSession.markedDeleted = false
        localSession.isLocallyCreated = true

        try context.save()

        // Verify flag is set
        XCTAssertTrue(localSession.isLocallyCreated)

        // Backend syncs session (after first message is sent)
        let sessions: [[String: Any]] = [
            [
                "session_id": sessionId.uuidString,
                "name": "Local Session",
                "working_directory": "/test",
                "last_modified": Date().timeIntervalSince1970 * 1000,
                "message_count": 2,
                "preview": "First message"
            ]
        ]

        syncManager.handleSessionList(sessions)

        // Wait for background save
        let expectation = XCTestExpectation(description: "Wait for save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Refetch and verify isLocallyCreated is cleared
        context.refreshAllObjects()
        let fetchRequest = CDSession.fetchSession(id: sessionId)
        let updated = try context.fetch(fetchRequest).first

        XCTAssertNotNil(updated)
        XCTAssertFalse(updated!.isLocallyCreated, "isLocallyCreated should be cleared when session is synced from backend")
        XCTAssertEqual(updated?.messageCount, 2)
    }
    
    // MARK: - Session Created Tests
    
    func testHandleSessionCreated() throws {
        let sessionData: [String: Any] = [
            "session_id": UUID().uuidString,
            "name": "Terminal: new-project - 2025-10-17 16:00",
            "working_directory": "/Users/test/code/new-project",
            "last_modified": 1697485600000.0,
            "message_count": 1,
            "preview": "First message"
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
        XCTAssertEqual(sessions.first?.messageCount, 1)
        XCTAssertEqual(sessions.first?.preview, "First message")
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

    func testHandleSessionUpdatedCreatesNonexistentSession() throws {
        // voice-code-201: Session creation from session_updated
        let nonexistentId = UUID()

        let messages: [[String: Any]] = [
            [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": "Test message"
                ],
                "timestamp": "2024-01-01T12:00:00.000Z",
                "uuid": UUID().uuidString
            ],
            [
                "type": "assistant",
                "message": [
                    "role": "assistant",
                    "content": [
                        ["type": "text", "text": "Test response"]
                    ]
                ],
                "timestamp": "2024-01-01T12:00:01.000Z",
                "uuid": UUID().uuidString
            ]
        ]

        syncManager.handleSessionUpdated(sessionId: nonexistentId.uuidString, messages: messages)

        // Wait for background save
        let expectation = XCTestExpectation(description: "Wait for save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Verify session was created
        context.refreshAllObjects()
        let sessionFetchRequest = CDSession.fetchSession(id: nonexistentId)
        let createdSession = try context.fetch(sessionFetchRequest).first

        XCTAssertNotNil(createdSession, "Session should be created from session_updated")
        XCTAssertEqual(createdSession?.id, nonexistentId)
        XCTAssertEqual(createdSession?.backendName, "", "backendName should be empty until session_list syncs")
        XCTAssertEqual(createdSession?.workingDirectory, "", "workingDirectory should be empty until session_list syncs")
        XCTAssertEqual(createdSession?.messageCount, 2, "messageCount should match messages added")
        XCTAssertFalse(createdSession?.markedDeleted ?? true)
        XCTAssertFalse(createdSession?.isLocallyCreated ?? true)
        XCTAssertEqual(createdSession?.unreadCount, 2, "unreadCount should be incremented for background session")

        // Verify messages were created
        let messageFetchRequest = CDMessage.fetchMessages(sessionId: nonexistentId)
        let savedMessages = try context.fetch(messageFetchRequest)

        XCTAssertEqual(savedMessages.count, 2, "Messages should be created")
        XCTAssertEqual(savedMessages.filter { $0.role == "user" }.count, 1)
        XCTAssertEqual(savedMessages.filter { $0.role == "assistant" }.count, 1)

        // Verify lastModified is recent
        let now = Date()
        XCTAssertNotNil(createdSession?.lastModified)
        XCTAssertLessThanOrEqual(createdSession!.lastModified.timeIntervalSince(now), 2.0,
                                "lastModified should be set to approximately now")
    }

    func testHandleSessionUpdatedExistingSessionStillWorksNormally() throws {
        // voice-code-201: Existing session flow unchanged
        let sessionId = UUID()

        // Create session first via session_list
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Existing Session"
        session.workingDirectory = "/test/path"
        session.lastModified = Date(timeIntervalSince1970: Date().timeIntervalSince1970 - 1000)
        session.messageCount = 2
        session.preview = "Old preview"
        session.unreadCount = 0
        session.markedDeleted = false
        session.isLocallyCreated = false

        try context.save()

        // Send update
        let messages: [[String: Any]] = [
            [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": "New message"
                ],
                "timestamp": "2024-01-01T12:00:00.000Z",
                "uuid": UUID().uuidString
            ]
        ]

        syncManager.handleSessionUpdated(sessionId: sessionId.uuidString, messages: messages)

        // Wait for background save
        let expectation = XCTestExpectation(description: "Wait for save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Verify session was updated (not created)
        context.refreshAllObjects()
        let sessionFetchRequest = CDSession.fetchSession(id: sessionId)
        let updatedSession = try context.fetch(sessionFetchRequest).first

        XCTAssertNotNil(updatedSession)
        XCTAssertEqual(updatedSession?.backendName, "Existing Session", "Metadata should be preserved")
        XCTAssertEqual(updatedSession?.workingDirectory, "/test/path", "Metadata should be preserved")
        XCTAssertEqual(updatedSession?.messageCount, 3, "messageCount should be incremented")

        // Verify only one session exists
        let allSessionsFetch = CDSession.fetchRequest()
        let allSessions = try context.fetch(allSessionsFetch)
        XCTAssertEqual(allSessions.count, 1, "Should only have one session (not duplicated)")
    }

    func testSessionCreatedFromUpdateSyncsMetadataOnSessionList() throws {
        // voice-code-201: Created session syncs metadata on next session_list
        let sessionId = UUID()

        // First: session_updated creates session with partial metadata
        let messages: [[String: Any]] = [
            [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": "Initial message"
                ],
                "timestamp": "2024-01-01T12:00:00.000Z",
                "uuid": UUID().uuidString
            ]
        ]

        syncManager.handleSessionUpdated(sessionId: sessionId.uuidString, messages: messages)

        // Wait for background save
        var expectation = XCTestExpectation(description: "Wait for update save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Verify session created with empty metadata
        context.refreshAllObjects()
        var sessionFetchRequest = CDSession.fetchSession(id: sessionId)
        var session = try context.fetch(sessionFetchRequest).first

        XCTAssertNotNil(session)
        XCTAssertEqual(session?.backendName, "")
        XCTAssertEqual(session?.workingDirectory, "")

        // Second: session_list provides full metadata
        let sessionList: [[String: Any]] = [
            [
                "session_id": sessionId.uuidString,
                "name": "Terminal: voice-code - 2025-10-20",
                "working_directory": "/Users/test/code/voice-code",
                "last_modified": Date().timeIntervalSince1970 * 1000,
                "message_count": 1,
                "preview": "Initial message"
            ]
        ]

        syncManager.handleSessionList(sessionList)

        // Wait for background save
        expectation = XCTestExpectation(description: "Wait for list save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Verify metadata now populated
        context.refreshAllObjects()
        sessionFetchRequest = CDSession.fetchSession(id: sessionId)
        session = try context.fetch(sessionFetchRequest).first

        XCTAssertNotNil(session)
        XCTAssertEqual(session?.backendName, "Terminal: voice-code - 2025-10-20")
        XCTAssertEqual(session?.workingDirectory, "/Users/test/code/voice-code")

        // Verify still only one session (no duplicate)
        let allSessionsFetch = CDSession.fetchRequest()
        let allSessions = try context.fetch(allSessionsFetch)
        XCTAssertEqual(allSessions.count, 1, "Should still have exactly one session")
    }

    func testMultipleUpdatesForNonexistentSessionNoDuplicates() throws {
        // voice-code-201: Multiple session_updated calls for same session should not create duplicates
        let sessionId = UUID()

        let firstMessages: [[String: Any]] = [
            [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": "First update"
                ],
                "timestamp": "2024-01-01T12:00:00.000Z",
                "uuid": UUID().uuidString
            ]
        ]

        let secondMessages: [[String: Any]] = [
            [
                "type": "assistant",
                "message": [
                    "role": "assistant",
                    "content": [
                        ["type": "text", "text": "Second update"]
                    ]
                ],
                "timestamp": "2024-01-01T12:00:01.000Z",
                "uuid": UUID().uuidString
            ]
        ]

        // Send first update
        syncManager.handleSessionUpdated(sessionId: sessionId.uuidString, messages: firstMessages)

        // Wait for background save
        var expectation = XCTestExpectation(description: "Wait for first save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Send second update
        syncManager.handleSessionUpdated(sessionId: sessionId.uuidString, messages: secondMessages)

        // Wait for background save
        expectation = XCTestExpectation(description: "Wait for second save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Verify only one session exists
        context.refreshAllObjects()
        let sessionFetchRequest = CDSession.fetchRequest()
        let allSessions = try context.fetch(sessionFetchRequest)

        XCTAssertEqual(allSessions.count, 1, "Should only have one session")

        let session = allSessions.first!
        XCTAssertEqual(session.id, sessionId)
        XCTAssertEqual(session.messageCount, 2, "Should have messages from both updates")

        // Verify both messages exist
        let messageFetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
        let savedMessages = try context.fetch(messageFetchRequest)

        XCTAssertEqual(savedMessages.count, 2, "Should have 2 messages total")
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
        session.isLocallyCreated = false

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

    func testExtractTextFromSystemMessage() throws {
        // System messages have content at top level, not nested in "message"
        let messageData: [String: Any] = [
            "type": "system",
            "subtype": "local_command",
            "content": "<command-name>/status</command-name>\n<command-message>status</command-message>",
            "level": "info",
            "timestamp": "2025-10-18T18:39:56.710Z",
            "uuid": "63ae4896-db63-4879-86b3-b564c556a0d4"
        ]

        let text = syncManager.extractText(from: messageData)
        XCTAssertEqual(text, "<command-name>/status</command-name>\n<command-message>status</command-message>")
    }

    func testExtractTextFromSystemMessageWithPlainContent() throws {
        // Test system message with simple plain text content
        let messageData: [String: Any] = [
            "type": "system",
            "content": "System notification message",
            "timestamp": "2025-10-18T18:39:56.710Z"
        ]

        let text = syncManager.extractText(from: messageData)
        XCTAssertEqual(text, "System notification message")
    }

    func testExtractTextFromSummaryMessage() throws {
        // Test summary message (error/status messages with summary field)
        let messageData: [String: Any] = [
            "type": "summary",
            "summary": "API Error: 401 authentication_error · Please run /login",
            "leafUuid": "00efc773-71db-419a-81a4-da764fbabd30"
        ]

        let text = syncManager.extractText(from: messageData)
        XCTAssertEqual(text, "API Error: 401 authentication_error · Please run /login")
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

    // MARK: - Message Filtering Tests

    func testFilterSummaryMessages() throws {
        // Create session
        let sessionId = UUID()
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.markedDeleted = false
        session.isLocallyCreated = false

        try context.save()

        // Create a mix of messages including summary types
        let messages: [[String: Any]] = [
            // Summary message (should be filtered)
            [
                "type": "summary",
                "summary": "API Error: 401 OAuth not supported"
            ],
            // User message (should be kept)
            [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": "Hello"
                ],
                "timestamp": "2024-01-01T12:00:00.000Z"
            ],
            // Another summary message (should be filtered)
            [
                "type": "summary",
                "summary": "Another error message"
            ],
            // Assistant message (should be kept)
            [
                "type": "assistant",
                "message": [
                    "role": "assistant",
                    "content": [
                        ["type": "text", "text": "Hi there"]
                    ]
                ],
                "timestamp": "2024-01-01T12:00:01.000Z"
            ]
        ]

        syncManager.handleSessionUpdated(sessionId: sessionId.uuidString, messages: messages)

        // Wait for background processing
        let expectation = XCTestExpectation(description: "Wait for sync")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Verify only user and assistant messages were created
        context.refreshAllObjects()
        let messageFetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
        let savedMessages = try context.fetch(messageFetchRequest)

        XCTAssertEqual(savedMessages.count, 2, "Should only have 2 messages (user and assistant)")
        XCTAssertEqual(savedMessages.filter { $0.role == "user" }.count, 1)
        XCTAssertEqual(savedMessages.filter { $0.role == "assistant" }.count, 1)
        XCTAssertEqual(savedMessages.filter { $0.role == "summary" }.count, 0, "Summary messages should be filtered")
    }

    func testFilterSystemMessages() throws {
        // Create session
        let sessionId = UUID()
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.markedDeleted = false
        session.isLocallyCreated = false

        try context.save()

        // Create a mix of messages including system types
        let messages: [[String: Any]] = [
            // System message (should be filtered)
            [
                "type": "system",
                "content": "<command-name>/status</command-name>",
                "timestamp": "2024-01-01T12:00:00.000Z"
            ],
            // User message (should be kept)
            [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": "Test"
                ],
                "timestamp": "2024-01-01T12:00:01.000Z"
            ],
            // Another system message (should be filtered)
            [
                "type": "system",
                "content": "<local-command-stdout>Done</local-command-stdout>",
                "timestamp": "2024-01-01T12:00:02.000Z"
            ]
        ]

        syncManager.handleSessionUpdated(sessionId: sessionId.uuidString, messages: messages)

        // Wait for background processing
        let expectation = XCTestExpectation(description: "Wait for sync")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Verify only user message was created
        context.refreshAllObjects()
        let messageFetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
        let savedMessages = try context.fetch(messageFetchRequest)

        XCTAssertEqual(savedMessages.count, 1, "Should only have 1 message (user)")
        XCTAssertEqual(savedMessages.first?.role, "user")
        XCTAssertEqual(savedMessages.filter { $0.role == "system" }.count, 0, "System messages should be filtered")
    }

    func testFilterMixedMessageTypes() throws {
        // Create session
        let sessionId = UUID()
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.markedDeleted = false
        session.isLocallyCreated = false

        try context.save()

        // Create all message types
        let messages: [[String: Any]] = [
            ["type": "summary", "summary": "Error"],
            ["type": "system", "content": "Command", "timestamp": "2024-01-01T12:00:00.000Z"],
            ["type": "user", "message": ["role": "user", "content": "Q"], "timestamp": "2024-01-01T12:00:01.000Z"],
            ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": "A"]]], "timestamp": "2024-01-01T12:00:02.000Z"]
        ]

        syncManager.handleSessionUpdated(sessionId: sessionId.uuidString, messages: messages)

        // Wait for background processing
        let expectation = XCTestExpectation(description: "Wait for sync")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Verify correct message count
        context.refreshAllObjects()
        let sessionFetchRequest = CDSession.fetchSession(id: sessionId)
        let updatedSession = try context.fetch(sessionFetchRequest).first

        XCTAssertEqual(updatedSession?.messageCount, 2, "Message count should only include user and assistant messages")

        let messageFetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
        let savedMessages = try context.fetch(messageFetchRequest)

        XCTAssertEqual(savedMessages.count, 2, "Should have 2 messages (user and assistant)")
    }

    // MARK: - Session History Tests (voice-code-181)

    func testHandleSessionHistoryDoesNotUpdateLastModified() throws {
        // voice-code-184: Verify lastModified is NOT updated during history replay
        let sessionId = UUID()
        let oldTimestamp = Date(timeIntervalSince1970: Date().timeIntervalSince1970 - 3600) // 1 hour ago

        // Create session with known lastModified timestamp
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = oldTimestamp
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.markedDeleted = false
        session.isLocallyCreated = false

        try context.save()

        // Simulate session_history message (history replay)
        let messages: [[String: Any]] = [
            [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": "First message"
                ],
                "timestamp": "2024-01-01T12:00:00.000Z",
                "uuid": UUID().uuidString
            ],
            [
                "type": "assistant",
                "message": [
                    "role": "assistant",
                    "content": [
                        ["type": "text", "text": "Response"]
                    ]
                ],
                "timestamp": "2024-01-01T12:00:01.000Z",
                "uuid": UUID().uuidString
            ]
        ]

        syncManager.handleSessionHistory(sessionId: sessionId.uuidString, messages: messages)

        // Wait for background save
        let expectation = XCTestExpectation(description: "Wait for save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Verify lastModified was NOT changed
        context.refreshAllObjects()
        let fetchRequest = CDSession.fetchSession(id: sessionId)
        let updated = try context.fetch(fetchRequest).first

        XCTAssertNotNil(updated)
        XCTAssertEqual(updated!.lastModified.timeIntervalSince1970,
                      oldTimestamp.timeIntervalSince1970,
                      accuracy: 1.0,
                      "lastModified should NOT be updated during history replay")

        // Verify messageCount WAS updated (we are processing the history)
        XCTAssertEqual(updated?.messageCount, 2, "messageCount should be updated to match history")

        // Verify messages were created
        let messageFetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
        let savedMessages = try context.fetch(messageFetchRequest)
        XCTAssertEqual(savedMessages.count, 2, "Messages should be created from history")
    }

    func testHandleSessionUpdatedUpdatesLastModified() throws {
        // voice-code-185: Verify lastModified IS updated for new messages
        let sessionId = UUID()
        let oldTimestamp = Date(timeIntervalSince1970: Date().timeIntervalSince1970 - 3600) // 1 hour ago

        // Create session with known lastModified timestamp
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = oldTimestamp
        session.messageCount = 2
        session.preview = "Old preview"
        session.unreadCount = 0
        session.markedDeleted = false
        session.isLocallyCreated = false

        try context.save()

        // Simulate session_updated message (NEW messages arriving)
        let messages: [[String: Any]] = [
            [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": "New question"
                ],
                "timestamp": "2024-01-01T13:00:00.000Z",
                "uuid": UUID().uuidString
            ],
            [
                "type": "assistant",
                "message": [
                    "role": "assistant",
                    "content": [
                        ["type": "text", "text": "New response"]
                    ]
                ],
                "timestamp": "2024-01-01T13:00:01.000Z",
                "uuid": UUID().uuidString
            ]
        ]

        let beforeUpdate = Date()
        syncManager.handleSessionUpdated(sessionId: sessionId.uuidString, messages: messages)

        // Wait for background save
        let expectation = XCTestExpectation(description: "Wait for save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Verify lastModified WAS updated to recent time
        context.refreshAllObjects()
        let fetchRequest = CDSession.fetchSession(id: sessionId)
        let updated = try context.fetch(fetchRequest).first

        XCTAssertNotNil(updated)
        XCTAssertGreaterThan(updated!.lastModified, oldTimestamp,
                            "lastModified should be updated when new messages arrive")
        XCTAssertGreaterThanOrEqual(updated!.lastModified, beforeUpdate,
                                   "lastModified should be updated to approximately now")
        XCTAssertLessThanOrEqual(updated!.lastModified.timeIntervalSince(beforeUpdate), 2.0,
                                "lastModified should be within 2 seconds of now")

        // Verify messageCount was incremented
        XCTAssertEqual(updated?.messageCount, 4, "messageCount should be incremented by 2")

        // Verify new messages were created
        let messageFetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
        let savedMessages = try context.fetch(messageFetchRequest)
        XCTAssertEqual(savedMessages.count, 2, "New messages should be created")
    }

    // MARK: - Server Change Tests (voice-code-119, voice-code-151)

    func testClearAllSessions() throws {
        // Create multiple sessions with messages
        let sessionIds = [UUID(), UUID(), UUID()]

        for sessionId in sessionIds {
            let session = CDSession(context: context)
            session.id = sessionId
            session.backendName = "Test Session \(sessionId)"
            session.workingDirectory = "/test"
            session.lastModified = Date()
            session.messageCount = 0
            session.preview = ""
            session.unreadCount = 0
            session.markedDeleted = false
            session.isLocallyCreated = false

            // Add messages to each session
            for i in 0..<3 {
                let message = CDMessage(context: context)
                message.id = UUID()
                message.sessionId = sessionId
                message.role = "user"
                message.text = "Message \(i)"
                message.timestamp = Date()
                message.messageStatus = .confirmed
                message.session = session
            }

            session.messageCount = 3
        }

        try context.save()

        // Verify sessions exist
        let initialFetch = CDSession.fetchRequest()
        let initialSessions = try context.fetch(initialFetch)
        XCTAssertEqual(initialSessions.count, 3, "Should have 3 sessions initially")

        let initialMessageFetch: NSFetchRequest<CDMessage> = CDMessage.fetchRequest()
        let initialMessages = try context.fetch(initialMessageFetch)
        XCTAssertEqual(initialMessages.count, 9, "Should have 9 messages initially (3 per session)")

        // Clear all sessions
        syncManager.clearAllSessions()

        // Wait for background deletion
        let expectation = XCTestExpectation(description: "Wait for deletion")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Verify all sessions deleted
        context.refreshAllObjects()
        let finalFetch = CDSession.fetchRequest()
        let finalSessions = try context.fetch(finalFetch)
        XCTAssertEqual(finalSessions.count, 0, "All sessions should be deleted")

        // Verify all messages deleted (cascade)
        let finalMessageFetch: NSFetchRequest<CDMessage> = CDMessage.fetchRequest()
        let finalMessages = try context.fetch(finalMessageFetch)
        XCTAssertEqual(finalMessages.count, 0, "All messages should be deleted (cascade)")
    }

    func testClearAllSessionsWhenEmpty() throws {
        // Test clearing when no sessions exist (should not crash)
        let initialFetch = CDSession.fetchRequest()
        let initialSessions = try context.fetch(initialFetch)
        XCTAssertEqual(initialSessions.count, 0, "Should start with no sessions")

        // Should not crash
        syncManager.clearAllSessions()

        // Wait for background processing
        let expectation = XCTestExpectation(description: "Wait for processing")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Verify still no sessions
        context.refreshAllObjects()
        let finalFetch = CDSession.fetchRequest()
        let finalSessions = try context.fetch(finalFetch)
        XCTAssertEqual(finalSessions.count, 0, "Should still have no sessions")
    }

    func testClearAllSessionsRemovesLocalMetadata() throws {
        // Create session with local customizations
        let sessionId = UUID()
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Backend Name"
        session.localName = "My Custom Name" // User renamed
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 5
        session.preview = "Preview"
        session.unreadCount = 3 // User has unread messages
        session.markedDeleted = false
        session.isLocallyCreated = false

        try context.save()

        // Verify session exists with local customizations
        let initialFetch = CDSession.fetchSession(id: sessionId)
        let initialSession = try context.fetch(initialFetch).first
        XCTAssertNotNil(initialSession)
        XCTAssertEqual(initialSession?.localName, "My Custom Name")
        XCTAssertEqual(initialSession?.unreadCount, 3)

        // Clear all sessions
        syncManager.clearAllSessions()

        // Wait for background deletion
        let expectation = XCTestExpectation(description: "Wait for deletion")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Verify session and all local metadata is gone
        context.refreshAllObjects()
        let finalFetch = CDSession.fetchSession(id: sessionId)
        let finalSession = try context.fetch(finalFetch).first
        XCTAssertNil(finalSession, "Session should be completely deleted")
    }

    func testClearAllSessionsForServerChange() throws {
        // Test realistic server change scenario
        let oldServerSessions = [UUID(), UUID()]

        // Create sessions from "old server"
        for sessionId in oldServerSessions {
            let session = CDSession(context: context)
            session.id = sessionId
            session.backendName = "Old Server Session"
            session.workingDirectory = "/old-server-project"
            session.lastModified = Date()
            session.messageCount = 10
            session.preview = "Old server preview"
            session.unreadCount = 0
            session.markedDeleted = false
            session.isLocallyCreated = false
        }

        try context.save()

        // Verify old sessions exist
        let oldFetch = CDSession.fetchRequest()
        let oldSessions = try context.fetch(oldFetch)
        XCTAssertEqual(oldSessions.count, 2, "Should have 2 old server sessions")

        // User changes server URL → clearAllSessions() is called
        syncManager.clearAllSessions()

        // Wait for background deletion
        let expectation = XCTestExpectation(description: "Wait for deletion")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Verify old sessions cleared
        context.refreshAllObjects()
        let clearedFetch = CDSession.fetchRequest()
        let clearedSessions = try context.fetch(clearedFetch)
        XCTAssertEqual(clearedSessions.count, 0, "Old server sessions should be cleared")

        // After this, new server would send session_list with its sessions
        // (tested separately in handleSessionList tests)
    }
}
