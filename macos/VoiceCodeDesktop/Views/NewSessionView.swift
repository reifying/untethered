// NewSessionView.swift
// Dialog for creating a new session

import SwiftUI
import CoreData
import OSLog
import VoiceCodeShared

private let logger = Logger(subsystem: "dev.910labs.voice-code-desktop", category: "NewSessionView")

/// Dialog for creating a new session with name and working directory
struct NewSessionView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    let onSessionCreated: (CDBackendSession) -> Void

    @State private var sessionName: String = ""
    @State private var workingDirectory: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            Text("New Session")
                .font(.title2)
                .fontWeight(.semibold)

            // Session name field
            VStack(alignment: .leading, spacing: 4) {
                Text("Session Name")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                TextField("Optional name for this session", text: $sessionName)
                    .textFieldStyle(.roundedBorder)
            }

            // Working directory field
            VStack(alignment: .leading, spacing: 4) {
                Text("Working Directory")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack {
                    TextField("Select or enter a directory path", text: $workingDirectory)
                        .textFieldStyle(.roundedBorder)

                    Button(action: selectDirectory) {
                        Image(systemName: "folder")
                    }
                    .help("Browse for directory")
                }

                if !workingDirectory.isEmpty && !isValidDirectory(workingDirectory) {
                    Text("Directory does not exist")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            // Error message
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Spacer()
                .frame(height: 8)

            // Buttons
            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Button("Create") {
                    createSession()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 400, height: 250)
    }

    // MARK: - Computed Properties

    private var canCreate: Bool {
        !workingDirectory.isEmpty && isValidDirectory(workingDirectory)
    }

    // MARK: - Actions

    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Select a working directory for the new session"
        panel.prompt = "Select"

        if !workingDirectory.isEmpty && isValidDirectory(workingDirectory) {
            panel.directoryURL = URL(fileURLWithPath: workingDirectory)
        }

        if panel.runModal() == .OK, let url = panel.url {
            workingDirectory = url.path
        }
    }

    private func createSession() {
        guard canCreate else { return }

        // Create new backend session
        let session = CDBackendSession(context: viewContext)
        session.id = UUID()
        session.workingDirectory = workingDirectory
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.isLocallyCreated = true

        // Backend name is the session UUID (lowercase)
        session.backendName = session.id.uuidString.lowercased()

        // Queue/priority queue defaults
        session.isInQueue = false
        session.queuePosition = 0
        session.isInPriorityQueue = false
        session.priority = 0
        session.priorityOrder = 0

        // If user provided a custom name, save it in user session
        if !sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let userSession = CDUserSession(context: viewContext)
            userSession.id = session.id
            userSession.customName = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
            userSession.isUserDeleted = false
        }

        // Save to CoreData
        do {
            try viewContext.save()
            logger.info("✅ Created new session: \(session.id.uuidString.prefix(8)) in \(workingDirectory)")
            onSessionCreated(session)
            dismiss()
        } catch {
            logger.error("❌ Failed to create session: \(error)")
            errorMessage = "Failed to create session: \(error.localizedDescription)"
        }
    }

    private func isValidDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

// MARK: - Preview

#Preview {
    NewSessionView { session in
        print("Created session: \(session.id)")
    }
    .environment(\.managedObjectContext, PersistenceController(inMemory: true).container.viewContext)
}
