// SessionsView.swift
// Session management and picker view

import SwiftUI
import CoreData
import OSLog

struct SessionsListView: View {
    @ObservedObject var client: VoiceCodeClient
    @ObservedObject var settings: AppSettings
    @ObservedObject var voiceOutput: VoiceOutputManager
    @Binding var showingSettings: Bool
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject var draftManager: DraftManager

    // Fetch active (non-deleted) sessions from CoreData
    @FetchRequest(
        fetchRequest: CDSession.fetchActiveSessions(),
        animation: .default)
    private var sessions: FetchedResults<CDSession>

    @State private var showingNewSession = false
    @State private var newSessionName = ""
    @State private var newWorkingDirectory = ""
    @State private var lastLoggedSessionCount = 0

    private let logger = Logger(subsystem: "com.travisbrown.VoiceCode", category: "SessionsView")

    // Group sessions by working directory
    private var groupedSessions: [String: [CDSession]] {
        let grouped = Dictionary(grouping: sessions, by: { $0.workingDirectory })

        // Log sessions displayed in view (only when count changes to avoid spam)
        if sessions.count != lastLoggedSessionCount {
            DispatchQueue.main.async {
                lastLoggedSessionCount = sessions.count
            }
            logger.info("📺 Sessions displayed in view: \(sessions.count) total")
            logger.info("📂 Grouped by working directory:")
            for (dir, dirSessions) in grouped.sorted(by: { $0.key < $1.key }) {
                logger.info("  \(dir): \(dirSessions.count) sessions")
                for session in dirSessions.sorted(by: { $0.lastModified > $1.lastModified }) {
                    logger.info("    - \(session.id.uuidString) | \(session.messageCount) msgs | \(session.displayName)")
                }
            }
        }

        return grouped
    }

    // Get sorted working directories (most recently modified first)
    private var sortedWorkingDirectories: [String] {
        groupedSessions.keys.sorted { dir1, dir2 in
            let sessions1 = groupedSessions[dir1] ?? []
            let sessions2 = groupedSessions[dir2] ?? []
            let maxDate1 = sessions1.map { $0.lastModified }.max() ?? Date.distantPast
            let maxDate2 = sessions2.map { $0.lastModified }.max() ?? Date.distantPast
            return maxDate1 > maxDate2
        }
    }

    // Default working directory for new sessions (most recently used)
    private var defaultWorkingDirectory: String {
        sortedWorkingDirectories.first ?? FileManager.default.currentDirectoryPath
    }

    var body: some View {
            Group {
                if sessions.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "tray")
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
                        ForEach(sortedWorkingDirectories, id: \.self) { workingDirectory in
                            Section(header: HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(workingDirectory)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text("\(groupedSessions[workingDirectory]?.count ?? 0) session\(groupedSessions[workingDirectory]?.count == 1 ? "" : "s")")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button(action: {
                                    // Pre-populate with this directory's working directory
                                    newWorkingDirectory = workingDirectory
                                    showingNewSession = true
                                }) {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundColor(.blue)
                                        .imageScale(.medium)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                            }
                            .textCase(nil)) {
                                ForEach(groupedSessions[workingDirectory]?.sorted(by: { $0.lastModified > $1.lastModified }) ?? []) { session in
                                    NavigationLink(value: session.id) {
                                        CDSessionRowContent(session: session)
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
                        }
                    }
                }
            }
            .navigationDestination(for: UUID.self) { sessionId in
                // Look up session by UUID from @FetchRequest results
                if let session = sessions.first(where: { $0.id == sessionId }) {
                    ConversationView(session: session, client: client, voiceOutput: voiceOutput, settings: settings)
                } else {
                    // Session not found (possibly deleted) - show message and allow back navigation
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 48))
                            .foregroundColor(.orange)
                        Text("Session Not Found")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("This session may have been deleted.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Text(sessionId.uuidString)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 8)
                    }
                    .padding()
                }
            }
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button(action: {
                            logger.info("🔄 Refresh button tapped - requesting session list from backend")
                            client.requestSessionList()
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
                    onCreate: {
                        createNewSession(
                            name: newSessionName,
                            workingDirectory: newWorkingDirectory.isEmpty ? nil : newWorkingDirectory
                        )
                        newSessionName = ""
                        newWorkingDirectory = ""
                        showingNewSession = false
                    },
                    onCancel: {
                        newSessionName = ""
                        newWorkingDirectory = ""
                        showingNewSession = false
                    }
                )
            }
    }
    
    private func createNewSession(name: String, workingDirectory: String?) {
        // Generate new UUID for session
        let sessionId = UUID()

        // Create CDSession in CoreData
        let session = CDSession(context: viewContext)
        session.id = sessionId
        session.backendName = name
        session.localName = name
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
            print("📝 [SessionsView] Created new session: \(sessionId.uuidString)")

            // Note: ConversationView will handle subscription when it appears (lazy loading)
            // This prevents duplicate subscriptions

        } catch {
            print("❌ [SessionsView] Failed to create session: \(error)")
        }
    }

    private func deleteSession(_ session: CDSession) {
        // Mark as deleted locally
        session.markedDeleted = true

        // Clean up draft for this session
        let sessionID = session.id.uuidString
        draftManager.cleanupDraft(sessionID: sessionID)

        // Save context
        do {
            try viewContext.save()

            // Unsubscribe from session
            client.unsubscribe(sessionId: session.id.uuidString)

            // Send session_deleted message to backend
            let message: [String: Any] = [
                "type": "session_deleted",
                "session_id": session.id.uuidString
            ]
            client.sendMessage(message)

        } catch {
            print("Failed to delete session: \(error)")
        }
    }
}

// MARK: - CoreData Session Row Content

struct CDSessionRowContent: View {
    @ObservedObject var session: CDSession

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayName)
                    .font(.headline)

                HStack(spacing: 8) {
                    Text("[\(session.id.uuidString.prefix(8))]")
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

                HStack(spacing: 8) {
                    Text("\(session.messageCount) messages")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if !session.preview.isEmpty {
                        Text("•")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(session.preview)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            // Show unread badge if there are unread messages
            if session.unreadCount > 0 {
                Text("\(session.unreadCount)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.red)
                    .clipShape(Capsule())
            }
        }
    }
}

// MARK: - New Session View

struct NewSessionView: View {
    @Binding var name: String
    @Binding var workingDirectory: String
    let onCreate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Session Details")) {
                    TextField("Session Name", text: $name)

                    TextField("Working Directory (Optional)", text: $workingDirectory)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }

                Section(header: Text("Examples")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("/Users/yourname/projects/myapp")
                        Text("/tmp/scratch")
                        Text("~/code/voice-code")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", action: onCancel)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create") {
                        onCreate()
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
    }
}

// MARK: - Preview

struct SessionsListView_Previews: PreviewProvider {
    static var previews: some View {
        let settings = AppSettings()
        let client = VoiceCodeClient(serverURL: settings.fullServerURL)
        let voiceOutput = VoiceOutputManager()
        
        NavigationView {
            SessionsListView(
                client: client,
                settings: settings,
                voiceOutput: voiceOutput,
                showingSettings: .constant(false)
            )
        }
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
