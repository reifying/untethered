import Foundation
import MediaPlayer
import Combine
import AVFoundation
#if os(macOS)
import CoreAudio
#endif

/// Log to the in-app LogManager so messages appear in the in-app debug log viewer.
private func hLog(_ msg: String) {
    LogManager.shared.log(msg, category: "HeadsetRemote")
}

private func hLogWarning(_ msg: String) {
    LogManager.shared.log("⚠️ \(msg)", category: "HeadsetRemote")
}

private func hLogError(_ msg: String) {
    LogManager.shared.log("❌ \(msg)", category: "HeadsetRemote")
}

class HeadsetRemoteCommandManager: ObservableObject {
    @Published var isActive = false

    // The interaction state machine differs per platform. iOS keeps the implicit
    // `HeadsetState` guards driven by the BPHeadset SDK / media-key handlers; macOS
    // is driven by the pure `SessionReducer` via a thin effect executor (this is
    // task 3x1.7 — see @docs/design/macos-headset-loop-state-machine.md). The
    // shared `BlueParrottPTTArbitrator` is retired on macOS (the gesture recognizer
    // de-brackets the raw stream instead).
    #if os(iOS)
    @Published private(set) var state: HeadsetState = .ready
    #else
    @Published private(set) var state: SessionState = .idle
    #endif

    /// Whether a button source is driving the state machine — and therefore whether
    /// TTS-completion and recording auto-finalize must be observed to return the
    /// machine to idle. Headset control sets `isActive` (it claims the
    /// MPRemoteCommandCenter / Now Playing slot). The macOS BlueParrott BLE source
    /// drives the same state machine via its events while `isActive` stays false —
    /// it deliberately does not claim the media slot — so on macOS the BlueParrott
    /// toggle counts too. This is also the executor-input GATE: when disengaged the
    /// session executor drops gesture/session events (the machine stays inert without
    /// special-casing inside the pure reducer).
    private var stateMachineEngaged: Bool {
        #if os(macOS)
        return isActive || settings.blueParrottEnabled
        #else
        return isActive
        #endif
    }

    private let voiceInput: VoiceInputManager
    private let voiceOutput: VoiceOutputManager
    private let client: VoiceCodeClient
    private let settings: AppSettings
    private let resolveActiveSession: () -> (sessionId: UUID, workingDirectory: String, isNewSession: Bool, provider: String)?
    private var cancellables = Set<AnyCancellable>()

    #if os(macOS)
    /// macOS BlueParrott button source over CoreBluetooth. Mirrors the iOS
    /// `blueParrottManager` (BPHeadset SDK); macOS feeds the de-bracketing
    /// `BlueParrottGestureRecognizer` → `SessionReducer` instead of the shared
    /// `BlueParrottButtonDelegate`.
    private(set) var blueParrottBLEManager: BlueParrottBLEManager?
    /// De-bracketer between the BLE raw-signal stream and the session reducer.
    private var gestureRecognizer: BlueParrottGestureRecognizer?
    /// Disconnect observation for the live BLE manager — a disconnect WHILE recording
    /// feeds `captureEnded` so `.recording` can't strand (Goal #2). Replaced on each
    /// `startBlueParrott()`.
    private var bleDisconnectCancellable: AnyCancellable?
    /// The source of the most recent button-driven event, used to label the
    /// system-derived events (TTS / capture / timers) the reducer requires a source
    /// for. None of those events trigger a source-gated effect, so this only matters
    /// for completeness.
    private var lastButtonSource: ButtonSource = .blueParrottBLE
    /// One-shot guard for the F3 capture restart (Risk 7): the reducer restarts on
    /// EVERY stall, so the executor stops re-feeding `captureStalled` after one retry
    /// and finalizes instead of looping. Reset on each fresh `startCapture`.
    private var captureRestartCount = 0

    #if os(macOS)
    /// True while output is parked on the headset for TTS playback (set when we restore for a
    /// spoken response). On TTS end we use it to move output BACK to built-in immediately —
    /// so the headset's A2DP release happens during the gap before the next press, not at
    /// mic-open (a capture opened while A2DP is still settling reads digital silence).
    private var outputOnHeadsetForTTS = false
    /// The system default OUTPUT device we moved away from for the current capture (the
    /// headset), so we can restore it when capture ends. nil when we didn't reroute (output
    /// wasn't the headset). See `rerouteOutputForCaptureIfNeeded` / `MacAudioOutput`.
    private var savedOutputDeviceID: AudioDeviceID?
    #endif

    /// Session-timer (captureGrace / awaitResponse) generation guards + retained work
    /// items, mirroring the BLE manager's pattern: arming or cancelling bumps the
    /// generation so a fired-but-superseded work item no-ops.
    private var sessionTimerGenerations: [SessionTimer: Int] = [:]
    private var sessionTimerWorkItems: [SessionTimer: DispatchWorkItem] = [:]

    /// Reentrancy queue for `ingest()` so each reduce→apply step is atomic — an effect
    /// whose application synchronously feeds an event back (e.g. a disconnected-client
    /// `startCapture` enqueuing `captureEnded`) is queued, not interleaved.
    private var isIngesting = false
    private var pendingSessionEvents: [(SessionEvent, ButtonSource)] = []

    /// Canonical voice-send, injected by the active `ConversationView` so the reducer's
    /// `.sendPrompt` effect goes through the SAME rich send path the UI uses
    /// (`sendPromptText`: new-session/resume, ghost, provider, draft, queue) instead of
    /// the bare `buildAndSend`. nil → fall back to `buildAndSend`. Returns whether a send
    /// was issued. This is what unifies the UI mic button and the headset onto one send.
    var sendVoicePrompt: ((String) -> Bool)?

    /// Audible-cue player. Test seam: defaults to the headset player; tests inject a spy.
    /// All playback routes through the single gated `playCue` (checks the opt-out setting).
    var earconPlayer: EarconPlaying = HeadsetEarconPlayer()

