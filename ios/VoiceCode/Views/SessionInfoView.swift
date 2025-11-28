// SessionInfoView.swift
// Modal view displaying session context information and actions

import SwiftUI
import CoreData

struct SessionInfoView: View {
    @ObservedObject var session: CDBackendSession
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
                Section(header: Text("Session Information")) {
                    InfoRow(label: "Name", value: session.displayName(context: viewContext))
                    InfoRow(label: "Working Directory", value: session.workingDirectory)
                    
                    if isLoadingBranch {
                        HStack {
                            Text("Git Branch")
                                .foregroundColor(.secondary)
                            Spacer()
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    } else if let branch = gitBranch {
                        InfoRow(label: "Git Branch", value: branch)
                    }
                    
                    InfoRow(label: "Session ID", value: session.id.uuidString.lowercased())
                }
                
                // Actions Section
                Section(header: Text("Actions")) {
                    Button(action: {
                        copySessionID()
                    }) {
                        HStack {
                            Image(systemName: "doc.on.doc")
                            Text("Copy Session ID")
                            Spacer()
                        }
                    }
                    
                    Button(action: {
                        exportSession()
                    }) {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("Export Conversation")
                            Spacer()
                        }
                    }
                    
                    Button(action: {
                        copyWorkingDirectory()
                    }) {
                        HStack {
                            Image(systemName: "folder")
                            Text("Copy Working Directory")
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
    
    private func copySessionID() {
        UIPasteboard.general.string = session.id.uuidString.lowercased()
        
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        
        showConfirmation("Session ID copied")
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
    
    private func copyWorkingDirectory() {
        UIPasteboard.general.string = session.workingDirectory
        
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        
        showConfirmation("Working directory copied")
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
}

// MARK: - Info Row Component

struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.body)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }
}
