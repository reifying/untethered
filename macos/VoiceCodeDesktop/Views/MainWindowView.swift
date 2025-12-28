// MainWindowView.swift
// Main 3-column layout with NavigationSplitView per Appendix J.1

import SwiftUI
import CoreData
import OSLog
import VoiceCodeShared

private let logger = Logger(subsystem: "dev.910labs.voice-code-desktop", category: "MainWindowView")

struct MainWindowView: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var client: VoiceCodeClient
    @State private var selectedDirectory: String?
    @State private var selectedSession: CDBackendSession?
    @State private var showingSettings = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var recentSessions: [RecentSession] = []
    @State private var showingNewSession = false
    @State private var allSessions: [CDBackendSession] = []

    @Environment(\.managedObjectContext) private var viewContext

    init(settings: AppSettings) {
        self.settings = settings
        _client = StateObject(wrappedValue: VoiceCodeClient(
            serverURL: settings.fullServerURL,
            appSettings: settings
        ))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar: Session list with sections
            SidebarView(
                recentSessions: recentSessions,
                selectedDirectory: $selectedDirectory,
                selectedSession: $selectedSession,
                connectionState: client.connectionState,
                settings: settings,
                serverURL: settings.serverURL,
                serverPort: settings.serverPort,
                onRetryConnection: { client.retryConnection() },
                onShowSettings: { showingSettings = true },
                onNewSession: { showingNewSession = true }
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
        } content: {
            // Content: Sessions for selected directory OR conversation for selected session
            if let directory = selectedDirectory {
                SessionListView(
                    workingDirectory: directory,
                    selectedSession: $selectedSession
                )
                .navigationSplitViewColumnWidth(min: 280, ideal: 350)
            } else if let session = selectedSession {
                // Session selected from Recent/Queue - show conversation
                ConversationDetailView(
                    session: session,
                    client: client,
                    settings: settings
                )
                .navigationSplitViewColumnWidth(min: 400, ideal: 600)
            } else {
                EmptySelectionView()
                    .navigationSplitViewColumnWidth(min: 300, ideal: 450)
            }
        } detail: {
            // Detail: Session info / resources
            if let session = selectedSession {
                if selectedDirectory != nil {
                    // When directory is selected, show conversation in detail pane
                    ConversationDetailView(
                        session: session,
                        client: client,
                        settings: settings
                    )
                } else {
                    // When session is selected directly, show session info
                    DetailPlaceholderView(session: session)
                }
            } else {
                Text("Select a session")
                    .foregroundColor(.secondary)
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .onAppear {
            setupRecentSessionsCallback()
            if settings.isServerConfigured {
                client.connect()
            }
        }
        .onChange(of: settings.serverURL) {
            reconnectIfConfigured()
        }
        .onChange(of: settings.serverPort) {
            reconnectIfConfigured()
        }
        .sheet(isPresented: $showingSettings) {
            MacSettingsView(settings: settings, onDismiss: {
                showingSettings = false
                if settings.isServerConfigured {
                    client.retryConnection()
                }
            })
        }
        .sheet(isPresented: $showingNewSession) {
            NewSessionView { session in
                // Select the newly created session
                selectedDirectory = nil
                selectedSession = session
            }
        }
        // Provide focused values for AppCommands
        .focusedSceneValue(\.selectedSession, selectedSession)
        .focusedSceneValue(\.voiceCodeClient, client)
        .focusedSceneValue(\.sessionsList, allSessions)
        .focusedSceneValue(\.selectedSessionBinding, $selectedSession)
        // Handle command notifications
        .onReceive(NotificationCenter.default.publisher(for: .requestNewSession)) { _ in
            showingNewSession = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestNewWindow)) { _ in
            // Open a new window - for WindowGroup-based apps this can be done
            // by using the NSApp.sendAction to trigger window creation
            // Note: In SwiftUI with WindowGroup, this opens a new instance
            if let window = NSApp.windows.first(where: { $0.isVisible }) {
                // Create a new window by using the standard macOS new window action
                NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil)
            }
        }
        .task {
            // Load all sessions for command navigation
            loadAllSessions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionListDidUpdate)) { _ in
            loadAllSessions()
        }
    }

    private func loadAllSessions() {
        do {
            allSessions = try CDBackendSession.fetchActiveSessions(context: viewContext)
        } catch {
            logger.error("❌ Failed to fetch all sessions for navigation: \(error)")
            allSessions = []
        }
    }

    private func reconnectIfConfigured() {
        client.updateServerURL(settings.fullServerURL)
        if settings.isServerConfigured {
            client.connect()
        }
    }

    private func setupRecentSessionsCallback() {
        client.onRecentSessionsReceived = { sessionDicts in
            let sessions = RecentSession.parseRecentSessions(sessionDicts)
            DispatchQueue.main.async {
                self.recentSessions = sessions
            }
        }
    }
}

