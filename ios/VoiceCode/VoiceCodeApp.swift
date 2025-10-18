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
    @State private var client: VoiceCodeClient?
    @State private var showingSettings = false
    
    var body: some View {
        NavigationView {
            SessionsListView(client: client ?? VoiceCodeClient(serverURL: settings.fullServerURL), settings: settings, voiceOutput: voiceOutput, showingSettings: $showingSettings)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(
                settings: settings,
                onServerChange: { newURL in
                    client?.updateServerURL(newURL)
                },
                voiceOutputManager: voiceOutput
            )
        }
        .onAppear {
            setupClient()
        }
    }
    
    private func setupClient() {
        let newClient = VoiceCodeClient(serverURL: settings.fullServerURL)
        newClient.connect()
        client = newClient
    }
}
