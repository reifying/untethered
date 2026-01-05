// SimpleCommandTest.swift
// Minimal test to debug crash

import XCTest
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCodeMac
#endif

class SimpleCommandTest: XCTestCase {
    func testCreateSession() {
        print("Test starting...")
        let session = CommandHistorySession(
            commandSessionId: "test",
            commandId: "build",
            shellCommand: "make",
            workingDirectory: "/tmp",
            timestamp: Date(),
            exitCode: 0,
            durationMs: 100,
            outputPreview: "ok"
        )
        print("Session created: \(session.id)")
        XCTAssertEqual(session.id, "test")
    }

    func testDecodeSession() throws {
        print("Test decode starting...")
        let json = """
        {
            "command_session_id": "cmd-123",
            "command_id": "build",
            "shell_command": "make build",
            "working_directory": "/Users/user/project",
            "timestamp": "2025-11-08T12:34:56.789Z",
            "exit_code": 0,
            "duration_ms": 1234,
            "output_preview": "Building project..."
        }
        """

        let data = json.data(using: .utf8)!
        let session = try JSONDecoder().decode(CommandHistorySession.self, from: data)

        print("Decoded session: \(session.commandSessionId)")
        XCTAssertEqual(session.commandSessionId, "cmd-123")
    }
}
