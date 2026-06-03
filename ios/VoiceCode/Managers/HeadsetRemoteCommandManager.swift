import Foundation
import MediaPlayer
import Combine
import AVFoundation

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
    @Published private(set) var state: HeadsetState = .ready

    private let voiceInput: VoiceInputManager
    private let voiceOutput: VoiceOutputManager
    private let client: VoiceCodeClient
    private let settings: AppSettings
    private let resolveActiveSession: () -> (sessionId: UUID, workingDirectory: String)?
    private var cancellables = Set<AnyCancellable>()
    #if os(macOS)
    private var bluetoothMonitor: BluetoothAudioMonitor?
    /// macOS BlueParrott button source over CoreBluetooth. Mirrors the iOS
    /// `blueParrottManager` (BPHeadset SDK); both feed the shared, unchanged
    /// `BlueParrottButtonDelegate` mapping so the two platforms converge.
    private(set) var blueParrottBLEManager: BlueParrottBLEManager?
    /// Strong owner of the PTT arbitrator wired between the BLE manager and this
    /// manager's delegate mapping (the BLE manager holds its `delegate` weakly).
    private var blueParrottArbitrator: BlueParrottPTTArbitrator?
    #if DEBUG
    /// Test seam: override to inject a fake-`BLECentral`-backed `BlueParrottBLEManager`
    /// instead of standing up a real `CBCentralManager`. DEBUG-only so it adds no
    /// release surface; production always builds the real adapter.
    var makeBlueParrottBLEManager: () -> BlueParrottBLEManager = { BlueParrottBLEManager() }
    #endif
    #endif
    #if DEBUG && os(macOS)
    // Phase A2 GATT explorer: runs alongside the CoreAudio mute proxy in debug
    // macOS builds to observe the BlueParrott control service over CoreBluetooth
    // (the App-Mode persistence experiment). Diagnostic only; never ships.
    private var gattExplorer: BPGattExplorer?
    #endif
    private var keepAlivePlayer: AVAudioPlayer?
    #if os(iOS)
    private var interruptionObserver: NSObjectProtocol?
    private(set) var blueParrottManager: BlueParrottButtonManager?
    #endif

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

    init(voiceInput: VoiceInputManager,
         voiceOutput: VoiceOutputManager,
         client: VoiceCodeClient,
         settings: AppSettings,
         resolveActiveSession: @escaping () -> (sessionId: UUID, workingDirectory: String)? = {
             guard let sessionId = ActiveSessionManager.shared.activeSessionId else { return nil }
             let context = PersistenceController.shared.container.viewContext
             guard let session = try? context.fetch(
                 CDBackendSession.fetchBackendSession(id: sessionId)
             ).first else { return nil }
             return (sessionId, session.workingDirectory)
         }) {
        self.voiceInput = voiceInput
        self.voiceOutput = voiceOutput
        self.client = client
        self.settings = settings
        self.resolveActiveSession = resolveActiveSession

        hLog("Headset: init — headsetModeEnabled=\(settings.headsetModeEnabled), autoSend=\(settings.headsetAutoSend)")

        voiceOutput.$isSpeaking
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isSpeaking in
                guard let self = self, self.isActive else { return }
                if isSpeaking && self.state == .sending {
                    self.state = .speaking
                    self.updateNowPlayingState()
                } else if !isSpeaking && self.state == .speaking {
                    self.state = .ready
                    self.updateNowPlayingState()
                    #if os(iOS)
                    self.activateAudioSession()
                    #endif
                } else if !isSpeaking {
                    // TTS ended but state wasn't .speaking — e.g. session-history replay TTS
                    // or other out-of-band speech. Re-assert only if TTS actually changed our
                    // category (avoids 187 redundant rebuilds when session history is replayed).
                    #if os(iOS)
                    let s = AVAudioSession.sharedInstance()
                    if s.category != .playAndRecord || !s.categoryOptions.contains(.allowBluetoothA2DP) {
                        hLog("Headset: isSpeaking→false — session changed (was \(s.category.rawValue)/opts=\(s.categoryOptions.rawValue)), re-asserting")
                        self.activateAudioSession()
                    }
                    #endif
                }
            }
            .store(in: &cancellables)

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

        #if os(macOS)
        settings.$headsetPTTEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self = self, self.isActive else { return }
                if enabled {
                    self.startPTTMonitoring()
                } else {
                    self.stopPTTMonitoring()
                }
            }
            .store(in: &cancellables)
        #endif

        // Observe speech recognizer auto-finalize. When SFSpeechRecognizer hits
        // its silence timeout (~30s) it sets isRecording=false from inside the
        // recognition callback — without a second button press. If our state is
        // still .recording at that point, advance to the send flow so the user
        // doesn't need a second press to unstick the state machine.
        voiceInput.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording in
                guard let self = self, self.isActive else { return }
                if !isRecording && self.state == .recording {
                    hLog("Headset: isRecording→false while state=.recording (auto-finalize) — triggering send")
                    self.stopRecordingAndSend()
                }
            }
            .store(in: &cancellables)

        setupKeepAlive()

        // Drive the BlueParrott button source from the same toggle on both
        // platforms — iOS via the BPHeadset SDK (`BlueParrottButtonManager`),
        // macOS via CoreBluetooth (`BlueParrottBLEManager`). Both feed the shared
        // `BlueParrottButtonDelegate` mapping below.
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
        if settings.headsetPTTEnabled { startPTTMonitoring() }
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
        stopPTTMonitoring()
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
        state = .ready
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
            self?.handleTogglePlayPause()
            return .success
        }

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            self?.handlePlay()
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            self?.handlePause()
            return .success
        }

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.handleInterrupt()
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

    private func updateNowPlayingState() {
        let info: [String: Any]
        let playbackState: MPNowPlayingPlaybackState

        switch state {
        case .ready:
            info = [
                MPMediaItemPropertyTitle: "VoiceCode — Ready",
                MPMediaItemPropertyPlaybackDuration: 0,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: 0
            ]
            // Report .playing because we continuously output silent audio to hold
            // the Now Playing slot. This makes AirPods consistently send ❚❚ for a
            // single press, which handlePause() treats as a toggle.
            playbackState = .playing

        case .recording:
            info = [
                MPMediaItemPropertyTitle: "VoiceCode — Recording",
                MPMediaItemPropertyPlaybackDuration: 0,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: 0
            ]
            playbackState = .playing

        case .sending:
            info = [
                MPMediaItemPropertyTitle: "VoiceCode — Processing",
                MPMediaItemPropertyPlaybackDuration: 0,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: 0
            ]
            playbackState = .paused

        case .speaking:
            info = [
                MPMediaItemPropertyTitle: "VoiceCode — Speaking",
                MPMediaItemPropertyPlaybackDuration: 0,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: 0
            ]
            playbackState = .playing
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = playbackState
    }

    // MARK: - Button Handlers

    private func handleTogglePlayPause() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            #if os(iOS)
            hLog("Headset: ▶︎/❚❚ received — state=\(self.state), audioCategory=\(AVAudioSession.sharedInstance().category.rawValue)")
            #else
            hLog("Headset: ▶︎/❚❚ received — state=\(self.state)")
            #endif
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
            #if os(iOS)
            hLog("Headset: ❚❚ received — state=\(self.state), audioCategory=\(AVAudioSession.sharedInstance().category.rawValue)")
            #else
            hLog("Headset: ❚❚ received — state=\(self.state)")
            #endif
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
    }

    // MARK: - Recording Lifecycle

    private func startRecording() {
        guard client.isConnected else {
            hLogWarning("Headset: startRecording ignored — not connected to backend")
            return
        }
        #if os(iOS)
        hLog("Headset: startRecording — audioCategory=\(AVAudioSession.sharedInstance().category.rawValue) route=\(AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portName))")
        #endif
        state = .recording
        updateNowPlayingState()
        #if os(iOS)
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
        #else
        voiceInput.startRecording()
        hLog("Headset: recording started")
        #endif
    }

    private func stopRecordingAndSend() {
        #if os(iOS)
        hLog("Headset: stopRecordingAndSend — pre-stop audioCategory=\(AVAudioSession.sharedInstance().category.rawValue)")
        #endif
        voiceInput.stopRecording()
        #if os(iOS)
        // Re-assert .playback session so MPRemoteCommandCenter keeps routing
        // AirPod/headset button events to our app during the sending/ready gap.
        activateAudioSession()
        hLog("Headset: stopRecordingAndSend — post-reactivation audioCategory=\(AVAudioSession.sharedInstance().category.rawValue)")
        #endif
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
                return
            }

            hLog("Headset: transcription ready, length=\(text.count), autoSend=\(self.settings.headsetAutoSend)")
            if self.settings.headsetAutoSend {
                self.sendToActiveSession(text)
            } else {
                self.state = .ready
                self.updateNowPlayingState()
            }
        }
    }

    private func sendToActiveSession(_ text: String) {
        guard let (sessionId, workingDirectory) = resolveActiveSession() else {
            hLogWarning("Headset: auto-send failed — no active session")
            state = .ready
            updateNowPlayingState()
            return
        }

        let sessionIdStr = sessionId.uuidString.lowercased()
        hLog("Headset: sending prompt to session=\(sessionIdStr) textLength=\(text.count) dir=\(workingDirectory)")

        client.sessionSyncManager.createOptimisticMessage(
            sessionId: sessionId,
            text: text
        ) { _ in }

        var message: [String: Any] = [
            "type": "prompt",
            "text": text,
            "resume_session_id": sessionIdStr,
            "working_directory": workingDirectory
        ]

        if !settings.systemPrompt.isEmpty {
            message["system_prompt"] = settings.systemPrompt
        }

        client.sendMessage(message)
        hLog("Headset: prompt sent to session \(sessionIdStr)")
    }
}

