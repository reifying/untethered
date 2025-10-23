// DirectoryListView.swift
// Top-level directory navigation view

import SwiftUI
import CoreData
import OSLog

private let logger = Logger(subsystem: "com.travisbrown.VoiceCode", category: "DirectoryList")

struct DirectoryListView: View {
    @ObservedObject var client: VoiceCodeClient
    @ObservedObject var settings: AppSettings
    @ObservedObject var voiceOutput: VoiceOutputManager
    @Binding var showingSettings: Bool
    @Binding var recentSessions: [RecentSession]
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject var draftManager: DraftManager

    // Fetch active (non-deleted) sessions from CoreData
    @FetchRequest(
        fetchRequest: CDSession.fetchActiveSessions(),
        animation: .default)
    private var sessions: FetchedResults<CDSession>

    @State private var showingNewSession = false
    @State private var newSessionName = ""
    @State private var newWorkingDirectory = ""
    @State private var isRecentExpanded = true

    // Directory metadata computed from sessions
    struct DirectoryInfo: Identifiable {
        let workingDirectory: String
        let directoryName: String
        let sessionCount: Int
        let totalUnread: Int
        let lastModified: Date

        var id: String { workingDirectory }
    }

    // Compute directory list from sessions
    private var directories: [DirectoryInfo] {
        let grouped = Dictionary(grouping: sessions, by: { $0.workingDirectory })

        return grouped.map { workingDirectory, sessions in
            let directoryName = (workingDirectory as NSString).lastPathComponent
            let sessionCount = sessions.count
            let totalUnread = sessions.reduce(0) { $0 + Int($1.unreadCount) }
            let lastModified = sessions.map { $0.lastModified }.max() ?? Date.distantPast

            return DirectoryInfo(
                workingDirectory: workingDirectory,
                directoryName: directoryName,
                sessionCount: sessionCount,
                totalUnread: totalUnread,
                lastModified: lastModified
            )
        }
        .sorted { $0.lastModified > $1.lastModified } // Most recent first
    }

    // Default working directory for new sessions (most recently used)
    private var defaultWorkingDirectory: String {
        directories.first?.workingDirectory ?? FileManager.default.currentDirectoryPath
    }

    var body: some View {
        Group {
            if sessions.isEmpty {
                // Empty state: no sessions at all
                VStack(spacing: 16) {
                    Image(systemName: "folder")
                        .font(.system(size: 64))
                        .foregroundColor(.secondary)
                    Text("No sessions yet")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Sessions will appear here automatically when you use Claude Code in the terminal or create a new session.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    // Recent Sessions section
                    if !recentSessions.isEmpty {
                        Section(isExpanded: $isRecentExpanded) {
                            ForEach(recentSessions) { session in
                                NavigationLink(value: UUID(uuidString: session.sessionId) ?? UUID()) {
                                    RecentSessionRowContent(session: session)
                                }
                            }
                        } header: {
                            Text("Recent")
                        }
                    }
                    
                    // Projects (Directories) section
                    Section {
                        ForEach(directories) { directory in
                            NavigationLink(value: directory.workingDirectory) {
                                DirectoryRowContent(directory: directory)
                            }
                        }
                    } header: {
                        Text("Projects")
                    }
                }
                .refreshable {
                    logger.info("Pull-to-refresh triggered - requesting session list")
                    client.requestSessionList()
                }
            }
        }
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    Button(action: {
                        logger.info("🔄 Refresh button tapped - requesting session list from backend")
                        client.requestSessionList()
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }

                    Button(action: {
                        // Pre-populate with most recently used directory
                        newWorkingDirectory = defaultWorkingDirectory
                        showingNewSession = true
                    }) {
                        Image(systemName: "plus")
                    }

                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gear")
                    }
                }
            }
        }
        .sheet(isPresented: $showingNewSession) {
            NewSessionView(
                name: $newSessionName,
                workingDirectory: $newWorkingDirectory,
                onCreate: {
                    createNewSession(
                        name: newSessionName,
                        workingDirectory: newWorkingDirectory.isEmpty ? nil : newWorkingDirectory
                    )
                    newSessionName = ""
                    newWorkingDirectory = ""
                    showingNewSession = false
                },
                onCancel: {
                    newSessionName = ""
                    newWorkingDirectory = ""
                    showingNewSession = false
                }
            )
        }

    }

    private func createNewSession(name: String, workingDirectory: String?) {
        // Generate new UUID for session
        let sessionId = UUID()

        // Create CDSession in CoreData
        let session = CDSession(context: viewContext)
        session.id = sessionId
        session.backendName = name
        session.localName = name
        session.workingDirectory = workingDirectory ?? FileManager.default.currentDirectoryPath
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.markedDeleted = false
        session.isLocallyCreated = true

        // Save to CoreData
        do {
            try viewContext.save()
            logger.info("📝 Created new session: \(sessionId.uuidString.lowercased())")

            // Note: ConversationView will handle subscription when it appears (lazy loading)

        } catch {
            logger.error("❌ Failed to create session: \(error)")
        }
    }
}

// MARK: - Directory Row Content

struct DirectoryRowContent: View {
    let directory: DirectoryListView.DirectoryInfo

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                // Line 1: Folder icon + directory name + unread badge
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.blue)
                        .imageScale(.medium)

                    Text(directory.directoryName)
                        .font(.headline)

                    Spacer()

                    if directory.totalUnread > 0 {
                        Text("\(directory.totalUnread)")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.red)
                            .clipShape(Capsule())
                    }
                }

                // Line 2: Full working directory path
                Text(directory.workingDirectory)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                // Line 3: Session count + timestamp
                HStack(spacing: 8) {
                    Text("\(directory.sessionCount) session\(directory.sessionCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text("•")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text(directory.lastModified.relativeFormatted())
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Recent Session Row Content

struct RecentSessionRowContent: View {
    let session: RecentSession
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Line 1: Session name
            Text(session.name)
                .font(.headline)
            
            // Line 2: Session ID (first 8 chars) + working directory
            HStack(spacing: 8) {
                Text("[\(session.sessionId.prefix(8))]")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fontDesign(.monospaced)
                Text("•")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(session.workingDirectory)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            // Line 3: Last modified timestamp
            Text(session.lastModified.relativeFormatted())
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Relative Time Formatting

extension Date {
    func relativeFormatted() -> String {
        let now = Date()
        let interval = now.timeIntervalSince(self)

        // Less than 1 minute
        if interval < 60 {
            return "just now"
        }

        // Less than 7 days: use RelativeDateTimeFormatter
        if interval < 7 * 24 * 60 * 60 {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return formatter.localizedString(for: self, relativeTo: now)
        }

        // 7+ days: use date format
        let calendar = Calendar.current
        let dateFormatter = DateFormatter()

        if calendar.isDate(self, equalTo: now, toGranularity: .year) {
            dateFormatter.dateFormat = "MMM d"
        } else {
            dateFormatter.dateFormat = "MMM d, yyyy"
        }

        return dateFormatter.string(from: self)
    }
}

// MARK: - Preview

struct DirectoryListView_Previews: PreviewProvider {
    static var previews: some View {
        let settings = AppSettings()
        let client = VoiceCodeClient(serverURL: settings.fullServerURL)
        let voiceOutput = VoiceOutputManager()

        NavigationStack {
            DirectoryListView(
                client: client,
                settings: settings,
                voiceOutput: voiceOutput,
                showingSettings: .constant(false),
                recentSessions: .constant([])
            )
        }
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
