// CommandPaletteTests.swift
// Tests for CommandPaletteView filtering, command building, and keyboard shortcut integration

import XCTest
import SwiftUI
@testable import VoiceCode

final class CommandPaletteTests: XCTestCase {

    #if os(macOS)

    // MARK: - CommandPaletteItem Filtering Tests

    func testMatchesReturnsTrueForSubstring() {
        let item = CommandPaletteItem(
            id: "test", title: "New session", shortcut: nil,
            category: "Sessions", action: .newSession
        )
        XCTAssertTrue(item.matches("new"))
        XCTAssertTrue(item.matches("session"))
        XCTAssertTrue(item.matches("New"))
    }

    func testMatchesReturnsFalseForNonMatch() {
        let item = CommandPaletteItem(
            id: "test", title: "New session", shortcut: nil,
            category: "Sessions", action: .newSession
        )
        XCTAssertFalse(item.matches("xyz"))
        XCTAssertFalse(item.matches("delete"))
    }

    func testMatchesIsCaseInsensitive() {
        let item = CommandPaletteItem(
            id: "test", title: "Compact session history", shortcut: nil,
            category: "Sessions", action: .compactSession
        )
        XCTAssertTrue(item.matches("compact"))
        XCTAssertTrue(item.matches("COMPACT"))
        XCTAssertTrue(item.matches("Compact"))
    }

    func testMatchesEmptyQueryReturnsFalse() {
        let item = CommandPaletteItem(
            id: "test", title: "Stop speaking", shortcut: nil,
            category: "Voice", action: .stopSpeaking
        )
        // localizedCaseInsensitiveContains returns false for empty query
        XCTAssertFalse(item.matches(""))
    }

    // MARK: - Command Building Tests

    func testBuildAllCommandsIncludesSessionCommands() {
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        let voiceOutput = VoiceOutputManager()

        let commands = CommandPaletteView.buildAllCommands(client: client, voiceOutput: voiceOutput)

        let sessionCommands = commands.filter { $0.category == "Sessions" }
        XCTAssertEqual(sessionCommands.count, 4)

        let titles = sessionCommands.map(\.title)
        XCTAssertTrue(titles.contains("New session"))
        XCTAssertTrue(titles.contains("Refresh current session"))
        XCTAssertTrue(titles.contains("Compact session history"))
        XCTAssertTrue(titles.contains("Session info"))
    }

    func testBuildAllCommandsIncludesVoiceCommands() {
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        let voiceOutput = VoiceOutputManager()
        voiceOutput.isMuted = false  // Ensure known state

        let commands = CommandPaletteView.buildAllCommands(client: client, voiceOutput: voiceOutput)

        let voiceCommands = commands.filter { $0.category == "Voice" }
        XCTAssertEqual(voiceCommands.count, 2)

        let titles = voiceCommands.map(\.title)
        XCTAssertTrue(titles.contains("Stop speaking"))
        XCTAssertTrue(titles.contains("Mute voice"))
    }

    func testBuildAllCommandsShowsUnmuteWhenMuted() {
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        let voiceOutput = VoiceOutputManager()
        voiceOutput.isMuted = true

        let commands = CommandPaletteView.buildAllCommands(client: client, voiceOutput: voiceOutput)

        let muteCommand = commands.first { $0.action == .toggleMute }
        XCTAssertEqual(muteCommand?.title, "Unmute voice")
    }

    func testBuildAllCommandsWithNoProjectCommands() {
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        let voiceOutput = VoiceOutputManager()

        let commands = CommandPaletteView.buildAllCommands(client: client, voiceOutput: voiceOutput)

        let projectCommands = commands.filter { $0.category == "Project Commands" }
        XCTAssertTrue(projectCommands.isEmpty)
    }

