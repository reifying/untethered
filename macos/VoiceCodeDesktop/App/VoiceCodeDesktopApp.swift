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
    @StateObject private var onboarding: OnboardingManager
    @StateObject private var settings: AppSettings

    init() {
        let appSettings = AppSettings()
        _settings = StateObject(wrappedValue: appSettings)
        _onboarding = StateObject(wrappedValue: OnboardingManager(appSettings: appSettings))
    }

    var body: some Scene {
        WindowGroup {
            if onboarding.needsOnboarding {
                OnboardingView(onboarding: onboarding, settings: settings)
            } else {
                MainWindowView(settings: settings)
            }
        }
        .commands {
            AppCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

// MARK: - Settings View

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
