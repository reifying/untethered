// VoiceOutputManager.swift
// Text-to-speech using AVSpeechSynthesizer

import Foundation
import AVFoundation
import Combine
import ObjectiveC.runtime

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

    /// When true, all speech requests are silently dropped. Set by VoiceInputManager
    /// when recording starts; cleared when recording stops or fails to start.
    /// Unlike `isMuted` (macOS-only, user-toggled, persisted), this is automatic,
    /// cross-platform, and transient. Plain `var` (internal) so VoiceInputManager
    /// can set it from a different file.
    var isRecordingActive = false

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
        let inFlightStr = inFlightSessionId?.uuidString.lowercased() ?? "nil"
        let activeStr = activeId?.uuidString.lowercased() ?? "nil"
        LogManager.shared.log("🎯 handleActiveSessionChange: inFlight=\(inFlightStr) active=\(activeStr)", category: "VoiceOutput")
        // Only cancel on transitions to a DIFFERENT non-nil session. Ignoring
        // nil transitions avoids false positives from SwiftUI firing
        // onDisappear during transient view rebuilds (sheet presentation,
        // partial swipe-back gestures, etc.) — those would otherwise kill
        // TTS for the session the user is still looking at. AC2 ("navigate
        // to home stops TTS") is sacrificed for now in favor of AC1
        // ("navigate to a different session stops TTS"); a follow-up can
        // restore home-stops behavior once we have a more reliable
        // "user is no longer in any session" signal.
        guard let newActive = activeId else { return }
        guard let inFlight = inFlightSessionId, inFlight != newActive else { return }
        LogManager.shared.log("🔇 STOPPING TTS — in-flight \(inFlight.uuidString.lowercased()) != active \(activeStr)", category: "VoiceOutput")
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
            LogManager.shared.log("Failed to create silent audio buffer", category: "VoiceOutput")
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
            LogManager.shared.log("Failed to setup silence player: \(error)", category: "VoiceOutput")
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
            LogManager.shared.log("🔇 Speech muted, ignoring request", category: "VoiceOutput")
            return
        }
        #endif

        // Suppress all speech while the microphone is recording — playing TTS
        // into the open mic creates a feedback loop. Drop the request (don't queue).
        if isRecordingActive {
            LogManager.shared.log("🔇 Speech suppressed — recording active, dropping request", category: "VoiceOutput")
            return
        }

        // Stop any ongoing speech
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        #if os(iOS)
        // When headset mode is active, HeadsetRemoteCommandManager owns the audio
        // session in .playAndRecord — switching to .playback/.ambient here would
        // cause iOS to re-evaluate the Now Playing slot and potentially hand AVRCP
        // routing to another app, making AirPod stem clicks unresponsive during TTS.
        // AVSpeechSynthesizer works fine under .playAndRecord so we skip the switch.
        if appSettings?.headsetModeEnabled != true {
            do {
                let shouldRespectSilentMode = respectSilentMode && (appSettings?.respectSilentMode ?? true)

                if shouldRespectSilentMode {
                    try audioSessionManager.configureAudioSessionForSilentMode()
                    let msg = "VoiceOutput: audio session → .ambient/.spokenAudio (silentMode)"
                    LogManager.shared.log(msg, category: "VoiceOutput")
                } else {
                    try audioSessionManager.configureAudioSessionForForcedPlayback()
                    let msg = "VoiceOutput: audio session → .playback/.spokenAudio (forcedPlayback)"
                    LogManager.shared.log(msg, category: "VoiceOutput")
                }
            } catch {
                LogManager.shared.log("Failed to setup audio session: \(error)", category: "VoiceOutput")
                return
            }
        } else {
            let msg = "VoiceOutput: headset mode active — keeping .playAndRecord session"
            LogManager.shared.log(msg, category: "VoiceOutput")
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
            LogManager.shared.log("🔊 Using voice: \(voice.name) [\(voice.language)]", category: "VoiceOutput")
        } else if let voiceIdentifier = voiceIdentifier {
            // Voice identifier was provided but not found
            LogManager.shared.log("⚠️ Voice not found for identifier: \(voiceIdentifier), trying fallback", category: "VoiceOutput")
            // Try en-US first
            if let enUSVoice = AVSpeechSynthesisVoice(language: "en-US") {
                utterance.voice = enUSVoice
                LogManager.shared.log("🔊 Using fallback en-US voice: \(enUSVoice.name)", category: "VoiceOutput")
            } else {
                // Use system default
                LogManager.shared.log("⚠️ en-US voice not available, using system default", category: "VoiceOutput")
                utterance.voice = nil  // AVSpeechSynthesizer will use system default
            }
        } else {
            // No voice identifier provided, use en-US or system default
            if let enUSVoice = AVSpeechSynthesisVoice(language: "en-US") {
                utterance.voice = enUSVoice
                LogManager.shared.log("🔊 Using default en-US voice: \(enUSVoice.name)", category: "VoiceOutput")
            } else {
                LogManager.shared.log("⚠️ en-US voice not available, using system default", category: "VoiceOutput")
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
        LogManager.shared.log("🔊 Invoking synthesizer.speak() with text length: \(text.count), voice: \(utterance.voice?.name ?? "system default"), sessionId: \(sessionId?.uuidString.lowercased() ?? "nil")", category: "VoiceOutput")
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
        // resume() bypasses speakWithVoice(), so it would otherwise play into an
        // open mic during recording. Guard it explicitly.
        guard !isRecordingActive else { return }
        synthesizer.continueSpeaking()
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        LogManager.shared.log("🔊 Speech STARTED: \(utterance.speechString.prefix(50))...", category: "VoiceOutput")
        DispatchQueue.main.async {
            self.isSpeaking = true
        }
        #if os(iOS)
        // Start keep-alive timer for long TTS playback
        startKeepAliveTimer()
        #endif
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        LogManager.shared.log("🔊 Speech FINISHED", category: "VoiceOutput")
        #if os(iOS)
        // Stop keep-alive timer
        stopKeepAliveTimer()

        // When headset mode is active, HeadsetRemoteCommandManager owns the session
        // lifecycle — deactivating here would kill the Now Playing slot.
        if appSettings?.headsetModeEnabled != true,
           !(appSettings?.continuePlaybackWhenLocked ?? true) {
            let audioSession = AVAudioSession.sharedInstance()
            do {
                try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                LogManager.shared.log("Failed to deactivate audio session: \(error.localizedDescription)", category: "VoiceOutput")
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
        LogManager.shared.log("🔊 Speech CANCELLED", category: "VoiceOutput")
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
