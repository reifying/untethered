// SessionSidebarView.swift
// macOS sidebar with sessions grouped by directory, recent sessions, and commands

#if os(macOS)
import SwiftUI
import CoreData
import OSLog

private let logger = Logger(subsystem: "com.travisbrown.VoiceCode", category: "SessionSidebar")

// MARK: - Sidebar ViewModel

/// Isolates VoiceCodeClient observation to only lockedSessions for the sidebar.
/// Prevents re-renders when unrelated client state changes.
class SessionSidebarViewModel: ObservableObject {
    @Published var lockedSessions: Set<String> = []

    init(client: VoiceCodeClient) {
        client.$lockedSessions
            .receive(on: DispatchQueue.main)
            .assign(to: &$lockedSessions)
    }

    func isSessionLocked(_ sessionId: String) -> Bool {
        lockedSessions.contains(sessionId)
    }
}

// MARK: - SessionSidebarView

struct SessionSidebarView: View {
    @ObservedObject var client: VoiceCodeClient
    @ObservedObject var settings: AppSettings
    @Binding var selectedSessionId: UUID?
    @Binding var recentSessions: [RecentSession]
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.openSettings) private var openSettings

    @StateObject private var viewModel: SessionSidebarViewModel

    @State private var sessions: [CDBackendSession] = []
    @State private var recentExpanded = true
    @State private var projectsExpanded = true
    @State private var commandsExpanded = false
    @State private var showingNewSession = false
    @State private var newSessionName = ""
    @State private var newWorkingDirectory = ""
    @State private var createWorktree = false

    // Cached computed properties
    @State private var cachedRecentSessions: [CDBackendSession] = []
    @State private var cachedSessionsByDirectory: [(directory: String, sessions: [CDBackendSession])] = []

    private static let commandSorter = CommandSorter()

    init(
        client: VoiceCodeClient,
        settings: AppSettings,
        selectedSessionId: Binding<UUID?>,
        recentSessions: Binding<[RecentSession]>
    ) {
        self.client = client
        self.settings = settings
        self._selectedSessionId = selectedSessionId
        self._recentSessions = recentSessions
        self._viewModel = StateObject(wrappedValue: SessionSidebarViewModel(client: client))
    }

    /// Top 10 most recently modified sessions
    static func computeRecentSessions(from sessions: [CDBackendSession]) -> [CDBackendSession] {
        Array(
            sessions
                .sorted { $0.lastModified > $1.lastModified }
                .prefix(10)
        )
    }

    /// Sessions grouped by working directory, sorted by most recent activity
    static func computeSessionsByDirectory(from sessions: [CDBackendSession]) -> [(directory: String, sessions: [CDBackendSession])] {
        let grouped = Dictionary(grouping: sessions, by: { $0.workingDirectory })
        return grouped
            .map { directory, sessions in
                let sorted = sessions.sorted { $0.lastModified > $1.lastModified }
                return (directory: directory, sessions: sorted)
            }
            .sorted { group1, group2 in
                let maxDate1 = group1.sessions.first?.lastModified ?? Date.distantPast
                let maxDate2 = group2.sessions.first?.lastModified ?? Date.distantPast
                return maxDate1 > maxDate2
            }
    }

    /// Sorted project commands (top 5 MRU)
    private var sortedProjectCommands: [Command] {
        guard let commands = client.availableCommands?.projectCommands else { return [] }
        return Array(Self.commandSorter.sortCommands(commands).prefix(5))
    }

    private var defaultWorkingDirectory: String {
        cachedSessionsByDirectory.first?.directory ?? FileManager.default.currentDirectoryPath
    }

    var body: some View {
        List(selection: $selectedSessionId) {
            // Recent Sessions
            if !recentSessions.isEmpty || !cachedRecentSessions.isEmpty {
                Section(isExpanded: $recentExpanded) {
                    // Show backend recent sessions if available, otherwise CoreData sessions
                    if !recentSessions.isEmpty {
                        ForEach(recentSessions) { session in
                            if let sessionUUID = UUID(uuidString: session.sessionId) {
                                SidebarRecentSessionRow(session: session)
                                    .tag(sessionUUID)
                            }
                        }
                    } else {
                        ForEach(cachedRecentSessions) { session in
                            SessionSidebarRow(
                                session: session,
                                isLocked: viewModel.isSessionLocked(session.id.uuidString.lowercased())
                            )
                            .tag(session.id)
                        }
                    }
                } header: {
                    Label("Recent", systemImage: "clock")
                }
            }

            // Projects grouped by directory
            Section(isExpanded: $projectsExpanded) {
                ForEach(cachedSessionsByDirectory, id: \.directory) { group in
                    DisclosureGroup {
                        ForEach(group.sessions) { session in
                            SessionSidebarRow(
                                session: session,
                                isLocked: viewModel.isSessionLocked(session.id.uuidString.lowercased())
                            )
                            .tag(session.id)
                        }
                    } label: {
                        HStack {
                            Label(
                                URL(fileURLWithPath: group.directory).lastPathComponent,
                                systemImage: "folder"
                            )

                            Spacer()

                            let totalUnread = group.sessions.reduce(0) { $0 + Int($1.unreadCount) }
                            if totalUnread > 0 {
                                Text("\(totalUnread)")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            } header: {
                Label("Projects", systemImage: "folder.badge.gearshape")
            }

            // Commands quick access
            if client.availableCommands != nil {
                Section(isExpanded: $commandsExpanded) {
                    ForEach(sortedProjectCommands, id: \.id) { command in
                        CommandSidebarRow(command: command)
                    }
                } header: {
                    Label("Commands", systemImage: "terminal")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Sessions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    newWorkingDirectory = defaultWorkingDirectory
                    showingNewSession = true
                }) {
                    Image(systemName: "plus")
                }
                .help("New Session (⌘N)")
            }

            ToolbarItem(placement: .automatic) {
                Button(action: { openSettings() }) {
                    Image(systemName: "gear")
                }
                .help("Settings (⌘,)")
            }
        }
        .task {
            loadSessions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionListDidUpdate)) { _ in
            logger.info("🔄 Session list updated, refreshing sidebar")
            loadSessions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sidebarCreateNewSession)) { _ in
            newWorkingDirectory = defaultWorkingDirectory
            showingNewSession = true
        }
        .sheet(isPresented: $showingNewSession) {
            NewSessionView(
                name: $newSessionName,
                workingDirectory: $newWorkingDirectory,
                createWorktree: $createWorktree,
                onCreate: {
                    createNewSession(
                        name: newSessionName,
                        workingDirectory: newWorkingDirectory.isEmpty ? nil : newWorkingDirectory
                    )
                    newSessionName = ""
                    newWorkingDirectory = ""
                    createWorktree = false
                    showingNewSession = false
                },
                onCancel: {
                    newSessionName = ""
                    newWorkingDirectory = ""
                    createWorktree = false
                    showingNewSession = false
                }
            )
        }
    }

    // MARK: - Data Loading

    private func loadSessions() {
        do {
            sessions = try CDBackendSession.fetchActiveSessions(context: viewContext)
            cachedRecentSessions = Self.computeRecentSessions(from: sessions)
            cachedSessionsByDirectory = Self.computeSessionsByDirectory(from: sessions)
        } catch {
            logger.error("❌ Failed to fetch sessions for sidebar: \(error)")
            sessions = []
        }
    }

    // MARK: - Session Creation

    private func createNewSession(name: String, workingDirectory: String?) {
        let sessionId = UUID()

        let session = CDBackendSession(context: viewContext)
        session.id = sessionId
        session.backendName = sessionId.uuidString.lowercased()
        session.workingDirectory = workingDirectory ?? FileManager.default.currentDirectoryPath
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.isLocallyCreated = true

        let fetchRequest = CDUserSession.fetchUserSession(id: sessionId)
        let userSession: CDUserSession
        if let existing = try? viewContext.fetch(fetchRequest).first {
            userSession = existing
        } else {
            userSession = CDUserSession(context: viewContext)
            userSession.id = sessionId
            userSession.createdAt = Date()
        }
        userSession.customName = name

        do {
            try viewContext.save()
            logger.info("📝 Created new session from sidebar: \(sessionId.uuidString.lowercased())")
            selectedSessionId = sessionId
            loadSessions()
        } catch {
            logger.error("❌ Failed to create session: \(error)")
        }
    }
}

