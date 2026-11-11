// NeuralVoiceSettingsSection.swift
// Settings: choose Kokoro or Apple's voice, and see Kokoro's model status.
// Design: docs/design/kokoro-neural-voice.md

#if os(iOS) && canImport(FluidAudio)
import SwiftUI

struct NeuralVoiceSettingsSection: View {
    @ObservedObject private var engine = KokoroSpeechEngine.shared
    @AppStorage(NeuralVoiceSettings.engineKey) private var engineChoice = NeuralVoiceSettings.kokoro
    let voiceOutputManager: VoiceOutputManager?

    private let previewText = "Hello! This is Kokoro, the neural voice that now reads your replies."

    var body: some View {
        Section(header: Text("Voice Engine"), footer: Text(footer)) {
            Picker("Engine", selection: $engineChoice) {
                Text("Kokoro (Heart)").tag(NeuralVoiceSettings.kokoro)
                Text("Apple").tag(NeuralVoiceSettings.apple)
            }
            .onChange(of: engineChoice) { _, _ in engine.selectionChanged() }

            if engineChoice == NeuralVoiceSettings.kokoro {
                HStack {
                    Text("Status")
                    Spacer()
                    if engine.state == .downloading || engine.state == .loading {
                        ProgressView().padding(.trailing, 4)
                    }
                    Text(statusText)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                switch engine.state {
                case .waitingForWiFi:
                    Button("Download now (about 100 MB)") { engine.downloadNow() }
                case .failed, .idle:
                    Button("Retry") { engine.downloadNow() }
                case .turnedOffAfterCrashes:
                    Button("Turn Kokoro back on") { engine.turnBackOn() }
                case .ready:
                    Button(action: { voiceOutputManager?.speak(previewText) }) {
                        HStack {
                            Text("Preview Kokoro")
                            Spacer()
                            Image(systemName: "speaker.wave.2.fill")
                        }
                    }
                case .downloading, .loading:
                    EmptyView()
                }
            }
        }
    }

    private var statusText: String {
        switch engine.state {
        case .idle: return "Not loaded"
        case .waitingForWiFi: return "Waiting for Wi-Fi to download"
        case .downloading: return "Downloading"
        case .loading: return "Loading"
        case .ready: return "Ready"
        case .failed(let message): return "Failed: \(message)"
        case .turnedOffAfterCrashes: return "Turned off: the app quit twice while Kokoro was speaking"
        }
    }

    private var footer: String {
        if engineChoice == NeuralVoiceSettings.apple {
            return "Replies are read by the Apple voice below."
        }
        return "Kokoro is a neural voice that runs on this iPhone. Its model downloads once, over Wi-Fi. "
            + "Until it is ready, and whenever it can't speak, the Apple voice below reads instead."
    }
}
#endif
