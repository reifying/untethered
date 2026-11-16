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
private var avSpeechUtteranceGenerationKey: UInt8 = 0

extension AVSpeechUtterance {
    var voiceCodeSessionId: UUID? {
        get { objc_getAssociatedObject(self, &avSpeechUtteranceSessionIdKey) as? UUID }
        set { objc_setAssociatedObject(self, &avSpeechUtteranceSessionIdKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    // Monotonic tag identifying WHICH speak call produced this utterance, so a
    // delegate callback can be matched against the newest one. See
    // VoiceOutputManager.isCurrentGeneration(_:event:).
    var voiceCodeGeneration: UInt64? {
        get { objc_getAssociatedObject(self, &avSpeechUtteranceGenerationKey) as? UInt64 }
        set { objc_setAssociatedObject(self, &avSpeechUtteranceGenerationKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
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

    // Same surface as AVSpeechSynthesizer. On iOS it reads with Kokoro when that voice is
    // selected and loaded, otherwise with Apple's synthesizer, and reports the delegate
    // callbacks for the utterances handed to it either way. See SpeechSynthesizerRouter.
    private let synthesizer = SpeechSynthesizerRouter()
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

    /// One reply waiting its turn behind the utterance in flight.
    private struct PendingSpeech {
        let text: String
        let rate: Float
        let voiceIdentifier: String?
        let respectSilentMode: Bool
        let sessionId: UUID?
    }

    // Replies queued by `enqueue(...)`, oldest first, read one after another
    // once the utterance in flight finishes. All access is on the main queue.
    private var pendingSpeech: [PendingSpeech] = []

    // The utterance most recently handed to the synthesizer, until its
    // didFinish/didCancel. Set synchronously when speech starts, so unlike
    // `synthesizer.isSpeaking` (which flips true tens of milliseconds after
    // speak() returns) it is accurate the instant `enqueue` asks "is anything
    // being read?". Compared by identity in the delegate callbacks, so the
    // late didCancel of an utterance that a Read Aloud already replaced can't
    // advance or clear the queue. All access is on the main queue.
    private(set) var currentUtterance: AVSpeechUtterance?

    /// How many replies are waiting behind the one being read.
    var pendingSpeechCount: Int { pendingSpeech.count }

    /// Utterances the synthesizer finished reading in full (not cancelled).
    /// Lets tests assert that queued replies were each read to the end rather
    /// than cut off by the next one.
    private(set) var utterancesFinished = 0

    // iOS-only: Audio session manager for silent switch handling
    #if os(iOS)
    private let audioSessionManager = DeviceAudioSessionManager()

    /// Test seam for "where would this utterance come out". Production leaves it nil and
    /// reads the live route; tests inject a fixed answer so the headphones/car branches —
    /// the two cases whose behavior actually changed — are reachable without hardware.
    /// Mirrors `VoiceInputManager.prefersBluetoothHFPInput`.
    var outputIsPrivateListening: (() -> Bool)?
    #endif

    // Monotonic counter bumped synchronously by each accepted speakWithVoice call.
    // `synthesizer.isSpeaking` is NOT usable for "is an utterance live": it flips true
    // asynchronously, tens of milliseconds after speak() returns, so it reads false
    // during exactly the window that matters. All access is on the main queue.
    private var utteranceGeneration: UInt64 = 0

    /// True from the synchronous start of a `speakWithVoice` call until the
    /// didFinish/didCancel of THAT utterance. Unlike `isSpeaking` (a published mirror
    /// updated through async hops) and unlike `synthesizer.isSpeaking` (which lags the
    /// speak call), this is accurate the instant `speakWithVoice` returns, so `stop`
    /// can tell "queued but not yet started" from "genuinely idle".
    private(set) var hasUtteranceInFlight = false

    /// The synthesizer's own (lagging) view of whether it is producing audio. Exposed for
    /// tests that need to wait for speech to genuinely START; production code must use
    /// `hasUtteranceInFlight`, which is accurate the instant `speakWithVoice` returns.
    var isSynthesizerSpeakingForTests: Bool { synthesizer.isSpeaking }

    /// How many superseded utterance-end callbacks have been dropped. Lets a test assert
    /// that the preempt it set up actually happened, rather than passing because the
    /// synthesizer never started and no cancel was ever delivered.
    private(set) var staleUtteranceEndsDropped = 0

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
        // Replies queued for the session the user just left are not read.
        let queuedBefore = pendingSpeech.count
        pendingSpeech.removeAll { $0.sessionId != nil && $0.sessionId != newActive }
        if pendingSpeech.count != queuedBefore {
            LogManager.shared.log("🔇 Dropped \(queuedBefore - pendingSpeech.count) queued replies for a session no longer active", category: "VoiceOutput")
        }
        guard let inFlight = inFlightSessionId, inFlight != newActive else { return }
        LogManager.shared.log("🔇 STOPPING TTS — in-flight \(inFlight.uuidString.lowercased()) != active \(activeStr)", category: "VoiceOutput")
        currentUtterance = nil
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

    /// Like `speakWithVoice`, but always with Apple's synthesizer, even when the Kokoro voice
    /// is selected. For previewing an Apple voice in Settings.
    func speakWithAppleVoice(_ text: String, rate: Float = 0.5, voiceIdentifier: String? = nil) {
        synthesizer.forceAppleVoiceForNextUtterance = true
        defer { synthesizer.forceAppleVoiceForNextUtterance = false }
        speakWithVoice(text, rate: rate, voiceIdentifier: voiceIdentifier)
    }

    /// Read `text` after everything already being read or waiting has been read
    /// in full. Nothing is interrupted: if an utterance is in flight, `text`
    /// waits its turn, and each queued reply starts when the one before it
    /// finishes. `isSpeaking` stays true from the first reply to the end of the
    /// last, so observers (the headset state machine, the macOS output router)
    /// see one stretch of speech rather than a stop and start between replies.
    ///
    /// For replies that arrive while a session is open. An explicit request —
    /// Read Aloud, a voice preview — goes through `speak` instead, which takes
    /// over immediately and discards the queue; so do `stop()` and switching to
    /// a different session.
    ///
    /// Parameters as for `speak`.
    func enqueue(_ text: String, rate: Float = 0.5, respectSilentMode: Bool = false, workingDirectory: String? = nil, sessionId: UUID? = nil) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            LogManager.shared.log("🔇 Queued speech skipped — nothing to speak", category: "VoiceOutput")
            return
        }
        let item = PendingSpeech(
            text: text,
            rate: rate,
            voiceIdentifier: appSettings?.resolveVoiceIdentifier(forWorkingDirectory: workingDirectory),
            respectSilentMode: respectSilentMode,
            sessionId: sessionId
        )
        if currentUtterance == nil {
            startUtterance(item)
        } else {
            pendingSpeech.append(item)
            LogManager.shared.log("🔊 Reply queued behind the one being read (\(pendingSpeech.count) waiting)", category: "VoiceOutput")
        }
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
        // Nothing to say. A message that processes down to an empty string must
        // not reach startUtterance, which would preempt whatever is currently
        // being read and discard the queue for an utterance with no words in it.
        // Drop the request before touching any audio or queue state.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            LogManager.shared.log("🔇 Speech skipped — nothing to speak", category: "VoiceOutput")
            return
        }

        // An explicit request takes over now: queued replies are discarded
        // along with whatever is playing.
        discardPendingSpeech(reason: "explicit speak")
        startUtterance(PendingSpeech(text: text, rate: rate, voiceIdentifier: voiceIdentifier,
                                     respectSilentMode: respectSilentMode, sessionId: sessionId))
    }

    /// Read `text` again now, because the user asked to hear it again: the headset's
    /// repeat gesture, or a driving-mode replay tile. Whatever is being read is cut
    /// off. Replies still waiting their turn are kept and follow it, so asking to
    /// hear one reply again never loses another the user has not heard yet. (`speak`
    /// discards them; that is for Read Aloud, where the user chose one message.)
    ///
    /// Returns false when nothing was started: blank text, muted, or recording.
    @discardableResult
    func replay(_ text: String, rate: Float = 0.5, workingDirectory: String? = nil, sessionId: UUID? = nil) -> Bool {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            LogManager.shared.log("🔇 Replay skipped — nothing to speak", category: "VoiceOutput")
            return false
        }
        LogManager.shared.log("🔊 Replay requested (\(pendingSpeech.count) waiting replies kept)", category: "VoiceOutput")
        return startUtterance(PendingSpeech(
            text: text,
            rate: rate,
            voiceIdentifier: appSettings?.resolveVoiceIdentifier(forWorkingDirectory: workingDirectory),
            respectSilentMode: false,
            sessionId: sessionId))
    }

    /// Stop reading the current reply and go straight to the next one waiting. With
    /// nothing waiting, this is `stop()`.
    ///
    /// When there is a next reply, `isSpeaking` stays true across the skip, exactly
    /// as it does when one queued reply follows another: the skipped utterance's
    /// late cancel callback belongs to a superseded generation and is dropped.
    func skipCurrent() {
        if startNextPendingSpeech() {
            LogManager.shared.log("⏭ Skipped to the next queued reply", category: "VoiceOutput")
            return
        }
        stop()
    }

    /// Hand one utterance to the synthesizer, preempting anything it is still
    /// playing. Returns false when the request was dropped (muted, recording,
    /// or the audio session could not be set up) and nothing is in flight.
    @discardableResult
    private func startUtterance(_ item: PendingSpeech) -> Bool {
        let text = item.text
        let rate = item.rate
        let voiceIdentifier = item.voiceIdentifier
        let respectSilentMode = item.respectSilentMode
        let sessionId = item.sessionId

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            LogManager.shared.log("🔇 Speech skipped — nothing to speak", category: "VoiceOutput")
            return false
        }

        #if os(macOS)
        // When muted, silently ignore all speech requests
        if isMuted {
            LogManager.shared.log("🔇 Speech muted, ignoring request", category: "VoiceOutput")
            return false
        }
        #endif

        // Suppress all speech while the microphone is recording — playing TTS
        // into the open mic creates a feedback loop. Drop the request (don't queue).
        if isRecordingActive {
            LogManager.shared.log("🔇 Speech suppressed — recording active, dropping request", category: "VoiceOutput")
            return false
        }

        // Stop any ongoing speech. `hasUtteranceInFlight` is part of the condition for the
        // same reason `stop(completion:)` uses it: `synthesizer.isSpeaking` flips true
        // asynchronously, so in the window right after a speak it reads false while an
        // utterance IS queued. Testing it alone means this call does NOT preempt —
        // the new utterance queues BEHIND the old one, and both then play under whichever
        // category the LAST speak configured. An automatic reply that chose .ambient,
        // followed within that window by a Read Aloud that chose .playback, is spoken out
        // loud on vibrate. SessionSyncManager speaks every new assistant text in one
        // main-queue turn, so that window is hit routinely.
        if synthesizer.isSpeaking || hasUtteranceInFlight {
            synthesizer.stopSpeaking(at: .immediate)
        }

        #if os(iOS)
        // The ringer switch has no API, so the only lever on it is the session
        // category: .ambient is silenced by the switch, .playback and .playAndRecord
        // are not. DeviceAudioSessionManager.speechSessionPlan folds the three inputs
        // that matter — the setting, headset mode, and where the audio would actually
        // come out — into one decision. Headset mode is NOT allowed to short-circuit
        // it; that is what made the setting a no-op and let the phone talk out loud on
        // vibrate. When the route is a headset/car, the switch is overruled instead:
        // it silences the room, not the ear the user deliberately put a headset in.
        //
        // ONE snapshot of the route feeds both the decision and the log line that
        // explains it, so the log can never describe a route the decision didn't use —
        // that log is what the on-device check reads to tell a misclassified headset
        // from a genuinely silenced phone.
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        let route = outputs
            .map { "\($0.portName) [\($0.portType.rawValue)]" }
            .joined(separator: ", ")
        let outputPrivate = outputIsPrivateListening?()
            ?? DeviceAudioSessionManager.isPrivateListening(outputPorts: outputs.map(\.portType))
        let plan = DeviceAudioSessionManager.speechSessionPlan(
            respectSilentModeRequested: respectSilentMode,
            userRespectsSilentMode: appSettings?.respectSilentMode ?? true,
            headsetModeEnabled: appSettings?.headsetModeEnabled == true,
            outputIsPrivateListening: outputPrivate
        )
        let context = "respectRequested=\(respectSilentMode) setting=\(appSettings?.respectSilentMode ?? true) "
            + "headsetMode=\(appSettings?.headsetModeEnabled == true) plan=\(plan) "
            + "category=\(session.category.rawValue) private=\(outputPrivate) "
            + "route=[\(outputs.isEmpty ? "unknown/empty" : route)]"
        do {
            switch plan {
            case .respectSilentSwitch:
                try audioSessionManager.configureAudioSessionForSilentMode()
                LogManager.shared.log("VoiceOutput: audio session → .ambient/.spokenAudio (silent switch honored) \(context)", category: "VoiceOutput")
            case .forcePlayback:
                try audioSessionManager.configureAudioSessionForForcedPlayback()
                LogManager.shared.log("VoiceOutput: audio session → .playback/.spokenAudio (forcedPlayback) \(context)", category: "VoiceOutput")
            case .useHeadsetSession:
                try audioSessionManager.configureAudioSessionForHeadsetPlayback()
                LogManager.shared.log("VoiceOutput: audio session → headset .playAndRecord \(context)", category: "VoiceOutput")
            }
        } catch {
            // Failure policy differs by plan, because the two failures are opposites.
            // Quiet was the whole point of .respectSilentSwitch, so if we cannot get the
            // session into a category the ringer switch silences, DROP the utterance —
            // speaking under whatever category is live is how the phone ends up talking
            // in a meeting. The other two plans had already decided this utterance should
            // be heard; dropping those silences the driving case and, under headset mode,
            // wedges the session state machine in .sending with no timeout out of it.
            // So speak anyway and let the category be whatever it is.
            switch plan {
            case .respectSilentSwitch:
                LogManager.shared.log("❌ VoiceOutput: could not enter a silenced category, dropping utterance — \(error.localizedDescription) \(context)", category: "VoiceOutput")
                return false
            case .forcePlayback, .useHeadsetSession:
                LogManager.shared.log("⚠️ VoiceOutput: audio session setup failed, speaking under the existing session — \(error.localizedDescription) \(context)", category: "VoiceOutput")
            }
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

        // Set in-flight tags synchronously so a focus change racing this call
        // observes the new session, not the previous utterance's session.
        // didCancel for any preempted prior utterance will compare against
        // these new values and skip acting on them.
        inFlightSessionId = sessionId
        currentUtterance = utterance
        utteranceGeneration &+= 1
        utterance.voiceCodeGeneration = utteranceGeneration
        hasUtteranceInFlight = true

        // Speak
        LogManager.shared.log("🔊 Invoking synthesizer.speak() with text length: \(text.count), voice: \(utterance.voice?.name ?? "system default"), sessionId: \(sessionId?.uuidString.lowercased() ?? "nil")", category: "VoiceOutput")
        synthesizer.speak(utterance)

        DispatchQueue.main.async {
            self.isSpeaking = true
        }
        return true
    }

    /// Start the next queued reply, skipping any that are dropped (recording
    /// started, muted). Returns true when one is now in flight.
    private func startNextPendingSpeech() -> Bool {
        while !pendingSpeech.isEmpty {
            let next = pendingSpeech.removeFirst()
            if startUtterance(next) {
                LogManager.shared.log("🔊 Reading next queued reply (\(pendingSpeech.count) still waiting)", category: "VoiceOutput")
                return true
            }
        }
        return false
    }

    private func discardPendingSpeech(reason: String) {
        guard !pendingSpeech.isEmpty else { return }
        LogManager.shared.log("🔇 Discarding \(pendingSpeech.count) queued replies — \(reason)", category: "VoiceOutput")
        pendingSpeech.removeAll()
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
        discardPendingSpeech(reason: "stop")
        currentUtterance = nil
        #if os(iOS)
        stopKeepAliveTimer()
        #endif

        // `synthesizer.isSpeaking` flips true asynchronously, so between speak() and the
        // synthesizer actually starting it reads false while an utterance IS queued.
        // Trusting it alone would fire `completion` immediately and let the caller —
        // typically VoiceInputManager — reconfigure the session for recording out from
        // under an utterance about to start. `hasUtteranceInFlight` covers that window.
        let wasSpeaking = synthesizer.isSpeaking || hasUtteranceInFlight
        let generation = utteranceGeneration

        if wasSpeaking {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.pendingStopTimeoutItem?.cancel()
                self.pendingStopCompletion = completion

                if completion != nil {
                    let timeoutItem = DispatchWorkItem { [weak self] in
                        guard let self = self else { return }
                        // The synthesizer never reported. Treat the utterance we were
                        // asked to stop as finished, but only if nothing newer started
                        // in the meantime — otherwise this clobbers a live utterance.
                        if self.isCurrentGeneration(generation, event: "stop timeout") {
                            self.markStopped()
                        }
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
                if self.isCurrentGeneration(generation, event: "stop") {
                    self.markStopped()
                }
            }
        } else {
            DispatchQueue.main.async {
                // Nothing was in flight when stop was called, but a speak may have landed
                // in the meantime — clearing unconditionally would reopen the window this
                // whole mechanism exists to close.
                if self.isCurrentGeneration(generation, event: "stop (idle)") {
                    self.markStopped()
                }
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
        let finishedSessionId = utterance.voiceCodeSessionId
        let generation = utterance.voiceCodeGeneration
        DispatchQueue.main.async {
            guard self.isCurrentGeneration(generation, event: "didFinish") else { return }
            if utterance === self.currentUtterance {
                self.currentUtterance = nil
                self.utterancesFinished += 1
                // Read the next queued reply. Speech carries on, so none of the
                // end-of-speech work below runs: `isSpeaking` never drops, the
                // keep-alive timer keeps running and the session stays up.
                if self.startNextPendingSpeech() { return }
            }
            #if os(iOS)
            self.stopKeepAliveTimer()
            self.deactivateSessionIfNoBackgroundPlayback()
            #endif
            self.markStopped()
            self.clearInFlightIfMatches(finishedSessionId)
            self.onSpeechComplete?()
            self.firePendingStopCompletion()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        LogManager.shared.log("🔊 Speech CANCELLED", category: "VoiceOutput")
        let cancelledSessionId = utterance.voiceCodeSessionId
        let generation = utterance.voiceCodeGeneration
        DispatchQueue.main.async {
            guard self.isCurrentGeneration(generation, event: "didCancel") else { return }
            // A cancelled read ends the queue: whoever cancelled it meant
            // "stop reading", not "skip to the next one".
            if utterance === self.currentUtterance {
                self.currentUtterance = nil
                self.discardPendingSpeech(reason: "current utterance cancelled")
            }
            #if os(iOS)
            self.stopKeepAliveTimer()
            #endif
            self.markStopped()
            self.clearInFlightIfMatches(cancelledSessionId)
            self.firePendingStopCompletion()
        }
    }

    #if os(iOS)
    /// Release the session when the user has opted out of background playback. Skipped
    /// under headset mode: `HeadsetRemoteCommandManager` owns the session lifecycle and
    /// deactivating here kills the Now Playing slot.
    private func deactivateSessionIfNoBackgroundPlayback() {
        guard appSettings?.headsetModeEnabled != true,
              !(appSettings?.continuePlaybackWhenLocked ?? true) else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            LogManager.shared.log("Failed to deactivate audio session: \(error.localizedDescription)", category: "VoiceOutput")
        }
    }
    #endif

    /// Whether an ending utterance is still the newest one, i.e. whether ANY of the work
    /// its callback does is still relevant.
    ///
    /// When `speakWithVoice` preempts an utterance, the old one's `didCancel` lands on
    /// main AFTER the replacement has already been handed to the synthesizer. Everything
    /// that callback does is then wrong, not just the `isSpeaking` publish:
    ///   • `isSpeaking = false` tells `HeadsetRemoteCommandManager` speech stopped, and it
    ///     answers by re-asserting `.playAndRecord` under an utterance deliberately put in
    ///     `.ambient` — the reply is spoken out loud on vibrate, which is the whole bug.
    ///   • `firePendingStopCompletion()` releases `VoiceInputManager` to reconfigure the
    ///     session for recording while the replacement is audibly still speaking.
    ///   • `clearInFlightIfMatches` drops the focus-change cancel tag; a batch of replies
    ///     shares one session id, so the match check does not catch this.
    ///   • `stopKeepAliveTimer()` kills the timer the LIVE utterance just started.
    ///   • the deactivate-on-finish path tears down the session under a queued utterance.
    /// So the guard sits over the whole callback body, not over one line of it.
    ///
    /// Gating at the publisher rather than in each observer fixes every subscriber at
    /// once — including the macOS session reducer, which consumes the same signal.
    private func isCurrentGeneration(_ generation: UInt64?, event: String) -> Bool {
        guard generation == utteranceGeneration else {
            let gen = generation.map(String.init) ?? "nil"
            staleUtteranceEndsDropped += 1
            LogManager.shared.log("🔊 Ignoring stale \(event) — generation \(gen) superseded by \(utteranceGeneration)", category: "VoiceOutput")
            return false
        }
        return true
    }

    /// Record that the newest utterance has ended. Callers must have cleared
    /// `isCurrentGeneration` first.
    private func markStopped() {
        hasUtteranceInFlight = false
        isSpeaking = false
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
        // Same lag as everywhere else: an utterance handed to the synthesizer moments ago
        // reports isSpeaking == false, and would keep speaking after this object is gone.
        if synthesizer.isSpeaking || hasUtteranceInFlight {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }
}
