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
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject var draftManager: DraftManager

    // Fetch sessions filtered by working directory
    @FetchRequest private var sessions: FetchedResults<CDSession>

    @State private var showingNewSession = false
    @State private var newSessionName = ""

    init(workingDirectory: String, client: VoiceCodeClient, settings: AppSettings, voiceOutput: VoiceOutputManager, showingSettings: Binding<Bool>) {
        self.workingDirectory = workingDirectory
        self.client = client
        self.settings = settings
        self.voiceOutput = voiceOutput
        self._showingSettings = showingSettings

        // Initialize FetchRequest with predicate filtering by directory
        _sessions = FetchRequest<CDSession>(
            sortDescriptors: [NSSortDescriptor(keyPath: \CDSession.lastModified, ascending: false)],
            predicate: NSPredicate(format: "workingDirectory == %@ AND markedDeleted == NO", workingDirectory),
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
                .refreshable {
                    logger.info("Pull-to-refresh triggered - requesting session list")
                    client.requestSessionList()
                }
            }
        }
        .navigationTitle(directoryName)
        .navigationBarTitleDisplayMode(.large)
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
        .sheet(isPresented: $showingNewSession) {
            NewSessionView(
                name: $newSessionName,
                workingDirectory: .constant(workingDirectory),
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
    }

    private func createNewSession(name: String) {
        // Generate new UUID for session
        let sessionId = UUID()

        // Create CDSession in CoreData
        let session = CDSession(context: viewContext)
        session.id = sessionId
        session.backendName = name
        session.localName = name
        session.workingDirectory = workingDirectory
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.markedDeleted = false
        session.isLocallyCreated = true

        // Save to CoreData
        do {
            try viewContext.save()
            logger.info("📝 Created new session: \(sessionId.uuidString) in \(workingDirectory)")

            // Note: ConversationView will handle subscription when it appears (lazy loading)

        } catch {
            logger.error("❌ Failed to create session: \(error)")
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
                showingSettings: .constant(false)
            )
        }
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
