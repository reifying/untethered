// CommandMenuView.swift
// macOS command menu with outline view, search, and keyboard navigation per Appendix I.5

import SwiftUI
import AppKit
import OSLog
import VoiceCodeShared

private let logger = Logger(subsystem: "dev.910labs.voice-code-desktop", category: "CommandMenuView")

// MARK: - CommandMenuView

/// macOS Command Menu View per Appendix I.5 specification:
/// - Outline view with expandable groups
/// - Search field at top (⌘F to focus)
/// - Recent commands section (last 5)
/// - Context menu on items: Run, Copy Command, Add to Favorites
/// - Keyboard navigation: Arrow keys, Enter to run
/// - Double-click to execute
struct CommandMenuView: View {
    @ObservedObject var client: VoiceCodeClientCore
    let workingDirectory: String

    @State private var searchText = ""
    @State private var selectedCommandId: String?
    @FocusState private var isSearchFocused: Bool

    private let sorter = CommandSorter()

    // MARK: - Computed Properties

    /// Recent commands (last 5 actually used commands)
    /// Note: sortCommands() handles MRU ordering; since all commands here are used,
    /// they'll all be sorted by timestamp descending (most recent first).
    private var recentCommands: [Command] {
        let usedCommandIds = sorter.getUsedCommandIds()
        guard !usedCommandIds.isEmpty else { return [] }

        let allCommands = flattenCommands(projectCommands + generalCommands)
        let usedCommands = allCommands.filter { usedCommandIds.contains($0.id) }
        return sorter.sortCommands(usedCommands)
            .prefix(5)
            .map { $0 }
    }

    private var projectCommands: [Command] {
        client.availableCommands?.projectCommands ?? []
    }

    private var generalCommands: [Command] {
        client.availableCommands?.generalCommands ?? []
    }

    /// Sorted project commands with MRU ordering
    private var sortedProjectCommands: [Command] {
        sorter.sortCommands(projectCommands)
    }

    /// Sorted general commands with MRU ordering
    private var sortedGeneralCommands: [Command] {
        sorter.sortCommands(generalCommands)
    }

    /// Filtered commands based on search text
    private var filteredProjectCommands: [Command] {
        filterCommands(sortedProjectCommands, searchText: searchText)
    }

    private var filteredGeneralCommands: [Command] {
        filterCommands(sortedGeneralCommands, searchText: searchText)
    }