// MARK: - SidebarView

struct SidebarView: View {
    let recentSessions: [RecentSession]
    @Binding var selectedDirectory: String?
    @Binding var selectedSession: CDBackendSession?
    let connectionState: ConnectionState
    let settings: AppSettings
    let serverURL: String
    let serverPort: String
    let onRetryConnection: () -> Void
    let onShowSettings: () -> Void
    let onNewSession: () -> Void

    @Environment(\.managedObjectContext) private var viewContext

    // Fetch active (non-deleted) sessions from CoreData
    @State private var sessions: [CDBackendSession] = []

    // Section expansion state
    @State private var isRecentExpanded = true
    @State private var isQueueExpanded = true
    @State private var isPriorityQueueExpanded = true
    @State private var isProjectsExpanded = true

    // Directory metadata for Projects section
    struct DirectoryInfo: Identifiable {
        let workingDirectory: String
        let directoryName: String
        let sessionCount: Int
        let totalUnread: Int32
        let lastModified: Date

        var id: String { workingDirectory }
    }

    // Computed properties for filtered sessions
    private var queuedSessions: [CDBackendSession] {
        sessions
            .filter { $0.isInQueue }
            .sorted { $0.queuePosition < $1.queuePosition }
    }

    private var priorityQueueSessions: [CDBackendSession] {
        sessions
            .filter { $0.isInPriorityQueue }
            .sorted { session1, session2 in
                // Three-level sort: priority → priorityOrder → session ID
                if session1.priority != session2.priority {
                    return session1.priority < session2.priority
                }
                if session1.priorityOrder != session2.priorityOrder {
                    return session1.priorityOrder < session2.priorityOrder
                }
                return session1.id.uuidString < session2.id.uuidString
            }
    }

    private var directories: [DirectoryInfo] {
        let grouped = Dictionary(grouping: sessions, by: { $0.workingDirectory })

        return grouped.map { workingDirectory, sessions in
            let directoryName = (workingDirectory as NSString).lastPathComponent
            let sessionCount = sessions.count
            let totalUnread = sessions.reduce(0) { $0 + $1.unreadCount }
            let lastModified = sessions.map { $0.lastModified }.max() ?? Date.distantPast

            return DirectoryInfo(
                workingDirectory: workingDirectory,
                directoryName: directoryName,
                sessionCount: sessionCount,
                totalUnread: totalUnread,
                lastModified: lastModified
            )
        }
        .sorted { $0.lastModified > $1.lastModified }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Session list with sections
            if sessions.isEmpty && recentSessions.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No Sessions")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Sessions will appear here when you connect to the backend.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedSession) {
                    // Recent section
                    if !recentSessions.isEmpty {
                        Section(isExpanded: $isRecentExpanded) {
                            ForEach(recentSessions) { session in
                                RecentSessionRowView(session: session)
                                    .tag(findCDSession(for: session))
                            }
                        } header: {
                            Text("Recent")
                        }
                    }

                    // Queue section
                    if settings.queueEnabled && !queuedSessions.isEmpty {
                        Section(isExpanded: $isQueueExpanded) {
                            ForEach(queuedSessions) { session in
                                SessionRowView(session: session)
                                    .tag(session)
                            }
                        } header: {
                            Text("Queue")
                        }
                    }

                    // Priority Queue section
                    if settings.priorityQueueEnabled && !priorityQueueSessions.isEmpty {
                        Section(isExpanded: $isPriorityQueueExpanded) {
                            ForEach(priorityQueueSessions) { session in
                                SessionRowView(session: session)
                                    .tag(session)
                                    .listRowBackground(priorityTintColor(for: session.priority))
                            }
                        } header: {
                            Text("Priority Queue")
                        }
                    }

                    // Projects section (grouped by directory)
                    Section(isExpanded: $isProjectsExpanded) {
                        ForEach(directories) { directory in
                            DirectoryRowView(
                                directory: directory,
                                isSelected: selectedDirectory == directory.workingDirectory
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedDirectory = directory.workingDirectory
                                selectedSession = nil
                            }
                        }
                    } header: {
                        Text("Projects")
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: selectedSession) {
                    // Clear directory selection when a session is selected
                    if selectedSession != nil {
                        selectedDirectory = nil
                    }
                }
            }

            Divider()

