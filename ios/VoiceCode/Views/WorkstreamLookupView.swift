// WorkstreamLookupView.swift
// Helper view to look up workstream by ID for navigation

import SwiftUI
import CoreData

struct WorkstreamLookupView: View {
    let workstreamId: UUID

    @ObservedObject var client: VoiceCodeClient
    @ObservedObject var voiceOutput: VoiceOutputManager
    @ObservedObject var settings: AppSettings

    @FetchRequest private var workstreams: FetchedResults<CDWorkstream>

    @State private var showingCopyConfirmation = false

    init(workstreamId: UUID, client: VoiceCodeClient, voiceOutput: VoiceOutputManager, settings: AppSettings) {
        self.workstreamId = workstreamId
        self.client = client
        self.voiceOutput = voiceOutput
        self.settings = settings

        // Fetch workstream by ID
        _workstreams = FetchRequest<CDWorkstream>(
            sortDescriptors: [],
            predicate: NSPredicate(format: "id == %@", workstreamId as CVarArg),
            animation: .default
        )
    }

    var body: some View {
        if let workstream = workstreams.first {
            // Use .id() to force view recreation when activeClaudeSessionId changes.
            // This ensures the FetchRequest gets a new predicate when the session changes
            // (e.g., after first prompt on a cleared workstream creates a new session).
            WorkstreamConversationView(workstream: workstream, client: client, voiceOutput: voiceOutput, settings: settings)
                .id(workstream.activeClaudeSessionId)
        } else {
            // Workstream not found (possibly deleted)
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48))
                    .foregroundColor(.orange)
                Text("Workstream Not Found")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("This workstream may have been deleted.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Text(workstreamId.uuidString.lowercased())
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
            }
            .padding()
            .contentShape(Rectangle())
            .contextMenu {
                Button(action: {
                    copyWorkstreamID()
                }) {
                    Label("Copy Workstream ID", systemImage: "doc.on.clipboard")
                }
            }
            .overlay(alignment: .top) {
                if showingCopyConfirmation {
                    Text("Workstream ID copied to clipboard")
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
        }
    }

    private func copyWorkstreamID() {
        // Copy workstream ID to clipboard
        UIPasteboard.general.string = workstreamId.uuidString.lowercased()

        // Trigger haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        // Show confirmation banner
        withAnimation {
            showingCopyConfirmation = true
        }

        // Hide confirmation after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                showingCopyConfirmation = false
            }
        }
    }
}
