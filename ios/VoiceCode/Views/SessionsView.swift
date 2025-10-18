// SessionsView.swift
// Session management and picker view

import SwiftUI
import CoreData

struct SessionsView: View {
    @ObservedObject var sessionManager: SessionManager
    @ObservedObject var client: VoiceCodeClient
    @Environment(\.dismiss) var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    // Fetch active (non-deleted) sessions from CoreData
    @FetchRequest(
        fetchRequest: CDSession.fetchActiveSessions(),
        animation: .default)
    private var sessions: FetchedResults<CDSession>

    @State private var showingNewSession = false
    @State private var newSessionName = ""
    @State private var newWorkingDirectory = ""
    @State private var selectedSession: CDSession?

    var body: some View {
        NavigationView {
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
                        ForEach(sessions) { session in
                            NavigationLink(
                                destination: ConversationView(session: session, client: client),
                                tag: session,
                                selection: $selectedSession
                            ) {
                                CDSessionRowContent(
                                    session: session,
                                    isSelected: sessionManager.currentSessionId == session.id
                                )
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteSession(session)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .onTapGesture {
                                sessionManager.selectSession(id: session.id)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingNewSession = true }) {
                        Image(systemName: "plus")
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

        // Save to CoreData
        do {
            try viewContext.save()
            print("📝 [SessionsView] Created new session: \(sessionId.uuidString)")

            // Subscribe to the session to receive updates
            client.subscribe(sessionId: sessionId.uuidString)

            // Navigate to the new session
            selectedSession = session
            sessionManager.selectSession(id: sessionId)

        } catch {
            print("❌ [SessionsView] Failed to create session: \(error)")
        }
    }

    private func deleteSession(_ session: CDSession) {
        // Mark as deleted locally
        session.markedDeleted = true

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
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayName)
                    .font(.headline)
                    .foregroundColor(isSelected ? .blue : .primary)

                Text(session.workingDirectory)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

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

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.blue)
            }
        }
    }
}

// MARK: - Legacy Session Row (for SessionManager compatibility)

struct SessionRow: View {
    let session: Session
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.name)
                        .font(.headline)
                        .foregroundColor(isSelected ? .blue : .primary)

                    if let workingDir = session.workingDirectory {
                        Text(workingDir)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Text("\(session.messages.count) messages")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
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

struct SessionsView_Previews: PreviewProvider {
    static var previews: some View {
        let settings = AppSettings()
        let client = VoiceCodeClient(serverURL: settings.fullServerURL)
        
        SessionsView(sessionManager: SessionManager(), client: client)
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
