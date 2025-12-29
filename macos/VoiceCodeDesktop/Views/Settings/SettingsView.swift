// SettingsView.swift
// macOS Preferences window with 4 panes per Appendix J.2

import SwiftUI
import AVFoundation

/// Settings window with tabbed panes for General, Voice, Sessions, and Advanced settings
struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    enum Tab: Hashable {
        case general
        case voice
        case sessions
        case advanced
    }

    @State private var selectedTab: Tab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsPane(settings: settings)
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(Tab.general)

            VoiceSettingsPane(settings: settings)
                .tabItem {
                    Label("Voice", systemImage: "waveform")
                }
                .tag(Tab.voice)

            SessionsSettingsPane(settings: settings)
                .tabItem {
                    Label("Sessions", systemImage: "bubble.left.and.bubble.right")
                }
                .tag(Tab.sessions)

            AdvancedSettingsPane(settings: settings)
                .tabItem {
                    Label("Advanced", systemImage: "gearshape.2")
                }
                .tag(Tab.advanced)
        }
        .frame(width: 500, height: 450)
        .padding()
    }
}

// MARK: - General Settings Pane

struct GeneralSettingsPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                TextField("Server URL:", text: $settings.serverURL)
                    .textFieldStyle(.roundedBorder)

                TextField("Port:", text: $settings.serverPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)

                Text("Full URL: \(settings.fullServerURL)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Server Configuration")
                    .font(.headline)
            }

            Divider()
                .padding(.vertical, 8)

            Section {
                TextEditor(text: $settings.systemPrompt)
                    .font(.body)
                    .frame(height: 80)
                    .border(Color.secondary.opacity(0.3), width: 1)

                Text("Optional instructions to append to Claude's system prompt on every message")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("System Prompt")
                    .font(.headline)
            }

            Divider()
                .padding(.vertical, 8)

            Section {
                Toggle("Connect automatically on launch", isOn: $settings.autoConnectOnLaunch)
                Toggle("Show in menu bar", isOn: $settings.showInMenuBar)
            } header: {
                Text("Startup")
                    .font(.headline)
            }
        }
        .padding()
    }
}

// MARK: - Voice Settings Pane

struct VoiceSettingsPane: View {
    @ObservedObject var settings: AppSettings
    @State private var isPreviewingVoice = false

    var body: some View {
        Form {
            Section {
                Picker("Voice:", selection: $settings.selectedVoiceIdentifier) {
                    Text("System Default").tag(nil as String?)

                    if !AppSettings.premiumVoices.isEmpty {
                        Text("All Premium Voices").tag(AppSettings.allPremiumVoicesIdentifier as String?)
                    }

                    ForEach(AppSettings.availableVoices, id: \.identifier) { voice in
                        Text(voice.name).tag(voice.identifier as String?)
                    }
                }
                .pickerStyle(.menu)

                if settings.selectedVoiceIdentifier == AppSettings.allPremiumVoicesIdentifier {
                    let premiumCount = AppSettings.premiumVoices.count
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Rotates between \(premiumCount) premium voice\(premiumCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Each project uses a consistent voice")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if let selectedId = settings.selectedVoiceIdentifier,
                          let voice = AppSettings.availableVoices.first(where: { $0.identifier == selectedId }) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Quality: \(voice.quality)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Language: \(voice.language)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Voice Selection")
                    .font(.headline)
            }

            Divider()
                .padding(.vertical, 8)

            Section {
                HStack {
                    Text("Speech Rate:")
                    Slider(value: $settings.speechRate, in: 0.0...1.0)
                    Text(speechRateLabel)
                        .frame(width: 50)
                        .foregroundColor(.secondary)
                }

                Button(action: previewVoice) {
                    HStack {
                        if isPreviewingVoice {
                            ProgressView()
                                .scaleEffect(0.8)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "speaker.wave.2.fill")
                        }
                        Text("Test Voice")
                    }
                }
                .disabled(isPreviewingVoice)
            } header: {
                Text("Playback")
                    .font(.headline)
            }

            Divider()
                .padding(.vertical, 8)

            Section {
                HStack {
                    Text("Push-to-Talk Hotkey:")
                    TextField("", text: $settings.pushToTalkHotkey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }

                Text("Default: ⌃⌥V (Control + Option + V)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Input")
                    .font(.headline)
            }
        }
        .padding()
    }

    private var speechRateLabel: String {
        if settings.speechRate < 0.3 {
            return "Slow"
        } else if settings.speechRate < 0.6 {
            return "Normal"
        } else {
            return "Fast"
        }
    }

    private func previewVoice() {
        isPreviewingVoice = true

        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: "Hello! This is a preview of the selected voice.")
        utterance.rate = settings.speechRate

        if let voiceId = settings.selectedVoiceIdentifier,
           voiceId != AppSettings.allPremiumVoicesIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: voiceId) {
            utterance.voice = voice
        } else if let firstPremium = AppSettings.premiumVoices.first,
                  let voice = AVSpeechSynthesisVoice(identifier: firstPremium.identifier) {
            utterance.voice = voice
        }

        synthesizer.speak(utterance)

        // Reset after approximate duration
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            isPreviewingVoice = false
        }
    }
}

