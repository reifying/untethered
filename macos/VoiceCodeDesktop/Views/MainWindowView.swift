// MainWindowView.swift
// Main 3-column layout with NavigationSplitView per Appendix J.1

import SwiftUI
import CoreData
import OSLog
import VoiceCodeShared

private let logger = Logger(subsystem: "dev.910labs.voice-code-desktop", category: "MainWindowView")

struct MainWindowView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var statusBarController: StatusBarController
    @StateObject private var client: VoiceCodeClient
    @StateObject private var resourcesManager: ResourcesManager
    @StateObject private var selectionManager = SessionSelectionManager()
    @ObservedObject private var windowRegistry = WindowSessionRegistry.shared
    @State private var showingSettings = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var recentSessions: [RecentSession] = []
    @State private var showingNewSession = false
    @State private var allSessions: [CDBackendSession] = []
    @State private var sessionToDelete: CDBackendSession?
    @State private var showingDeleteConfirmation = false
    @State private var sessionToRename: CDBackendSession?
    @State private var showingRenameSheet = false
    @State private var renameText = ""
    @State private var currentWindow: NSWindow?

    @Environment(\.managedObjectContext) private var viewContext

    /// Selected directory (synced with selectionManager)
    private var selectedDirectory: String? {
        get { selectionManager.selectedDirectory }
    }

    /// Binding to selected directory for child views
    private var selectedDirectoryBinding: Binding<String?> {
        Binding(
            get: { selectionManager.selectedDirectory },
            set: { selectionManager.selectedDirectory = $0 }
        )
    }

    /// Selected session resolved from ID via allSessions
    private var selectedSession: CDBackendSession? {
        guard let id = selectionManager.selectedSessionId else { return nil }
        return allSessions.first { $0.id == id }
    }

    /// Binding to selected session for child views.
    /// Uses WindowSessionRegistry to ensure sessions are only open in one window at a time.
    private var selectedSessionBinding: Binding<CDBackendSession?> {
        Binding(
            get: { selectedSession },
            set: { session in
                // Unregister old session from this window
                if let oldId = selectionManager.selectedSessionId {
                    windowRegistry.unregisterWindow(for: oldId)
                }

                guard let newSession = session else {
                    selectionManager.selectedSessionId = nil
                    return
                }

                // Try to select the new session
                // If it's already open in another window, that window will be focused
                if windowRegistry.trySelectSession(newSession.id, from: currentWindow) {
                    selectionManager.selectedSessionId = newSession.id
                    if let window = currentWindow {
                        windowRegistry.registerWindow(window, for: newSession.id)
                    }
                }
                // If trySelectSession returns false, selection is blocked and other window is focused
            }
        )
    }

    init(settings: AppSettings, statusBarController: StatusBarController) {
        self.settings = settings
        self.statusBarController = statusBarController
        let voiceCodeClient = VoiceCodeClient(
            serverURL: settings.fullServerURL,
            appSettings: settings
        )
        _client = StateObject(wrappedValue: voiceCodeClient)
        _resourcesManager = StateObject(wrappedValue: ResourcesManager(
            client: voiceCodeClient,
            appSettings: settings
        ))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar: Session list with sections
            SidebarView(
                recentSessions: recentSessions,
                selectedDirectory: selectedDirectoryBinding,
                selectedSession: selectedSessionBinding,
                connectionState: client.connectionState,
                settings: settings,
                serverURL: settings.serverURL,
                serverPort: settings.serverPort,
                onRetryConnection: { client.retryConnection() },
                onShowSettings: { showingSettings = true },
                onNewSession: { showingNewSession = true }
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 300)
        } content: {
            // Content: Sessions for selected directory OR conversation for selected session
            if let directory = selectedDirectory {
                SessionListView(
                    workingDirectory: directory,
                    selectedSession: selectedSessionBinding
                )
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 400)
            } else if let session = selectedSession {
                // Session selected from Recent/Queue - show conversation
                ConversationDetailView(
                    session: session,
                    client: client,
                    resourcesManager: resourcesManager,
                    settings: settings
                )
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 400)
            } else if let sessionId = selectionManager.selectedSessionId {
                // Session ID selected but session not found
                SessionNotFoundView(
                    sessionId: sessionId,
                    onDismiss: { selectionManager.selectedSessionId = nil },
                    onRefresh: { loadAllSessions() }
                )
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 400)
            } else {
                EmptySelectionView()
                    .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 400)
            }
        } detail: {
            // Detail: Session info / resources
            if let session = selectedSession {
                if selectedDirectory != nil {
                    // When directory is selected, show conversation in detail pane
                    ConversationDetailView(
                        session: session,
                        client: client,
                        resourcesManager: resourcesManager,
                        settings: settings
                    )
                } else {
                    // When session is selected directly, show session info
                    DetailPlaceholderView(session: session)
                }
            } else if let sessionId = selectionManager.selectedSessionId {
                // Session ID selected but session not found - show in detail pane too
                SessionNotFoundView(
                    sessionId: sessionId,
                    onDismiss: { selectionManager.selectedSessionId = nil },
                    onRefresh: { loadAllSessions() }
                )
            } else {
                Text("Select a session")
                    .foregroundColor(.secondary)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(WindowAccessor { window in
            if let window = window {
                currentWindow = window
                // Set as main window if it's the first one
                if windowRegistry.allRegisteredSessions().isEmpty {
                    windowRegistry.setMainWindow(window)
                }
            }
        })
        .onAppear {
            setupRecentSessionsCallback()
            setupStatusBarController()
            if settings.isServerConfigured {
                client.connect()
            }
        }
        .onDisappear {
            // Unregister all sessions from this window when it closes
            if let window = currentWindow {
                windowRegistry.unregisterAllSessions(for: window)
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
                selectionManager.selectedDirectory = nil
                selectionManager.selectedSessionId = session.id
            }
        }
        // Provide focused values for AppCommands
        .focusedSceneValue(\.selectedSession, selectedSession)
        .focusedSceneValue(\.voiceCodeClient, client)
        .focusedSceneValue(\.sessionsList, allSessions)
        .focusedSceneValue(\.selectedSessionBinding, selectedSessionBinding)
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

            // Check and renormalize priority queue on app launch if needed
            if CDBackendSession.needsRenormalization(context: viewContext) {
                logger.info("📍 [PriorityQueue] Renormalization needed on app launch")
                CDBackendSession.renormalizePriorityQueue(context: viewContext)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionListDidUpdate)) { _ in
            loadAllSessions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .statusBarDisconnectRequested)) { _ in
            client.disconnect()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestSessionDeletion)) { notification in
            if let sessionId = notification.userInfo?["sessionId"] as? UUID,
               let session = allSessions.first(where: { $0.id == sessionId }) {
                sessionToDelete = session
                showingDeleteConfirmation = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionDeleted)) { notification in
            // Clear selection if the deleted session was selected
            if let sessionIdString = notification.userInfo?["sessionId"] as? String,
               let selectedId = selectionManager.selectedSessionId,
               selectedId.uuidString.lowercased() == sessionIdString {
                selectionManager.selectedSessionId = nil
            }
            // Refresh session list
            loadAllSessions()
        }
        .alert("Delete Session", isPresented: $showingDeleteConfirmation, presenting: sessionToDelete) { session in
            Button("Cancel", role: .cancel) {
                sessionToDelete = nil
            }
            Button("Delete", role: .destructive) {
                deleteSession(session)
                sessionToDelete = nil
            }
        } message: { session in
            Text("Are you sure you want to delete \"\(session.displayName(context: viewContext))\"? This will hide the session from the list. The session data is preserved and can be recovered.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestSessionRename)) { notification in
            if let sessionId = notification.userInfo?["sessionId"] as? UUID,
               let session = allSessions.first(where: { $0.id == sessionId }) {
                sessionToRename = session
                renameText = session.displayName(context: viewContext)
                showingRenameSheet = true
            }
        }
        .sheet(isPresented: $showingRenameSheet) {
            SessionRenameSheet(
                sessionName: $renameText,
                onRename: {
                    if let session = sessionToRename {
                        renameSession(session, to: renameText)
                    }
                    showingRenameSheet = false
                    sessionToRename = nil
                    renameText = ""
                },
                onCancel: {
                    showingRenameSheet = false
                    sessionToRename = nil
                    renameText = ""
                }
            )
        }
    }

    private func loadAllSessions() {
        do {
            allSessions = try CDBackendSession.fetchActiveSessions(context: viewContext)
            // Validate selection after loading sessions
            selectionManager.validateSelection(against: allSessions)
            selectionManager.validateDirectorySelection(against: allSessions)
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

    private func deleteSession(_ session: CDBackendSession) {
        CDBackendSession.softDeleteSession(session, context: viewContext)
    }

    private func renameSession(_ session: CDBackendSession, to newName: String) {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        // Create or update CDUserSession with custom name
        let fetchRequest = CDUserSession.fetchUserSession(id: session.id)
        let userSession: CDUserSession
        if let existing = try? viewContext.fetch(fetchRequest).first {
            userSession = existing
        } else {
            userSession = CDUserSession(context: viewContext)
            userSession.id = session.id
            userSession.createdAt = Date()
        }
        userSession.customName = trimmedName

        do {
            try viewContext.save()
            logger.info("📝 Renamed session \(session.id.uuidString.prefix(8)) to: \(trimmedName)")
            loadAllSessions()
        } catch {
            logger.error("❌ Failed to rename session: \(error)")
        }
    }

    private func setupStatusBarController() {
        // Set up the status bar
        statusBarController.setup()

        // Observe connection state from client
        statusBarController.observeConnectionState(from: client)

        // Set up callbacks
        statusBarController.onRetryConnection = { [weak client] in
            client?.retryConnection()
        }

        statusBarController.onShowMainWindow = {
            // Activate app and bring window to front
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.isVisible }) {
                window.makeKeyAndOrderFront(nil)
            }
        }

        statusBarController.onOpenPreferences = {
            // Open Settings window via standard macOS action
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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
                            .onMove { source, destination in
                                reorderPriorityQueue(from: source, to: destination)
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

    /// Reorder sessions in priority queue based on drag destination
    /// Uses midpoint calculation for priorityOrder to maintain order stability
    private func reorderPriorityQueue(from source: IndexSet, to destination: Int) {
        guard let sourceIndex = source.first else { return }

        // Handle edge case: moving to same position (no-op)
        // SwiftUI destination is "insert before" index, so moving down by 1 gives destination = sourceIndex + 2
        if destination == sourceIndex || destination == sourceIndex + 1 {
            return
        }

        let movingSession = priorityQueueSessions[sourceIndex]

        // Calculate neighbors at the destination slot
        // SwiftUI destination means "insert before this index" in the original array
        let above: CDBackendSession? = destination > 0 ? priorityQueueSessions[destination - 1] : nil
        let below: CDBackendSession? = destination < priorityQueueSessions.count ? priorityQueueSessions[destination] : nil

        // Exclude the moving session from neighbors (it may be adjacent to destination)
        let finalAbove = above?.id == movingSession.id ? nil : above
        let finalBelow = below?.id == movingSession.id ? nil : below

        logger.info("🔄 [PriorityQueue] Reordering: source=\(sourceIndex) dest=\(destination) above=\(finalAbove?.id.uuidString.prefix(8) ?? "nil") below=\(finalBelow?.id.uuidString.prefix(8) ?? "nil")")

        CDBackendSession.reorderSession(movingSession, between: finalAbove, and: finalBelow, context: viewContext)

        // Check if renormalization is needed after reorder
        if CDBackendSession.needsRenormalization(context: viewContext) {
            CDBackendSession.renormalizePriorityQueue(context: viewContext)
        }

        // Refresh sessions to reflect new order
        do {
            sessions = try CDBackendSession.fetchActiveSessions(context: viewContext)
        } catch {
            logger.error("❌ Failed to refresh sessions after reorder: \(error)")
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
    @ObservedObject private var windowRegistry = WindowSessionRegistry.shared
    @Environment(\.managedObjectContext) private var viewContext

    /// Whether this session is open in a detached (non-main) window
    private var isInDetachedWindow: Bool {
        windowRegistry.sessionsInDetachedWindows.contains(session.id)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(session.displayName(context: viewContext))
                        .font(.headline)
                        .lineLimit(1)

                    // Detached window indicator
                    if isInDetachedWindow {
                        Image(systemName: "square.on.square")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .help("Open in another window")
                    }
                }

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
        .contextMenu {
            SessionContextMenu(session: session)
        }
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
    @ObservedObject private var windowRegistry = WindowSessionRegistry.shared
    @Environment(\.managedObjectContext) private var viewContext

    /// Whether this session is open in a detached (non-main) window
    private var isInDetachedWindow: Bool {
        windowRegistry.sessionsInDetachedWindows.contains(session.id)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                // Line 1: Session name with optional detached window indicator
                HStack(spacing: 4) {
                    Text(session.displayName(context: viewContext))
                        .font(.headline)
                        .lineLimit(1)

                    // Detached window indicator
                    if isInDetachedWindow {
                        Image(systemName: "square.on.square")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .help("Open in another window")
                    }
                }

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
        .contextMenu {
            SessionContextMenu(session: session)
        }
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

// MARK: - SessionNotFoundView

/// Displayed when a selected session cannot be found (deleted or unavailable)
struct SessionNotFoundView: View {
    let sessionId: UUID
    let onDismiss: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Session Not Found")
                .font(.title2)

            Text("This session may have been deleted or is no longer available.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Text("Session ID: \(sessionId.uuidString.lowercased().prefix(8))...")
                .font(.caption)
                .foregroundColor(.secondary)
                .fontDesign(.monospaced)

            HStack(spacing: 12) {
                Button("Refresh") { onRefresh() }
                Button("Close") { onDismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
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

// MARK: - WindowAccessor

/// NSViewRepresentable to access the hosting NSWindow from SwiftUI
struct WindowAccessor: NSViewRepresentable {
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            onWindowChange(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onWindowChange(nsView.window)
        }
    }
}

// MARK: - SessionContextMenu

/// Reusable context menu for session rows
struct SessionContextMenu: View {
    let session: CDBackendSession

    var body: some View {
        Group {
            Button {
                // Copy session ID
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(session.id.uuidString.lowercased(), forType: .string)
            } label: {
                Label("Copy Session ID", systemImage: "doc.on.doc")
            }

            Button {
                // Show in Finder
                let url = URL(fileURLWithPath: session.workingDirectory)
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }

            Divider()

            Button {
                NotificationCenter.default.post(
                    name: .requestSessionRename,
                    object: nil,
                    userInfo: ["sessionId": session.id]
                )
            } label: {
                Label("Rename...", systemImage: "pencil")
            }

            Divider()

            Button(role: .destructive) {
                NotificationCenter.default.post(
                    name: .requestSessionDeletion,
                    object: nil,
                    userInfo: ["sessionId": session.id]
                )
            } label: {
                Label("Delete Session...", systemImage: "trash")
            }
        }
    }
}

// MARK: - SessionRenameSheet

/// Sheet for renaming a session
struct SessionRenameSheet: View {
    @Binding var sessionName: String
    let onRename: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename Session")
                .font(.headline)

            TextField("Session name", text: $sessionName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit {
                    if !sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        onRename()
                    }
                }

            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape)

                Button("Rename", action: onRename)
                    .buttonStyle(.borderedProminent)
                    .disabled(sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 320)
    }
}

#Preview {
    let settings = AppSettings()
    return MainWindowView(settings: settings, statusBarController: StatusBarController(appSettings: settings))
        .environment(\.managedObjectContext, PersistenceController(inMemory: true).container.viewContext)
}
