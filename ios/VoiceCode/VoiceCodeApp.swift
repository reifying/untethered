// VoiceCodeApp.swift
// Main app entry point for voice-code iOS app

import SwiftUI
import OSLog
import UserNotifications

private let logger = Logger(subsystem: "com.travisbrown.VoiceCode", category: "RootView")

@main
struct VoiceCodeApp: App {
    let persistenceController = PersistenceController.shared
    @StateObject private var settings = AppSettings()
    @StateObject private var draftManager = DraftManager()

    var body: some Scene {
        WindowGroup {
            RootView(settings: settings)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environmentObject(draftManager)
        }
    }
}

// MARK: - Root View

struct RootView: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var voiceOutput = VoiceOutputManager()
    @StateObject private var client: VoiceCodeClient
    @State private var showingSettings = false
    @State private var navigationPath = NavigationPath()
    @State private var recentSessions: [RecentSession] = []

    init(settings: AppSettings) {
        self.settings = settings
        // Create VoiceOutputManager with AppSettings for centralized voice management
        let voiceManager = VoiceOutputManager(appSettings: settings)
        _voiceOutput = StateObject(wrappedValue: voiceManager)
        _client = StateObject(wrappedValue: VoiceCodeClient(
            serverURL: settings.fullServerURL,
            voiceOutputManager: voiceManager,
            appSettings: settings
        ))
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            DirectoryListView(client: client, settings: settings, voiceOutput: voiceOutput, showingSettings: $showingSettings, recentSessions: $recentSessions)
                .navigationDestination(for: String.self) { workingDirectory in
                    SessionsForDirectoryView(
                        workingDirectory: workingDirectory,
                        client: client,
                        settings: settings,
                        voiceOutput: voiceOutput,
                        showingSettings: $showingSettings
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

                let parsed = sessions.compactMap { RecentSession(json: $0) }
                logger.info("✅ Successfully parsed \(parsed.count) of \(sessions.count) sessions")
                self.recentSessions = parsed
                logger.info("🔄 Updated recentSessions state array, count: \(self.recentSessions.count)")
            }
            logger.info("🔌 Connecting to backend...")
            client.connect()
        }
    }
}