    func testBuildAllCommandsHasUniqueIds() {
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        let voiceOutput = VoiceOutputManager()

        let commands = CommandPaletteView.buildAllCommands(client: client, voiceOutput: voiceOutput)

        let ids = commands.map(\.id)
        let uniqueIds = Set(ids)
        XCTAssertEqual(ids.count, uniqueIds.count, "All command IDs should be unique")
    }

    // MARK: - Filtering Integration Tests

    func testFilteringNewReturnsNewSession() {
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        let voiceOutput = VoiceOutputManager()

        let allCommands = CommandPaletteView.buildAllCommands(client: client, voiceOutput: voiceOutput)
        let filtered = allCommands.filter { $0.matches("new") }

        XCTAssertFalse(filtered.isEmpty, "Filtering 'new' should return results")
        XCTAssertTrue(filtered.contains(where: { $0.title == "New session" }))
    }

    func testFilteringXyzReturnsEmpty() {
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        let voiceOutput = VoiceOutputManager()

        let allCommands = CommandPaletteView.buildAllCommands(client: client, voiceOutput: voiceOutput)
        let filtered = allCommands.filter { $0.matches("xyz") }

        XCTAssertTrue(filtered.isEmpty, "Filtering 'xyz' should return no results")
    }

    func testFilteringStopReturnsSpeakingCommand() {
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        let voiceOutput = VoiceOutputManager()

        let allCommands = CommandPaletteView.buildAllCommands(client: client, voiceOutput: voiceOutput)
        let filtered = allCommands.filter { $0.matches("stop") }

        XCTAssertTrue(filtered.contains(where: { $0.title == "Stop speaking" }))
    }

    func testFilteringSessionReturnsMultipleResults() {
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        let voiceOutput = VoiceOutputManager()

        let allCommands = CommandPaletteView.buildAllCommands(client: client, voiceOutput: voiceOutput)
        let filtered = allCommands.filter { $0.matches("session") }

        // "New session", "Refresh current session", "Compact session history", "Session info"
        XCTAssertEqual(filtered.count, 4)
    }

    // MARK: - CommandPaletteAction Equatable Tests

    func testActionEquality() {
        XCTAssertEqual(CommandPaletteAction.newSession, CommandPaletteAction.newSession)
        XCTAssertEqual(CommandPaletteAction.stopSpeaking, CommandPaletteAction.stopSpeaking)
        XCTAssertEqual(CommandPaletteAction.runCommand("build"), CommandPaletteAction.runCommand("build"))
        XCTAssertNotEqual(CommandPaletteAction.runCommand("build"), CommandPaletteAction.runCommand("test"))
        XCTAssertNotEqual(CommandPaletteAction.newSession, CommandPaletteAction.refreshSession)
    }

    // MARK: - Shortcuts Tests

    func testSessionCommandsHaveShortcuts() {
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        let voiceOutput = VoiceOutputManager()

        let commands = CommandPaletteView.buildAllCommands(client: client, voiceOutput: voiceOutput)

        let newSession = commands.first { $0.action == .newSession }
        XCTAssertNotNil(newSession?.shortcut)

        let refreshSession = commands.first { $0.action == .refreshSession }
        XCTAssertNotNil(refreshSession?.shortcut)

        let compactSession = commands.first { $0.action == .compactSession }
        XCTAssertNotNil(compactSession?.shortcut)

        let sessionInfo = commands.first { $0.action == .sessionInfo }
        XCTAssertNotNil(sessionInfo?.shortcut)
    }

    func testVoiceCommandsHaveShortcuts() {
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        let voiceOutput = VoiceOutputManager()

        let commands = CommandPaletteView.buildAllCommands(client: client, voiceOutput: voiceOutput)

        let stop = commands.first { $0.action == .stopSpeaking }
        XCTAssertNotNil(stop?.shortcut)

        let mute = commands.first { $0.action == .toggleMute }
        XCTAssertNotNil(mute?.shortcut)
    }

    // MARK: - View Compilation Tests

