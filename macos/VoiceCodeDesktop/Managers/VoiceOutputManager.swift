// VoiceOutputManager.swift
// Text-to-speech using AVSpeechSynthesizer for macOS

import Foundation
import AVFoundation
import Combine

/// macOS-specific voice output manager
/// Uses AVSpeechSynthesizer without iOS-specific AVAudioSession handling
class VoiceOutputManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private weak var appSettings: AppSettings?
    var onSpeechComplete: (() -> Void)?

    init(appSettings: AppSettings? = nil) {
        self.appSettings = appSettings
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Public API

    /// Speak the given text
    /// - Parameters:
    ///   - text: The text to speak
    ///   - respectSilentMode: Not used on macOS (no silent mode concept)
    ///   - workingDirectory: Used for voice rotation when "All Premium Voices" is selected
    func speak(_ text: String, respectSilentMode: Bool = false, workingDirectory: String = "") {
        // Stop any current speech
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)

        // Resolve voice identifier using voice rotation logic
        let workingDir = workingDirectory.isEmpty ? nil : workingDirectory
        if let voiceIdentifier = appSettings?.resolveVoiceIdentifier(forWorkingDirectory: workingDir) {
            utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
        }

        // Default rate and pitch
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0

        isSpeaking = true
        synthesizer.speak(utterance)
    }

    /// Stop any current speech
    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            self?.isSpeaking = false
            self?.onSpeechComplete?()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            self?.isSpeaking = false
        }
    }
}
