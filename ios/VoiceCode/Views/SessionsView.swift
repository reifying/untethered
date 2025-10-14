// SessionsView.swift
// Session management and picker view

import SwiftUI

struct SessionsView: View {
    @ObservedObject var sessionManager: SessionManager
    @Environment(\.dismiss) var dismiss

    @State private var showingNewSession = false
    @State private var newSessionName = ""
    @State private var newWorkingDirectory = ""

    var body: some View {
        NavigationView {
            List {
                ForEach(sessionManager.sessions) { session in
                    SessionRow(
                        session: session,
                        isSelected: session.id == sessionManager.currentSession?.id,
                        onSelect: {
                            sessionManager.selectSession(session)
                            dismiss()
                        },
                        onDelete: {
                            sessionManager.deleteSession(session)
                        }
                    )
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
}

// MARK: - Session Row

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
