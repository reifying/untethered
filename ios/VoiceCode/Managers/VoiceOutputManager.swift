// VoiceOutputManager.swift
// Text-to-speech using AVSpeechSynthesizer

import Foundation
import AVFoundation
import Combine
import os.log

private let logger = Logger(subsystem: "dev.910labs.voice-code", category: "VoiceOutput")

class VoiceOutputManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private weak var appSettings: AppSettings?
    var onSpeechComplete: (() -> Void)?

    // iOS-only: Audio session manager for silent switch handling
    #if os(iOS)
    private let audioSessionManager = DeviceAudioSessionManager()
    #endif

    // iOS-only: Background playback support
    #if os(iOS)
    private var silencePlayer: AVAudioPlayer?
    private var keepAliveTimer: Timer?
    #endif

    init(appSettings: AppSettings? = nil) {
        self.appSettings = appSettings
        super.init()
        synthesizer.delegate = self
        #if os(iOS)
        setupSilencePlayer()
        #endif
    }

    // MARK: - iOS Background Playback Support

    #if os(iOS)
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

    private func startKeepAliveTimer() {
        // Only start timer if user wants background playback
        guard appSettings?.continuePlaybackWhenLocked ?? true else { return }

        stopKeepAliveTimer()

        // Play silent audio every 25 seconds to keep the audio session alive
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: true) { [weak self] _ in
            self?.playSilence()
        }
    }

    private func stopKeepAliveTimer() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }

    private func playSilence() {
        silencePlayer?.play()
    }
    #endif

    // MARK: - Speech Control

    /// Speak text using the user's configured voice from AppSettings
    /// - Parameters:
    ///   - text: The text to speak
    ///   - rate: Speech rate (default: 0.5)
    ///   - respectSilentMode: Whether to respect silent mode setting (default: false for manual actions)
    ///   - workingDirectory: Optional working directory for voice rotation when "All Premium Voices" is selected
    func speak(_ text: String, rate: Float = 0.5, respectSilentMode: Bool = false, workingDirectory: String? = nil) {
        let voiceIdentifier = appSettings?.resolveVoiceIdentifier(forWorkingDirectory: workingDirectory)
        speakWithVoice(text, rate: rate, voiceIdentifier: voiceIdentifier, respectSilentMode: respectSilentMode)
    }

    /// Speak text with a specific voice identifier (for special cases like voice preview)
    /// - Parameters:
    ///   - text: The text to speak
    ///   - rate: Speech rate (default: 0.5)
    ///   - voiceIdentifier: Optional voice identifier to use instead of user's configured voice
    ///   - respectSilentMode: Whether to respect the silent mode setting (default: false for manual actions)
    func speakWithVoice(_ text: String, rate: Float = 0.5, voiceIdentifier: String? = nil, respectSilentMode: Bool = false) {
        // Stop any ongoing speech
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        #if os(iOS)
        // iOS requires explicit audio session configuration
        do {
            let shouldRespectSilentMode = respectSilentMode && (appSettings?.respectSilentMode ?? true)

            if shouldRespectSilentMode {
                // Use .ambient category which respects the silent switch
                // Audio will not play when the ringer switch is on silent/vibrate
                try audioSessionManager.configureAudioSessionForSilentMode()
            } else {
                // Use .playback category which ignores the silent switch
                // Audio plays regardless of ringer switch position
                try audioSessionManager.configureAudioSessionForForcedPlayback()
            }

            // Note: continuePlaybackWhenLocked is handled by the category choice:
            // - .ambient stops when screen locks (regardless of setting)
            // - .playback can continue when locked (if iOS allows background audio)
            // For silent mode respect, we always use .ambient, which takes precedence
        } catch {
            print("Failed to setup audio session: \(error)")
            return
        }
        #endif
        // macOS: No audio session management needed, AVSpeechSynthesizer works directly

        // Create utterance
        let utterance = AVSpeechUtterance(string: text)

        // Select voice based on identifier, or use default
        if let identifier = voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            utterance.voice = voice
            logger.info("🔊 Using voice: \(voice.name, privacy: .public) [\(voice.language, privacy: .public)]")
        } else if let voiceIdentifier = voiceIdentifier {
            // Voice identifier was provided but not found
            logger.warning("⚠️ Voice not found for identifier: \(voiceIdentifier, privacy: .public), trying fallback")
            // Try en-US first
            if let enUSVoice = AVSpeechSynthesisVoice(language: "en-US") {
                utterance.voice = enUSVoice
                logger.info("🔊 Using fallback en-US voice: \(enUSVoice.name, privacy: .public)")
            } else {
                // Use system default
                logger.warning("⚠️ en-US voice not available, using system default")
                utterance.voice = nil  // AVSpeechSynthesizer will use system default
            }
        } else {
            // No voice identifier provided, use en-US or system default
            if let enUSVoice = AVSpeechSynthesisVoice(language: "en-US") {
                utterance.voice = enUSVoice
                logger.info("🔊 Using default en-US voice: \(enUSVoice.name, privacy: .public)")
            } else {
                logger.warning("⚠️ en-US voice not available, using system default")
                utterance.voice = nil  // AVSpeechSynthesizer will use system default
            }
        }

        utterance.rate = rate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        // Speak
        logger.info("🔊 Invoking synthesizer.speak() with text length: \(text.count), voice: \(utterance.voice?.name ?? "system default", privacy: .public)")
        synthesizer.speak(utterance)

        DispatchQueue.main.async {
            self.isSpeaking = true
        }
    }

    func stop() {
        #if os(iOS)
        stopKeepAliveTimer()
        #endif
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
        logger.info("🔊 Speech STARTED: \(utterance.speechString.prefix(50), privacy: .public)...")
        DispatchQueue.main.async {
            self.isSpeaking = true
        }
        #if os(iOS)
        // Start keep-alive timer for long TTS playback
        startKeepAliveTimer()
        #endif
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        logger.info("🔊 Speech FINISHED")
        #if os(iOS)
        // Stop keep-alive timer
        stopKeepAliveTimer()

        // Only deactivate audio session if background playback is disabled
        // Keeping it active when locked allows subsequent TTS to play without app suspension
        if !(appSettings?.continuePlaybackWhenLocked ?? true) {
            let audioSession = AVAudioSession.sharedInstance()
            do {
                try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                logger.error("Failed to deactivate audio session: \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif

        DispatchQueue.main.async {
            self.isSpeaking = false
            self.onSpeechComplete?()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        logger.info("🔊 Speech CANCELLED")
        #if os(iOS)
        // Stop keep-alive timer
        stopKeepAliveTimer()
        #endif

        DispatchQueue.main.async {
            self.isSpeaking = false
        }
    }

    deinit {
        #if os(iOS)
        stopKeepAliveTimer()
        #endif
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }
}
