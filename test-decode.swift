#!/usr/bin/env swift

import Foundation

// Copy of CommandHistorySession from Command.swift
struct CommandHistorySession: Identifiable, Codable, Equatable {
    let commandSessionId: String
    let commandId: String
    let shellCommand: String
    let workingDirectory: String
    let timestamp: Date
    let exitCode: Int?
    let durationMs: Int?
    let outputPreview: String

    var id: String { commandSessionId }

    private enum CodingKeys: String, CodingKey {
        case commandSessionId = "command_session_id"
        case commandId = "command_id"
        case shellCommand = "shell_command"
        case workingDirectory = "working_directory"
        case timestamp
        case exitCode = "exit_code"
        case durationMs = "duration_ms"
        case outputPreview = "output_preview"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        commandSessionId = try container.decode(String.self, forKey: .commandSessionId)
        commandId = try container.decode(String.self, forKey: .commandId)
        shellCommand = try container.decode(String.self, forKey: .shellCommand)
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        exitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode)
        durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
        outputPreview = try container.decode(String.self, forKey: .outputPreview)

        // Decode ISO-8601 timestamp
        let timestampString = try container.decode(String.self, forKey: .timestamp)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: timestampString) {
            timestamp = date
        } else {
            // Fallback without fractional seconds
            formatter.formatOptions = [.withInternetDateTime]
            timestamp = formatter.date(from: timestampString) ?? Date()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(commandSessionId, forKey: .commandSessionId)
        try container.encode(commandId, forKey: .commandId)
        try container.encode(shellCommand, forKey: .shellCommand)
        try container.encode(workingDirectory, forKey: .workingDirectory)
        try container.encodeIfPresent(exitCode, forKey: .exitCode)
        try container.encodeIfPresent(durationMs, forKey: .durationMs)
        try container.encode(outputPreview, forKey: .outputPreview)

        // Encode ISO-8601 timestamp
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestampString = formatter.string(from: timestamp)
        try container.encode(timestampString, forKey: .timestamp)
    }

    // For testing
    init(commandSessionId: String, commandId: String, shellCommand: String, workingDirectory: String, timestamp: Date, exitCode: Int?, durationMs: Int?, outputPreview: String) {
        self.commandSessionId = commandSessionId
        self.commandId = commandId
        self.shellCommand = shellCommand
        self.workingDirectory = workingDirectory
        self.timestamp = timestamp
        self.exitCode = exitCode
        self.durationMs = durationMs
        self.outputPreview = outputPreview
    }
}

// Test 1: Decode from JSON
print("Test 1: Decode from JSON with fractional seconds")
let json1 = """
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

do {
    let data = json1.data(using: .utf8)!
    let session = try JSONDecoder().decode(CommandHistorySession.self, from: data)
    print("✅ Decoded successfully: \(session.commandSessionId)")
} catch {
    print("❌ Failed to decode: \(error)")
}

// Test 2: Manual init
print("\nTest 2: Manual initializer")
do {
    let session = CommandHistorySession(
        commandSessionId: "cmd-123",
        commandId: "build",
        shellCommand: "make build",
        workingDirectory: "/Users/user/project",
        timestamp: Date(),
        exitCode: 0,
        durationMs: 1234,
        outputPreview: "Building..."
    )
    print("✅ Manual init successful: \(session.id)")
} catch {
    print("❌ Manual init failed: \(error)")
}

// Test 3: Equatable
print("\nTest 3: Equatable conformance")
let date = Date()
let s1 = CommandHistorySession(
    commandSessionId: "cmd-123",
    commandId: "build",
    shellCommand: "make build",
    workingDirectory: "/Users/user/project",
    timestamp: date,
    exitCode: 0,
    durationMs: 1234,
    outputPreview: "Building..."
)

let s2 = CommandHistorySession(
    commandSessionId: "cmd-123",
    commandId: "build",
    shellCommand: "make build",
    workingDirectory: "/Users/user/project",
    timestamp: date,
    exitCode: 0,
    durationMs: 1234,
    outputPreview: "Building..."
)

if s1 == s2 {
    print("✅ Equatable works correctly")
} else {
    print("❌ Equatable failed")
}

print("\nAll tests completed!")