// MARK: - Session Sidebar Row

struct SessionSidebarRow: View {
    @ObservedObject var session: CDBackendSession
    let isLocked: Bool
    @Environment(\.managedObjectContext) private var viewContext

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.displayName(context: viewContext))
                        .font(.body)
                        .lineLimit(1)

                    if session.provider != "claude" {
                        Text(session.provider.uppercased())
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .cornerRadius(3)
                    }
                }

                Text(session.workingDirectory.components(separatedBy: "/").suffix(2).joined(separator: "/"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            if session.unreadCount > 0 {
                Text("\(session.unreadCount)")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Sidebar Recent Session Row

struct SidebarRecentSessionRow: View {
    let session: RecentSession
    @Environment(\.managedObjectContext) private var viewContext

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName(context: viewContext))
                    .font(.body)
                    .lineLimit(1)

                Text(URL(fileURLWithPath: session.workingDirectory).lastPathComponent)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            RelativeTimeText(session.lastModified)
                .font(.caption2)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Command Sidebar Row

struct CommandSidebarRow: View {
    let command: Command

    var body: some View {
        HStack {
            Image(systemName: "play.fill")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(command.label)
                .lineLimit(1)
        }
    }
}

// MARK: - Empty Detail View

struct EmptyDetailView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("Select a session or create a new one")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("⌘N to create new session")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
#endif
