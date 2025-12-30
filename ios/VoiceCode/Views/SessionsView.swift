// SessionsView.swift
// Reusable session components

import SwiftUI
import CoreData

// MARK: - CoreData Session Row Content (Legacy - for CDBackendSession)

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

// MARK: - CoreData Workstream Row Content

struct CDWorkstreamRowContent: View {
    @ObservedObject var workstream: CDWorkstream

    var body: some View {
        let _ = RenderTracker.count(Self.self)
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                // Line 1: Workstream name
                Text(workstream.name)
                    .font(.headline)

                // Line 2: Working directory (last component)
                HStack(spacing: 8) {
                    Text(URL(fileURLWithPath: workstream.workingDirectory).lastPathComponent)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                // Line 3: Message count and preview (or cleared state)
                HStack(spacing: 8) {
                    if workstream.isCleared {
                        // Cleared workstream: no active Claude session
                        Text("Ready to start")
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .italic()
                    } else {
                        Text("\(workstream.messageCount) messages")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        if let preview = workstream.preview, !preview.isEmpty {
                            Text("•")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(preview)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            Spacer()

            // Visual indicator for cleared state
            if workstream.isCleared {
                Image(systemName: "circle.dashed")
                    .foregroundColor(.orange)
                    .imageScale(.small)
            }

            // Show unread badge if there are unread messages
            if workstream.unreadCount > 0 {
                Text("\(workstream.unreadCount)")
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
                        .autocapitalization(.none)
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", action: onCancel)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create") {
                        onCreate()
                    }
                    .disabled(name.isEmpty || (createWorktree && workingDirectory.isEmpty))
                }
            }
        }
    }
}

// Alias for backwards compatibility with existing code
typealias CDBackendSessionRowContent = CDSessionRowContent
