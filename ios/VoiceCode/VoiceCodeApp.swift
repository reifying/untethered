// VoiceCodeApp.swift
// Main app entry point for voice-code iOS app

import SwiftUI
import OSLog
import UserNotifications

private let logger = Logger(subsystem: "com.travisbrown.VoiceCode", category: "RootView")

// MARK: - Navigation Targets

enum ResourcesNavigationTarget: Hashable {
    case list
    case share
}

@main
struct VoiceCodeApp: App {
    let persistenceController = PersistenceController.shared
    @StateObject private var settings = AppSettings()
    @StateObject private var draftManager = DraftManager()
    @StateObject private var voiceOutput: VoiceOutputManager
    @StateObject private var client: VoiceCodeClient
    @StateObject private var resourcesManager: ResourcesManager

    init() {
        // Create instances in correct dependency order
        let settings = AppSettings()
        let voiceManager = VoiceOutputManager(appSettings: settings)
        let voiceClient = VoiceCodeClient(
            serverURL: settings.fullServerURL,
            voiceOutputManager: voiceManager,
            appSettings: settings
        )
        let resManager = ResourcesManager(voiceCodeClient: voiceClient, appSettings: settings)

        // Initialize StateObjects
        _settings = StateObject(wrappedValue: settings)
        _draftManager = StateObject(wrappedValue: DraftManager())
        _voiceOutput = StateObject(wrappedValue: voiceManager)
        _client = StateObject(wrappedValue: voiceClient)
        _resourcesManager = StateObject(wrappedValue: resManager)
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                settings: settings,
                voiceOutput: voiceOutput,
                client: client,
                resourcesManager: resourcesManager
            )
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environmentObject(draftManager)
        }
    }
}

// MARK: - Root View

struct RootView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var voiceOutput: VoiceOutputManager
    @ObservedObject var client: VoiceCodeClient
    @ObservedObject var resourcesManager: ResourcesManager
    @State private var showingSettings = false
    @State private var navigationPath = NavigationPath()
    @State private var recentSessions: [RecentSession] = []
    @Environment(\.managedObjectContext) private var viewContext

    var body: some View {
        NavigationStack(path: $navigationPath) {
            DirectoryListView(client: client, settings: settings, voiceOutput: voiceOutput, showingSettings: $showingSettings, recentSessions: $recentSessions, navigationPath: $navigationPath, resourcesManager: resourcesManager)
                .navigationDestination(for: String.self) { workingDirectory in
                    SessionsForDirectoryView(
                        workingDirectory: workingDirectory,
                        client: client,
                        settings: settings,
                        voiceOutput: voiceOutput,
                        showingSettings: $showingSettings,
                        navigationPath: $navigationPath
                    )
                }
                .navigationDestination(for: UUID.self) { sessionId in
                    SessionLookupView(
                        sessionId: sessionId,
                        client: client,
                        voiceOutput: voiceOutput,
                        settings: settings
                    )
                }
                .navigationDestination(for: ResourcesNavigationTarget.self) { target in
                    switch target {
                    case .list:
                        ResourcesView(resourcesManager: resourcesManager, client: client)
                    case .share:
                        ResourceShareView(resourcesManager: resourcesManager)
                    }
                }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(
                settings: settings,
                onServerChange: { newURL in
                    client.updateServerURL(newURL)
                },
                voiceOutputManager: voiceOutput
            )
        }
        .onAppear {
            logger.info("🔵 RootView appeared, setting up recent sessions callback")
            
            // Set up NotificationManager with VoiceOutputManager
            NotificationManager.shared.setVoiceOutputManager(voiceOutput)
            
            // Request notification permissions
            Task {
                let authorized = await NotificationManager.shared.requestAuthorization()
                if authorized {
                    logger.info("✅ Notifications enabled for 'Read Aloud' feature")
                }
            }
            
            // Set up callback for recent_sessions before connecting
            client.onRecentSessionsReceived = { sessions in
                logger.info("📥 Received \(sessions.count) recent sessions from backend")

                // Debug: log first session JSON keys
                if let firstSession = sessions.first {
                    logger.info("🔍 First session keys: \(firstSession.keys.sorted())")
                    logger.info("🔍 First session JSON: \(firstSession)")
                }

                // Use batch parsing to eliminate N+1 queries (single CoreData fetch for all sessions)
                let parsed = RecentSession.parseRecentSessions(sessions, using: self.viewContext)
                logger.info("✅ Successfully parsed \(parsed.count) of \(sessions.count) sessions with batch fetch")

                // Defer state update to avoid SwiftUI update conflicts
                DispatchQueue.main.async {
                    self.recentSessions = parsed
                    logger.info("🔄 Updated recentSessions state array, count: \(self.recentSessions.count)")
                }
            }
            logger.info("🔌 Connecting to backend...")
            client.connect()

            // Process pending uploads after connection
            logger.info("📂 Checking for pending resource uploads...")
            resourcesManager.updatePendingCount()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            logger.info("🔄 App entering foreground, checking for pending uploads...")
            resourcesManager.updatePendingCount()
            if client.isConnected {
                resourcesManager.processPendingUploads()
            }
        }
    }
}
