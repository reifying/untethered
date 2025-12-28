//
//  VoiceCodeDesktopApp.swift
//  VoiceCodeDesktop
//
//  Main entry point for the macOS app
//

import SwiftUI
import VoiceCodeShared

// MARK: - Focused Values for Session Commands

/// Focused value key for the currently selected session
struct SelectedSessionKey: FocusedValueKey {
    typealias Value = CDBackendSession
}

/// Focused value key for the VoiceCodeClient
struct VoiceCodeClientKey: FocusedValueKey {
    typealias Value = VoiceCodeClient
}

extension FocusedValues {
    var selectedSession: CDBackendSession? {
        get { self[SelectedSessionKey.self] }
        set { self[SelectedSessionKey.self] = newValue }
    }

    var voiceCodeClient: VoiceCodeClient? {
        get { self[VoiceCodeClientKey.self] }
        set { self[VoiceCodeClientKey.self] = newValue }
    }
}

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
            SessionCommands()
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

// MARK: - Session Commands

struct SessionCommands: Commands {
    @FocusedValue(\.selectedSession) var selectedSession
    @FocusedValue(\.voiceCodeClient) var client

    var body: some Commands {
        CommandMenu("Session") {
            Button("Refresh Session") {
                guard let session = selectedSession, let client = client else { return }
                client.requestSessionRefresh(sessionId: session.backendSessionId)
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(selectedSession == nil || client == nil)

            Button("Compact Session...") {
                guard let session = selectedSession, let client = client else { return }
                // Compaction is handled via notification to show confirmation dialog
                NotificationCenter.default.post(
                    name: .requestSessionCompaction,
                    object: nil,
                    userInfo: ["sessionId": session.backendSessionId]
                )
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(selectedSession == nil || client == nil)

            Divider()

            Button("Kill Session") {
                guard let session = selectedSession, let client = client else { return }
                NotificationCenter.default.post(
                    name: .requestSessionKill,
                    object: nil,
                    userInfo: ["sessionId": session.backendSessionId]
                )
            }
            .disabled(selectedSession == nil || client == nil)
        }
    }
}

// MARK: - Notification Names for Session Commands

extension Notification.Name {
    static let requestSessionCompaction = Notification.Name("requestSessionCompaction")
    static let requestSessionKill = Notification.Name("requestSessionKill")
}
