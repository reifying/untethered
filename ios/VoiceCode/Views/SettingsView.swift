// SettingsView.swift
// Server configuration UI for voice-code iPhone app

import SwiftUI
import AVFoundation

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) var dismiss

    @State private var testingConnection = false
    @State private var testResult: String?
    @State private var testSuccess = false
    @State private var previewingVoice = false
    @State private var localSystemPrompt: String = ""
    @State private var pendingAPIKeyInput: String = ""
    @State private var showingAPIKeyError = false

    let onServerChange: (String) -> Void
    let onMaxMessageSizeChange: ((Int) -> Void)?
    let voiceOutputManager: VoiceOutputManager?
    let onAPIKeyChanged: (() -> Void)?

    var body: some View {
        NavigationView {
            Form {
                APIKeySection(onKeyChanged: onAPIKeyChanged, apiKeyInput: $pendingAPIKeyInput)

                Section(header: Text("Server Configuration")) {
                    TextField("Server Address", text: $settings.serverURL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)

                    TextField("Port", text: $settings.serverPort)
                        .keyboardType(.numberPad)

                    Text("Full URL: \(settings.fullServerURL)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("Voice Selection")) {
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
                            } else {
                                Image(systemName: "speaker.wave.2.fill")
                            }
                        }
                    }
                    .disabled(previewingVoice)

                    Text("Premium voices require download in Settings → Accessibility → Spoken Content → Voices")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("Audio Playback")) {
                    Toggle("Silence speech when phone is on vibrate", isOn: $settings.respectSilentMode)

                    Text("When enabled, speech will not play when your phone's ringer switch is on silent/vibrate")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Continue playback when locked", isOn: $settings.continuePlaybackWhenLocked)

                    Text("When enabled, audio will continue playing even when you lock your screen")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("Recent")) {
                    Stepper("Show \(settings.recentSessionsLimit) sessions", value: $settings.recentSessionsLimit, in: 1...20)

                    Text("Number of recent sessions to display in the Projects view")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("Queue")) {
                    Toggle("Enable Queue", isOn: $settings.queueEnabled)

                    Text("Show threads in queue on the Projects view. Threads are added when you send a message and removed manually.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("Priority Queue")) {
                    Toggle("Enable Priority Queue", isOn: $settings.priorityQueueEnabled)

                    Text("Track sessions in priority-based queue. Add sessions manually via toolbar button and adjust priorities to control sort order. Lower numbers = higher priority.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("Resources")) {
                    TextField("Storage Location", text: $settings.resourceStorageLocation)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                    Text("Directory where uploaded files will be saved on the backend")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("Message Size Limit")) {
                    Stepper("\(settings.maxMessageSizeKB) KB", value: $settings.maxMessageSizeKB, in: 50...250, step: 10)
                        .onChange(of: settings.maxMessageSizeKB) { newValue in
                            onMaxMessageSizeChange?(newValue)
                        }

                    Text("Maximum WebSocket message size. Large responses will be truncated to fit. iOS has a 256 KB limit.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("System Prompt")) {
                    TextField("Custom System Prompt", text: $localSystemPrompt, axis: .vertical)
                        .lineLimit(3...6)
                        .autocapitalization(.sentences)
                        .onChange(of: localSystemPrompt) { newValue in
                            settings.systemPrompt = newValue
                        }

                    Text("Optional instructions to append to Claude's system prompt on every message. Leave empty to use default behavior.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("Connection Test")) {
                    Button(action: testConnection) {
                        HStack {
                            Text("Test Connection")
                            Spacer()
                            if testingConnection {
                                ProgressView()
                            } else if let result = testResult {
                                Image(systemName: testSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundColor(testSuccess ? .green : .red)
                            }
                        }
                    }
                    .disabled(testingConnection)

                    if let result = testResult {
                        Text(result)
                            .font(.caption)
                            .foregroundColor(testSuccess ? .green : .red)
                    }
                }

                Section(header: Text("Help")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Server Setup")
                            .font(.headline)
                        Text("1. Start the backend server on your computer")
                        Text("2. Find your server's IP address")
                        Text("3. Enter that IP address above (e.g., 192.168.1.100)")
                        Text("4. Make sure your server is running on the specified port")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                Section(header: Text("Examples")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Local network: 192.168.1.100")
                        Text("Localhost: 127.0.0.1 (testing only)")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        // Save pending API key if there is one
                        if !pendingAPIKeyInput.isEmpty {
                            if KeychainManager.shared.isValidAPIKeyFormat(pendingAPIKeyInput) {
                                try? KeychainManager.shared.saveAPIKey(pendingAPIKeyInput)
                                pendingAPIKeyInput = ""
                                onAPIKeyChanged?()
                            } else {
                                // Show error alert for invalid API key format
                                showingAPIKeyError = true
                                return
                            }
                        }
                        // Settings auto-save via didSet
                        onServerChange(settings.fullServerURL)
                        dismiss()
                    }
                }
            }
            .onAppear {
                // Initialize local state from settings
                localSystemPrompt = settings.systemPrompt
            }
            .alert("Invalid API Key", isPresented: $showingAPIKeyError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("API key must start with 'voice-code-' and be 43 characters.")
            }
        }
    }

    func testConnection() {
        testingConnection = true
        testResult = nil

        settings.testConnection { success, message in
            testingConnection = false
            testSuccess = success
            testResult = message
        }
    }

    func previewVoice() {
        guard let manager = voiceOutputManager else { return }

        previewingVoice = true

        let previewText = "Hello! This is a preview of the selected voice. Premium voices sound more natural and expressive."

        // Use speakWithVoice to preview the specific selected voice
        manager.speakWithVoice(previewText, voiceIdentifier: settings.selectedVoiceIdentifier)

        // Reset state after a delay (approximate speech duration)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            previewingVoice = false
        }
    }
}

// Preview for SwiftUI Canvas
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(
            settings: AppSettings(),
            onServerChange: { _ in },
            onMaxMessageSizeChange: nil,
            voiceOutputManager: nil,
            onAPIKeyChanged: nil
        )
    }
}
