// SessionsView.swift
// Reusable session components

import SwiftUI
import CoreData

// MARK: - CoreData Session Row Content

struct CDSessionRowContent: View {
    @ObservedObject var session: CDBackendSession
    @Environment(\.managedObjectContext) private var viewContext

    var body: some View {
        let _ = RenderTracker.count(Self.self)
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayName(context: viewContext))
                    .font(.headline)

                HStack(spacing: 8) {
                    Text(URL(fileURLWithPath: session.workingDirectory).lastPathComponent)
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
    @Binding var createWorktree: Bool
    let onCreate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Session Details")) {
                    TextField("Session Name", text: $name)

                    TextField(createWorktree ? "Parent Repository Path" : "Working Directory (Optional)", text: $workingDirectory)
                        #if os(iOS)
                        .autocapitalization(.none)
                        #endif
                        .disableAutocorrection(true)
                }

                Section(header: Text("Examples")) {
                    VStack(alignment: .leading, spacing: 4) {
                        if createWorktree {
                            Text("/Users/yourname/projects/myapp")
                            Text("~/code/voice-code")
                            Text("~/projects/my-repo")
                        } else {
                            Text("/Users/yourname/projects/myapp")
                            Text("/tmp/scratch")
                            Text("~/code/voice-code")
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                Section(header: Text("Git Worktree"), footer: Text("Creates a new git worktree with an isolated branch for this session. Requires the parent directory to be a git repository.")) {
                    Toggle("Create Git Worktree", isOn: $createWorktree)
                }
            }
            .navigationTitle("New Session")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", action: onCancel)
                }
                #else
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                #endif

                #if os(iOS)
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create") {
                        onCreate()
                    }
                    .disabled(name.isEmpty || (createWorktree && workingDirectory.isEmpty))
                }
                #else
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate()
                    }
                    .disabled(name.isEmpty || (createWorktree && workingDirectory.isEmpty))
                }
                #endif
            }
        }
    }
}

// Alias for backwards compatibility with existing code
typealias CDBackendSessionRowContent = CDSessionRowContent
