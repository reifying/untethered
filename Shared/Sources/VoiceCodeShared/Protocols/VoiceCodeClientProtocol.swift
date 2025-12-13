// VoiceCodeClientProtocol.swift
// Protocol for platform-specific VoiceCodeClient implementations

import Foundation
import Combine

/// Protocol defining the interface for VoiceCodeClient
/// Platform-specific implementations (iOS/macOS) conform to this protocol
/// while VoiceCodeClientCore provides shared implementation
public protocol VoiceCodeClientProtocol: ObservableObject {
    // MARK: - Published Properties

    /// Whether the WebSocket connection is established
    var isConnected: Bool { get }

    /// Set of Claude session IDs currently locked (processing)
    var lockedSessions: Set<String> { get }

    /// Available commands for current working directory
    var availableCommands: AvailableCommands? { get }

    /// Currently running commands (command_session_id -> execution)
    var runningCommands: [String: CommandExecution] { get }

    /// Command history sessions
    var commandHistory: [CommandHistorySession] { get }

    /// Full output for a command (single at a time)
    var commandOutputFull: CommandOutputFull? { get }

    /// Latest file upload response
    var fileUploadResponse: (filename: String, success: Bool)? { get }

    /// List of uploaded resources
    var resourcesList: [Resource] { get }

    /// Current error message (if any)
    var currentError: String? { get }

    /// Whether a prompt is currently being processed
    var isProcessing: Bool { get }

    // MARK: - Connection Management

    /// Connect to the WebSocket server
    /// - Parameter sessionId: Optional session ID to register with
    func connect(sessionId: String?)

    /// Disconnect from the WebSocket server
    func disconnect()

    /// Update the server URL and reconnect
    /// - Parameter url: New server URL
    func updateServerURL(_ url: String)

    // MARK: - Prompts

    /// Send a prompt to Claude
    /// - Parameters:
    ///   - text: The prompt text
    ///   - iosSessionId: iOS session UUID for multiplexing
    ///   - sessionId: Optional Claude session ID (nil for new session)
    ///   - workingDirectory: Optional working directory override
    ///   - systemPrompt: Optional custom system prompt
    func sendPrompt(_ text: String, iosSessionId: String, sessionId: String?, workingDirectory: String?, systemPrompt: String?)

    // MARK: - Session Management

    /// Subscribe to session updates
    /// - Parameter sessionId: Claude session ID to subscribe to
    func subscribe(sessionId: String)

    /// Unsubscribe from session updates
    /// - Parameter sessionId: Claude session ID to unsubscribe from
    func unsubscribe(sessionId: String)

    /// Request fresh session list from backend
    func requestSessionList() async

    /// Refresh a specific session
    /// - Parameter sessionId: Claude session ID to refresh
    func requestSessionRefresh(sessionId: String)

    /// Compact a session to reduce context size
    /// - Parameter sessionId: Claude session ID to compact
    /// - Returns: Compaction result
    func compactSession(sessionId: String) async throws -> CompactionResult

    /// Kill a running session process
    /// - Parameter sessionId: Claude session ID to kill
    func killSession(sessionId: String)

    /// Request inferred name for a session based on message text
    /// - Parameters:
    ///   - sessionId: Claude session ID
    ///   - messageText: Text to infer name from
    func requestInferredName(sessionId: String, messageText: String)

    // MARK: - Commands

    /// Execute a command
    /// - Parameters:
    ///   - commandId: Command identifier
    ///   - workingDirectory: Directory to execute in
    /// - Returns: Command session ID
    func executeCommand(commandId: String, workingDirectory: String) async -> String

    /// Get command history
    /// - Parameters:
    ///   - workingDirectory: Optional filter by directory
    ///   - limit: Maximum number of results
    func getCommandHistory(workingDirectory: String?, limit: Int)

    /// Get full output for a command
    /// - Parameter commandSessionId: Command session ID
    func getCommandOutput(commandSessionId: String)

    // MARK: - Working Directory

    /// Set the current working directory
    /// - Parameter path: Absolute path
    func setWorkingDirectory(_ path: String)

    // MARK: - Resources

    /// List resources in a storage location
    /// - Parameter storageLocation: Storage location path
    func listResources(storageLocation: String)

    /// Delete a resource
    /// - Parameters:
    ///   - filename: Resource filename
    ///   - storageLocation: Storage location path
    func deleteResource(filename: String, storageLocation: String)

    // MARK: - Utility

    /// Send a ping message
    func ping()

    /// Send a raw message dictionary
    /// - Parameter message: Message dictionary
    func sendMessage(_ message: [String: Any])
}

/// Result of a session compaction operation
public struct CompactionResult: Sendable {
    public let sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}
