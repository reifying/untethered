// VoiceOutputManager.swift
// Text-to-speech using AVSpeechSynthesizer

import Foundation
import AVFoundation
import Combine

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

    // MARK: - Speech Control

    /// Speak text using the user's configured voice from AppSettings
    /// - Parameters:
    ///   - text: The text to speak
    ///   - rate: Speech rate (default: 0.5)
    func speak(_ text: String, rate: Float = 0.5) {
        let voiceIdentifier = appSettings?.selectedVoiceIdentifier
        speakWithVoice(text, rate: rate, voiceIdentifier: voiceIdentifier)
    }

    /// Speak text with a specific voice identifier (for special cases like voice preview)
    /// - Parameters:
    ///   - text: The text to speak
    ///   - rate: Speech rate (default: 0.5)
    ///   - voiceIdentifier: Optional voice identifier to use instead of user's configured voice
    func speakWithVoice(_ text: String, rate: Float = 0.5, voiceIdentifier: String? = nil) {
        // Stop any ongoing speech
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        // Configure audio session for playback
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playback, mode: .default, options: [])
            try audioSession.setActive(true)
        } catch {
            print("Failed to setup audio session: \(error)")
            return
        }

        // Create utterance
        let utterance = AVSpeechUtterance(string: text)

        // Select voice based on identifier, or use default
        if let identifier = voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            utterance.voice = voice
            print("Using voice: \(voice.name) [\(voice.language)]")
        } else {
            // Fallback to default en-US voice
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            print("Using default en-US voice")
        }

        utterance.rate = rate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        // Speak
        synthesizer.speak(utterance)

        DispatchQueue.main.async {
            self.isSpeaking = true
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        DispatchQueue.main.async {
            self.isSpeaking = false
        }
    }

    func pause() {
        synthesizer.pauseSpeaking(at: .word)
    }

    func resume() {
        synthesizer.continueSpeaking()
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = true
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // Reset audio session
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }

        DispatchQueue.main.async {
            self.isSpeaking = false
            self.onSpeechComplete?()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
        }
    }

    deinit {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }
}
