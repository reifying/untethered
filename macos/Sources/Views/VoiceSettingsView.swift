// VoiceSettingsView.swift
// Voice settings tab for TTS configuration

import SwiftUI
import AVFoundation
import UntetheredCore

struct VoiceSettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var speechRate: Double = 0.5
    @StateObject private var voiceOutputManager = VoiceOutputManager()

    var body: some View {
        Form {
            Section(header: Text("Playback")) {
                Toggle("Auto-play Responses", isOn: $settings.autoPlayResponses)
                Text("Automatically speak assistant responses when they arrive")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Voice Selection")) {
                Picker("Voice:", selection: $settings.selectedVoiceIdentifier) {
                    // "All Premium Voices" rotation option
                    Text("All Premium Voices (Rotate)")
                        .tag(AppSettings.allPremiumVoicesIdentifier as String?)

                    Divider()

                    // Individual voices
                    ForEach(AppSettings.availableVoices, id: \.identifier) { voice in
                        Text(voice.name)
                            .tag(voice.identifier as String?)
                    }
                }
                .pickerStyle(.menu)

                Button("Test Voice") {
                    testVoice()
                }
                .disabled(settings.selectedVoiceIdentifier == nil)

                Text("Select a voice for text-to-speech or choose 'All Premium Voices' to rotate based on project")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Speech Rate")) {
                HStack {
                    Text("0.5x")
                        .font(.caption)
                    Slider(value: $speechRate, in: 0.5...2.0, step: 0.1)
                    Text("2.0x")
                        .font(.caption)
                    Text(String(format: "%.1fx", speechRate))
                        .frame(width: 40)
                        .font(.caption)
                }
                Text("Adjust speaking speed (default: 0.5x)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .onAppear {
            // Load speech rate
            speechRate = UserDefaults.standard.double(forKey: "speechRate")
            if speechRate == 0 {
                speechRate = 0.5
            }
        }
        .onChange(of: speechRate) { newRate in
            UserDefaults.standard.set(newRate, forKey: "speechRate")
        }
    }

    private func testVoice() {
        let testMessage = "Hello! This is a test of the selected voice."

        // Resolve the voice identifier
        let voiceIdentifier = settings.resolveVoiceIdentifier(forWorkingDirectory: nil)

        // Create utterance
        let utterance = AVSpeechUtterance(string: testMessage)
        utterance.rate = Float(speechRate)

        if let identifier = voiceIdentifier {
            utterance.voice = AVSpeechSynthesisVoice(identifier: identifier)
        }

        voiceOutputManager.speak(testMessage)
    }
}