    /// Scheduler for the session timers. Test seam: defaults to `main.asyncAfter`;
    /// unit tests inject a non-firing recorder and drive timers via `testFireSessionTimer`.
    var sessionScheduleWork: (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    /// Scheduler for the gesture recognizer's hold timer. Same test-seam rationale —
    /// tests capture the block and fire it deterministically (no wall-clock).
    var gestureScheduleAfter: (TimeInterval, @escaping () -> Void) -> Void = { delay, block in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
    }

    /// Session-timer durations (tunable; grounded in the findings). `captureGrace`: a
    /// live route delivers buffers within ~300 ms even when silent, so zero buffers by
    /// ~1 s ⇒ dead route (F3). `awaitResponse`: generous backstop for the F4 strand.
    static let captureGraceInterval: TimeInterval = 1.0
    static let awaitResponseInterval: TimeInterval = 120.0

    #if DEBUG
    /// Test seam: override to inject a fake-`BLECentral`-backed `BlueParrottBLEManager`
    /// instead of standing up a real `CBCentralManager`. DEBUG-only so it adds no
    /// release surface; production always builds the real adapter.
    var makeBlueParrottBLEManager: () -> BlueParrottBLEManager = { BlueParrottBLEManager() }
    /// Test observability: counts of the source-gated keep-alive effects applied, so
    /// integration tests can assert a media-key recording does NOT suspend keep-alive
    /// (acceptance #7) while a BLE recording does.
    private(set) var suspendKeepAliveCount = 0
    private(set) var resumeKeepAliveCount = 0
    /// Counts how many times the keep-alive player ACTUALLY started (not suppressed). Lets
    /// tests assert the BlueParrott path never streams the A2DP keep-alive that would starve
    /// the HFP mic, even though the `.resumeKeepAlive` effect still fires.
    private(set) var keepAliveStartedCount = 0
    /// Test observability: how many times the output reroute / restore were INVOKED (counted
    /// at entry, before the CoreAudio guards). Lets tests assert the wiring — reroute fires on
    /// capture start, restore fires on TTS start and NOT after every capture — without a real
    /// audio device. The actual device switch is hardware-validated.
    private(set) var rerouteOutputInvokedCount = 0
    private(set) var restoreOutputInvokedCount = 0
    private(set) var parkOutputInvokedCount = 0
    #endif
    #endif

    #if DEBUG && os(macOS)
    // Phase A2 GATT explorer: a DEBUG-only diagnostic that observes the BlueParrott
    // control service over CoreBluetooth (the App-Mode persistence experiment). Parks
    // when the live BLE client is the active source (see startGattExplorer). Never ships.
    private var gattExplorer: BPGattExplorer?
    #endif
    private var keepAlivePlayer: AVAudioPlayer?
    #if os(iOS)
    private var interruptionObserver: NSObjectProtocol?
    private(set) var blueParrottManager: BlueParrottButtonManager?

    /// True when a BlueParrott comms headset is connected — the condition under which
    /// the capture session engages the Bluetooth HFP mic (`.allowBluetooth`) instead of
    /// the phone's built-in mic. Set in init to read `blueParrottManager?.isConnected`;
    /// overridable as a test seam so audio-session option tests don't need a live
    /// BPHeadset SDK.
    var isBlueParrottConnected: () -> Bool = { false }

    /// De-bracketer between the BPHeadset SDK's raw button stream and the recording
    /// actions. The SDK fires `down`/`up` PLUS a derived `tap`/`long-press` for the SAME
    /// physical press (a tap is `down,up,tapCode`; a hold is `down,longPressCode,up`).
    /// Handling those raw events independently made a hold's long-press fire interrupt
    /// mid-press (so the release never sent) and a tap's trailing code reset a
    /// just-started send. This collapses each press into exactly one clean gesture —
    /// the same `BlueParrottGestureRecognizer` the macOS path uses.
    private var gestureRecognizer: BlueParrottGestureRecognizer?

    /// Scheduler for the recognizer's hold timer. Test seam: tests inject a recorder and
    /// fire the captured block deterministically (no wall-clock read).
    var gestureScheduleAfter: (TimeInterval, @escaping () -> Void) -> Void = { delay, block in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
    }

    /// Audible-cue player for eyes-free start/stop feedback. Test seam: defaults to the
    /// headset tone player; tests inject a spy. All playback routes through the gated
    /// `playCue` (honors `headsetAudibleCuesEnabled`).
    var earconPlayer: EarconPlaying = HeadsetEarconPlayer()

    enum HeadsetState: CustomStringConvertible, Equatable {
        case ready
        case recording
        case sending
        case speaking

        var description: String {
            switch self {
            case .ready: return "Ready"
            case .recording: return "Recording"
            case .sending: return "Processing"
            case .speaking: return "Speaking"
            }
        }
    }
    #endif

    init(voiceInput: VoiceInputManager,
         voiceOutput: VoiceOutputManager,
         client: VoiceCodeClient,
         settings: AppSettings,
         resolveActiveSession: @escaping () -> (sessionId: UUID, workingDirectory: String, isNewSession: Bool, provider: String)? = {
             guard let sessionId = ActiveSessionManager.shared.activeSessionId else { return nil }
             let context = PersistenceController.shared.container.viewContext
             guard let session = try? context.fetch(
                 CDBackendSession.fetchBackendSession(id: sessionId)
             ).first else { return nil }
             // Mirror ConversationView.sendPromptText: a session with no messages
             // yet is NEW (mint it on the backend via new_session_id); otherwise
             // resume. Without this, the headset path always resumed and a
             // first-time Bluetooth send to a fresh session created a phantom the
             // backend never had — `claude --resume <uuid>` then timed out.
             let provider = session.provider.isEmpty ? "claude" : session.provider
             return (sessionId, session.workingDirectory, session.messageCount == 0, provider)
         }) {
        self.voiceInput = voiceInput
        self.voiceOutput = voiceOutput
        self.client = client
        self.settings = settings
        self.resolveActiveSession = resolveActiveSession

        hLog("Headset: init — headsetModeEnabled=\(settings.headsetModeEnabled), autoSend=\(settings.headsetAutoSend)")

        #if os(iOS)
        voiceOutput.$isSpeaking
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isSpeaking in
                guard let self = self, self.stateMachineEngaged else { return }
                if isSpeaking && self.state == .sending {
                    self.state = .speaking
                    self.updateNowPlayingState()
                } else if !isSpeaking && self.state == .speaking {
                    self.state = .ready
                    self.updateNowPlayingState()
                    self.activateAudioSession()
                } else if !isSpeaking {
                    // TTS ended but state wasn't .speaking — e.g. session-history replay TTS
                    // or other out-of-band speech. Re-assert only if TTS actually changed our
                    // category (avoids 187 redundant rebuilds when session history is replayed).
                    let s = AVAudioSession.sharedInstance()
                    if s.category != .playAndRecord || !s.categoryOptions.contains(.allowBluetoothA2DP) {
                        hLog("Headset: isSpeaking→false — session changed (was \(s.category.rawValue)/opts=\(s.categoryOptions.rawValue)), re-asserting")
                        self.activateAudioSession()
                    }
                }
            }
            .store(in: &cancellables)
        #else
        // macOS: TTS start/end feed the session reducer (ttsStarted/ttsEnded). On TTS
        // START, restore output to the headset so the spoken response plays IN-EAR — this
        // is the ONLY time we move output back onto the headset (not after every capture),
        // because re-establishing A2DP and then yanking it for the next recording silences
        // the mic (confirmed: capture 1 works, every post-restore capture is digital
        // silence). Back-to-back recordings now never cycle the route; only an actual
        // spoken response does.
        voiceOutput.$isSpeaking
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isSpeaking in
                guard let self = self else { return }
                if isSpeaking {
                    self.restoreOutputAfterCapture()   // TTS → headset (in-ear)
                } else {
                    self.parkOutputToBuiltInAfterTTS() // TTS ended/dismissed → built-in early, so A2DP settles before the next press
                }
                self.handleSystemEvent(isSpeaking ? .ttsStarted : .ttsEnded)
            }
            .store(in: &cancellables)
        // macOS: a backend drop mid-await must not strand `.awaitingResponse` (F4).
        client.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                guard let self = self, !connected else { return }
                self.handleSystemEvent(.backendUnavailable)
            }
            .store(in: &cancellables)
        // macOS: the live capture-readiness signal (F3) — first non-silent buffer
        // cancels the grace window.
        voiceInput.onCaptureProducedAudio = { [weak self] in
            self?.handleSystemEvent(.captureProducedAudio)
        }
        #endif

        settings.$headsetModeEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                if enabled {
                    self?.activate()
                } else {
                    self?.deactivate()
                }
            }
            .store(in: &cancellables)

        #if os(iOS)
        // Observe speech recognizer auto-finalize. When SFSpeechRecognizer hits
        // its silence timeout (~30s) it sets isRecording=false from inside the
        // recognition callback — without a second button press. If our state is
        // still .recording at that point, advance to the send flow so the user
        // doesn't need a second press to unstick the state machine.
        voiceInput.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording in
                guard let self = self, self.stateMachineEngaged else { return }
                if !isRecording && self.state == .recording {
                    hLog("Headset: isRecording→false while state=.recording (auto-finalize) — triggering send")
                    self.stopRecordingAndSend()
                }
            }
            .store(in: &cancellables)

        // Engage the Bluetooth HFP mic for capture while a BlueParrott is connected.
        // Its buttons arrive over BLE (not AVRCP), so HFP costs no button delivery and
        // is the only way to record from the headset mic rather than the built-in mic.
        // VoiceInputManager reads this each time it (re)configures the capture session.
        isBlueParrottConnected = { [weak self] in self?.blueParrottManager?.isConnected == true }
        voiceInput.prefersBluetoothHFPInput = { [weak self] in self?.isBlueParrottConnected() ?? false }
        #else
        // macOS: capture ending with no `up` (recognizer silence auto-finalize /
        // engine failure) feeds `captureEnded` so `.recording` can't strand (Goal #2).
        // `(.finalizing/.idle, .captureEnded)` is a reducer no-op, so this is safe even
        // when capture ended because WE stopped it.
        voiceInput.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording in
                guard let self = self, !isRecording else { return }
                self.handleSystemEvent(.captureEnded)
            }
            .store(in: &cancellables)
        #endif

        setupKeepAlive()

        // Drive the BlueParrott button source from the same toggle on both
        // platforms — iOS via the BPHeadset SDK (`BlueParrottButtonManager`),
        // macOS via CoreBluetooth (`BlueParrottBLEManager` → gesture recognizer →
        // session reducer).
        settings.$blueParrottEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self = self else { return }
                if enabled {
                    self.startBlueParrott()
                } else {
                    self.stopBlueParrott()
                }
            }
            .store(in: &cancellables)
    }

    func activate() {
        guard !isActive else { return }
        hLog("Headset: activating remote control")
        registerRemoteCommands()
        #if os(macOS)
        startKeepAlive()
        #if DEBUG
        startGattExplorer()
        #endif
        #elseif os(iOS)
        activateAudioSession()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self = self, self.isActive else { return }
            guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                hLogWarning("Headset: interruption notification with unreadable type")
                return
            }
            let shouldResume = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .flatMap { AVAudioSession.InterruptionOptions(rawValue: $0) }
                .map { $0.contains(.shouldResume) } ?? false
            let typeStr = type == .began ? "began" : "ended"
            hLog("Headset: interruption \(typeStr) — shouldResume=\(shouldResume), state=\(self.state)")
            if type == .ended {
                if shouldResume {
                    self.activateAudioSession()
                    hLog("Headset: audio session restored after interruption")
                } else {
                    hLogWarning("Headset: interruption ended without shouldResume — NOT restored, state=\(self.state)")
                }
            }
        }
        #endif
        updateNowPlayingState()
        isActive = true
        hLog("Headset remote control activated")
    }

    func deactivate() {
        guard isActive else { return }
        // Stop recording first — otherwise the audio engine stays live after deactivation.
        if state == .recording {
            voiceInput.stopRecording()
        }
        #if os(macOS)
        restoreOutputAfterCapture()   // safety: deactivate stops recording without the reducer stopCapture path
        stopKeepAlive()
        #if DEBUG
        stopGattExplorer()
        #endif
        #endif
        unregisterRemoteCommands()
        #if os(iOS)
        if let token = interruptionObserver {
            NotificationCenter.default.removeObserver(token)
            interruptionObserver = nil
        }
        deactivateAudioSession()
        #endif
        MPNowPlayingInfoCenter.default().playbackState = .unknown
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        isActive = false
        #if os(iOS)
        state = .ready
        #else
        state = .idle
        #endif
        hLog("Headset remote control deactivated")
    }

    func reclaimNowPlaying() {
        guard settings.headsetModeEnabled else { return }
        #if os(iOS)
        // Re-activate audio session first — if iOS suspended us while backgrounded
        // the session may be inactive, and updating NowPlayingInfo alone won't
        // restore MPRemoteCommandCenter delivery without an active audio session.
        activateAudioSession()
        #endif
        updateNowPlayingState()
        hLog("Headset: reclaimed now-playing slot — state=\(self.state)")
    }

    deinit {
        deactivate()
    }

    // MARK: - MPRemoteCommandCenter

    private func registerRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            #if os(iOS)
            self?.handleTogglePlayPause()
            #else
            self?.handleMediaButton(.tap)
            #endif
            return .success
        }

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            #if os(iOS)
            self?.handlePlay()
            #else
            self?.handleMediaButton(.tap)
            #endif
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            #if os(iOS)
            self?.handlePause()
            #else
            self?.handleMediaButton(.tap)
            #endif
            return .success
        }

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            #if os(iOS)
            self?.handleInterrupt()
            #else
            self?.handleMediaButton(.doubleTap)
            #endif
            return .success
        }

        center.previousTrackCommand.isEnabled = false
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.changePlaybackRateCommand.isEnabled = false
    }

    private func unregisterRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.isEnabled = false
        center.playCommand.removeTarget(nil)
        center.playCommand.isEnabled = false
        center.pauseCommand.removeTarget(nil)
        center.pauseCommand.isEnabled = false
        center.nextTrackCommand.removeTarget(nil)
        center.nextTrackCommand.isEnabled = false
    }

    fileprivate func updateNowPlayingState() {
        let title: String
        let playbackState: MPNowPlayingPlaybackState
        switch state {
        #if os(iOS)
        case .ready:
            title = "VoiceCode — Ready"
            // Report .playing because we continuously output silent audio to hold
            // the Now Playing slot. This makes AirPods consistently send ❚❚ for a
            // single press, which handlePause() treats as a toggle.
            playbackState = .playing
        case .recording:
            title = "VoiceCode — Recording"
            playbackState = .playing
        case .sending:
            title = "VoiceCode — Processing"
            playbackState = .paused
        case .speaking:
            title = "VoiceCode — Speaking"
            playbackState = .playing
        #else
        case .idle:
            title = "VoiceCode — Ready"
            playbackState = .playing
        case .recording:
            title = "VoiceCode — Recording"
            playbackState = .playing
        case .finalizing, .awaitingResponse:
            title = "VoiceCode — Processing"
            playbackState = .paused
        case .speaking:
            title = "VoiceCode — Speaking"
            playbackState = .playing
        #endif
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: 0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0
        ]
        MPNowPlayingInfoCenter.default().playbackState = playbackState
    }

    // MARK: - Prompt send (shared)

    /// Build the prompt message and send it to the active session. Returns false if
    /// there is no active session to send to — the caller decides how to recover
    /// (iOS returns to `.ready`; the macOS executor feeds `.backendUnavailable`). Does
    /// NOT touch state, so it stays platform-neutral.
    @discardableResult
    fileprivate func buildAndSend(_ text: String) -> Bool {
        guard let (sessionId, workingDirectory, isNewSession, provider) = resolveActiveSession() else {
            hLogWarning("Headset: auto-send failed — no active session")
            return false
        }

        let sessionIdStr = sessionId.uuidString.lowercased()
        hLog("Headset: sending prompt to session=\(sessionIdStr) new=\(isNewSession) provider=\(provider) textLength=\(text.count) dir=\(workingDirectory)")

        client.sessionSyncManager.createOptimisticMessage(
            sessionId: sessionId,
            text: text
        ) { _ in }

        // Reuse the canonical builder ConversationView.sendPromptText uses so the
        // headset/Bluetooth send shares one wire contract: new_session_id+provider
        // for a fresh session, resume_session_id for an existing one, plus
        // working_directory and an optional non-empty system_prompt. Ghost is
        // never honored here (the headset has no ghost gesture).
        let message = PromptMessageBuilder.build(
            text: text,
            sessionId: sessionIdStr,
            workingDirectory: workingDirectory,
            isNewSession: isNewSession,
            provider: provider,
            systemPrompt: settings.systemPrompt
        )

        client.sendMessage(message)
        hLog("Headset: prompt sent to session \(sessionIdStr) (new=\(isNewSession))")
        return true
    }
}