// MARK: - Sessions Settings Pane

struct SessionsSettingsPane: View {
    @ObservedObject var settings: AppSettings
    @State private var showingDirectoryPicker = false

    var body: some View {
        Form {
            Section {
                Stepper("Recent Sessions: \(settings.recentSessionsLimit)", value: $settings.recentSessionsLimit, in: 1...50)

                Text("Number of recent sessions to display in the sidebar")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Display")
                    .font(.headline)
            }

            Divider()
                .padding(.vertical, 8)

            Section {
                Toggle("Enable Queue", isOn: $settings.queueEnabled)

                Text("Show threads in queue on the sidebar")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("Enable Priority Queue", isOn: $settings.priorityQueueEnabled)

                Text("Track sessions with priority-based ordering")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("Auto-add to queue", isOn: $settings.autoAddToQueue)
                    .disabled(!settings.queueEnabled && !settings.priorityQueueEnabled)

                Text("Automatically add sessions when sending messages")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Queue Settings")
                    .font(.headline)
            }

            Divider()
                .padding(.vertical, 8)

            Section {
                HStack {
                    TextField("Default Working Directory:", text: $settings.defaultWorkingDirectory)
                        .textFieldStyle(.roundedBorder)

                    Button("Browse...") {
                        showingDirectoryPicker = true
                    }
                }
                .fileImporter(
                    isPresented: $showingDirectoryPicker,
                    allowedContentTypes: [.folder],
                    allowsMultipleSelection: false
                ) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        settings.defaultWorkingDirectory = url.path
                    }
                }

                Text("Default directory for new sessions")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Directories")
                    .font(.headline)
            }

            Divider()
                .padding(.vertical, 8)

            Section {
                Stepper("Retention: \(settings.sessionRetentionDays) days", value: $settings.sessionRetentionDays, in: 1...365)

                Text("Automatically clean up sessions older than this")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Cleanup")
                    .font(.headline)
            }
        }
        .padding()
    }
}

// MARK: - Advanced Settings Pane

struct AdvancedSettingsPane: View {
    @ObservedObject var settings: AppSettings
    @State private var showingResetConfirmation = false
    @State private var showingClearCacheConfirmation = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable debug logging", isOn: $settings.debugLoggingEnabled)

                HStack {
                    Text("Log Location:")
                    Text(settings.logFileLocation.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: settings.logFileLocation.path)
                    }
                    .font(.caption)
                }
            } header: {
                Text("Logging")
                    .font(.headline)
            }

            Divider()
                .padding(.vertical, 8)

            Section {
                Toggle("Notify on response", isOn: $settings.notifyOnResponse)

                Text("Show system notification when Claude responds")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Notifications")
                    .font(.headline)
            }

            Divider()
                .padding(.vertical, 8)

            Section {
                TextField("Resource Storage:", text: $settings.resourceStorageLocation)
                    .textFieldStyle(.roundedBorder)

                Text("Directory where uploaded files are saved on the backend")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Resources")
                    .font(.headline)
            }

            Divider()
                .padding(.vertical, 8)

            Section {
                HStack {
                    Button("Clear Cache") {
                        showingClearCacheConfirmation = true
                    }
                    .confirmationDialog(
                        "Clear Cache?",
                        isPresented: $showingClearCacheConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Clear Cache", role: .destructive) {
                            settings.clearCache()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will clear cached voice data. It will be rebuilt on next use.")
                    }

                    Spacer()

                    Button("Reset to Defaults", role: .destructive) {
                        showingResetConfirmation = true
                    }
                    .confirmationDialog(
                        "Reset All Settings?",
                        isPresented: $showingResetConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Reset to Defaults", role: .destructive) {
                            settings.resetToDefaults()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will reset all settings to their default values. This cannot be undone.")
                    }
                }
            } header: {
                Text("Maintenance")
                    .font(.headline)
            }
        }
        .padding()
    }
}

// MARK: - Preview

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(settings: AppSettings())
    }
}
