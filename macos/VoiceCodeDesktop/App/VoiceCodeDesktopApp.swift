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

// Note: Additional focused value keys are defined in Commands/AppCommands.swift:
// - messageInput: Binding<String>? - for message input text
// - sendMessageAction: (() -> Void)? - for triggering message send
// - showSessionInfoAction: (() -> Void)? - for showing session info
// - sessionsList: [CDBackendSession]? - for session navigation
// - selectedSessionBinding: Binding<CDBackendSession?>? - for session selection

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


// MARK: - Notification Names for Session Commands

extension Notification.Name {
    static let requestSessionCompaction = Notification.Name("requestSessionCompaction")
    static let requestSessionKill = Notification.Name("requestSessionKill")
}