// MARK: - iOS state machine (HeadsetState)

#if os(iOS)
extension HeadsetRemoteCommandManager {

    // MARK: - Button Handlers

    private func handleTogglePlayPause() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            hLog("Headset: ▶︎/❚❚ received — state=\(self.state), audioCategory=\(AVAudioSession.sharedInstance().category.rawValue)")
            switch self.state {
            case .ready:
                self.startRecording()
            case .recording:
                self.stopRecordingAndSend()
            case .speaking:
                self.performInterrupt()
            case .sending:
                // Reset to ready so a second press can start a new recording.
                // State can strand here if TTS is disabled or the isSpeaking
                // transition never fires (e.g. the response was silent).
                hLog("Headset: ▶︎/❚❚ while sending — resetting to ready")
                self.state = .ready
                self.updateNowPlayingState()
            }
        }
    }

    private func handlePlay() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            hLog("Headset: ▶︎ received — state=\(self.state)")
            if self.state == .ready {
                self.startRecording()
            } else {
                hLog("Headset: ▶︎ ignored — state=\(self.state)")
            }
        }
    }

    private func handlePause() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            hLog("Headset: ❚❚ received — state=\(self.state), audioCategory=\(AVAudioSession.sharedInstance().category.rawValue)")
            // Continuous silent audio causes AirPods to always send ❚❚ (pause)
            // rather than ▶︎ (play), regardless of our NowPlaying playbackState.
            // Treat ❚❚ as a toggle so it works symmetrically with handleTogglePlayPause.
            switch self.state {
            case .ready:
                self.startRecording()
            case .recording:
                self.stopRecordingAndSend()
            case .speaking:
                self.performInterrupt()
            case .sending:
                hLog("Headset: ❚❚ while sending — resetting to ready")
                self.state = .ready
                self.updateNowPlayingState()
            }
        }
    }

    private func handleInterrupt() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            hLog("Headset: ⏭ received — state=\(self.state)")
            self.performInterrupt()
        }
    }

    // Single authoritative implementation of the interrupt action. Called from
    // handleTogglePlayPause (.speaking case), handleInterrupt (next-track button),
    // and simulateInterrupt (test hook) — all of which are already on the main queue.
    private func performInterrupt() {
        voiceOutput.stop()
        state = .ready
        updateNowPlayingState()
        hLog("Headset interrupt: stopped TTS")
        // Distinct "dismissed" blip so canceling the assistant's speech is audibly
        // different from STARTING a recording (.listening's rising chirp).
        playCue(.cancelled)
    }

    /// The single gated entry point for audible cues — honors the opt-out setting, then
    /// plays through `earconPlayer` (routed to the active HFP headset session). Cues fire on
    /// recording START (`.listening`) and STOP (`.sent`/`.error`) so a headset user knows
    /// eyes-free whether recording began and whether the turn was captured + sent.
    private func playCue(_ earcon: Earcon) {
        guard settings.headsetAudibleCuesEnabled else { return }
        hLog("Headset: ♪ cue \(earcon)")
        earconPlayer.play(earcon)
    }

    /// Apply ONE clean, de-bracketed gesture from `BlueParrottGestureRecognizer`. This is
    /// the single place the BlueParrott drives recording — raw `down`/`up`/`tap`/`long-press`
    /// no longer act independently. A hold is press-and-hold-to-talk (release sends); a tap
    /// toggles record/stop and dismisses a busy state; a double-tap interrupts.
    private func handleHeadsetGesture(_ gesture: HeadsetGesture) {
        hLog("Headset: ▶︎ de-bracketed gesture=\(gesture) state=\(self.state)")
        switch gesture {
        case .holdStarted:
            switch state {
            case .ready:     hLog("Headset: holdStarted (ready) → startRecording"); startRecording()
            case .speaking:  hLog("Headset: holdStarted (speaking) → interrupt + startRecording [barge-in]"); performInterrupt(); startRecording()
            case .sending:   hLog("Headset: holdStarted (sending) → startRecording [talk over pending]"); startRecording()
            case .recording: hLog("Headset: holdStarted (recording) → ignored, already recording")
            }
        case .holdEnded:
            if state == .recording {
                hLog("Headset: holdEnded (recording) → stopRecordingAndSend")
                stopRecordingAndSend()
            } else {
                hLog("Headset: holdEnded (\(state)) → ignored, not recording")
            }
        case .tap:
            switch state {
            case .ready:     hLog("Headset: tap (ready) → startRecording"); startRecording()
            case .recording: hLog("Headset: tap (recording) → stopRecordingAndSend"); stopRecordingAndSend()
            case .speaking:  hLog("Headset: tap (speaking) → interrupt"); performInterrupt()
            case .sending:
                hLog("Headset: tap (sending) → resetting to ready")
                state = .ready
                updateNowPlayingState()
            }
        case .doubleTap:
            hLog("Headset: doubleTap (\(state)) → interrupt"); performInterrupt()
        }
    }

    // MARK: - Recording Lifecycle

    private func startRecording() {
        guard client.isConnected else {
            hLogWarning("Headset: startRecording ignored — not connected to backend")
            return
        }
        hLog("Headset: startRecording — audioCategory=\(AVAudioSession.sharedInstance().category.rawValue) route=\(AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portName))")
        state = .recording
        updateNowPlayingState()
        // Eyes-free "recording started" cue, played IMMEDIATELY through the already-up
        // keep-alive HFP session — don't wait for the SCO mic warm-up — so a hold gives
        // prompt confirmation that the press registered and recording began.
        playCue(.listening)
        // Pass onSessionReady so we restart the silence player AFTER
        // VoiceInputManager switches the audio session to .playAndRecord.
        // AVAudioPlayer binds audio routing at prepareToPlay() time. Playing or
        // replaying it while the session is still .playback causes it to be
        // interrupted by the subsequent setCategory(.playAndRecord) call, after
        // which it produces no output — which removes us from the Now Playing
        // slot and causes AirPods to route the second stem press to another app.
        // startKeepAlive() calls setupKeepAlive() to reconstruct the player in
        // the current session context, then immediately starts it.
        voiceInput.startRecording(onSessionReady: { [weak self] in
            guard let self = self else { return }
            self.startKeepAlive()
            let s = AVAudioSession.sharedInstance()
            let outputs = s.currentRoute.outputs.map(\.portName).joined(separator: ", ")
            let opts = s.categoryOptions.rawValue
            hLog("Headset: recording started — silence player rebuilt+started, playing=\(self.keepAlivePlayer?.isPlaying ?? false), audioCategory=\(s.category.rawValue), outputs=[\(outputs)], opts=\(opts)")
        })
    }

    private func stopRecordingAndSend() {
        hLog("Headset: stopRecordingAndSend — pre-stop audioCategory=\(AVAudioSession.sharedInstance().category.rawValue)")
        voiceInput.stopRecording()
        // Re-assert .playback session so MPRemoteCommandCenter keeps routing
        // AirPod/headset button events to our app during the sending/ready gap.
        activateAudioSession()
        hLog("Headset: stopRecordingAndSend — post-reactivation audioCategory=\(AVAudioSession.sharedInstance().category.rawValue)")
        state = .sending
        updateNowPlayingState()

        // Defer reading transcribedText by one run-loop tick. stopRecording()
        // triggers the final recognition callback on the main queue — reading
        // synchronously here would miss that final result.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let text = self.voiceInput.transcribedText
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else {
                hLog("Headset: empty transcription — returning to ready")
                self.state = .ready
                self.updateNowPlayingState()
                self.playCue(.error)   // nothing recognized → "that didn't work"
                return
            }

            hLog("Headset: transcription ready, length=\(text.count), autoSend=\(self.settings.headsetAutoSend)")
            if self.settings.headsetAutoSend {
                self.sendToActiveSession(text)
            } else {
                // Captured but not auto-sent: still a successful STOP, so cue "got it".
                self.state = .ready
                self.updateNowPlayingState()
                self.playCue(.sent)
            }
        }
    }

    private func sendToActiveSession(_ text: String) {
        if buildAndSend(text) {
            playCue(.sent)             // confirmed send → "got it"
        } else {
            state = .ready
            updateNowPlayingState()
            playCue(.error)            // no active session / send failed → "that didn't work"
        }
    }
}
#endif

