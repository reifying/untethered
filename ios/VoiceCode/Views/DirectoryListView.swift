// DirectoryListView.swift
// Top-level directory navigation view

import SwiftUI
import CoreData
import OSLog

private let logger = Logger(subsystem: "com.travisbrown.VoiceCode", category: "DirectoryList")

struct DirectoryListView: View {
    @ObservedObject var client: VoiceCodeClient
    @ObservedObject var settings: AppSettings
    @ObservedObject var voiceOutput: VoiceOutputManager
    @Binding var showingSettings: Bool
    @Binding var recentSessions: [RecentSession]
    @Binding var navigationPath: NavigationPath
    @ObservedObject var resourcesManager: ResourcesManager
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject var draftManager: DraftManager

    // ViewModel isolates observation to only lockedSessions (not all 9 @Published properties)
    @StateObject private var viewModel: DirectoryListViewModel

    // Fetch active (non-deleted) sessions from CoreData
    @FetchRequest(
        fetchRequest: CDSession.fetchActiveSessions(),
        animation: .default)
    private var sessions: FetchedResults<CDSession>

    @State private var showingNewSession = false
    @State private var newSessionName = ""
    @State private var newWorkingDirectory = ""
    @State private var createWorktree = false
    @State private var isRecentExpanded = true
    @State private var isQueueExpanded = true
    @State private var showingCopyConfirmation = false
    @State private var copyConfirmationMessage = ""

    // Cached computed properties to prevent recomputation on every render
    @State private var cachedDirectories: [DirectoryInfo] = []
    @State private var cachedQueuedSessions: [CDSession] = []

    // Queue sessions filtered by lock state and sorted by position (FIFO)
    private var queuedSessions: [CDSession] {
        cachedQueuedSessions
    }

    init(
        client: VoiceCodeClient,
        settings: AppSettings,
        voiceOutput: VoiceOutputManager,
        showingSettings: Binding<Bool>,
        recentSessions: Binding<[RecentSession]>,
        navigationPath: Binding<NavigationPath>,
        resourcesManager: ResourcesManager
    ) {
        self.client = client
        self.settings = settings
        self.voiceOutput = voiceOutput
        self._showingSettings = showingSettings
        self._recentSessions = recentSessions
        self._navigationPath = navigationPath
        self.resourcesManager = resourcesManager

        // Initialize ViewModel to isolate observation scope
        self._viewModel = StateObject(wrappedValue: DirectoryListViewModel(client: client))
    }

    private func isSessionLocked(_ session: CDSession) -> Bool {
        let claudeSessionId = session.id.uuidString.lowercased()
        return viewModel.isSessionLocked(claudeSessionId)
    }

    // Directory metadata computed from sessions
    struct DirectoryInfo: Identifiable {
        let workingDirectory: String
        let directoryName: String
        let sessionCount: Int
        let totalUnread: Int
        let lastModified: Date

        var id: String { workingDirectory }
    }

    // Compute directory list from sessions
    private var directories: [DirectoryInfo] {
        cachedDirectories
    }

    // Default working directory for new sessions (most recently used)
    private var defaultWorkingDirectory: String {
        directories.first?.workingDirectory ?? FileManager.default.currentDirectoryPath
    }