    private var hasCommands: Bool {
        !projectCommands.isEmpty || !generalCommands.isEmpty
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            searchField

            Divider()

            if !hasCommands {
                emptyState
            } else if filteredProjectCommands.isEmpty && filteredGeneralCommands.isEmpty {
                // No results only when searching (when not searching, recent section may still show)
                if !searchText.isEmpty {
                    noResultsState
                } else {
                    commandList
                }
            } else {
                commandList
            }
        }
        .frame(minWidth: 300, minHeight: 400)
        .onAppear {
            logger.info("📋 CommandMenuView appeared for directory: \(workingDirectory)")
        }
        .background {
            // Hidden button to handle ⌘F keyboard shortcut
            Button("") {
                isSearchFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Subviews

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            TextField("Search commands...", text: $searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear {
            // Auto-focus search field
            isSearchFocused = true
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No Commands Available")
                .font(.title3)
                .foregroundColor(.secondary)

            Text("Commands will appear when connected to a project with a Makefile.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No Results")
                .font(.title3)
                .foregroundColor(.secondary)

            Text("No commands match \"\(searchText)\"")
                .font(.body)
                .foregroundColor(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var commandList: some View {
        List(selection: $selectedCommandId) {
            // Recent Commands section (only show if not searching and there are recent commands)
            if searchText.isEmpty && !recentCommands.isEmpty {
                Section("Recent") {
                    ForEach(recentCommands) { command in
                        CommandRowView(
                            command: command,
                            onExecute: { executeCommand(command) },
                            onCopyCommand: { copyCommand(command) }
                        )
                        .tag(command.id)
                    }
                }
            }

            // Project Commands section
            if !filteredProjectCommands.isEmpty {
                Section("Project Commands") {
                    ForEach(filteredProjectCommands) { command in
                        CommandOutlineRow(
                            command: command,
                            onExecute: { executeCommand($0) },
                            onCopyCommand: { copyCommand($0) }
                        )
                    }
                }
            }

            // General Commands section
            if !filteredGeneralCommands.isEmpty {
                Section("General Commands") {
                    ForEach(filteredGeneralCommands) { command in
                        CommandRowView(
                            command: command,
                            onExecute: { executeCommand(command) },
                            onCopyCommand: { copyCommand(command) }
                        )
                        .tag(command.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onKeyPress(.return) {
            if let commandId = selectedCommandId {
                if let command = findCommand(byId: commandId) {
                    executeCommand(command)
                }
            }
            return .handled
        }
    }

    // MARK: - Helper Methods

    /// Flatten nested command structure for MRU tracking
    private func flattenCommands(_ commands: [Command]) -> [Command] {
        var result: [Command] = []
        for command in commands {
            if command.type == .command {
                result.append(command)
            }
            if let children = command.children {
                result.append(contentsOf: flattenCommands(children))
            }
        }
        return result
    }

    /// Filter commands recursively based on search text
    private func filterCommands(_ commands: [Command], searchText: String) -> [Command] {
        guard !searchText.isEmpty else { return commands }

        let lowercased = searchText.lowercased()

        return commands.compactMap { command in
            // Check if command matches
            let matches = command.label.lowercased().contains(lowercased) ||
                         command.id.lowercased().contains(lowercased) ||
                         (command.description?.lowercased().contains(lowercased) ?? false)

            if command.type == .group, let children = command.children {
                // Filter children recursively
                let filteredChildren = filterCommands(children, searchText: searchText)

                // Include group if it matches or has matching children
                if matches || !filteredChildren.isEmpty {
                    return Command(
                        id: command.id,
                        label: command.label,
                        type: command.type,
                        description: command.description,
                        children: filteredChildren.isEmpty ? nil : filteredChildren
                    )
                }
                return nil
            }

            return matches ? command : nil
        }
    }

    /// Find a command by ID (searches recursively)
    private func findCommand(byId id: String) -> Command? {
        let allCommands = projectCommands + generalCommands
        return findCommand(byId: id, in: allCommands)
    }

    private func findCommand(byId id: String, in commands: [Command]) -> Command? {
        for command in commands {
            if command.id == id {
                return command
            }
            if let children = command.children,
               let found = findCommand(byId: id, in: children) {
                return found
            }
        }
        return nil
    }

    private func executeCommand(_ command: Command) {
        logger.info("▶️ Executing command: \(command.id)")
        sorter.markCommandUsed(commandId: command.id)

        Task {
            let commandSessionId = await client.executeCommand(
                commandId: command.id,
                workingDirectory: workingDirectory
            )
            logger.info("✅ Command started with session ID: \(commandSessionId)")
        }
    }

    private func copyCommand(_ command: Command) {
        // Resolve shell command from command ID
        let shellCommand: String
        if command.id.hasPrefix("git.") {
            shellCommand = "git \(command.id.dropFirst(4))"
        } else if command.id.contains(".") {
            // Group command like "docker.up" -> "make docker-up"
            let makeTarget = command.id.replacingOccurrences(of: ".", with: "-")
            shellCommand = "make \(makeTarget)"
        } else {
            shellCommand = "make \(command.id)"
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shellCommand, forType: .string)
        logger.info("📋 Copied command to clipboard: \(shellCommand)")
    }
}

// MARK: - CommandOutlineRow

/// Recursive row for outline view with expandable groups
struct CommandOutlineRow: View {
    let command: Command
    let onExecute: (Command) -> Void
    let onCopyCommand: (Command) -> Void

    @State private var isExpanded = false

    var body: some View {
        if command.type == .group, let children = command.children, !children.isEmpty {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(children) { child in
                    CommandOutlineRow(
                        command: child,
                        onExecute: onExecute,
                        onCopyCommand: onCopyCommand
                    )
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.blue)
                    Text(command.label)
                        .font(.body)
                    Spacer()
                    Text("\(children.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
        } else {
            CommandRowView(
                command: command,
                onExecute: { onExecute(command) },
                onCopyCommand: { onCopyCommand(command) }
            )
            .tag(command.id)
        }
    }
}

// MARK: - CommandRowView

/// Individual command row with context menu
struct CommandRowView: View {
    let command: Command
    let onExecute: () -> Void
    let onCopyCommand: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(command.label)
                    .font(.body)
                    .foregroundColor(.primary)

                if let description = command.description {
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onExecute()
        }
        .contextMenu {
            Button("Run") {
                onExecute()
            }
            .keyboardShortcut(.return, modifiers: [])

            Button("Copy Command") {
                onCopyCommand()
            }
            .keyboardShortcut("c", modifiers: [.command])

            Divider()

            // Favorites feature placeholder (can be implemented later)
            Button("Add to Favorites") {
                // TODO: Implement favorites
            }
            .disabled(true)
        }
    }
}

// MARK: - Preview

#Preview("CommandMenuView with Commands") {
    let client = VoiceCodeClient(
        serverURL: "ws://localhost:8080",
        setupObservers: false
    )

    // Mock available commands
    let mockCommands = AvailableCommands(
        workingDirectory: "/Users/test/project",
        projectCommands: [
            Command(id: "build", label: "Build", type: .command, description: "Build the project"),
            Command(id: "test", label: "Test", type: .command, description: "Run tests"),
            Command(id: "docker", label: "Docker", type: .group, children: [
                Command(id: "docker.up", label: "Up", type: .command, description: "Start containers"),
                Command(id: "docker.down", label: "Down", type: .command, description: "Stop containers"),
                Command(id: "docker.logs", label: "Logs", type: .command, description: "View logs")
            ])
        ],
        generalCommands: [
            Command(id: "git.status", label: "Git Status", type: .command, description: "Show working tree status"),
            Command(id: "git.log", label: "Git Log", type: .command, description: "Show commit logs")
        ]
    )
    client.availableCommands = mockCommands

    return CommandMenuView(
        client: client,
        workingDirectory: "/Users/test/project"
    )
    .frame(width: 400, height: 500)
}

#Preview("CommandMenuView Empty") {
    let client = VoiceCodeClient(
        serverURL: "ws://localhost:8080",
        setupObservers: false
    )

    return CommandMenuView(
        client: client,
        workingDirectory: "/Users/test/project"
    )
    .frame(width: 400, height: 500)
}