// MARK: - Silent Audio Keep-Alive (cross-platform)

extension HeadsetRemoteCommandManager {

    func startKeepAlive() {
        #if os(macOS)
        // The BlueParrott mic captures over Bluetooth HFP/SCO, which is mutually exclusive
        // with A2DP output on the same headset (HFP is a single bidirectional 16kHz link).
        // The keep-alive is a CONTINUOUS A2DP output stream — it exists only to hold the
        // Now Playing slot for MEDIA-KEY routing (AirPods stem / system keys). The
        // BlueParrott's buttons arrive over BLE/GATT and don't need it. When BlueParrott is
        // the active source, streaming the keep-alive to the headset pins it in A2DP and
        // starves the HFP mic (confirmed on the B450-XT: capture dies at ~3 silent buffers
        // while the keep-alive streams to the headset, and works the instant output leaves
        // it). So suppress the keep-alive entirely while BlueParrott is enabled.
        if settings.blueParrottEnabled {
            keepAlivePlayer?.stop()
            hLog("Headset: keep-alive suppressed — BlueParrott BLE active (A2DP output would starve the HFP mic)")
            return
        }
        #endif
        keepAlivePlayer?.stop()
        setupKeepAlive()
        let played = keepAlivePlayer?.play() ?? false
        #if os(macOS) && DEBUG
        keepAliveStartedCount += 1
        #endif
        hLog("Headset: keep-alive started — looping=\(played)")
    }

