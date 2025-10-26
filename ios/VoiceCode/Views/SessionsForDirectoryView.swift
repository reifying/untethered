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
    @State private var showingCopyConfirmation = false
    @State private var showingDirectoryCopyConfirmation = false

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
                    client.requestSessionList()
                }
            }
        }
        .navigationTitle(directoryName)
        .navigationBarTitleDisplayMode(.large)
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
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: {
                    copyDirectoryPath()
                }) {
                    Image(systemName: "doc.on.clipboard")
                }
            }
            
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
    }

    private func createNewSession(name: String) {
        // Generate new UUID for session
        let sessionId = UUID()

        // Create CDSession in CoreData
        let session = CDSession(context: viewContext)
        session.id = sessionId
        session.backendName = sessionId.uuidString.lowercased()  // Backend ID = iOS UUID for new sessions
        session.localName = name  // User-friendly display name
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
            logger.info("📝 Created new session: \(sessionId.uuidString.lowercased()) in \(workingDirectory)")

            // Note: ConversationView will handle subscription when it appears (lazy loading)

        } catch {
            logger.error("❌ Failed to create session: \(error)")
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
    
    private func copySessionID(_ session: CDSession) {
        // Copy session ID to clipboard
        UIPasteboard.general.string = session.id.uuidString.lowercased()
        
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
    }

    private func deleteSession(_ session: CDSession) {
        // Mark as deleted locally
        session.markedDeleted = true

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
                showingSettings: .constant(false)
            )
        }
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
