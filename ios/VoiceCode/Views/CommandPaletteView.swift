// CommandPaletteView.swift
// Spotlight-style command palette for quick keyboard access to app actions

#if os(macOS)
import SwiftUI

// MARK: - Command Palette Action

enum CommandPaletteAction: Equatable {
    case newSession
    case refreshSession
    case compactSession
    case sessionInfo
    case stopSpeaking
    case toggleMute
    case toggleSidebar
    case runCommand(String)
}

// MARK: - Command Palette Item

struct CommandPaletteItem: Identifiable {
    let id: String
    let title: String
    let shortcut: String?
    let category: String
    let action: CommandPaletteAction

    func matches(_ query: String) -> Bool {
        title.localizedCaseInsensitiveContains(query)
    }
}

// MARK: - Command Palette Overlay

/// Wraps CommandPaletteView in a dimmed overlay with proper dismissal behavior.
struct CommandPaletteOverlay: View {
    @ObservedObject var client: VoiceCodeClient
    @ObservedObject var voiceOutput: VoiceOutputManager
    @Binding var isPresented: Bool
    let onAction: (CommandPaletteAction) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    isPresented = false
                }

            CommandPaletteView(
                client: client,
                voiceOutput: voiceOutput,
                onAction: { action in
                    isPresented = false
                    onAction(action)
                },
                onDismiss: {
                    isPresented = false
                }
            )
        }
    }
}

// MARK: - Command Palette View

struct CommandPaletteView: View {
    @ObservedObject var client: VoiceCodeClient
    @ObservedObject var voiceOutput: VoiceOutputManager

    @State private var searchText = ""
    @State private var selectedIndex = 0
    @FocusState private var isSearchFocused: Bool

    let onAction: (CommandPaletteAction) -> Void
    let onDismiss: () -> Void

    var filteredCommands: [CommandPaletteItem] {
        let all = Self.buildAllCommands(client: client, voiceOutput: voiceOutput)
        if searchText.isEmpty { return all }
        return all.filter { $0.matches(searchText) }
    }

    static func buildAllCommands(client: VoiceCodeClient, voiceOutput: VoiceOutputManager) -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []

        // Session commands
        items.append(contentsOf: [
            CommandPaletteItem(id: "new-session", title: "New session", shortcut: "\u{2318}N", category: "Sessions", action: .newSession),
            CommandPaletteItem(id: "refresh-session", title: "Refresh current session", shortcut: "\u{2318}R", category: "Sessions", action: .refreshSession),
            CommandPaletteItem(id: "compact-session", title: "Compact session history", shortcut: "\u{2318}\u{21E7}C", category: "Sessions", action: .compactSession),
            CommandPaletteItem(id: "session-info", title: "Session info", shortcut: "\u{2318}I", category: "Sessions", action: .sessionInfo),
        ])

        // Voice commands
        items.append(contentsOf: [
            CommandPaletteItem(id: "stop-speaking", title: "Stop speaking", shortcut: "\u{2318}.", category: "Voice", action: .stopSpeaking),
            CommandPaletteItem(id: "toggle-mute", title: voiceOutput.isMuted ? "Unmute voice" : "Mute voice", shortcut: "\u{2318}\u{21E7}M", category: "Voice", action: .toggleMute),
        ])

        // Project commands from backend
        if let projectCommands = client.availableCommands?.projectCommands {
            let sorted = CommandSorter().sortCommands(projectCommands)
            for command in sorted {
                items.append(CommandPaletteItem(
                    id: "cmd-\(command.id)",
                    title: command.label,
                    shortcut: nil,
                    category: "Project Commands",
                    action: .runCommand(command.id)
                ))
            }
        }

        return items
    }

    var groupedCommands: [(key: String, value: [CommandPaletteItem])] {
        let categoryOrder = ["Sessions", "Project Commands", "Voice"]
        return Dictionary(grouping: filteredCommands) { $0.category }
            .sorted { a, b in
                let aIndex = categoryOrder.firstIndex(of: a.key) ?? Int.max
                let bIndex = categoryOrder.firstIndex(of: b.key) ?? Int.max
                return aIndex < bIndex
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Type a command...", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onSubmit { executeSelected() }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Results list
            if filteredCommands.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("No matching commands")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(groupedCommands, id: \.key) { category, commands in
                                Text(category)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 8)
                                    .padding(.bottom, 4)

                                ForEach(commands) { item in
                                    let itemIndex = filteredCommands.firstIndex(where: { $0.id == item.id }) ?? 0
                                    CommandPaletteRow(item: item, isSelected: itemIndex == selectedIndex)
                                        .id(item.id)
                                        .contentShape(Rectangle())
                                        .onTapGesture { execute(item) }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: selectedIndex) { _, newIndex in
                        if newIndex < filteredCommands.count {
                            proxy.scrollTo(filteredCommands[newIndex].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 500, height: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.3), radius: 20)
        .onAppear {
            isSearchFocused = true
            selectedIndex = 0
        }
        .onChange(of: searchText) { _, _ in
            selectedIndex = 0
        }
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
        .onKeyPress(.escape) { onDismiss(); return .handled }
    }

    private func moveSelection(_ delta: Int) {
        let newIndex = selectedIndex + delta
        if newIndex >= 0 && newIndex < filteredCommands.count {
            selectedIndex = newIndex
        }
    }

    private func executeSelected() {
        guard selectedIndex < filteredCommands.count else { return }
        execute(filteredCommands[selectedIndex])
    }

    private func execute(_ item: CommandPaletteItem) {
        onAction(item.action)
    }
}

// MARK: - Command Palette Row

struct CommandPaletteRow: View {
    let item: CommandPaletteItem
    let isSelected: Bool

    var body: some View {
        HStack {
            Image(systemName: iconName)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 16)
            Text(item.title)
            Spacer()
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(6)
        .padding(.horizontal, 4)
    }

    private var iconName: String {
        switch item.action {
        case .newSession: return "plus"
        case .refreshSession: return "arrow.clockwise"
        case .compactSession: return "archivebox"
        case .sessionInfo: return "info.circle"
        case .stopSpeaking: return "speaker.slash"
        case .toggleMute: return "speaker.wave.2"
        case .toggleSidebar: return "sidebar.left"
        case .runCommand: return "play.fill"
        }
    }
}
#endif