    func stopKeepAlive() {
        keepAlivePlayer?.stop()
    }

    private func setupKeepAlive() {
        let sampleRate: Double = 44100.0
        let frameCount = UInt32(sampleRate)  // 1 second
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        // macOS determines the Now Playing app by watching CoreAudio output.
        // Pure silence (all zeros) doesn't register as active audio, so the
        // system ignores our MPRemoteCommandCenter registration and plays a
        // beep instead of routing the media key. A ~20Hz tone at -80dB is
        // inaudible but produces non-zero samples that satisfy the heuristic.
        if let channelData = buffer.floatChannelData?[0] {
            let amplitude: Float = 0.0001  // -80dB, inaudible
            let frequency: Float = 20.0     // below human hearing threshold
            for i in 0..<Int(frameCount) {
                channelData[i] = amplitude * sin(2.0 * .pi * frequency * Float(i) / Float(sampleRate))
            }
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("headset_silence.caf")
        do {
            let file = try AVAudioFile(forWriting: tempURL, settings: format.settings)
            try file.write(from: buffer)
            keepAlivePlayer = try AVAudioPlayer(contentsOf: tempURL)
            keepAlivePlayer?.numberOfLoops = -1
            keepAlivePlayer?.prepareToPlay()
        } catch {
            hLogError("Headset: failed to create silence player: \(error.localizedDescription)")
        }
    }
}

// MARK: - iOS Audio Session

#if os(iOS)
extension HeadsetRemoteCommandManager {

    func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            let prevCategory = session.category.rawValue
            // Keep the ready/keep-alive session options in lockstep with the capture
            // session (VoiceInputManager) so the route doesn't flip A2DP↔HFP between
            // ready and recording — flipping re-runs the SCO handshake on every press
            // and clips the first word. When a BlueParrott is connected this keeps HFP
            // warm; otherwise it stays A2DP-only (AirPods-safe).
            let options = VoiceInputManager.recordingCategoryOptions(prefersBluetoothHFP: isBlueParrottConnected())
            try session.setCategory(.playAndRecord, mode: .default, options: options)
            try session.setActive(true)
            startKeepAlive()
            let outputs = session.currentRoute.outputs.map(\.portName).joined(separator: ", ")
            let opts = session.categoryOptions.rawValue
            hLog("Headset: audio session → .playAndRecord/opts=\(opts) (was \(prevCategory)), route=[\(outputs)]")
        } catch {
            hLogError("Headset: failed to activate audio session: \(error.localizedDescription)")
        }
    }

    func deactivateAudioSession() {
        stopKeepAlive()
        do {
            try AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation
            )
            hLog("Headset: audio session deactivated")
        } catch {
            hLogError("Headset: failed to deactivate audio session: \(error.localizedDescription)")
        }
    }

    // MARK: - BlueParrott SDK

    func startBlueParrott() {
        guard blueParrottManager == nil else { return }
        #if DEBUG
        // Phase A1 collector: capture the SDK's GATT traffic (App-Mode enable
        // write + per-gesture notification bytes) for the macOS reimplementation.
        BPSniffer.install()
        #endif
        // De-bracket the SDK's raw button stream into one clean gesture per press.
        gestureRecognizer = BlueParrottGestureRecognizer(
            emit: { [weak self] gesture in self?.handleHeadsetGesture(gesture) },
            scheduleAfter: { [weak self] delay, block in self?.gestureScheduleAfter(delay, block) })
        let bp = BlueParrottButtonManager()
        bp.delegate = self
        bp.start()
        blueParrottManager = bp
        hLog("Headset: BlueParrott SDK started")
    }

    func stopBlueParrott() {
        blueParrottManager?.stop()
        blueParrottManager = nil
        gestureRecognizer = nil
        hLog("Headset: BlueParrott SDK stopped")
    }
}

