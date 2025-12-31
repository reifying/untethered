// SessionLookupView.swift
// Helper view to look up session by ID for navigation

import SwiftUI
import CoreData
import VoiceCodeShared

struct SessionLookupView: View {
    let sessionId: UUID

    @ObservedObject var client: VoiceCodeClient
    @ObservedObject var voiceOutput: VoiceOutputManager
    @ObservedObject var settings: AppSettings

    @Environment(\.dismiss) private var dismiss
    @FetchRequest private var sessions: FetchedResults<CDBackendSession>

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
            // Session not found - use recovery view per AD.3
            SessionNotFoundView(
                sessionId: sessionId,
                onDismiss: {
                    dismiss()
                },
                onRefresh: {
                    refreshFromBackend()
                }
            )
        }
    }

    private func refreshFromBackend() {
        // Request fresh session list from backend
        client.sendMessage(["type": "get_session_list"])
    }
}
