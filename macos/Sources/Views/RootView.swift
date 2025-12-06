// RootView.swift
// Main window view for macOS app with NavigationSplitView

import SwiftUI
import CoreData
import UntetheredCore

struct RootView: View {
    @EnvironmentObject var client: VoiceCodeClient
    @EnvironmentObject var settings: AppSettings
    @Environment(\.managedObjectContext) private var viewContext

    @State private var selectedSessionId: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    // Fetch active sessions
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \CDBackendSession.lastModified, ascending: false)],
        animation: nil
    )
    private var allSessions: FetchedResults<CDBackendSession>

    // Filter to active sessions (not user-deleted)
    private var activeSessions: [CDBackendSession] {
        allSessions.filter { !$0.isUserDeleted(context: viewContext) }
    }

    // Find selected session
    private var selectedSession: CDBackendSession? {
        guard let selectedSessionId = selectedSessionId else { return nil }
        return activeSessions.first { $0.id == selectedSessionId }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar: Session list
            SessionListView(
                sessions: activeSessions,
                selectedSessionId: $selectedSessionId
            )
            .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 400)
        } detail: {
            // Detail: Conversation view or placeholder
            if let session = selectedSession {
                ConversationDetailView(session: session)
            } else {
                PlaceholderView()
            }
        }
        .onAppear {
            client.connect(sessionId: nil)

            // Select first session if none selected
            if selectedSessionId == nil, let firstSession = activeSessions.first {
                selectedSessionId = firstSession.id
            }
        }
    }
}

// MARK: - Session List Sidebar

struct SessionListView: View {
    let sessions: [CDBackendSession]
    @Binding var selectedSessionId: UUID?
    @EnvironmentObject var client: VoiceCodeClient
    @EnvironmentObject var settings: AppSettings
    @Environment(\.managedObjectContext) private var viewContext

    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Header with connection status
            HStack(spacing: 8) {
                Text("Sessions")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                Button(action: { showingSettings = true }) {
                    Image(systemName: "gear")
                }
                .buttonStyle(.plain)
                .help("Settings")

                ConnectionStatusView()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .sheet(isPresented: $showingSettings) {
                SettingsView(settings: settings)
            }

            Divider()

            // Session list
            List(sessions, id: \.id, selection: $selectedSessionId) { session in
                SessionRowView(session: session)
                    .tag(session.id)
            }
            .listStyle(.sidebar)

            Divider()

            // New session button
            Button(action: createNewSession) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("New Session")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(12)
        }
    }

    private func createNewSession() {
        // TODO: Implement new session creation
        print("Create new session")
    }
}

// MARK: - Session Row

struct SessionRowView: View {
    @ObservedObject var session: CDBackendSession
    @Environment(\.managedObjectContext) private var viewContext

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.displayName(context: viewContext))
                .font(.headline)
                .lineLimit(1)

            HStack(spacing: 8) {
                Text(URL(fileURLWithPath: session.workingDirectory).lastPathComponent)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                if session.messageCount > 0 {
                    Text("•")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(session.messageCount) messages")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if !session.preview.isEmpty {
                Text(session.preview)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Connection Status

struct ConnectionStatusView: View {
    @EnvironmentObject var client: VoiceCodeClient

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(client.isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(client.isConnected ? "Connected" : "Disconnected")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Placeholder View

struct PlaceholderView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "message")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            Text("No Session Selected")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("Select a session from the sidebar to start.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