// MARK: - BlueParrottButtonDelegate (iOS)
//
// The iOS BPHeadset SDK (`BlueParrottButtonManager`) maps its de-bracketed gestures
// onto the implicit `HeadsetState` machine. macOS no longer uses this path — it
// drives the pure `SessionReducer` via the gesture recognizer instead (the shared
// `BlueParrottPTTArbitrator` is retired).

// The BPHeadset SDK brackets EVERY gesture with raw down/up and adds a derived
// tap/long-press for the same press. These handlers therefore feed the RAW signals
// into `BlueParrottGestureRecognizer`, which collapses each press into exactly one
// clean `HeadsetGesture` (`handleHeadsetGesture`) — so a hold isn't interrupted
// mid-press by its long-press code, and a tap's trailing code can't reset a send.
extension HeadsetRemoteCommandManager: BlueParrottButtonDelegate {
    /// Feed one raw SDK signal into the recognizer, logging it so the full chain
    /// (raw signal → de-bracketed gesture → action) is reconstructable from shared logs.
    private func feedRaw(_ signal: RawButtonSignal, _ label: String) {
        if gestureRecognizer == nil {
            hLogWarning("Headset: raw \(label) but gestureRecognizer is nil — dropped (BlueParrott not started?)")
            return
        }
        hLog("Headset: ◀︎ raw \(label) → recognizer (state=\(state))")
        gestureRecognizer?.feed(signal)
    }
    func blueParrottButtonDown()  { feedRaw(.down, "DOWN") }
    func blueParrottButtonUp()    { feedRaw(.up, "UP") }
    func blueParrottTap()         { feedRaw(.tapCode, "TAP-code") }
    func blueParrottDoubleTap()   { feedRaw(.doubleTapCode, "DOUBLE-TAP-code") }
    func blueParrottLongPress()   { feedRaw(.longPressCode, "LONG-PRESS-code (dropped by de-bracketer)") }
}
#endif

// MARK: - macOS session reducer executor

#if os(macOS)
extension HeadsetRemoteCommandManager {

    /// Executor input for a de-bracketed button gesture (BLE) or a media-key press.
    /// Sets the last button source, applies the engagement gate (drop gesture/session
    /// events when disengaged), and the not-connected guard (a fresh recording needs a
    /// live client to send the prompt), then ingests into the reducer.
    /// The on-screen mic button, routed through the SAME session reducer as the headset
    /// so they share one recording-state owner: a headset tap can stop a UI-started
    /// recording (and vice versa) without the cross-source restart that silently lost
    /// the message. A tap toggles idle→record, recording→finalize+send.
    func toggleRecordingFromUI() {
        handleButtonEvent(.tap, source: .ui)
    }

    func handleButtonEvent(_ event: SessionEvent, source: ButtonSource) {
        lastButtonSource = source
        // Log every executor input with its source and the current state. The BLE path
        // also logs raw-signal/gesture upstream, but the .ui (mic-button) path has no
        // other trace — this is what makes a UI toggle / cross-source state issue
        // diagnosable from shared logs.
        hLog("Session: button \(event) source=\(source) state=\(state)")
        // The on-screen mic button (.ui) is a deliberate in-app action and ALWAYS acts.
        // The engagement gate exists only to suppress HEADSET / media-key events when
        // hands-free is off (so a disabled headset can't drive recording) — it must not
        // disable a UI affordance the user clicked on purpose.
        guard source == .ui || stateMachineEngaged else {
            hLog("Session: \(event) dropped — not engaged")
            return
        }
        if beginsRecording(event, source: source), !client.isConnected {
            hLogWarning("Session: \(event) ignored — not connected to backend")
            playCue(.error)   // a press that can't record/send cues the failure (guard returns pre-reducer)
            return
        }
        ingest(event, source: source)
    }

    /// Executor input for a system-derived event (TTS / capture lifecycle / timers /
    /// disconnect). Gated on engagement; uses the last real button source (no
    /// source-gated effect is reachable from these events).
    func handleSystemEvent(_ event: SessionEvent) {
        // Allow system events when engaged OR when a turn is already in flight
        // (state != idle). A UI-button recording started while hands-free is off must
        // still receive its capture / transcription / TTS events to finalize — otherwise
        // `.recording` would strand with the engagement gate dropping `captureEnded`.
        guard stateMachineEngaged || state != .idle else { return }
        ingest(event, source: lastButtonSource)
    }

    /// True when `event` from `source` would BEGIN a recording in the current state — the
    /// transitions that must be blocked when the backend is down (a fresh recording needs
    /// a live client to send the prompt). Covers an idle start (any source) and the UI
    /// mic's barge-in-and-record from a busy state (`.speaking`/`.awaitingResponse`),
    /// which a headset/SDK `.tap` does NOT do (it dismisses). Mirrors `SessionReducer`'s
    /// recording-start transitions.
    private func beginsRecording(_ event: SessionEvent, source: ButtonSource) -> Bool {
        switch (state, event) {
        case (.idle, .holdStarted), (.idle, .tap): return true
        case (.speaking, .tap), (.awaitingResponse, .tap): return source == .ui
        default: return false
        }
    }

    /// Reduce one event and apply the returned effects, serialized on the main queue.
    /// Reentrant calls (an effect that synchronously feeds an event back) are queued
    /// and drained FIFO so two events' effects never interleave.
    private func ingest(_ event: SessionEvent, source: ButtonSource) {
        pendingSessionEvents.append((event, source))
        guard !isIngesting else { return }
        isIngesting = true
        defer { isIngesting = false }
        while !pendingSessionEvents.isEmpty {
            let (e, src) = pendingSessionEvents.removeFirst()
            let (newState, effects) = SessionReducer.reduce(state, e, source: src)
            state = newState
            for effect in effects { apply(effect) }
        }
    }

