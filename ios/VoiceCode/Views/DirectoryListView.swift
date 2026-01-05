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
    @State private var sessions: [CDBackendSession] = []

    @State private var showingNewSession = false
    @State private var newSessionName = ""
    @State private var newWorkingDirectory = ""
    @State private var createWorktree = false
    @State private var isRecentExpanded = true
    @State private var isQueueExpanded = true
    @State private var isPriorityQueueExpanded = true
    @State private var showingCopyConfirmation = false
    @State private var copyConfirmationMessage = ""
    @State private var isRefreshing = false

    // Cached computed properties to prevent recomputation on every render
    @State private var cachedDirectories: [DirectoryInfo] = []
    @State private var cachedQueuedSessions: [CDBackendSession] = []
    @State private var cachedPriorityQueueSessions: [CDBackendSession] = []

    // Background state tracking to suspend updates when not visible
    @Environment(\.scenePhase) private var scenePhase
    @State private var isAppActive = true

    // Debounce work item for queue updates
    @State private var queueUpdateWorkItem: DispatchWorkItem?
    @State private var priorityQueueUpdateWorkItem: DispatchWorkItem?

    // Queue sessions filtered by lock state and sorted by position (FIFO)
    private var queuedSessions: [CDBackendSession] {
        cachedQueuedSessions
    }

    // Priority queue sessions filtered by lock state and sorted by three-level sort
    // Sort: priority (ascending) → priorityOrder (ascending) → session ID (deterministic)
    private var priorityQueueSessions: [CDBackendSession] {
        cachedPriorityQueueSessions
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

    private func isSessionLocked(_ session: CDBackendSession) -> Bool {
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
        let _ = RenderTracker.count(Self.self)
        Group {
            if !settings.isServerConfigured {
                // First-run state: server not configured
                VStack(spacing: 16) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 64))
                        .foregroundColor(.secondary)
                    Text("Configure Server")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Connect to your voice-code backend to get started.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button(action: { showingSettings = true }) {
                        Label("Open Settings", systemImage: "gear")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sessions.isEmpty && recentSessions.isEmpty {
                // Empty state: server configured but no sessions yet
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
                                    CDBackendSessionRowContent(session: session)
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

                    // Priority Queue section
                    if settings.priorityQueueEnabled && !priorityQueueSessions.isEmpty {
                        Section(isExpanded: $isPriorityQueueExpanded) {
                            ForEach(priorityQueueSessions) { session in
                                NavigationLink(value: session.id) {
                                    CDBackendSessionRowContent(session: session)
                                }
                                .listRowBackground(priorityTintColor(for: session.priority))
                                // Compound identity: session.id + priority ensures row rebuilds when priority changes
                                // This forces SwiftUI to re-evaluate listRowBackground after drag reorder
                                .id("\(session.id)-P\(session.priority)")
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        removeFromPriorityQueue(session)
                                    } label: {
                                        Label("Remove", systemImage: "xmark.circle")
                                    }
                                }
                            }
                            .onMove { source, destination in
                                reorderPriorityQueue(from: source, to: destination)
                            }
                        } header: {
                            Text("Priority Queue")
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
        .task {
            // Load sessions when view appears
            do {
                sessions = try CDBackendSession.fetchActiveSessions(context: viewContext)
            } catch {
                logger.error("❌ Failed to fetch active sessions: \(error)")
                sessions = []
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
                        isRefreshing = true
                        Task {
                            await client.requestSessionList()
                            await MainActor.run { isRefreshing = false }
                        }
                    }) {
                        if isRefreshing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isRefreshing)

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
            logger.info("🔧 [DirectoryList] onAppear - priorityQueueEnabled=\(settings.priorityQueueEnabled)")
            updateCachedDirectories()
            updateCachedQueuedSessions()
            updateCachedPriorityQueueSessions()
        }
        .onChange(of: sessions.count) { _ in
            updateCachedDirectories()
            updateCachedQueuedSessions()
            updateCachedPriorityQueueSessions()
        }
        .onChange(of: viewModel.lockedSessions) { _ in
            updateCachedQueuedSessions()
            updateCachedPriorityQueueSessions()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            // Track app state to suspend layout updates in background
            isAppActive = (newPhase == .active)

            if newPhase == .active && oldPhase == .background {
                logger.info("📱 App returned to foreground, refreshing caches")
                updateCachedDirectories()
                updateCachedQueuedSessions()
                updateCachedPriorityQueueSessions()
            } else if newPhase == .background {
                logger.info("📱 App entering background, suspending cache updates")
                // Cancel any pending debounced updates
                queueUpdateWorkItem?.cancel()
                priorityQueueUpdateWorkItem?.cancel()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionListDidUpdate)) { _ in
            // Refetch sessions when backend sends updated session list
            // This handles initial connection, server URL changes, and refresh requests
            logger.info("🔄 Session list updated notification received, refetching sessions")
            do {
                sessions = try CDBackendSession.fetchActiveSessions(context: viewContext)
                updateCachedDirectories()
                updateCachedQueuedSessions()
                updateCachedPriorityQueueSessions()
            } catch {
                logger.error("❌ Failed to refetch sessions after update: \(error)")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .priorityQueueChanged)) { notification in
            // Update priority queue cache when changes occur in other views
            logger.info("🔄 Priority queue changed notification received")
            if let sessionId = notification.userInfo?["sessionId"] as? String {
                logger.debug("   Session: \(sessionId)")
            }
            updateCachedPriorityQueueSessions()
        }
    }

    // MARK: - Cache Update Methods

    private func updateCachedDirectories() {
        // Skip updates when app is in background to prevent watchdog kills
        guard isAppActive else {
            logger.debug("⏸️ Skipping directory cache update (app in background)")
            return
        }

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
        // Skip updates when app is in background to prevent watchdog kills
        guard isAppActive else {
            logger.debug("⏸️ Skipping queue cache update (app in background)")
            return
        }

        // Debounce updates to prevent rapid-fire recalculations
        queueUpdateWorkItem?.cancel()

        let workItem = DispatchWorkItem { [viewModel, sessions] in
            // CRITICAL: Take snapshot to avoid triggering SwiftUI dependency tracking
            // Reading viewModel.lockedSessions inside filter() causes infinite layout loop
            // that triggers iOS watchdog termination (0x8BADF00D) when app is in background
            let lockedSessionIds = viewModel.lockedSessions

            let updatedSessions = sessions
                .filter { $0.isInQueue }
                .filter { session in
                    let sessionId = session.id.uuidString.lowercased()
                    return !lockedSessionIds.contains(sessionId)
                }
                .sorted { $0.queuePosition < $1.queuePosition }

            // Update on main thread
            DispatchQueue.main.async {
                self.cachedQueuedSessions = updatedSessions
                logger.debug("🔄 Updated queue cache: \(updatedSessions.count) sessions")
            }
        }

        queueUpdateWorkItem = workItem

        // Debounce by 150ms to batch rapid updates
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private func updateCachedPriorityQueueSessions() {
        // Skip updates when app is in background to prevent watchdog kills
        guard isAppActive else {
            logger.debug("⏸️ Skipping priority queue cache update (app in background)")
            return
        }

        // Cancel any pending updates
        priorityQueueUpdateWorkItem?.cancel()

        let workItem = DispatchWorkItem { [viewModel, sessions] in
            // CRITICAL: Take snapshot to avoid triggering SwiftUI dependency tracking
            let lockedSessionIds = viewModel.lockedSessions

            let updatedSessions = sessions
                .filter { $0.isInPriorityQueue }
                .filter { session in
                    let sessionId = session.id.uuidString.lowercased()
                    return !lockedSessionIds.contains(sessionId)
                }
                .sorted { session1, session2 in
                    // Three-level sort:
                    // 1. Priority (ascending - lower number = higher priority)
                    if session1.priority != session2.priority {
                        return session1.priority < session2.priority
                    }
                    // 2. Priority order (ascending - lower order = added earlier)
                    if session1.priorityOrder != session2.priorityOrder {
                        return session1.priorityOrder < session2.priorityOrder
                    }
                    // 3. Session ID (deterministic tiebreaker)
                    return session1.id.uuidString < session2.id.uuidString
                }

            // Update on main thread
            DispatchQueue.main.async {
                self.cachedPriorityQueueSessions = updatedSessions
                logger.info("🔄 [PriorityQueueCache] Updated: \(updatedSessions.count) sessions (from \(sessions.filter { $0.isInPriorityQueue }.count) in queue)")
            }
        }

        priorityQueueUpdateWorkItem = workItem

        // Debounce by 150ms to batch rapid updates
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    // MARK: - Queue Management

    private func removeFromQueue(_ session: CDBackendSession) {
        guard session.isInQueue else { return }

        let removedPosition = session.queuePosition
        session.isInQueue = false
        session.queuePosition = 0
        session.queuedAt = nil

        // Reorder remaining queue items
        let fetchRequest = CDBackendSession.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "isInQueue == YES AND queuePosition > %d", removedPosition)

        if let sessionsToReorder = try? viewContext.fetch(fetchRequest) {
            for s in sessionsToReorder {
                s.queuePosition -= 1
            }
        }

        do {
            try viewContext.save()
            updateCachedQueuedSessions()
            logger.info("✅ [Queue] Removed session from queue, reordered sessions")
        } catch {
            logger.error("❌ [Queue] Failed to remove session from queue: \(error)")
        }
    }

    // MARK: - Priority Queue Management

    /// Helper: Save CoreData context with error handling
    private func saveContext() {
        do {
            try viewContext.save()
        } catch {
            logger.error("❌ [PriorityQueue] CoreData save failed: \(error.localizedDescription)")
        }
    }

    /// Returns a subtle background tint color based on priority level
    /// Uses varying opacity so colorblind users can distinguish by shade (darker = higher priority)
    private func priorityTintColor(for priority: Int32) -> Color {
        switch priority {
        case 1:  // High - darkest tint
            return Color.blue.opacity(0.18)
        case 5:  // Medium - medium tint
            return Color.blue.opacity(0.10)
        default: // Low (10) - no tint (default background)
            return Color.clear
        }
    }

    /// Add session to priority queue
    private func addToPriorityQueue(_ session: CDBackendSession) {
        CDBackendSession.addToPriorityQueue(session, context: viewContext)
        updateCachedPriorityQueueSessions()
    }

    /// Remove session from priority queue
    private func removeFromPriorityQueue(_ session: CDBackendSession) {
        CDBackendSession.removeFromPriorityQueue(session, context: viewContext)
        updateCachedPriorityQueueSessions()
    }

    /// Change session priority (only for sessions in priority queue)
    private func changePriority(_ session: CDBackendSession, newPriority: Int32) {
        CDBackendSession.changePriority(session, newPriority: newPriority, context: viewContext)
        updateCachedPriorityQueueSessions()
    }

    /// Reorder priority queue based on drag source and destination indices
    ///
    /// SwiftUI's `onMove` provides:
    /// - `source`: IndexSet containing the original index of the dragged item
    /// - `destination`: The "insert before" index in the original (pre-move) array
    ///
    /// Example: Array [A, B, C, D] dragging B (index 1) to after C:
    /// - source = {1}, destination = 3 (insert before index 3, which is D)
    /// - Result: [A, C, B, D]
    ///
    /// Edge case: Moving down by 1 gives destination = sourceIndex + 2, not +1
    /// because destination is where item goes BEFORE the move happens.
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
        updateCachedPriorityQueueSessions()
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

        // Create CDBackendSession in CoreData
        let session = CDBackendSession(context: viewContext)
        session.id = sessionId
        session.backendName = sessionId.uuidString.lowercased()  // Backend ID = iOS UUID for new sessions
        session.workingDirectory = workingDirectory ?? FileManager.default.currentDirectoryPath
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.isLocallyCreated = true

        // Create CDUserSession with custom name
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

        // Save to CoreData
        do {
            try viewContext.save()
            logger.info("📝 Created new session: \(sessionId.uuidString.lowercased())")

            // Auto-add to priority queue if enabled
            if settings.priorityQueueEnabled {
                addToPriorityQueue(session)
                logger.info("📌 Auto-added new session to priority queue: \(sessionId.uuidString.lowercased())")
            }

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
        let _ = RenderTracker.count(Self.self)
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
    @Environment(\.managedObjectContext) private var viewContext

    var body: some View {
        let _ = RenderTracker.count(Self.self)
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                // Line 1: Session name
                Text(session.displayName(context: viewContext))
                    .font(.headline)

                // Line 2: Working directory (last path component only)
                HStack(spacing: 8) {
                    Text(URL(fileURLWithPath: session.workingDirectory).lastPathComponent)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                // Line 3: Relative timestamp
                HStack(spacing: 8) {
                    Text(session.lastModified.relativeFormatted())
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
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
