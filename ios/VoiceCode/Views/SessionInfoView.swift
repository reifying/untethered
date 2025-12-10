// SessionInfoView.swift
// Modal view displaying session context information and actions

import SwiftUI
import CoreData

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
        NavigationView {
            List {
                // Session Information Section
                Section {
                    InfoRow(
                        label: "Name",
                        value: session.displayName(context: viewContext),
                        onCopy: { value in
                            copyToClipboard(value, message: "Name copied")
                        }
                    )

                    InfoRow(
                        label: "Working Directory",
                        value: session.workingDirectory,
                        onCopy: { value in
                            copyToClipboard(value, message: "Directory copied")
                        }
                    )

                    if isLoadingBranch {
                        HStack {
                            Text("Git Branch")
                                .foregroundColor(.secondary)
                            Spacer()
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    } else if let branch = gitBranch {
                        InfoRow(
                            label: "Git Branch",
                            value: branch,
                            onCopy: { value in
                                copyToClipboard(value, message: "Branch copied")
                            }
                        )
                    }

                    InfoRow(
                        label: "Session ID",
                        value: session.id.uuidString.lowercased(),
                        onCopy: { value in
                            copyToClipboard(value, message: "Session ID copied")
                        }
                    )
                } header: {
                    Text("Session Information")
                } footer: {
                    Text("Tap to copy any field")
                        .font(.caption)
                }

                // Priority Queue Section
                if settings.priorityQueueEnabled && session.isInPriorityQueue {
                    Section {
                        // Priority Picker
                        Picker("Priority", selection: Binding(
                            get: { session.priority },
                            set: { newPriority in
                                changePriority(session, newPriority: newPriority)
                            }
                        )) {
                            Text("High (1)").tag(Int32(1))
                            Text("Medium (5)").tag(Int32(5))
                            Text("Low (10)").tag(Int32(10))
                        }
                        .pickerStyle(.segmented)

                        // Priority Order (read-only)
                        HStack {
                            Text("Order")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(String(format: "%.1f", session.priorityOrder))
                                .foregroundColor(.primary)
                        }

                        // Queued Timestamp (read-only)
                        if let queuedAt = session.priorityQueuedAt {
                            HStack {
                                Text("Queued")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(queuedAt, style: .relative)
                                    .foregroundColor(.primary)
                            }
                        }
                    } header: {
                        Text("Priority Queue")
                    } footer: {
                        Text("Change priority to adjust position in queue. Lower priority number = higher importance.")
                            .font(.caption)
                    }
                }

                // Actions Section
                Section(header: Text("Actions")) {
                    Button(action: {
                        exportSession()
                    }) {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("Export Conversation")
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Session Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .overlay(alignment: .top) {
                if showCopyConfirmation {
                    Text(copyConfirmationMessage)
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
            .task {
                await loadGitBranch()
            }
        }
    }

    // MARK: - Git Branch Detection

    private func loadGitBranch() async {
        isLoadingBranch = true
        gitBranch = await GitBranchDetector.detectBranch(workingDirectory: session.workingDirectory)
        isLoadingBranch = false
    }

    // MARK: - Actions

    private func copyToClipboard(_ text: String, message: String) {
        UIPasteboard.general.string = text

        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

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
            print("❌ Failed to fetch messages for export: \(error)")
            exportText += "Error: Failed to export messages\n"
        }

        // Copy to clipboard
        UIPasteboard.general.string = exportText

        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        showConfirmation("Conversation exported")
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

    private func changePriority(_ session: CDBackendSession, newPriority: Int32) {
        CDBackendSession.changePriority(session, newPriority: newPriority, context: viewContext)
        showConfirmation("Priority changed to \(newPriority)")
    }
}

// MARK: - Info Row Component

struct InfoRow: View {
    let label: String
    let value: String
    let onCopy: (String) -> Void

    var body: some View {
        Button(action: {
            onCopy(value)
        }) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.body)
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