    private func apply(_ effect: SessionEffect) {
        switch effect {
        case .startCapture:
            startSessionCapture()
        case .restartCapture:
            voiceInput.restartCapture()
        case .stopCapture:
            stopSessionCaptureAndReadTranscription()
        case .sendPrompt(let text):
            // Prefer the injected rich send (UI's `sendPromptText`); fall back to the
            // bare `buildAndSend` when no ConversationView is wired. One send path for
            // headset + UI + silence-timeout finalize.
            let sent = sendVoicePrompt?(text) ?? buildAndSend(text)
            if sent {
                // Confirmed send → "got it". Played here (not as a reducer effect alongside
                // the optimistic `.sendPrompt`) so a FAILED send can't lie ("sent" → "error").
                playCue(.sent)
            } else {
                // No active session → don't strand `.awaitingResponse`. The reducer turns
                // `.backendUnavailable` into `.error`, so a failed send cues `.error` alone.
                handleSystemEvent(.backendUnavailable)
            }
        case .interruptTTS:
            voiceOutput.stop()
        case .suspendKeepAlive:
            stopKeepAlive()
            #if DEBUG
            suspendKeepAliveCount += 1
            #endif
        case .resumeKeepAlive:
            startKeepAlive()
            #if DEBUG
            resumeKeepAliveCount += 1
            #endif
        case .armTimer(let timer):
            armSessionTimer(timer)
        case .cancelTimer(let timer):
            cancelSessionTimer(timer)
        case .updateNowPlaying:
            updateNowPlayingState()
        case .playEarcon(let earcon):
            playCue(earcon)
        case .log(let message):
            hLog("Session: \(message)")
        }
    }

    /// The ONE gated entry point for audible cues. Quiet on the desktop and when the user
    /// opted out; every call site (reducer `.playEarcon` effects, the confirmed-send `.sent`,
    /// the not-connected guard) routes through here so no play site can forget the gate.
    /// Headset-engagement is already guaranteed upstream by `handleButtonEvent` /
    /// `handleSystemEvent`, so this only adds the opt-out check.
    private func playCue(_ earcon: Earcon) {
        guard settings.headsetAudibleCuesEnabled else { return }
        earconPlayer.play(earcon)
    }

    private func startSessionCapture() {
        captureRestartCount = 0
        #if os(macOS)
        // Free the HFP mic BEFORE opening the engine: if the system default output is the
        // same headset we're capturing from, A2DP output is pinning the radio and the mic
        // would deliver silent buffers. Move output to the built-in device for the capture.
        rerouteOutputForCaptureIfNeeded()
        #endif
        voiceInput.startRecording()
        hLog("Session: capture started")
    }

    #if os(macOS)
    /// If the system default OUTPUT is the same headset we're about to capture from, move
    /// output to the built-in device so the headset can give us its HFP mic (A2DP-out and
    /// HFP-in are mutually exclusive). Saves the prior device for restore. No-op when output
    /// is already a different device, when there's no built-in output, or when the BlueParrott
    /// isn't the active source. Idempotent (won't double-save).
    func rerouteOutputForCaptureIfNeeded() {
        #if DEBUG
        rerouteOutputInvokedCount += 1
        #endif
        guard settings.blueParrottEnabled, savedOutputDeviceID == nil else { return }
        let outputID = MacAudioOutput.defaultOutputDeviceID()
        let outputUID = MacAudioOutput.deviceUID(outputID)
        let inputUID = MacAudioOutput.deviceUID(MacAudioOutput.defaultInputDeviceID())
        guard MacAudioOutput.shouldRerouteForCapture(outputUID: outputUID, inputUID: inputUID),
              let builtIn = MacAudioOutput.builtInOutputDeviceID() else { return }
        savedOutputDeviceID = outputID
        let ok = MacAudioOutput.setDefaultOutputDevice(builtIn)
        hLog("Headset: routed output off the headset for capture (\(outputUID ?? "?") → built-in, ok=\(ok)) so the HFP mic frees up")
    }

    /// Restore the headset as the default output so a spoken response plays in-ear. Called
    /// on TTS START (and as a deactivate cleanup) — NOT after every capture: re-establishing
    /// A2DP between back-to-back recordings silenced the mic. No-op when we didn't reroute.
    func restoreOutputAfterCapture() {
        #if DEBUG
        restoreOutputInvokedCount += 1
        #endif
        guard let saved = savedOutputDeviceID else { return }
        savedOutputDeviceID = nil
        let ok = MacAudioOutput.setDefaultOutputDevice(saved)
        outputOnHeadsetForTTS = true   // now on the headset for TTS; park back to built-in when it ends
        hLog("Headset: restored output to the headset for playback (ok=\(ok))")
    }

    /// On TTS end / dismiss, move output back to the built-in device so the headset's A2DP
    /// release settles during the gap before the next press (a capture opened while A2DP is
    /// still settling reads silence — confirmed: the first record right after a spoken
    /// response failed). No-op unless we had parked output on the headset for TTS.
    func parkOutputToBuiltInAfterTTS() {
        #if DEBUG
        parkOutputInvokedCount += 1
        #endif
        guard outputOnHeadsetForTTS else { return }
        outputOnHeadsetForTTS = false
        rerouteOutputForCaptureIfNeeded()   // headset → built-in (mic-ready resting state)
    }
    #endif

    private func stopSessionCaptureAndReadTranscription() {
        voiceInput.stopRecording()
        // NOTE: output is deliberately LEFT on the built-in device here — it is restored to
        // the headset only when a spoken response actually starts (the $isSpeaking sink).
        // Restoring after every capture re-established A2DP and the next recording's reroute
        // silenced the mic (rapid A2DP↔built-in cycling). Back-to-back recordings stay on
        // built-in so the mic keeps working.
        // ALWAYS emit transcription after stopCapture so `.finalizing` can't strand
        // (nil when nothing was recognized / on error). Deferred one run-loop hop so
        // the final recognition callback lands first.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let text = self.voiceInput.transcribedText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.handleSystemEvent(.transcription(text.isEmpty ? nil : text))
        }
    }

    // MARK: - Session timers (captureGrace / awaitResponse)

    private func armSessionTimer(_ timer: SessionTimer) {
        cancelSessionTimer(timer)
        let generation = (sessionTimerGenerations[timer] ?? 0) + 1
        sessionTimerGenerations[timer] = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self = self,
                  self.sessionTimerGenerations[timer] == generation else { return }
            self.sessionTimerWorkItems[timer] = nil
            self.sessionTimerFired(timer)
        }
        sessionTimerWorkItems[timer] = work
        sessionScheduleWork(sessionTimerDuration(timer), work)
    }

    private func cancelSessionTimer(_ timer: SessionTimer) {
        sessionTimerGenerations[timer] = (sessionTimerGenerations[timer] ?? 0) + 1
        sessionTimerWorkItems[timer]?.cancel()
        sessionTimerWorkItems[timer] = nil
    }

    private func sessionTimerDuration(_ timer: SessionTimer) -> TimeInterval {
        switch timer {
        case .captureGrace: return Self.captureGraceInterval
        case .awaitResponse: return Self.awaitResponseInterval
        }
    }

    private func sessionTimerFired(_ timer: SessionTimer) {
        switch timer {
        case .captureGrace:
            // The grace window elapsed. A cold Bluetooth SCO route delivers ≤1 silent
            // priming buffer then nothing (≥2 ⇒ a live ~10/grace stream): restart it,
            // up to `maxRestarts`, then finalize rather than looping (Risk 7). A live
            // but silent route (F2 warm-up) clears the bar and just lets the window
            // lapse. Decision is the pure `CaptureReadiness.graceOutcome`.
            let buffers = voiceInput.capturedBufferCount
            switch CaptureReadiness.graceOutcome(bufferCount: buffers, restartCount: captureRestartCount) {
            case .restart:
                captureRestartCount += 1
                hLog("Session: captureGrace — route cold (\(buffers) buffers) → restart \(captureRestartCount)/\(CaptureReadiness.maxRestarts)")
                handleSystemEvent(.captureStalled)
            case .finalize:
                hLog("Session: capture still cold after \(captureRestartCount) restart(s) (\(buffers) buffers) — finalizing (no loop)")
                handleSystemEvent(.captureEnded)
            case .live:
                hLog("Session: captureGrace elapsed — route live (\(buffers) buffers)")
            }
        case .awaitResponse:
            handleSystemEvent(.awaitTimedOut)
        }
    }

    /// Map a recognizer gesture to its session event.
    fileprivate static func sessionEvent(for gesture: HeadsetGesture) -> SessionEvent {
        switch gesture {
        case .holdStarted: return .holdStarted
        case .holdEnded:   return .holdEnded
        case .tap:         return .tap
        case .doubleTap:   return .doubleTap
        }
    }

    /// Media-key entry: AirPods stem / system media keys map play/pause→tap,
    /// next→doubleTap with `source: .mediaKey` (no hold semantics, keeps keep-alive).
    /// MPRemoteCommandCenter may invoke off-main, so hop to main first.
    private func handleMediaButton(_ event: SessionEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.handleButtonEvent(event, source: .mediaKey)
        }
    }
}