    var body: some View {
        Group {
            if sessions.isEmpty {
                // Empty state: no sessions at all
                VStack(spacing: 16) {
                    Image(systemName: "folder")
                        .font(.system(size: 64))
                        .foregroundColor(.secondary)
                    Text("No sessions yet")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Sessions will appear here automatically when you use Claude Code in the terminal or create a new session.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    // Recent section
                    if !recentSessions.isEmpty {
                        Section(isExpanded: $isRecentExpanded) {
                            ForEach(recentSessions) { session in
                                NavigationLink(value: UUID(uuidString: session.sessionId) ?? UUID()) {
                                    RecentSessionRowContent(session: session)
                                }
                                .contextMenu {
                                    Button(action: {
                                        copyToClipboard(session.sessionId, message: "Session ID copied to clipboard")
                                    }) {
                                        Label("Copy Session ID", systemImage: "doc.on.clipboard")
                                    }
                                    
                                    Button(action: {
                                        copyToClipboard(session.workingDirectory, message: "Directory path copied to clipboard")
                                    }) {
                                        Label("Copy Directory Path", systemImage: "folder")
                                    }
                                }
                            }
                        } header: {
                            Text("Recent")
                        }
                    }

                    // Queue section
                    if settings.queueEnabled && !queuedSessions.isEmpty {
                        Section(isExpanded: $isQueueExpanded) {
                            ForEach(queuedSessions) { session in
                                NavigationLink(value: session.id) {
                                    CDSessionRowContent(session: session)
                                }
                                .id(session.id) // Stable view identity prevents motion vector recalculation
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        removeFromQueue(session)
                                    } label: {
                                        Label("Remove", systemImage: "xmark.circle")
                                    }
                                }
                            }
                        } header: {
                            Text("Queue")
                        }
                    }

                    // Projects (Directories) section
                    Section {
                        ForEach(directories) { directory in
                            NavigationLink(value: directory.workingDirectory) {
                                DirectoryRowContent(directory: directory)
                            }
                            .id(directory.workingDirectory) // Stable view identity prevents motion vector recalculation
                            .contextMenu {
                                Button(action: {
                                    copyToClipboard(directory.workingDirectory, message: "Directory path copied to clipboard")
                                }) {
                                    Label("Copy Directory Path", systemImage: "folder")
                                }
                            }
                        }
                    } header: {
                        Text("Projects")
                    }

                    // Debug section
                    Section {
                        NavigationLink(destination: DebugLogsView()) {
                            HStack {
                                Image(systemName: "ladybug")
                                    .foregroundColor(.orange)
                                Text("Debug Logs")
                                    .font(.body)
                            }
                        }
                    } header: {
                        Text("Debug")
                    } footer: {
                        Text("View and copy app logs for troubleshooting")
                            .font(.caption2)
                    }
                }
                .refreshable {
                    logger.info("Pull-to-refresh triggered - requesting session list")
                    await client.requestSessionList()
                }
            }
        }
        .overlay(alignment: .top) {
            if showingCopyConfirmation {
                Text(copyConfirmationMessage)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.9))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    // Resources button with badge
                    Button(action: {
                        navigationPath.append(ResourcesNavigationTarget.list)
                    }) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "doc.on.doc")

                            if resourcesManager.pendingUploadCount > 0 {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 8, height: 8)
                                    .offset(x: 4, y: -4)
                            }
                        }
                    }

                    Button(action: {
                        logger.info("🔄 Refresh button tapped - requesting session list from backend")
                        Task {
                            await client.requestSessionList()
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }

                    Button(action: {
                        // Pre-populate with most recently used directory
                        newWorkingDirectory = defaultWorkingDirectory
                        showingNewSession = true
                    }) {
                        Image(systemName: "plus")
                    }

                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gear")
                    }
                }
            }
        }
        .sheet(isPresented: $showingNewSession) {
            NewSessionView(
                name: $newSessionName,
                workingDirectory: $newWorkingDirectory,
                createWorktree: $createWorktree,
                onCreate: {
                    if createWorktree {
                        createWorktreeSession(
                            name: newSessionName,
                            parentDirectory: newWorkingDirectory
                        )
                    } else {
                        createNewSession(
                            name: newSessionName,
                            workingDirectory: newWorkingDirectory.isEmpty ? nil : newWorkingDirectory
                        )
                    }
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
        .onAppear {
            updateCachedDirectories()
            updateCachedQueuedSessions()
        }
        .onChange(of: sessions.count) { _ in
            updateCachedDirectories()
            updateCachedQueuedSessions()
        }
        .onChange(of: viewModel.lockedSessions) { _ in
            updateCachedQueuedSessions()
        }
    }

    // MARK: - Cache Update Methods

    private func updateCachedDirectories() {
        let grouped = Dictionary(grouping: sessions, by: { $0.workingDirectory })

        cachedDirectories = grouped.map { workingDirectory, sessions in
            let directoryName = (workingDirectory as NSString).lastPathComponent
            let sessionCount = sessions.count
            let totalUnread = sessions.reduce(0) { $0 + Int($1.unreadCount) }
            let lastModified = sessions.map { $0.lastModified }.max() ?? Date.distantPast

            return DirectoryInfo(
                workingDirectory: workingDirectory,
                directoryName: directoryName,
                sessionCount: sessionCount,
                totalUnread: totalUnread,
                lastModified: lastModified
            )
        }
        .sorted { $0.lastModified > $1.lastModified } // Most recent first
    }

    private func updateCachedQueuedSessions() {
        cachedQueuedSessions = sessions
            .filter { $0.isInQueue && !$0.markedDeleted }
            .filter { !isSessionLocked($0) }
            .sorted { $0.queuePosition < $1.queuePosition }
    }

    // MARK: - Queue Management

    private func removeFromQueue(_ session: CDSession) {
        guard session.isInQueue else { return }

        let removedPosition = session.queuePosition
        session.isInQueue = false
        session.queuePosition = 0
        session.queuedAt = nil

        // Reorder remaining queue items
        let fetchRequest = CDSession.fetchActiveSessions()
        fetchRequest.predicate = NSPredicate(format: "isInQueue == YES AND queuePosition > %d", removedPosition)

        if let sessionsToReorder = try? viewContext.fetch(fetchRequest) {
            for s in sessionsToReorder {
                s.queuePosition -= 1
            }
        }

        do {
            try viewContext.save()
            logger.info("✅ [Queue] Removed session from queue, reordered sessions")
        } catch {
            logger.error("❌ [Queue] Failed to remove session from queue: \(error)")
        }
    }

    private func copyToClipboard(_ text: String, message: String) {
        // Copy to clipboard
        UIPasteboard.general.string = text
        
        // Trigger haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        
        // Show confirmation banner
        copyConfirmationMessage = message
        withAnimation {
            showingCopyConfirmation = true
        }
        
        // Hide confirmation after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                showingCopyConfirmation = false
            }
        }
        
        logger.info("📋 Copied to clipboard: \(text)")
    }
    
    private func createNewSession(name: String, workingDirectory: String?) {
        // Generate new UUID for session
        let sessionId = UUID()

        // Create CDSession in CoreData
        let session = CDSession(context: viewContext)
        session.id = sessionId
        session.backendName = sessionId.uuidString.lowercased()  // Backend ID = iOS UUID for new sessions
        session.localName = name  // User-friendly display name
        session.workingDirectory = workingDirectory ?? FileManager.default.currentDirectoryPath
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.markedDeleted = false
        session.isLocallyCreated = true

        // Save to CoreData
        do {
            try viewContext.save()
            logger.info("📝 Created new session: \(sessionId.uuidString.lowercased())")

            // Navigate to the new session
            navigationPath.append(sessionId)
            logger.info("🔄 Navigating to new session: \(sessionId.uuidString.lowercased())")

            // Note: ConversationView will handle subscription when it appears (lazy loading)

        } catch {
            logger.error("❌ Failed to create session: \(error)")
        }
    }

    private func createWorktreeSession(name: String, parentDirectory: String) {
        // Validate inputs
        guard !name.isEmpty, !parentDirectory.isEmpty else {
            logger.error("❌ Invalid worktree session parameters: name or parent directory empty")
            return
        }

        logger.info("📝 Creating worktree session: \(name) in \(parentDirectory)")

        // Send WebSocket message to backend
        let message: [String: Any] = [
            "type": "create_worktree_session",
            "session_name": name,
            "parent_directory": parentDirectory
        ]
        client.sendMessage(message)

        // Note: Do NOT create CoreData session here
        // Session will arrive via session_created message when backend completes
    }
}