// MARK: - Silent Audio Keep-Alive (cross-platform)

extension HeadsetRemoteCommandManager {

    func startKeepAlive() {
        keepAlivePlayer?.stop()
        setupKeepAlive()
        let played = keepAlivePlayer?.play() ?? false
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
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP])
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
        #if DEBUG && os(iOS)
        // Phase A1 collector: capture the SDK's GATT traffic (App-Mode enable
        // write + per-gesture notification bytes) for the macOS reimplementation.
        BPSniffer.install()
        #endif
        let bp = BlueParrottButtonManager()
        bp.delegate = self
        bp.start()
        blueParrottManager = bp
        hLog("Headset: BlueParrott SDK started")
    }

    func stopBlueParrott() {
        blueParrottManager?.stop()
        blueParrottManager = nil
        hLog("Headset: BlueParrott SDK stopped")
    }
}
#endif

// MARK: - BlueParrottButtonDelegate
//
// Cross-platform: shared by the iOS BPHeadset SDK path (`BlueParrottButtonManager`)
// and the macOS CoreBluetooth path (`BlueParrottBLEManager`). The state mapping is
// unchanged on both platforms so they converge on one downstream path
// (@docs/design/macos-blueparrott-corebluetooth.md §3).

extension HeadsetRemoteCommandManager: BlueParrottButtonDelegate {
    func blueParrottButtonDown() {
        hLog("Headset: BlueParrott button DOWN — state=\(self.state)")
        if state == .ready {
            startRecording()
        }
    }

