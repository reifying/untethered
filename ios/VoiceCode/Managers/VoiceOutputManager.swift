// VoiceOutputManager.swift
// Text-to-speech using AVSpeechSynthesizer

import Foundation
import AVFoundation
import Combine
import os.log
import ObjectiveC.runtime

private let logger = Logger(subsystem: "dev.910labs.voice-code", category: "VoiceOutput")

// Per-utterance session tag, attached via associated objects. Lets the
// AVSpeechSynthesizerDelegate callbacks identify which session an utterance
// was enqueued for without subclassing AVSpeechUtterance.
private var avSpeechUtteranceSessionIdKey: UInt8 = 0

extension AVSpeechUtterance {
    var voiceCodeSessionId: UUID? {
        get { objc_getAssociatedObject(self, &avSpeechUtteranceSessionIdKey) as? UUID }
        set { objc_setAssociatedObject(self, &avSpeechUtteranceSessionIdKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

class VoiceOutputManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var isSpeaking = false

    /// When muted, all speech requests are silently ignored (macOS only)
    #if os(macOS)
    @Published var isMuted: Bool {
        didSet {
            UserDefaults.standard.set(isMuted, forKey: "voiceOutputMuted")
            if isMuted {
                // Stop any current speech when muting
                stop()
            }
        }
    }
    #endif

    private let synthesizer = AVSpeechSynthesizer()
    private weak var appSettings: AppSettings?
    var onSpeechComplete: (() -> Void)?

    // Session UUID of the utterance currently held by the synthesizer, or nil
    // when idle / when the active utterance has no session affinity (voice
    // preview, notification "read aloud" action). Updated synchronously in
    // speakWithVoice (so a focus change racing the speak call still observes
    // the new tag) and cleared from didCancel/didFinish only when the
    // finishing utterance's tag matches — that match-and-clear protects
    // against the line-148 self-preempt race where didCancel for an old
    // utterance can fire after the next speak has already updated the tag.
    private(set) var inFlightSessionId: UUID?
    private var activeSessionCancellable: AnyCancellable?

    // Set when stop(completion:) is called while the synthesizer is mid-utterance.
    // Fired from didCancel/didFinish (or a safety-timeout) so the audio session is
    // fully released before the caller — typically VoiceInputManager — reconfigures
    // it for recording. All access is on the main queue.
    private var pendingStopCompletion: (() -> Void)?
    private var pendingStopTimeoutItem: DispatchWorkItem?

    // iOS-only: Audio session manager for silent switch handling
    #if os(iOS)
    private let audioSessionManager = DeviceAudioSessionManager()
    #endif

    // iOS-only: Background playback support
    #if os(iOS)
    private var silencePlayer: AVAudioPlayer?
    private var keepAliveTimer: Timer?
    #endif

    init(appSettings: AppSettings? = nil,
         activeSession: ActiveSessionManager = .shared) {
        self.appSettings = appSettings
        #if os(macOS)
        self.isMuted = UserDefaults.standard.bool(forKey: "voiceOutputMuted")
        #endif
        super.init()
        synthesizer.delegate = self
        #if os(iOS)
        setupSilencePlayer()
        #endif

        // Cancel any in-flight TTS when the user switches focus to a different
        // session (or back to the home screen). Skip when there is no
        // session-tagged utterance playing (e.g. voice preview from Settings).
        activeSessionCancellable = activeSession.$activeSessionId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] activeId in
                self?.handleActiveSessionChange(activeId)
            }
    }

    private func handleActiveSessionChange(_ activeId: UUID?) {
        guard let inFlight = inFlightSessionId, inFlight != activeId else { return }
        logger.info("🔇 Active session changed (in-flight: \(inFlight.uuidString.lowercased(), privacy: .public), now: \(activeId?.uuidString.lowercased() ?? "nil", privacy: .public)); stopping TTS")
        synthesizer.stopSpeaking(at: .immediate)
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
    ///   - sessionId: Originating session UUID. Pass nil for non-session speech (voice preview,
    ///     notification action). When non-nil, the utterance will be auto-cancelled if the active
    ///     session changes before it finishes.
    func speak(_ text: String, rate: Float = 0.5, respectSilentMode: Bool = false, workingDirectory: String? = nil, sessionId: UUID? = nil) {
        let voiceIdentifier = appSettings?.resolveVoiceIdentifier(forWorkingDirectory: workingDirectory)
        speakWithVoice(text, rate: rate, voiceIdentifier: voiceIdentifier, respectSilentMode: respectSilentMode, sessionId: sessionId)
    }

    /// Speak text with a specific voice identifier (for special cases like voice preview)
    /// - Parameters:
    ///   - text: The text to speak
    ///   - rate: Speech rate (default: 0.5)
    ///   - voiceIdentifier: Optional voice identifier to use instead of user's configured voice
    ///   - respectSilentMode: Whether to respect the silent mode setting (default: false for manual actions)
    ///   - sessionId: Originating session UUID for auto-cancellation on focus change. Nil for
    ///     non-session speech.
    func speakWithVoice(_ text: String, rate: Float = 0.5, voiceIdentifier: String? = nil, respectSilentMode: Bool = false, sessionId: UUID? = nil) {
        #if os(macOS)
        // When muted, silently ignore all speech requests
        if isMuted {
            logger.info("🔇 Speech muted, ignoring request")
            return
        }
        #endif

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

        // Create utterance and tag with originating session for didFinish/didCancel matching
        let utterance = AVSpeechUtterance(string: text)
        utterance.voiceCodeSessionId = sessionId

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

        // Set in-flight tag synchronously so a focus change racing this call
        // observes the new session, not the previous utterance's session.
        // didCancel for any preempted prior utterance will compare against
        // this new value and skip clearing it.
        inFlightSessionId = sessionId

        // Speak
        logger.info("🔊 Invoking synthesizer.speak() with text length: \(text.count), voice: \(utterance.voice?.name ?? "system default", privacy: .public)")
        synthesizer.speak(utterance)

        DispatchQueue.main.async {
            self.isSpeaking = true
        }
    }

    func stop() {
        stop(completion: nil)
    }

    /// Stop any in-flight TTS, invoking `completion` on the main queue once the
    /// synthesizer has actually released its audio resources (didCancel/didFinish),
    /// or after a 300ms safety timeout. If nothing was speaking, `completion` runs
    /// on the next main-queue tick.
    ///
    /// Callers that need the audio session free before reconfiguring it (e.g.
    /// VoiceInputManager flipping AVAudioSession to .record) must use this form.
    func stop(completion: (() -> Void)?) {
        #if os(iOS)
        stopKeepAliveTimer()
        #endif

        let wasSpeaking = synthesizer.isSpeaking

        if wasSpeaking {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.pendingStopTimeoutItem?.cancel()
                self.pendingStopCompletion = completion

                if completion != nil {
                    let timeoutItem = DispatchWorkItem { [weak self] in
                        guard let self = self else { return }
                        let cb = self.pendingStopCompletion
                        self.pendingStopCompletion = nil
                        self.pendingStopTimeoutItem = nil
                        cb?()
                    }
                    self.pendingStopTimeoutItem = timeoutItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: timeoutItem)
                }
            }
            synthesizer.stopSpeaking(at: .immediate)
            DispatchQueue.main.async {
                self.isSpeaking = false
            }
        } else {
            DispatchQueue.main.async {
                self.isSpeaking = false
                completion?()
            }
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

        let finishedSessionId = utterance.voiceCodeSessionId
        DispatchQueue.main.async {
            self.isSpeaking = false
            self.clearInFlightIfMatches(finishedSessionId)
            self.onSpeechComplete?()
            self.firePendingStopCompletion()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        logger.info("🔊 Speech CANCELLED")
        #if os(iOS)
        // Stop keep-alive timer
        stopKeepAliveTimer()
        #endif

        let cancelledSessionId = utterance.voiceCodeSessionId
        DispatchQueue.main.async {
            self.isSpeaking = false
            self.clearInFlightIfMatches(cancelledSessionId)
            self.firePendingStopCompletion()
        }
    }

    /// Clear inFlightSessionId iff it still matches the utterance that just
    /// ended. Skipping the clear when it doesn't match preserves the
    /// already-updated tag set by a follow-up `speakWithVoice` call (the
    /// line-148 self-preempt race).
    private func clearInFlightIfMatches(_ utteranceSessionId: UUID?) {
        if inFlightSessionId == utteranceSessionId {
            inFlightSessionId = nil
        }
    }

    /// Called on the main queue from didCancel/didFinish so a stop(completion:)
    /// caller can proceed once the synthesizer has actually released its audio
    /// resources. Safe to call when nothing is pending.
    private func firePendingStopCompletion() {
        pendingStopTimeoutItem?.cancel()
        pendingStopTimeoutItem = nil
        let cb = pendingStopCompletion
        pendingStopCompletion = nil
        cb?()
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
