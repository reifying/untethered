//
//  VoiceCodeDesktopApp.swift
//  VoiceCodeDesktop
//
//  Main entry point for the macOS app
//

import SwiftUI
import VoiceCodeShared

@main
struct VoiceCodeDesktopApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            AppCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

// MARK: - Placeholder Views

struct ContentView: View {
    var body: some View {
        Text("Untethered Desktop")
            .frame(minWidth: 400, minHeight: 300)
    }
}

struct SettingsView: View {
    var body: some View {
        Text("Settings")
            .frame(width: 400, height: 300)
    }
}

// MARK: - App Commands

struct AppCommands: Commands {
    var body: some Commands {
        // Add custom menu commands here
        EmptyCommands()
    }
}
