// SessionLookupView.swift
// Helper view to look up session by ID for navigation

import SwiftUI
import CoreData

struct SessionLookupView: View {
    let sessionId: UUID

    @ObservedObject var client: VoiceCodeClient
    @ObservedObject var voiceOutput: VoiceOutputManager
    @ObservedObject var settings: AppSettings

    @FetchRequest private var sessions: FetchedResults<CDSession>

    init(sessionId: UUID, client: VoiceCodeClient, voiceOutput: VoiceOutputManager, settings: AppSettings) {
        self.sessionId = sessionId
        self.client = client
        self.voiceOutput = voiceOutput
        self.settings = settings

        // Fetch session by ID
        _sessions = FetchRequest<CDSession>(
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
                Text(sessionId.uuidString)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
            }
            .padding()
        }
    }
}
