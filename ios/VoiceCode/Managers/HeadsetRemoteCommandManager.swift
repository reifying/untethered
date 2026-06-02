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

        #if os(iOS)
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
        #endif
    }

    func activate() {
        guard !isActive else { return }
        hLog("Headset: activating remote control")
        registerRemoteCommands()
        #if os(macOS)
        if settings.headsetPTTEnabled { startPTTMonitoring() }
        startKeepAlive()
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

// MARK: - BlueParrottButtonDelegate

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