    func blueParrottButtonUp() {
        hLog("Headset: BlueParrott button UP — state=\(self.state)")
        if state == .recording {
            stopRecordingAndSend()
        }
    }

    func blueParrottTap() {
        hLog("Headset: BlueParrott tap — state=\(self.state)")
        switch state {
        case .ready:
            startRecording()
        case .recording:
            stopRecordingAndSend()
        case .speaking:
            performInterrupt()
        case .sending:
            hLog("Headset: BlueParrott tap while sending — resetting to ready")
            state = .ready
            updateNowPlayingState()
        }
    }

    func blueParrottDoubleTap() {
        hLog("Headset: BlueParrott double-tap — state=\(self.state)")
        performInterrupt()
    }

    func blueParrottLongPress() {
        hLog("Headset: BlueParrott long-press — state=\(self.state)")
        performInterrupt()
    }
}

// MARK: - BlueParrott PTT Arbitrator (macOS)

#if os(macOS)
/// Reduces the raw BlueParrott GATT event stream to push-to-talk semantics before
/// it reaches the shared `BlueParrottButtonDelegate` mapping.
///
/// The hardware brackets every gesture with down/up: a hold streams `01,04,00`
/// (down, long-press ~1s in, up), a tap `01,00,02`, a double `01,00,01,00,03`
/// (see @docs/design/macos-blueparrott-corebluetooth.md §3 note 1). Forwarding all
/// five events into the state machine would double-drive it — e.g. the in-bracket
/// long-press would `performInterrupt` mid-recording. So the macOS path drives off
/// down/up (PTT) only and drops the in-bracket gesture-classification codes; a hold
/// of any length records on down and stops+sends on up.
///
/// This is the down/up-vs-gesture arbitration the design assigns to the macOS
/// rewire. It is an additive filter — the shared state mapping is unchanged.
/// (Discrete tap/double/long actions would need a separate, non-PTT button
/// configuration and are out of scope for the PTT path.)
final class BlueParrottPTTArbitrator: BlueParrottButtonDelegate {
    weak var downstream: BlueParrottButtonDelegate?

