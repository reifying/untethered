// SessionsForDirectoryView.swift
// Shows workstreams for a specific working directory

import SwiftUI
import CoreData
import OSLog

private let logger = Logger(subsystem: "com.travisbrown.VoiceCode", category: "SessionsForDirectory")

struct SessionsForDirectoryView: View {
    let workingDirectory: String

    @ObservedObject var client: VoiceCodeClient
    @ObservedObject var settings: AppSettings
    @ObservedObject var voiceOutput: VoiceOutputManager
    @Binding var showingSettings: Bool
    @Binding var navigationPath: NavigationPath
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject var draftManager: DraftManager

    // Fetch workstreams filtered by working directory
    @FetchRequest private var workstreams: FetchedResults<CDWorkstream>

    @State private var showingNewSession = false
    @State private var newSessionName = ""
    @State private var showingCopyConfirmation = false
    @State private var showingDirectoryCopyConfirmation = false
    @State private var showingCommandMenu = false
    @State private var showingCommandHistory = false

    init(workingDirectory: String, client: VoiceCodeClient, settings: AppSettings, voiceOutput: VoiceOutputManager, showingSettings: Binding<Bool>, navigationPath: Binding<NavigationPath>) {
        self.workingDirectory = workingDirectory
        self.client = client
        self.settings = settings
        self.voiceOutput = voiceOutput
        self._showingSettings = showingSettings
        self._navigationPath = navigationPath

        // Initialize FetchRequest with predicate filtering by directory (using CDWorkstream)
        _workstreams = FetchRequest<CDWorkstream>(
            sortDescriptors: [NSSortDescriptor(keyPath: \CDWorkstream.lastModified, ascending: false)],
            predicate: NSPredicate(format: "workingDirectory == %@", workingDirectory),
            animation: .default
        )
    }

    private var directoryName: String {
        (workingDirectory as NSString).lastPathComponent
    }

    var body: some View {
        Group {
            if workstreams.isEmpty {
                // Empty state: no workstreams in this directory
                VStack(spacing: 16) {
                    Image(systemName: "tray")
                        .font(.system(size: 64))
                        .foregroundColor(.secondary)
                    Text("No workstreams in \(directoryName)")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Create a new workstream with the + button to get started.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(workstreams) { workstream in
                        NavigationLink(value: workstream.id) {
                            CDWorkstreamRowContent(workstream: workstream)
                        }
                        .contextMenu {
                            Button(action: {
                                copyWorkstreamID(workstream)
                            }) {
                                Label("Copy Workstream ID", systemImage: "doc.on.clipboard")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                deleteWorkstream(workstream)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .refreshable {
                    logger.info("Pull-to-refresh triggered - requesting workstream list")
                    await client.requestSessionList()
                }
            }
        }
        .navigationTitle(directoryName)
        .navigationBarTitleDisplayMode(.large)
        .overlay(alignment: .top) {
            if showingCopyConfirmation {
                Text("Workstream ID copied to clipboard")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.9))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if showingDirectoryCopyConfirmation {
                Text("Directory path copied to clipboard")
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
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: {
                    copyDirectoryPath()
                }) {
                    Image(systemName: "doc.on.clipboard")
                }
            }
            
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    // Command menu button - execute commands
                    if client.availableCommands != nil {
                        Button(action: {
                            showingCommandMenu = true
                        }) {
                            let totalCount = (client.availableCommands?.projectCommands.count ?? 0) +
                                           (client.availableCommands?.generalCommands.count ?? 0)
                            if totalCount > 0 {
                                ZStack(alignment: .topTrailing) {
                                    Image(systemName: "play.rectangle")
                                    Text("\(totalCount)")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(3)
                                        .background(Color.blue)
                                        .clipShape(Circle())
                                        .offset(x: 8, y: -8)
                                }
                            } else {
                                Image(systemName: "play.rectangle")
                            }
                        }
                    }

                    // Command history button - view past executions
                    Button(action: {
                        showingCommandHistory = true
                    }) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "clock.arrow.circlepath")
                            if !client.runningCommands.isEmpty {
                                Circle()
                                    .fill(Color.green)
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
                        // Pre-fill with this directory's path
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
        .sheet(isPresented: $showingCommandMenu) {
            CommandMenuView(
                client: client,
                workingDirectory: workingDirectory
            )
        }
        .sheet(isPresented: $showingNewSession) {
            NewSessionView(
                name: $newSessionName,
                workingDirectory: .constant(workingDirectory),
                createWorktree: .constant(false),
                onCreate: {
                    createNewSession(name: newSessionName)
                    newSessionName = ""
                    showingNewSession = false
                },
                onCancel: {
                    newSessionName = ""
                    showingNewSession = false
                }
            )
        }
        .sheet(isPresented: $showingCommandHistory) {
            NavigationView {
                ActiveCommandsListView(client: client)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") {
                                showingCommandHistory = false
                            }
                        }
                    }
            }
        }
        .onAppear {
            // Notify backend of working directory so it can parse Makefile
            client.setWorkingDirectory(workingDirectory)
        }
    }

