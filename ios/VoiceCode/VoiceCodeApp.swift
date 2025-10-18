// VoiceCodeApp.swift
// Main app entry point for voice-code iOS app

import SwiftUI

@main
struct VoiceCodeApp: App {
    let persistenceController = PersistenceController.shared
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView(settings: settings)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}

// MARK: - Root View

struct RootView: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var voiceOutput = VoiceOutputManager()
    @StateObject private var client: VoiceCodeClient
    @State private var showingSettings = false

    init(settings: AppSettings) {
        self.settings = settings
        // Create VoiceOutputManager with AppSettings for centralized voice management
        let voiceManager = VoiceOutputManager(appSettings: settings)
        _voiceOutput = StateObject(wrappedValue: voiceManager)
        _client = StateObject(wrappedValue: VoiceCodeClient(
            serverURL: settings.fullServerURL,
            voiceOutputManager: voiceManager
        ))
    }
    
    var body: some View {
        NavigationView {
            SessionsListView(client: client, settings: settings, voiceOutput: voiceOutput, showingSettings: $showingSettings)
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
            client.connect()
        }
    }
}
