// SessionsView.swift
// Reusable session components

import SwiftUI
import CoreData

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
