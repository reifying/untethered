// SessionsForDirectoryView.swift
// Shows sessions for a specific working directory

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

    // Fetch sessions filtered by working directory
    @FetchRequest private var sessions: FetchedResults<CDBackendSession>

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

        // Initialize FetchRequest with predicate filtering by directory
        _sessions = FetchRequest<CDBackendSession>(
            sortDescriptors: [NSSortDescriptor(keyPath: \CDBackendSession.lastModified, ascending: false)],
            predicate: NSPredicate(format: "workingDirectory == %@", workingDirectory),
            animation: .default
        )
    }

    private var directoryName: String {
        (workingDirectory as NSString).lastPathComponent
    }

    var body: some View {
        Group {
            if sessions.isEmpty {
                // Empty state: no sessions in this directory
                VStack(spacing: 16) {
                    Image(systemName: "tray")
                        .font(.system(size: 64))
                        .foregroundColor(.secondary)
                    Text("No sessions in \(directoryName)")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Create a new session with the + button to get started.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(sessions) { session in
                        NavigationLink(value: session.id) {
                            CDBackendSessionRowContent(session: session)
                        }
                        .contextMenu {
                            Button(action: {
                                copySessionID(session)
                            }) {
                                Label("Copy Session ID", systemImage: "doc.on.clipboard")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                deleteSession(session)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .refreshable {
                    logger.info("Pull-to-refresh triggered - requesting session list")
                    await client.requestSessionList()
                }
            }
        }
        .navigationTitle(directoryName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .overlay(alignment: .top) {
            if showingCopyConfirmation {
                Text("Session ID copied to clipboard")
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
            #if os(iOS)
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: {
                    copyDirectoryPath()
                }) {
                    Image(systemName: "doc.on.clipboard")
                }
            }
            #else
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    copyDirectoryPath()
                }) {
                    Image(systemName: "doc.on.clipboard")
                }
            }
            #endif

            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    // Stop speech button (visible when speaking)
                    if voiceOutput.isSpeaking {
                        Button(action: { voiceOutput.stop() }) {
                            Image(systemName: "stop.circle.fill")
                                .foregroundColor(.red)
                        }
                    }

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
            #else
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 16) {
                    // Stop speech button (visible when speaking)
                    if voiceOutput.isSpeaking {
                        Button(action: { voiceOutput.stop() }) {
                            Image(systemName: "stop.circle.fill")
                                .foregroundColor(.red)
                        }
                        .help("Stop speaking (Cmd+.)")
                    }

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
            #endif
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
            NavigationController(minWidth: 600, minHeight: 400) {
                ActiveCommandsListView(client: client)
                    .toolbar {
                        #if os(iOS)
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") {
                                showingCommandHistory = false
                            }
                        }
                        #else
                        ToolbarItem(placement: .automatic) {
                            Button("Done") {
                                showingCommandHistory = false
                            }
                        }
                        #endif
                    }
            }
        }
        .onAppear {
            // Notify backend of working directory so it can parse Makefile
            client.setWorkingDirectory(workingDirectory)
        }
        .swipeToBack()
    }

    private func createNewSession(name: String) {
        // Generate new UUID for session
        let sessionId = UUID()

        // Create CDBackendSession in CoreData
        let session = CDBackendSession(context: viewContext)
        session.id = sessionId
        session.backendName = sessionId.uuidString.lowercased()  // Backend ID = iOS UUID for new sessions
        session.workingDirectory = workingDirectory
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
            logger.info("📝 Created new session: \(sessionId.uuidString.lowercased()) in \(workingDirectory)")

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

    private func copyDirectoryPath() {
        // Copy directory path to clipboard
        ClipboardUtility.copy(workingDirectory)

        // Trigger haptic feedback
        ClipboardUtility.triggerSuccessHaptic()

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

    private func copySessionID(_ session: CDBackendSession) {
        // Copy session ID to clipboard
        ClipboardUtility.copy(session.id.uuidString.lowercased())

        // Trigger haptic feedback
        ClipboardUtility.triggerSuccessHaptic()

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
    }

    private func addToPriorityQueue(_ session: CDBackendSession) {
        CDBackendSession.addToPriorityQueue(session, context: viewContext)
    }

    private func deleteSession(_ session: CDBackendSession) {
        // Create or update CDUserSession to mark as deleted
        let fetchRequest: NSFetchRequest<CDUserSession> = CDUserSession.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", session.id as CVarArg)

        let userSession: CDUserSession
        if let existing = try? viewContext.fetch(fetchRequest).first {
            userSession = existing
        } else {
            userSession = CDUserSession(context: viewContext)
            userSession.id = session.id
        }

        userSession.isUserDeleted = true

        // Clean up draft for this session
        let sessionID = session.id.uuidString.lowercased()
        draftManager.cleanupDraft(sessionID: sessionID)

        // Save context
        do {
            try viewContext.save()

            // Unsubscribe from session
            client.unsubscribe(sessionId: session.id.uuidString.lowercased())

            // Send session_deleted message to backend
            let message: [String: Any] = [
                "type": "session_deleted",
                "session_id": session.id.uuidString.lowercased()
            ]
            client.sendMessage(message)

        } catch {
            logger.error("Failed to delete session: \(error)")
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