/// Display string for the macOS settings "State" row (parity with the retired
/// `HeadsetState.description`). `finalizing`/`awaitingResponse` both read "Processing".
extension SessionState {
    var description: String {
        switch self {
        case .idle: return "Ready"
        case .recording: return "Recording"
        case .finalizing, .awaitingResponse: return "Processing"
        case .speaking: return "Speaking"
        }
    }
}

// MARK: - BlueParrott BLE (macOS)

extension HeadsetRemoteCommandManager {

    /// Start the macOS BlueParrott button source, gated by `settings.blueParrottEnabled`
    /// (mirrors the iOS SDK path). The raw GATT stream flows BLE manager →
    /// `BlueParrottGestureRecognizer` (de-brackets every gesture into exactly one
    /// semantic gesture) → `SessionReducer` (via `handleButtonEvent`). The retired
    /// `BlueParrottPTTArbitrator` and the implicit `HeadsetState` guards are gone.
    func startBlueParrott() {
        guard blueParrottBLEManager == nil else { return }
        #if DEBUG
        let ble = makeBlueParrottBLEManager()
        #else
        let ble = BlueParrottBLEManager()
        #endif
        let recognizer = BlueParrottGestureRecognizer(
            emit: { [weak self] gesture in
                hLog("Headset: gesture \(gesture) → session event")
                self?.handleButtonEvent(Self.sessionEvent(for: gesture), source: .blueParrottBLE)
            },
            scheduleAfter: gestureScheduleAfter
        )
        gestureRecognizer = recognizer
        // Trace the raw de-bracketing stream so a flicker/strand can be read off the
        // log: raw signal in → recognizer → gesture out (above) → session event.
        ble.rawSignalSink = { [weak recognizer] signal in
            hLog("Headset: raw signal \(signal)")
            recognizer?.feed(signal)
        }
        // A disconnect WHILE recording feeds `captureEnded` so `.recording` can't
        // strand on an out-of-range mid-recording (Goal #2). `dropFirst` skips the
        // initial `isConnected == false`.
        bleDisconnectCancellable = ble.$isConnected
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] connected in
                guard let self = self, !connected else { return }
                self.handleSystemEvent(.captureEnded)
            }
        ble.start()
        blueParrottBLEManager = ble
        #if DEBUG
        // The Phase A2 explorer and the live client would otherwise both stand up a
        // CBCentralManager scanning the same service and contend; the persistence
        // experiment is concluded, so the live client takes over.
        stopGattExplorer()
        #endif
        hLog("Headset: BlueParrott BLE started (macOS CoreBluetooth → session reducer)")
    }

    func stopBlueParrott() {
        blueParrottBLEManager?.stop()
        blueParrottBLEManager = nil
        gestureRecognizer = nil
        bleDisconnectCancellable = nil
        hLog("Headset: BlueParrott BLE stopped (macOS)")
    }

    #if DEBUG
    // Phase A2: launch the CoreBluetooth GATT explorer for the App-Mode
    // persistence experiment. DEBUG-only; logs to category "BPExplore".
    func startGattExplorer() {
        guard gattExplorer == nil else { return }
        // Don't contend with the live BLE client for the same peripheral: when
        // BlueParrott is the active button source, the diagnostic explorer stays
        // parked (the persistence experiment it served is concluded).
        guard !settings.blueParrottEnabled else {
            hLog("Headset: BPGattExplorer skipped — BlueParrott BLE client is the active source")
            return
        }
        let explorer = BPGattExplorer()
        explorer.start()
        gattExplorer = explorer
        hLog("Headset: BPGattExplorer started (Phase A2 — macOS)")
    }

    func stopGattExplorer() {
        gattExplorer?.stop()
        gattExplorer = nil
    }
    #endif
}
#endif

// MARK: - Debug Test Hooks

#if DEBUG
extension HeadsetRemoteCommandManager {
    #if os(iOS)
    func simulateTogglePlayPause() {
        switch state {
        case .ready:
            startRecording()
        case .recording:
            stopRecordingAndSend()
        case .speaking:
            performInterrupt()
        case .sending:
            break
        }
    }

    func simulatePlay() {
        if state == .ready { startRecording() }
    }

    func simulatePause() {
        if state == .recording { stopRecordingAndSend() }
    }

    func simulateInterrupt() {
        performInterrupt()
    }

    /// Test hook: stand up the gesture recognizer (as `startBlueParrott` does), wired to
    /// `handleHeadsetGesture` and the injectable `gestureScheduleAfter`, WITHOUT a live
    /// BPHeadset SDK — so wiring tests can drive the real `BlueParrottButtonDelegate`
    /// methods and fire the hold timer deterministically.
    func testInstallGestureRecognizer() {
        gestureRecognizer = BlueParrottGestureRecognizer(
            emit: { [weak self] g in self?.handleHeadsetGesture(g) },
            scheduleAfter: { [weak self] delay, block in self?.gestureScheduleAfter(delay, block) })
    }
    #else
    // macOS test hooks: drive the session executor directly (gesture / media-key
    // inputs) and the injected session timers.
    func simulateMediaTap() { handleButtonEvent(.tap, source: .mediaKey) }
    func simulateMediaDoubleTap() { handleButtonEvent(.doubleTap, source: .mediaKey) }
    func testFireSessionTimer(_ timer: SessionTimer) { sessionTimerWorkItems[timer]?.perform() }
    func testHasArmedSessionTimer(_ timer: SessionTimer) -> Bool { sessionTimerWorkItems[timer] != nil }
    var testSessionState: SessionState { state }
    #endif
}
#endif
