// SessionLookupView.swift
// Helper view to look up session by ID for navigation

import SwiftUI
import CoreData

struct SessionLookupView: View {
    let sessionId: UUID

    @ObservedObject var client: VoiceCodeClient
    @ObservedObject var voiceOutput: VoiceOutputManager
    @ObservedObject var settings: AppSettings

    @FetchRequest private var sessions: FetchedResults<CDBackendSession>
    
    @State private var showingCopyConfirmation = false

    init(sessionId: UUID, client: VoiceCodeClient, voiceOutput: VoiceOutputManager, settings: AppSettings) {
        self.sessionId = sessionId
        self.client = client
        self.voiceOutput = voiceOutput
        self.settings = settings

        // Fetch session by ID
        _sessions = FetchRequest<CDBackendSession>(
            sortDescriptors: [],
            predicate: NSPredicate(format: "id == %@", sessionId as CVarArg),
            animation: .default
        )
    }

    var body: some View {
        if let session = sessions.first {
            ConversationView(session: session, client: client, voiceOutput: voiceOutput, settings: settings)
        } else {
            // Session not found (possibly deleted)
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48))
                    .foregroundColor(.orange)
                Text("Session Not Found")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("This session may have been deleted.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Text(sessionId.uuidString.lowercased())
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
            }
            .padding()
            .contentShape(Rectangle())
            .contextMenu {
                Button(action: {
                    copySessionID()
                }) {
                    Label("Copy Session ID", systemImage: "doc.on.clipboard")
                }
            }
            .overlay(alignment: .top) {
                if showingCopyConfirmation {
                    Text("Session ID copied to clipboard")
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
    
    private func copySessionID() {
        // Copy session ID to clipboard
        ClipboardUtility.copy(sessionId.uuidString.lowercased())

        // Trigger haptic feedback
        ClipboardUtility.triggerSuccessHaptic()

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