// MARK: - Directory Row Content

struct DirectoryRowContent: View {
    let directory: DirectoryListView.DirectoryInfo

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                // Line 1: Folder icon + directory name + unread badge
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.blue)
                        .imageScale(.medium)

                    Text(directory.directoryName)
                        .font(.headline)

                    Spacer()

                    if directory.totalUnread > 0 {
                        Text("\(directory.totalUnread)")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.red)
                            .clipShape(Capsule())
                    }
                }

                // Line 2: Full working directory path
                Text(directory.workingDirectory)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                // Line 3: Session count + timestamp
                HStack(spacing: 8) {
                    Text("\(directory.sessionCount) session\(directory.sessionCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text("•")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text(directory.lastModified.relativeFormatted())
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Recent Session Row Content

struct RecentSessionRowContent: View {
    let session: RecentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Line 1: Session name (pre-fetched from batch query, no N+1 CoreData lookup)
            Text(session.displayName)
                .font(.headline)
            
            // Line 2: Session ID (first 8 chars) + working directory
            HStack(spacing: 8) {
                Text("[\(session.sessionId.prefix(8))]")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fontDesign(.monospaced)
                Text("•")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(session.workingDirectory)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            // Line 3: Last modified timestamp
            Text(session.lastModified.relativeFormatted())
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Relative Time Formatting

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

// MARK: - Preview

struct DirectoryListView_Previews: PreviewProvider {
    static var previews: some View {
        let settings = AppSettings()
        let client = VoiceCodeClient(serverURL: settings.fullServerURL)
        let voiceOutput = VoiceOutputManager()

        NavigationStack {
            DirectoryListView(
                client: client,
                settings: settings,
                voiceOutput: voiceOutput,
                showingSettings: .constant(false),
                recentSessions: .constant([]),
                navigationPath: .constant(NavigationPath()),
                resourcesManager: ResourcesManager(voiceCodeClient: client)
            )
        }
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
