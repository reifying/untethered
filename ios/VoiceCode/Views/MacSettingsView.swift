// MacSettingsView.swift
// Tabbed macOS Settings scene following native macOS conventions

#if os(macOS)
import SwiftUI

struct MacSettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var client: VoiceCodeClient
    @EnvironmentObject var voiceOutput: VoiceOutputManager

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            ConnectionSettingsTab(
                onServerChange: { newURL in
                    client.updateServerURL(newURL)
                },
                onAPIKeyChanged: {
                    client.disconnect()
                    client.connect()
                }
            )
            .tabItem {
                Label("Connection", systemImage: "network")
            }

            VoiceSettingsTab()
                .tabItem {
                    Label("Voice", systemImage: "waveform")
                }

            AdvancedSettingsTab()
                .tabItem {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }
        }
        .frame(width: 500, height: 400)
    }
}

// MARK: - General Settings Tab

struct GeneralSettingsTab: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Recent Sessions") {
                Stepper("Show \(settings.recentSessionsLimit) recent sessions",
                        value: $settings.recentSessionsLimit, in: 1...20)
            }

            Section("Queue") {
                Toggle("Enable session queue", isOn: $settings.queueEnabled)
                Toggle("Enable priority queue", isOn: $settings.priorityQueueEnabled)
            }

            Section("Provider") {
                Picker("Default Provider", selection: $settings.defaultProvider) {
                    Text("Claude").tag("claude")
                    Text("Copilot").tag("copilot")
                }
                Text("AI provider used for new sessions")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Resources") {
                TextField("Storage location", text: $settings.resourceStorageLocation)
                    .textFieldStyle(.roundedBorder)
                Text("Directory where uploaded files will be saved on the backend")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Connection Settings Tab

struct ConnectionSettingsTab: View {
    @EnvironmentObject var settings: AppSettings

    let onServerChange: (String) -> Void
    let onAPIKeyChanged: () -> Void

    @State private var testingConnection = false
    @State private var testResult: String?
    @State private var testSuccess = false
    @State private var apiKeyInput: String = ""
    @State private var apiKeyError: String?
    @State private var hasKey: Bool = false
    @State private var showingDeleteConfirmation = false
    @State private var savedServerURL: String = ""
    @State private var savedServerPort: String = ""

    /// Whether the current server fields differ from the last-applied values
    private var serverSettingsChanged: Bool {
        settings.serverURL != savedServerURL || settings.serverPort != savedServerPort
    }

    var body: some View {
        Form {
            Section("Server") {
                TextField("Server address", text: $settings.serverURL)
                    .textFieldStyle(.roundedBorder)

                TextField("Port", text: $settings.serverPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)

                HStack {
                    Text("URL: \(settings.fullServerURL)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if serverSettingsChanged {
                        Button("Apply") {
                            savedServerURL = settings.serverURL
                            savedServerPort = settings.serverPort
                            onServerChange(settings.fullServerURL)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }

            Section("Authentication") {
                if hasKey {
                    HStack {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundColor(.green)
                        Text("API Key Configured")
                        Spacer()
                        if let key = KeychainManager.shared.retrieveAPIKey() {
                            Text(MacSettingsView.maskedKey(key))
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }

                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Text("Delete Key")
                    }
                } else {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("API Key Required")
                    }

                    SecureField("Paste API key", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)

                    if let error = apiKeyError {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }

                    Button("Save Key") {
                        saveAPIKey()
                    }
                    .disabled(apiKeyInput.isEmpty)
                }
            }

            Section("Test") {
                HStack {
                    Button("Test Connection") {
                        testConnection()
                    }
                    .disabled(testingConnection)

                    if testingConnection {
                        ProgressView()
                            .controlSize(.small)
                    } else if let result = testResult {
                        Image(systemName: testSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(testSuccess ? .green : .red)
                        Text(result)
                            .font(.caption)
                            .foregroundColor(testSuccess ? .green : .red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            hasKey = KeychainManager.shared.hasAPIKey()
            savedServerURL = settings.serverURL
            savedServerPort = settings.serverPort
        }
        .alert("Delete API Key?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteAPIKey()
            }
        } message: {
            Text("You will need to re-enter the API key to connect to the backend.")
        }
    }

    private func testConnection() {
        testingConnection = true
        testResult = nil

        settings.testConnection { success, message in
            testingConnection = false
            testSuccess = success
            testResult = message
        }
    }

    private func saveAPIKey() {
        apiKeyError = nil

        guard KeychainManager.shared.isValidAPIKeyFormat(apiKeyInput) else {
            apiKeyError = "Invalid format. Must start with 'untethered-' and be 43 characters."
            return
        }

        do {
            try KeychainManager.shared.saveAPIKey(apiKeyInput)
            apiKeyInput = ""
            hasKey = true
            onAPIKeyChanged()
        } catch {
            apiKeyError = "Failed to save: \(error.localizedDescription)"
        }
    }

    private func deleteAPIKey() {
        do {
            try KeychainManager.shared.deleteAPIKey()
            hasKey = false
            onAPIKeyChanged()
        } catch {
            apiKeyError = "Failed to delete: \(error.localizedDescription)"
        }
    }
}

// MARK: - Voice Settings Tab

struct VoiceSettingsTab: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var voiceOutput: VoiceOutputManager

    @State private var previewingVoice = false

    var body: some View {
        Form {
            Section("Voice Selection") {
                Picker("Voice", selection: $settings.selectedVoiceIdentifier) {
                    Text("System Default").tag(nil as String?)
                    if !AppSettings.premiumVoices.isEmpty {
                        Text("All Premium Voices").tag(AppSettings.allPremiumVoicesIdentifier as String?)
                    }
                    ForEach(AppSettings.availableVoices, id: \.identifier) { voice in
                        Text(voice.name).tag(voice.identifier as String?)
                    }
                }

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

                Button(action: previewVoice) {
                    HStack {
                        Text("Preview Voice")
                        Spacer()
                        if previewingVoice {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "speaker.wave.2.fill")
                        }
                    }
                }
                .disabled(previewingVoice)
            }

            Section("Keyboard Shortcut") {
                HStack {
                    Text("Push-to-talk:")
                    Spacer()
                    Text("Option + Space")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                        .font(.system(.body, design: .monospaced))
                }
            }

            Section("Mute") {
                Toggle("Mute voice output", isOn: $voiceOutput.isMuted)
                Text("When muted, speech is silently ignored (Cmd+Shift+M)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func previewVoice() {
        previewingVoice = true

        let previewText = "Hello! This is a preview of the selected voice. Premium voices sound more natural and expressive."
        voiceOutput.speakWithVoice(previewText, voiceIdentifier: settings.selectedVoiceIdentifier)

        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            previewingVoice = false
        }
    }
}

// MARK: - Advanced Settings Tab

struct AdvancedSettingsTab: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var client: VoiceCodeClient

    var body: some View {
        Form {
            Section("Message Size") {
                Stepper("Max size: \(settings.maxMessageSizeKB) KB",
                        value: $settings.maxMessageSizeKB, in: 50...250, step: 10)
                Text("Large responses will be truncated. iOS has a 256 KB limit.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("System Prompt") {
                TextEditor(text: $settings.systemPrompt)
                    .frame(minHeight: 100)
                    .font(.body)
                Text("Custom instructions appended to Claude's system prompt")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: settings.maxMessageSizeKB) { newValue in
            client.sendMaxMessageSize(newValue)
        }
    }
}

// MARK: - Helpers

extension MacSettingsView {
    static func maskedKey(_ key: String) -> String {
        guard key.count > 8 else { return key }
        let prefix = String(key.prefix(4))
        let suffix = String(key.suffix(4))
        return "\(prefix)...\(suffix)"
    }
}
#endif
