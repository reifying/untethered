// VoiceOutputManager.swift
// Text-to-speech using AVSpeechSynthesizer

import Foundation
import AVFoundation
import Combine

/// Manages text-to-speech output with background playback support
///
/// Thread Safety: This class is isolated to the main actor since it updates
/// @Published properties for UI state. The AVSpeechSynthesizerDelegate methods
/// are marked nonisolated since they're called from the audio thread, and they
/// properly dispatch to the main thread when updating @Published properties.
@MainActor
class VoiceOutputManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private weak var appSettings: AppSettings?
    var onSpeechComplete: (() -> Void)?

    // Background playback support
    private var silencePlayer: AVAudioPlayer?
    private var keepAliveTimer: Timer?

    init(appSettings: AppSettings? = nil) {
        self.appSettings = appSettings
        super.init()
        synthesizer.delegate = self
        setupSilencePlayer()
    }

    private func setupSilencePlayer() {
        // Create a 100ms silent audio buffer
        let silenceDuration: TimeInterval = 0.1
        let sampleRate: Double = 44100.0
        let channelCount = 1
        let frameCount = UInt32(silenceDuration * sampleRate)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channelCount)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            print("Failed to create silent audio buffer")
            return
        }

        buffer.frameLength = frameCount
        // Buffer is already silent (zeros) by default

        // Create a temporary file for the silent audio
        let tempDir = FileManager.default.temporaryDirectory
        let silenceURL = tempDir.appendingPathComponent("silence.caf")

        do {
            // Write the silent buffer to a file
            let audioFile = try AVAudioFile(forWriting: silenceURL, settings: format.settings)
            try audioFile.write(from: buffer)

            // Create player with the silent audio file
            silencePlayer = try AVAudioPlayer(contentsOf: silenceURL)
            silencePlayer?.prepareToPlay()
        } catch {
            print("Failed to setup silence player: \(error)")
        }
    }

    // MARK: - Background Playback Support

    private func startKeepAliveTimer() {
        // Only start timer if user wants background playback
        guard appSettings?.continuePlaybackWhenLocked ?? true else { return }

        stopKeepAliveTimer()

        // Play silent audio every 25 seconds to keep the audio session alive
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.playSilence()
            }
        }
    }

    private func stopKeepAliveTimer() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }

    private func playSilence() {
        silencePlayer?.play()
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
            // Use .playback category if user wants audio to continue when locked
            // Otherwise use .ambient which stops when screen locks
            let category: AVAudioSession.Category = (appSettings?.continuePlaybackWhenLocked ?? true) ? .playback : .ambient
            try audioSession.setCategory(category, mode: .spokenAudio, options: [])
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
        stopKeepAliveTimer()
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

    // Delegate methods are called from the audio thread, so they must be nonisolated.
    // They dispatch to main thread when updating @Published properties.

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = true
            // Start keep-alive timer for long TTS playback
            self.startKeepAliveTimer()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            // Stop keep-alive timer
            self.stopKeepAliveTimer()

            // Only deactivate audio session if background playback is disabled
            // Keeping it active when locked allows subsequent TTS to play without app suspension
            if !(self.appSettings?.continuePlaybackWhenLocked ?? true) {
                let audioSession = AVAudioSession.sharedInstance()
                do {
                    try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                } catch {
                    print("Failed to deactivate audio session: \(error)")
                }
            }

            self.isSpeaking = false
            self.onSpeechComplete?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            // Stop keep-alive timer
            self.stopKeepAliveTimer()
            self.isSpeaking = false
        }
    }

    // deinit is nonisolated, so we need to be careful about calling MainActor-isolated methods
    deinit {
        // Note: We can't safely call stopKeepAliveTimer() or check synthesizer state from deinit
        // since it's not isolated to the main actor. The timer will be cleaned up when released.
        // This is acceptable since VoiceOutputManager is typically a singleton that lives for
        // the app lifetime.
    }
}
