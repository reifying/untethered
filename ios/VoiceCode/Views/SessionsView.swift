// SessionsView.swift
// Session management and picker view

import SwiftUI
import CoreData

struct SessionsView: View {
    @ObservedObject var sessionManager: SessionManager
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
                            CDSessionRow(
                                session: session,
                                isSelected: sessionManager.currentSessionId == session.id,
                                onSelect: {
                                    sessionManager.selectSession(id: session.id)
                                    dismiss()
                                },
                                onDelete: {
                                    deleteSession(session)
                                }
                            )
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
                        sessionManager.createSession(
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
    
    private func deleteSession(_ session: CDSession) {
        // Mark as deleted locally
        session.markedDeleted = true
        
        // Save context
        do {
            try viewContext.save()
            
            // TODO: Send session_deleted message to backend
            // TODO: Send unsubscribe message to backend
            
        } catch {
            print("Failed to delete session: \(error)")
        }
    }
}

// MARK: - CoreData Session Row

struct CDSessionRow: View {
    @ObservedObject var session: CDSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onSelect) {
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
        SessionsView(sessionManager: SessionManager())
    }
}