    private func createNewSession(name: String) {
        // Generate new UUID for workstream
        let workstreamId = UUID()

        // Create CDWorkstream in CoreData
        let workstream = CDWorkstream(context: viewContext)
        workstream.id = workstreamId
        workstream.name = name
        workstream.workingDirectory = workingDirectory
        workstream.queuePriority = "normal"
        workstream.priorityOrder = 0
        workstream.createdAt = Date()
        workstream.lastModified = Date()
        workstream.messageCount = 0
        workstream.unreadCount = 0
        workstream.isInPriorityQueue = false
        // activeClaudeSessionId is nil initially (cleared state)

        // Also create CDBackendSession for navigation compatibility
        // (ConversationView still requires CDBackendSession during migration)
        let session = CDBackendSession(context: viewContext)
        session.id = workstreamId
        session.backendName = workstreamId.uuidString.lowercased()
        session.workingDirectory = workingDirectory
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.isLocallyCreated = true

        // Create CDUserSession with custom name
        let userSession = CDUserSession(context: viewContext)
        userSession.id = workstreamId
        userSession.customName = name
        userSession.createdAt = Date()

        // Save to CoreData
        do {
            try viewContext.save()
            logger.info("📝 Created new workstream: \(workstreamId.uuidString.lowercased()) in \(workingDirectory)")

            // Auto-add to priority queue if enabled
            if settings.priorityQueueEnabled {
                addToPriorityQueue(workstream)
                logger.info("📌 Auto-added new workstream to priority queue: \(workstreamId.uuidString.lowercased())")
            }

            // Navigate to the new workstream
            navigationPath.append(workstreamId)
            logger.info("🔄 Navigating to new workstream: \(workstreamId.uuidString.lowercased())")

            // Send create_workstream message to backend
            client.createWorkstream(id: workstreamId, name: name, workingDirectory: workingDirectory)

        } catch {
            logger.error("❌ Failed to create workstream: \(error)")
        }
    }

    private func copyDirectoryPath() {
        // Copy directory path to clipboard
        UIPasteboard.general.string = workingDirectory
        
        // Trigger haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        
        // Show confirmation banner
        withAnimation {
            showingDirectoryCopyConfirmation = true
        }
        
        // Hide confirmation after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                showingDirectoryCopyConfirmation = false
            }
        }
        
        logger.info("📋 Copied directory path to clipboard: \(self.workingDirectory)")
    }
    
    private func copyWorkstreamID(_ workstream: CDWorkstream) {
        // Copy workstream ID to clipboard
        let workstreamID = workstream.id.uuidString.lowercased()
        UIPasteboard.general.string = workstreamID

        // Trigger haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        // Show confirmation banner
        withAnimation {
            showingCopyConfirmation = true
        }

        // Hide confirmation after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                showingCopyConfirmation = false
            }
        }

        logger.info("📋 Copied workstream ID to clipboard: \(workstreamID)")
    }

    private func addToPriorityQueue(_ workstream: CDWorkstream) {
        // Add workstream to priority queue
        workstream.isInPriorityQueue = true
        workstream.priorityQueuedAt = Date()

        // Calculate next priority order (append at end)
        let fetchRequest = CDWorkstream.fetchQueuedWorkstreams()
        if let existingWorkstreams = try? viewContext.fetch(fetchRequest) {
            let maxOrder = existingWorkstreams.map { $0.priorityOrder }.max() ?? 0
            workstream.priorityOrder = maxOrder + 1
        }

        do {
            try viewContext.save()
            logger.info("✅ Added workstream to priority queue: \(workstream.id.uuidString.lowercased())")
        } catch {
            logger.error("❌ Failed to add workstream to priority queue: \(error)")
        }
    }

    private func deleteWorkstream(_ workstream: CDWorkstream) {
        // Clean up draft for this workstream
        let workstreamID = workstream.id.uuidString.lowercased()
        draftManager.cleanupDraft(sessionID: workstreamID)

        // Delete associated CDBackendSession (for navigation compatibility during migration)
        let sessionFetchRequest: NSFetchRequest<CDBackendSession> = CDBackendSession.fetchRequest()
        sessionFetchRequest.predicate = NSPredicate(format: "id == %@", workstream.id as CVarArg)
        if let sessions = try? viewContext.fetch(sessionFetchRequest) {
            for session in sessions {
                viewContext.delete(session)
            }
        }

        // Delete associated CDUserSession (for custom name storage)
        let userSessionFetchRequest: NSFetchRequest<CDUserSession> = CDUserSession.fetchRequest()
        userSessionFetchRequest.predicate = NSPredicate(format: "id == %@", workstream.id as CVarArg)
        if let userSessions = try? viewContext.fetch(userSessionFetchRequest) {
            for userSession in userSessions {
                viewContext.delete(userSession)
            }
        }

        // Delete the workstream from CoreData
        viewContext.delete(workstream)

        // Save context
        do {
            try viewContext.save()
            logger.info("✅ Deleted workstream: \(workstreamID)")

            // Send workstream_deleted message to backend
            let message: [String: Any] = [
                "type": "workstream_deleted",
                "workstream_id": workstreamID
            ]
            client.sendMessage(message)

        } catch {
            logger.error("❌ Failed to delete workstream: \(error)")
        }
    }
}

// MARK: - Preview

struct SessionsForDirectoryView_Previews: PreviewProvider {
    static var previews: some View {
        let settings = AppSettings()
        let client = VoiceCodeClient(serverURL: settings.fullServerURL)
        let voiceOutput = VoiceOutputManager()

        NavigationStack {
            SessionsForDirectoryView(
                workingDirectory: "/Users/travis/code/voice-code",
                client: client,
                settings: settings,
                voiceOutput: voiceOutput,
                showingSettings: .constant(false),
                navigationPath: .constant(NavigationPath())
            )
        }
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
