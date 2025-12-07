// SettingsWindow.swift
// macOS Settings window with tabs for General, Voice, and Advanced

import SwiftUI
import UntetheredCore

struct SettingsWindow: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        TabView {
            GeneralSettingsView()
                .environmentObject(settings)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            VoiceSettingsView()
                .environmentObject(settings)
                .tabItem {
                    Label("Voice", systemImage: "speaker.wave.2")
                }

            AdvancedSettingsView()
                .environmentObject(settings)
                .tabItem {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }
        }
        .frame(width: 500, height: 400)
    }
}