            // Connection status footer
            ConnectionStatusFooter(
                connectionState: connectionState,
                serverURL: serverURL,
                serverPort: serverPort,
                onRetryConnection: onRetryConnection,
                onShowSettings: onShowSettings
            )
        }
        .navigationTitle("Sessions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onNewSession) {
                    Label("New Session", systemImage: "plus")
                }
                .help("New Session (⌘N)")
                .keyboardShortcut("n")
            }
        }
        .task {
            // Load sessions when view appears
            do {
                sessions = try CDBackendSession.fetchActiveSessions(context: viewContext)
            } catch {
                logger.error("❌ Failed to fetch active sessions: \(error)")
                sessions = []
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionListDidUpdate)) { _ in
            // Refetch sessions when backend sends updated session list
            logger.info("🔄 Session list updated notification received, refetching sessions")
            do {
                sessions = try CDBackendSession.fetchActiveSessions(context: viewContext)
            } catch {
                logger.error("❌ Failed to refetch sessions after update: \(error)")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .priorityQueueChanged)) { _ in
            // Refresh when priority queue changes
            do {
                sessions = try CDBackendSession.fetchActiveSessions(context: viewContext)
            } catch {
                logger.error("❌ Failed to refetch sessions after priority queue change: \(error)")
            }
        }
    }

    // Find the CDBackendSession corresponding to a RecentSession
    private func findCDSession(for recentSession: RecentSession) -> CDBackendSession? {
        guard let uuid = UUID(uuidString: recentSession.sessionId) else { return nil }
        return sessions.first { $0.id == uuid }
    }

    /// Returns a subtle background tint color based on priority level
    private func priorityTintColor(for priority: Int32) -> Color {
        switch priority {
        case 1:  // High - darkest tint
            return Color.blue.opacity(0.18)
        case 5:  // Medium - medium tint
            return Color.blue.opacity(0.10)
        default: // Low (10) - no tint
            return Color.clear
        }
    }
}

// MARK: - RecentSessionRowView

struct RecentSessionRowView: View {
    let session: RecentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Line 1: Session name
            Text(session.displayName)
                .font(.headline)
                .lineLimit(1)

