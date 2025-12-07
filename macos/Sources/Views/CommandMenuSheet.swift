// CommandMenuSheet.swift
// Command execution menu for macOS with keyboard shortcut Cmd+K

import SwiftUI
import UntetheredCore

struct CommandMenuSheet: View {
    @EnvironmentObject var client: VoiceCodeClient
    let workingDirectory: String
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var selectedCommandId: String?

    // Filtered commands based on search
    private var filteredProjectCommands: [Command] {
        filterCommands(client.availableCommands?.projectCommands ?? [])
    }

    private var filteredGeneralCommands: [Command] {
        filterCommands(client.availableCommands?.generalCommands ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search commands...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Command list
            if client.availableCommands == nil {
                // Empty state
                VStack(spacing: 16) {
                    Image(systemName: "terminal")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No commands available")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Text("Commands will appear when connected to a project directory.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredProjectCommands.isEmpty && filteredGeneralCommands.isEmpty {
                // No results
                VStack(spacing: 16) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No commands found")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Text("Try a different search term")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedCommandId) {
                    // Project Commands
                    if !filteredProjectCommands.isEmpty {
                        Section("Project Commands") {
                            ForEach(filteredProjectCommands) { command in
                                CommandRowView(
                                    command: command,
                                    searchText: searchText,
                                    onExecute: { commandId in
                                        executeCommand(commandId: commandId)
                                    }
                                )
                            }
                        }
                    }

                    // General Commands
                    if !filteredGeneralCommands.isEmpty {
                        Section("General Commands") {
                            ForEach(filteredGeneralCommands) { command in
                                CommandRowView(
                                    command: command,
                                    searchText: searchText,
                                    onExecute: { commandId in
                                        executeCommand(commandId: commandId)
                                    }
                                )
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 600, height: 400)
    }

    private func filterCommands(_ commands: [Command]) -> [Command] {
        guard !searchText.isEmpty else { return commands }

        return commands.compactMap { command in
            if command.type == .group, let children = command.children {
                let filteredChildren = filterCommands(children)
                if !filteredChildren.isEmpty {
                    return Command(
                        id: command.id,
                        label: command.label,
                        type: command.type,
                        description: command.description,
                        children: filteredChildren
                    )
                }
                return nil
            } else {
                // Leaf command: check if label or description matches search
                let query = searchText.lowercased()
                let matchesLabel = command.label.lowercased().contains(query)
                let matchesDescription = command.description?.lowercased().contains(query) ?? false
                return (matchesLabel || matchesDescription) ? command : nil
            }
        }
    }

    private func executeCommand(commandId: String) {
        print("📤 Executing command: \(commandId) in \(workingDirectory)")
        Task {
            _ = await client.executeCommand(commandId: commandId, workingDirectory: workingDirectory)
        }
        dismiss()
    }
}

// MARK: - Command Row

struct CommandRowView: View {
    let command: Command
    let searchText: String
    let onExecute: (String) -> Void
    @State private var isExpanded = true  // Start expanded when searching

    var body: some View {
        if command.type == .group, let children = command.children {
            // Group with children
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(children) { child in
                    CommandRowView(
                        command: child,
                        searchText: searchText,
                        onExecute: onExecute
                    )
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundColor(.secondary)
                    Text(command.label)
                        .font(.body)
                }
            }
        } else {
            // Leaf command
            Button(action: {
                onExecute(command.id)
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "play.circle")
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(command.label)
                            .font(.body)
                            .foregroundColor(.primary)
                        if let description = command.description {
                            Text(description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