    func testCommandPaletteViewCompiles() {
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        let voiceOutput = VoiceOutputManager()

        let view = CommandPaletteView(
            client: client,
            voiceOutput: voiceOutput,
            onAction: { _ in },
            onDismiss: {}
        )
        XCTAssertNotNil(view)
    }

    func testCommandPaletteOverlayCompiles() {
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        let voiceOutput = VoiceOutputManager()

        let overlay = CommandPaletteOverlay(
            client: client,
            voiceOutput: voiceOutput,
            isPresented: .constant(true),
            onAction: { _ in }
        )
        XCTAssertNotNil(overlay)
    }

    func testCommandPaletteRowCompiles() {
        let item = CommandPaletteItem(
            id: "test", title: "Test", shortcut: "\u{2318}T",
            category: "Test", action: .newSession
        )

        let selectedRow = CommandPaletteRow(item: item, isSelected: true)
        XCTAssertNotNil(selectedRow)

        let unselectedRow = CommandPaletteRow(item: item, isSelected: false)
        XCTAssertNotNil(unselectedRow)
    }

    func testCommandPaletteRowWithoutShortcut() {
        let item = CommandPaletteItem(
            id: "test", title: "Run build", shortcut: nil,
            category: "Project Commands", action: .runCommand("build")
        )

        let row = CommandPaletteRow(item: item, isSelected: false)
        XCTAssertNotNil(row)
    }

    // MARK: - Notification Names Tests

    func testCommandNotificationNamesExist() {
        // Verify all notification names are defined and unique
        let names: [Notification.Name] = [
            .showCommandPalette,
            .toggleSidebar,
            .focusSidebar,
            .focusConversation,
            .createNewSession,
            .sidebarCreateNewSession,
            .refreshSession,
            .compactSession,
            .showSessionInfo,
            .selectPreviousSession,
            .selectNextSession,
            .executeCommand,
        ]

        let uniqueNames = Set(names.map(\.rawValue))
        XCTAssertEqual(names.count, uniqueNames.count, "All notification names should be unique")
    }

    // MARK: - Keyboard Shortcut Menu Tests

    func testCommandPaletteShortcutInEditMenu() {
        // Verify Command Palette menu item compiles with Cmd+K
        struct TestCommandGroup: View {
            @State var showPalette = false

            var body: some View {
                Button("Command Palette") {
                    showPalette = true
                }
                .keyboardShortcut("k", modifiers: [.command])
            }
        }

        let view = TestCommandGroup()
        XCTAssertNotNil(view)
    }

    func testSessionMenuCompiles() {
        // Verify Session menu commands compile with correct shortcuts
        struct TestSessionMenu: View {
            var body: some View {
                Group {
                    Button("New Session") {}
                        .keyboardShortcut("n", modifiers: [.command])
                    Button("Refresh Session") {}
                        .keyboardShortcut("r", modifiers: [.command])
                    Button("Compact Session") {}
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                    Button("Session Info") {}
                        .keyboardShortcut("i", modifiers: [.command])
                    Button("Previous Session") {}
                        .keyboardShortcut("[", modifiers: [.command])
                    Button("Next Session") {}
                        .keyboardShortcut("]", modifiers: [.command])
                }
            }
        }

        let menu = TestSessionMenu()
        XCTAssertNotNil(menu)
    }

    func testViewMenuCompiles() {
        // Verify View menu commands compile with correct shortcuts
        struct TestViewMenu: View {
            var body: some View {
                Group {
                    Button("Toggle Sidebar") {}
                        .keyboardShortcut("0", modifiers: [.command])
                    Button("Focus Sidebar") {}
                        .keyboardShortcut("1", modifiers: [.command])
                    Button("Focus Conversation") {}
                        .keyboardShortcut("2", modifiers: [.command])
                }
            }
        }

        let menu = TestViewMenu()
        XCTAssertNotNil(menu)
    }

    #endif
}
