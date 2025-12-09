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
    @State private var recentSessions: [RecentSession] = []

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

    // Queue sessions (not yet implemented in CoreData model)
    private var queuedSessions: [CDBackendSession] {
        []
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar: Session list
            SessionListView(
                sessions: activeSessions,
                queuedSessions: queuedSessions,
                recentSessions: recentSessions,
                selectedSessionId: $selectedSessionId
            )
            .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 400)
        } detail: {
            // Detail: Session lookup view
            if let selectedSessionId = selectedSessionId {
                SessionLookupView(sessionId: selectedSessionId)
            } else {
                PlaceholderView()
            }
        }
        .onAppear {
            // Set up recent sessions callback
            client.onRecentSessionsReceived = { sessions in
                let parsed = RecentSession.parseRecentSessions(sessions)
                DispatchQueue.main.async {
                    self.recentSessions = parsed
                }
            }

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
    let queuedSessions: [CDBackendSession]
    let recentSessions: [RecentSession]
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
            .onChange(of: settings.fullServerURL) { newURL in
                // Reconnect when server URL changes
                client.updateServerURL(newURL)
            }

            Divider()

            // Session list with sections
            List(selection: $selectedSessionId) {
                // Recent section
                if !recentSessions.isEmpty {
                    Section(header: Text("Recent")) {
                        ForEach(recentSessions) { session in
                            if let sessionUUID = UUID(uuidString: session.sessionId) {
                                RecentSessionRowView(session: session)
                                    .tag(sessionUUID)
                            }
                        }
                    }
                }

                // Queue section
                if settings.queueEnabled && !queuedSessions.isEmpty {
                    Section(header: Text("Queue")) {
                        ForEach(queuedSessions) { session in
                            SessionRowView(session: session)
                                .tag(session.id)
                        }
                    }
                }

                // All Sessions section
                Section(header: Text("All Sessions")) {
                    ForEach(sessions) { session in
                        SessionRowView(session: session)
                            .tag(session.id)
                    }
                }
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

// MARK: - Recent Session Row

struct RecentSessionRowView: View {
    let session: RecentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.displayName)
                .font(.headline)
                .lineLimit(1)
            Text(session.workingDirectory)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text(session.lastModified, style: .relative)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
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

// MARK: - Session Lookup View

struct SessionLookupView: View {
    let sessionId: UUID
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest private var sessions: FetchedResults<CDBackendSession>

    init(sessionId: UUID) {
        self.sessionId = sessionId

        // Fetch session by ID
        _sessions = FetchRequest<CDBackendSession>(
            sortDescriptors: [],
            predicate: NSPredicate(format: "id == %@", sessionId as CVarArg),
            animation: .default
        )
    }

    var body: some View {
        if let session = sessions.first {
            ConversationDetailView(session: session)
        } else {
            // Session not found (possibly not synced from backend yet)
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48))
                    .foregroundColor(.orange)
                Text("Session Not Found")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("This session may not be synced yet or has been deleted.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Text(sessionId.uuidString.lowercased())
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Placeholder View

struct PlaceholderView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var client: VoiceCodeClient
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 16) {
            if !settings.isServerConfigured {
                // First-run state: server not configured
                Image(systemName: "server.rack")
                    .font(.system(size: 64))
                    .foregroundColor(.secondary)
                Text("Configure Server")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text("Connect to your voice-code backend to get started.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button(action: { showingSettings = true }) {
                    Label("Open Settings", systemImage: "gear")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            } else if !client.isConnected {
                // Server configured but not connected
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 64))
                    .foregroundColor(.secondary)
                Text("Disconnected")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text("Unable to connect to voice-code backend. Check your server settings.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button(action: { showingSettings = true }) {
                    Label("Open Settings", systemImage: "gear")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            } else {
                // Default: no session selected
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingSettings) {
            SettingsView(settings: settings)
        }
    }
}
