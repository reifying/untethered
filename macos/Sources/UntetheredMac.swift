// UntetheredMac.swift
// Main entry point for Untethered macOS app

import SwiftUI
import UntetheredCore

@main
struct UntetheredMacApp: App {
    @StateObject private var client: VoiceCodeClient
    @StateObject private var settings = AppSettings()

    init() {
        let appSettings = AppSettings()
        let client = VoiceCodeClient(
            serverURL: appSettings.serverURL,
            appSettings: appSettings,
            setupObservers: false
        )
        _client = StateObject(wrappedValue: client)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(client)
                .environmentObject(settings)
        }
        .defaultSize(width: 800, height: 600)
    }
}