            // Line 2: Session ID prefix + working directory
            HStack(spacing: 4) {
                Text("[\(session.sessionId.prefix(8))]")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fontDesign(.monospaced)

                Text("•")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Text(URL(fileURLWithPath: session.workingDirectory).lastPathComponent)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            // Line 3: Last modified
            Text(session.lastModified.relativeFormatted())
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - SessionRowView

struct SessionRowView: View {
    @ObservedObject var session: CDBackendSession
    @Environment(\.managedObjectContext) private var viewContext

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayName(context: viewContext))
                    .font(.headline)
                    .lineLimit(1)

                Text(URL(fileURLWithPath: session.workingDirectory).lastPathComponent)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                if !session.preview.isEmpty {
                    Text(session.preview)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            if session.unreadCount > 0 {
                Text("\(session.unreadCount)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - SessionListView

/// Shows sessions for a selected project/directory with search functionality
struct SessionListView: View {
    let workingDirectory: String
    @Binding var selectedSession: CDBackendSession?

    @Environment(\.managedObjectContext) private var viewContext

    @State private var searchText = ""
    @State private var sessions: [CDBackendSession] = []

    /// Directory name for display in navigation title
    private var directoryName: String {
        (workingDirectory as NSString).lastPathComponent
    }

    /// Filtered sessions based on search text
    private var filteredSessions: [CDBackendSession] {
        guard !searchText.isEmpty else { return sessions }

        let lowercasedSearch = searchText.lowercased()
        return sessions.filter { session in
            // Search in display name
            let displayName = session.displayName(context: viewContext).lowercased()
            if displayName.contains(lowercasedSearch) {
                return true
            }

            // Search in session ID
            if session.id.uuidString.lowercased().contains(lowercasedSearch) {
                return true
            }

            // Search in preview
            if session.preview.lowercased().contains(lowercasedSearch) {
                return true
            }

            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if sessions.isEmpty {
                // Empty state: no sessions in this directory
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No Sessions")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Text("No sessions found in \(directoryName)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedSession) {
                    ForEach(filteredSessions) { session in
                        SessionListRowView(session: session)
                            .tag(session)
                    }
                }
                .listStyle(.inset)
                .searchable(text: $searchText, prompt: "Search sessions")
            }
        }
        .navigationTitle(directoryName)
        .task {
            loadSessions()
        }
        .onChange(of: workingDirectory) {
            loadSessions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionListDidUpdate)) { _ in
            loadSessions()
        }
    }

    private func loadSessions() {
        do {
            // Fetch active sessions filtered by working directory, sorted by last modified
            sessions = try CDBackendSession.fetchActiveSessions(
                workingDirectory: workingDirectory,
                context: viewContext
            ).sorted { $0.lastModified > $1.lastModified }
        } catch {
            logger.error("❌ Failed to fetch sessions for directory \(workingDirectory): \(error)")
            sessions = []
        }
    }
}

// MARK: - SessionListRowView

/// Row view for sessions in SessionListView
struct SessionListRowView: View {
    @ObservedObject var session: CDBackendSession
    @Environment(\.managedObjectContext) private var viewContext

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                // Line 1: Session name
                Text(session.displayName(context: viewContext))
                    .font(.headline)
                    .lineLimit(1)

                // Line 2: Session ID prefix + last modified
                HStack(spacing: 4) {
                    Text("[\(session.id.uuidString.lowercased().prefix(8))]")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fontDesign(.monospaced)

                    Text("•")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text(session.lastModified.relativeFormatted())
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // Line 3: Preview text (if available)
                if !session.preview.isEmpty {
                    Text(session.preview)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            // Message count badge
            if session.messageCount > 0 {
                Text("\(session.messageCount)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }

            // Unread badge
            if session.unreadCount > 0 {
                Text("\(session.unreadCount)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - DirectoryRowView

struct DirectoryRowView: View {
    let directory: SidebarView.DirectoryInfo
    var isSelected: Bool = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                // Line 1: Folder icon + directory name
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundColor(isSelected ? .white : .blue)
                        .imageScale(.medium)

                    Text(directory.directoryName)
                        .font(.headline)
                        .foregroundColor(isSelected ? .white : .primary)
                        .lineLimit(1)
                }

                // Line 2: Full path
                Text(directory.workingDirectory)
                    .font(.caption)
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                    .lineLimit(1)

                // Line 3: Session count + timestamp
                HStack(spacing: 4) {
                    Text("\(directory.sessionCount) session\(directory.sessionCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)

                    Text("•")
                        .font(.caption2)
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)

                    Text(directory.lastModified.relativeFormatted())
                        .font(.caption2)
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                }
            }

            Spacer()

            if directory.totalUnread > 0 {
                Text("\(directory.totalUnread)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(isSelected ? .accentColor : .white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(isSelected ? Color.white : Color.red)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor : Color.clear)
        .cornerRadius(6)
    }
}

// MARK: - ConnectionStatusFooter

struct ConnectionStatusFooter: View {
    let connectionState: ConnectionState
    let serverURL: String
    let serverPort: String
    let onRetryConnection: () -> Void
    let onShowSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Status indicator dot
            ConnectionStatusDot(connectionState: connectionState)

            // Status text with server details
            ConnectionStatusText(
                connectionState: connectionState,
                showDetails: true,
                serverURL: serverURL,
                serverPort: serverPort
            )

            Spacer()

            // Action buttons
            if connectionState == .failed || connectionState == .disconnected {
                Button(action: onRetryConnection) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Retry connection")
                .accessibilityLabel("Retry connection")
            }

            Button(action: onShowSettings) {
                Image(systemName: "gear")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .accessibilityLabel("Open settings")
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - DetailPlaceholderView

struct DetailPlaceholderView: View {
    @ObservedObject var session: CDBackendSession
    @Environment(\.managedObjectContext) private var viewContext

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Session Info")
                .font(.headline)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Name", value: session.displayName(context: viewContext))
                    LabeledContent("Directory", value: session.workingDirectory)
                    LabeledContent("Messages", value: "\(session.messageCount)")
                    LabeledContent("Last Modified", value: session.lastModified.formatted())
                }
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - EmptySelectionView

struct EmptySelectionView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("Select a Session")
                .font(.title2)
                .foregroundColor(.secondary)

            Text("Choose a session from the sidebar to view the conversation.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - macOS Settings View

struct MacSettingsView: View {
    @ObservedObject var settings: AppSettings
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Server Settings")
                .font(.title2)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Server Address")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextField("e.g., localhost", text: $settings.serverURL)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Port")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextField("e.g., 8080", text: $settings.serverPort)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(.horizontal)

            Spacer()

            HStack {
                Spacer()

                Button("Done") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(width: 350, height: 250)
    }
}

// MARK: - Date Extension for Relative Formatting

extension Date {
    func relativeFormatted() -> String {
        let now = Date()
        let interval = now.timeIntervalSince(self)

        // Less than 1 minute
        if interval < 60 {
            return "just now"
        }

        // Less than 7 days: use RelativeDateTimeFormatter
        if interval < 7 * 24 * 60 * 60 {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return formatter.localizedString(for: self, relativeTo: now)
        }

        // 7+ days: use date format
        let calendar = Calendar.current
        let dateFormatter = DateFormatter()

        if calendar.isDate(self, equalTo: now, toGranularity: .year) {
            dateFormatter.dateFormat = "MMM d"
        } else {
            dateFormatter.dateFormat = "MMM d, yyyy"
        }

        return dateFormatter.string(from: self)
    }
}

#Preview {
    MainWindowView(settings: AppSettings())
        .environment(\.managedObjectContext, PersistenceController(inMemory: true).container.viewContext)
}
