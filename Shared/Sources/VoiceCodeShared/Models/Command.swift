// Command.swift
// Command model for command execution menu

import Foundation

public struct Command: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let type: CommandType
    public let description: String?
    public let children: [Command]?

    public enum CommandType: String, Codable, Sendable {
        case command = "command"
        case group = "group"
    }

    public init(id: String, label: String, type: CommandType, description: String? = nil, children: [Command]? = nil) {
        self.id = id
        self.label = label
        self.type = type
        self.description = description
        self.children = children
    }

    // Decode from JSON (snake_case to camelCase conversion)
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        type = try container.decode(CommandType.self, forKey: .type)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        children = try container.decodeIfPresent([Command].self, forKey: .children)
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, type, description, children
    }
}

public struct AvailableCommands: Codable, Sendable {
    public let workingDirectory: String?
    public let projectCommands: [Command]
    public let generalCommands: [Command]

    private enum CodingKeys: String, CodingKey {
        case workingDirectory = "working_directory"
        case projectCommands = "project_commands"
        case generalCommands = "general_commands"
    }

    public init(workingDirectory: String?, projectCommands: [Command], generalCommands: [Command]) {
        self.workingDirectory = workingDirectory
        self.projectCommands = projectCommands
        self.generalCommands = generalCommands
    }
}

// CommandExecution tracks a running or completed command execution
public struct CommandExecution: Identifiable, Equatable, Sendable {
    public let id: String  // command_session_id
    public let commandId: String
    public let shellCommand: String
    public var status: ExecutionStatus
    public var output: [OutputLine]
    public var exitCode: Int?
    public var startTime: Date
    public var duration: TimeInterval?

    public enum ExecutionStatus: Equatable, Sendable {
        case running
        case completed
        case error
    }

    public struct OutputLine: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public let stream: StreamType
        public let text: String

        public enum StreamType: String, Sendable {
            case stdout
            case stderr
        }

        public init(stream: StreamType, text: String) {
            self.stream = stream
            self.text = text
        }
    }

    public init(id: String, commandId: String, shellCommand: String) {
        self.id = id
        self.commandId = commandId
        self.shellCommand = shellCommand
        self.status = .running
        self.output = []
        self.exitCode = nil
        self.startTime = Date()
        self.duration = nil
    }

    public mutating func appendOutput(stream: OutputLine.StreamType, text: String) {
        output.append(OutputLine(stream: stream, text: text))
    }

    public mutating func complete(exitCode: Int, duration: TimeInterval) {
        self.exitCode = exitCode
        self.duration = duration
        self.status = exitCode == 0 ? .completed : .error
    }
}

// CommandHistorySession represents a single command execution from history
public struct CommandHistorySession: Identifiable, Codable, Equatable, Sendable {
    public let commandSessionId: String
    public let commandId: String
    public let shellCommand: String
    public let workingDirectory: String
    public let timestamp: Date
    public let exitCode: Int?
    public let durationMs: Int?
    public let outputPreview: String

    public var id: String { commandSessionId }

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

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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
    public init(commandSessionId: String, commandId: String, shellCommand: String, workingDirectory: String, timestamp: Date, exitCode: Int?, durationMs: Int?, outputPreview: String) {
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

public struct CommandHistory: Codable, Sendable {
    public let sessions: [CommandHistorySession]
    public let limit: Int

    public init(sessions: [CommandHistorySession], limit: Int) {
        self.sessions = sessions
        self.limit = limit
    }
}

// CommandOutputFull represents the full output response for a command
public struct CommandOutputFull: Codable, Equatable, Sendable {
    public let commandSessionId: String
    public let output: String
    public let exitCode: Int
    public let timestamp: Date
    public let durationMs: Int
    public let commandId: String
    public let shellCommand: String
    public let workingDirectory: String

    private enum CodingKeys: String, CodingKey {
        case commandSessionId = "command_session_id"
        case output
        case exitCode = "exit_code"
        case timestamp
        case durationMs = "duration_ms"
        case commandId = "command_id"
        case shellCommand = "shell_command"
        case workingDirectory = "working_directory"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        commandSessionId = try container.decode(String.self, forKey: .commandSessionId)
        output = try container.decode(String.self, forKey: .output)
        exitCode = try container.decode(Int.self, forKey: .exitCode)
        durationMs = try container.decode(Int.self, forKey: .durationMs)
        commandId = try container.decode(String.self, forKey: .commandId)
        shellCommand = try container.decode(String.self, forKey: .shellCommand)
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)

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

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(commandSessionId, forKey: .commandSessionId)
        try container.encode(output, forKey: .output)
        try container.encode(exitCode, forKey: .exitCode)
        try container.encode(durationMs, forKey: .durationMs)
        try container.encode(commandId, forKey: .commandId)
        try container.encode(shellCommand, forKey: .shellCommand)
        try container.encode(workingDirectory, forKey: .workingDirectory)

        // Encode ISO-8601 timestamp
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestampString = formatter.string(from: timestamp)
        try container.encode(timestampString, forKey: .timestamp)
    }

    // For testing
    public init(commandSessionId: String, output: String, exitCode: Int, timestamp: Date, durationMs: Int, commandId: String, shellCommand: String, workingDirectory: String) {
        self.commandSessionId = commandSessionId
        self.output = output
        self.exitCode = exitCode
        self.timestamp = timestamp
        self.durationMs = durationMs
        self.commandId = commandId
        self.shellCommand = shellCommand
        self.workingDirectory = workingDirectory
    }
}
