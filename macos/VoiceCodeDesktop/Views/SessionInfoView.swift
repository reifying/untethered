// SessionInfoView.swift
// Inspector panel displaying session context information and actions (⌘I)
// Per Section 11.5 and Appendix D of macos-desktop-design.md

import SwiftUI
import CoreData
import OSLog
import VoiceCodeShared

private let logger = Logger(subsystem: "dev.910labs.voice-code-desktop", category: "SessionInfoView")

// MARK: - SessionInfoView

/// Inspector panel for session details, accessible via ⌘I
struct SessionInfoView: View {
    @ObservedObject var session: CDBackendSession
    @ObservedObject var settings: AppSettings
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    @State private var showCopyConfirmation = false
    @State private var copyConfirmationMessage = ""
    @State private var gitBranch: String?
    @State private var isLoadingBranch = true

    var body: some View {
        VStack(spacing: 0) {
            // Header with title and close button
            HStack {
                Text("Session Info")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Session Information Section
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            InfoRowMac(
                                label: "Name",
                                value: session.displayName(context: viewContext),
                                onCopy: { value in
                                    copyToClipboard(value, message: "Name copied")
                                }
                            )

                            Divider()

                            InfoRowMac(
                                label: "Working Directory",
                                value: session.workingDirectory,
                                onCopy: { value in
                                    copyToClipboard(value, message: "Directory copied")
                                }
                            )

                            Divider()

                            if isLoadingBranch {
                                HStack {
                                    Text("Git Branch")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            } else if let branch = gitBranch {
                                InfoRowMac(
                                    label: "Git Branch",
                                    value: branch,
                                    onCopy: { value in
                                        copyToClipboard(value, message: "Branch copied")
                                    }
                                )
                            } else {
                                HStack {
                                    Text("Git Branch")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("Not a git repository")
                                        .font(.body)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Divider()

                            InfoRowMac(
                                label: "Session ID",
                                value: session.id.uuidString.lowercased(),
                                onCopy: { value in
                                    copyToClipboard(value, message: "Session ID copied")
                                }
                            )

                            Divider()

                            // Session metadata
                            HStack {
                                Text("Created")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                if let userSession = fetchUserSession() {
                                    Text(userSession.createdAt, style: .date)
                                        .font(.body)
                                } else {
                                    Text("Unknown")
                                        .font(.body)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Divider()

                            HStack {
                                Text("Last Modified")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(session.lastModified.formatted(date: .abbreviated, time: .shortened))
                                    .font(.body)
                            }

                            Divider()

                            HStack {
                                Text("Messages")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(session.messageCount)")
                                    .font(.body)
                            }
                        }
                        .padding(.vertical, 4)
                    } label: {
                        Text("Session Information")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }

                    // Priority Queue Section
                    if settings.priorityQueueEnabled {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                if session.isInPriorityQueue {
                                    // Priority Picker
                                    HStack {
                                        Text("Priority")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Picker("", selection: Binding(
                                            get: { session.priority },
                                            set: { newPriority in
                                                changePriority(session, newPriority: newPriority)
                                            }
                                        )) {
                                            Text("High").tag(Int32(1))
                                            Text("Medium").tag(Int32(5))
                                            Text("Low").tag(Int32(10))
                                        }
                                        .pickerStyle(.segmented)
                                        .frame(maxWidth: 200)
                                    }

                                    Divider()

                                    // Priority Order (read-only)
                                    HStack {
                                        Text("Order")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Text(String(format: "%.1f", session.priorityOrder))
                                            .font(.body)
                                    }

                                    // Queued Timestamp (read-only)
                                    if let queuedAt = session.priorityQueuedAt {
                                        Divider()
                                        HStack {
                                            Text("Queued")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            Spacer()
                                            Text(queuedAt, style: .relative)
                                                .font(.body)
                                        }
                                    }

                                    Divider()

                                    // Remove from queue button
                                    Button(role: .destructive) {
                                        removeFromPriorityQueue(session)
                                    } label: {
                                        Label("Remove from Priority Queue", systemImage: "star.slash")
                                    }
                                    .buttonStyle(.borderless)
                                } else {
                                    // Add to queue button when not in queue
                                    Button {
                                        addToPriorityQueue(session)
                                    } label: {
                                        Label("Add to Priority Queue", systemImage: "star.fill")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            .padding(.vertical, 4)
                        } label: {
                            Text("Priority Queue")
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                    }

                    // Actions Section
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Button(action: exportSession) {
                                Label("Export Conversation", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.borderless)

                            Button(action: openInFinder) {
                                Label("Show in Finder", systemImage: "folder")
                            }
                            .buttonStyle(.borderless)

                            Divider()

                            Button(role: .destructive, action: deleteSession) {
                                Label("Delete Session...", systemImage: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    } label: {
                        Text("Actions")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                }
                .padding()
            }

            Divider()

            // Footer with Done button
            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 400, height: 550)
        .overlay(alignment: .top) {
            if showCopyConfirmation {
                Text(copyConfirmationMessage)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.9))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task {
            await loadGitBranch()
        }
    }

    // MARK: - Git Branch Detection

    private func loadGitBranch() async {
        isLoadingBranch = true
        gitBranch = await GitBranchDetector.detectBranch(workingDirectory: session.workingDirectory)
        isLoadingBranch = false
    }

    // MARK: - User Session Lookup

    private func fetchUserSession() -> CDUserSession? {
        let request = CDUserSession.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", session.id as CVarArg)
        request.fetchLimit = 1
        return try? viewContext.fetch(request).first
    }

    // MARK: - Actions

    private func copyToClipboard(_ text: String, message: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        showConfirmation(message)
    }

    private func exportSession() {
        // Format session header
        var exportText = "# \(session.displayName(context: viewContext))\n"
        exportText += "Session ID: \(session.id.uuidString.lowercased())\n"
        exportText += "Working Directory: \(session.workingDirectory)\n"

        if let branch = gitBranch {
            exportText += "Git Branch: \(branch)\n"
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        exportText += "Exported: \(dateFormatter.string(from: Date()))\n"
        exportText += "\n---\n\n"

        // Fetch ALL messages for export (not just the displayed 50)
        let exportFetchRequest = CDMessage.fetchRequest()
        exportFetchRequest.predicate = NSPredicate(format: "sessionId == %@", session.id as CVarArg)
        exportFetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CDMessage.timestamp, ascending: true)]

        do {
            let allMessages = try viewContext.fetch(exportFetchRequest)
            exportText += "Message Count: \(allMessages.count)\n\n"

            // Add all messages in chronological order
            for message in allMessages {
                let roleLabel = message.role == "user" ? "User" : "Assistant"
                exportText += "[\(roleLabel)]\n"
                exportText += "\(message.text)\n\n"
            }
        } catch {
            logger.error("❌ Failed to fetch messages for export: \(error)")
            exportText += "Error: Failed to export messages\n"
        }

        // Copy to clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(exportText, forType: .string)

        showConfirmation("Conversation exported to clipboard")
    }

    private func openInFinder() {
        let url = URL(fileURLWithPath: session.workingDirectory)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    private func deleteSession() {
        dismiss()
        // Post notification to trigger confirmation dialog in MainWindowView
        NotificationCenter.default.post(
            name: .requestSessionDeletion,
            object: nil,
            userInfo: ["sessionId": session.id]
        )
    }

    private func showConfirmation(_ message: String) {
        copyConfirmationMessage = message
        withAnimation {
            showCopyConfirmation = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                showCopyConfirmation = false
            }
        }
    }

    // MARK: - Priority Queue Management

    private func addToPriorityQueue(_ session: CDBackendSession) {
        CDBackendSession.addToPriorityQueue(session, context: viewContext)
        showConfirmation("Added to Priority Queue")
    }

    private func removeFromPriorityQueue(_ session: CDBackendSession) {
        CDBackendSession.removeFromPriorityQueue(session, context: viewContext)
        showConfirmation("Removed from Priority Queue")
    }

    private func changePriority(_ session: CDBackendSession, newPriority: Int32) {
        CDBackendSession.changePriority(session, newPriority: newPriority, context: viewContext)
        showConfirmation("Priority changed")
    }
}

// MARK: - InfoRowMac Component

/// macOS-styled info row with click-to-copy functionality
struct InfoRowMac: View {
    let label: String
    let value: String
    let onCopy: (String) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)

            Text(value)
                .font(.body)
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: { onCopy(value) }) {
                Image(systemName: "doc.on.doc")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1.0 : 0.0)
            .help("Copy to clipboard")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Preview

#Preview {
    let controller = PersistenceController(inMemory: true)
    let context = controller.container.viewContext

    // Create a test session
    let session = CDBackendSession(context: context)
    session.id = UUID()
    session.workingDirectory = "/Users/test/project"
    session.backendName = "Test Session"
    session.lastModified = Date()
    session.messageCount = 5

    try? context.save()

    return SessionInfoView(session: session, settings: AppSettings())
        .environment(\.managedObjectContext, context)
}
