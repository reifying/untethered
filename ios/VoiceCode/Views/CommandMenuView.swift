// CommandMenuView.swift
// Command execution menu with MRU sorting and hierarchical display

import SwiftUI

struct CommandMenuView: View {
    @ObservedObject var client: VoiceCodeClient
    let workingDirectory: String
    @Environment(\.dismiss) private var dismiss

    private let sorter = CommandSorter()
    @State private var isLoading = false
    @State private var activeCommandSessionId: String?
    @State private var navigateToExecution = false

    // Sorted commands from client
    private var sortedProjectCommands: [Command] {
        guard let commands = client.availableCommands?.projectCommands else {
            return []
        }
        return sorter.sortCommands(commands)
    }

    private var sortedGeneralCommands: [Command] {
        guard let commands = client.availableCommands?.generalCommands else {
            return []
        }
        return sorter.sortCommands(commands)
    }

    var body: some View {
        NavigationView {
            ZStack {
                // NavigationLink hidden in background for programmatic navigation
                if let commandSessionId = activeCommandSessionId {
                    NavigationLink(
                        destination: CommandExecutionView(client: client, commandSessionId: commandSessionId),
                        isActive: $navigateToExecution
                    ) {
                        EmptyView()
                    }
                    .hidden()
                }

            Group {
                if isLoading {
                    // Loading state
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Loading commands...")
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if client.availableCommands == nil {
                    // Empty state (no commands available)
                    VStack(spacing: 16) {
                        Image(systemName: "terminal")
                            .font(.system(size: 64))
                            .foregroundColor(.secondary)
                        Text("No commands available")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        Text("Commands will appear when connected to a project directory.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Command list
                    List {
                        // Project Commands section
                        if !sortedProjectCommands.isEmpty {
                            Section {
                                ForEach(sortedProjectCommands) { command in
                                    CommandRowView(
                                        command: command,
                                        onExecute: { commandId in
                                            executeCommand(commandId: commandId)
                                        }
                                    )
                                }
                            } header: {
                                Text("Project Commands")
                            }
                        }

                        // General Commands section
                        if !sortedGeneralCommands.isEmpty {
                            Section {
                                ForEach(sortedGeneralCommands) { command in
                                    CommandRowView(
                                        command: command,
                                        onExecute: { commandId in
                                            executeCommand(commandId: commandId)
                                        }
                                    )
                                }
                            } header: {
                                Text("General Commands")
                            }
                        }
                    }
                }
            }
            }
            .navigationTitle("Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            // Request commands if not already available
            if client.availableCommands == nil {
                isLoading = true
                // Commands will be sent automatically by backend after connect/set_directory
                // For now, just wait for them to arrive
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    isLoading = false
                }
            }
        }
    }

    private func executeCommand(commandId: String) {
        print("📤 [CommandMenuView] Executing command: \(commandId)")
        sorter.markCommandUsed(commandId: commandId)
        client.executeCommand(commandId: commandId, workingDirectory: workingDirectory)

        // Wait briefly for backend to send command_started message with session ID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // Find the most recent command (the one we just started)
            if let mostRecentCommand = client.runningCommands.values.max(by: { $0.startTime < $1.startTime }) {
                activeCommandSessionId = mostRecentCommand.id
                navigateToExecution = true
            }
        }
    }
}

// MARK: - Command Row View

struct CommandRowView: View {
    let command: Command
    let onExecute: (String) -> Void
    @State private var isExpanded = false

    var body: some View {
        if command.type == .group, let children = command.children {
            // Group with children: use DisclosureGroup
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(children) { child in
                    CommandRowView(command: child, onExecute: onExecute)
                }
            } label: {
                HStack(spacing: 8) {
                    Text("📁")
                        .font(.body)
                    Text(command.label)
                        .font(.body)
                    Spacer()
                }
            }
        } else {
            // Leaf command: tappable button
            Button(action: {
                onExecute(command.id)
            }) {
                HStack(spacing: 8) {
                    Text("▶️")
                        .font(.body)
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

// MARK: - Preview

struct CommandMenuView_Previews: PreviewProvider {
    static var previews: some View {
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080")

        // Mock available commands
        let mockCommands = AvailableCommands(
            workingDirectory: "/Users/test/project",
            projectCommands: [
                Command(id: "build", label: "Build", type: .command),
                Command(id: "docker", label: "Docker", type: .group, children: [
                    Command(id: "docker.up", label: "Up", type: .command),
                    Command(id: "docker.down", label: "Down", type: .command)
                ])
            ],
            generalCommands: [
                Command(id: "git.status", label: "Git Status", type: .command, description: "Show git working tree status")
            ]
        )
        client.availableCommands = mockCommands

        return CommandMenuView(
            client: client,
            workingDirectory: "/Users/test/project"
        )
    }
}