    init(downstream: BlueParrottButtonDelegate?) {
        self.downstream = downstream
    }

    func blueParrottButtonDown() { downstream?.blueParrottButtonDown() }
    func blueParrottButtonUp() { downstream?.blueParrottButtonUp() }

    // In-bracket gesture-classification codes — dropped so they don't double-drive
    // the PTT state machine alongside the down/up that bracket them.
    func blueParrottTap() {}
    func blueParrottDoubleTap() {}
    func blueParrottLongPress() {}
}
#endif

// MARK: - PTT Monitoring

#if os(macOS)
extension HeadsetRemoteCommandManager {

    func startPTTMonitoring() {
        guard bluetoothMonitor == nil else { return }
        let monitor = BluetoothAudioMonitor()
        // BluetoothAudioMonitor delivers onMuteChanged on DispatchQueue.main already
        // (AudioObjectAddPropertyListenerBlock is given DispatchQueue.main). No re-dispatch needed.
        monitor.startMonitoring { [weak self] isMuted in
            guard let self = self else { return }
            if !isMuted && self.state == .ready {
                self.startRecording()
            } else if isMuted && self.state == .recording {
                self.stopRecordingAndSend()
            }
        }
        bluetoothMonitor = monitor
    }

    func stopPTTMonitoring() {
        bluetoothMonitor?.stopMonitoring()
        bluetoothMonitor = nil
    }

    // MARK: - BlueParrott BLE (CoreBluetooth)

    /// Start the macOS BlueParrott button source, gated by `settings.blueParrottEnabled`
    /// (mirrors the iOS SDK path). Events flow BLE manager → PTT arbitrator → this
    /// manager's shared `BlueParrottButtonDelegate` mapping.
    ///
    /// The arbitrator is required because the raw GATT stream brackets every gesture
    /// with down/up (a hold streams `01,04,00`); feeding all five events straight
    /// into the state machine would double-drive it — the in-bracket long-press
    /// would `performInterrupt` mid-recording and the trailing up would then no-op,
    /// orphaning the recording. Per the design (§3 note 1) the macOS path drives off
    /// down/up (PTT) only and the arbitrator drops the in-bracket gesture codes. The
    /// state mapping itself is unchanged — the arbitrator is an additive filter.
    func startBlueParrott() {
        guard blueParrottBLEManager == nil else { return }
        #if DEBUG
        let ble = makeBlueParrottBLEManager()
        #else
        let ble = BlueParrottBLEManager()
        #endif
        let arbitrator = BlueParrottPTTArbitrator(downstream: self)
        ble.delegate = arbitrator
        blueParrottArbitrator = arbitrator
        ble.start()
        blueParrottBLEManager = ble
        #if DEBUG
        // The Phase A2 explorer and the live client would otherwise both stand up a
        // CBCentralManager scanning the same service and contend; the persistence
        // experiment is concluded, so the live client takes over.
        stopGattExplorer()
        #endif
        hLog("Headset: BlueParrott BLE started (macOS CoreBluetooth)")
    }

    func stopBlueParrott() {
        blueParrottBLEManager?.stop()
        blueParrottBLEManager = nil
        blueParrottArbitrator = nil
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
    #if os(macOS)
    var isPTTMonitoring: Bool { bluetoothMonitor != nil }
    #endif

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

    #if os(macOS)
    func simulateMuteChanged(isMuted: Bool) {
        if !isMuted && state == .ready {
            startRecording()
        } else if isMuted && state == .recording {
            stopRecordingAndSend()
        }
    }
    #endif
}
#endif
