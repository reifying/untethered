import Foundation
import MediaPlayer
import Combine
import os.log
#if os(iOS)
import AVFoundation
#endif

private let logger = Logger(subsystem: "dev.910labs.voice-code", category: "HeadsetRemote")

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
    #if os(iOS)
    private var keepAlivePlayer: AVAudioPlayer?
    private var keepAliveTimer: Timer?
    private var interruptionObserver: NSObjectProtocol?
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

        #if os(iOS)
        setupKeepAlive()
        #endif
    }

    func activate() {
        guard !isActive else { return }
        registerRemoteCommands()
        #if os(macOS)
        if settings.headsetPTTEnabled { startPTTMonitoring() }
        #elseif os(iOS)
        activateAudioSession()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self = self, self.isActive else { return }
            guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue),
                  type == .ended else { return }
            let shouldResume = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .flatMap { AVAudioSession.InterruptionOptions(rawValue: $0) }
                .map { $0.contains(.shouldResume) } ?? false
            if shouldResume {
                self.activateAudioSession()
                logger.info("Headset: audio session restored after interruption")
            }
        }
        #endif
        updateNowPlayingState()
        isActive = true
        logger.info("Headset remote control activated")
    }

    func deactivate() {
        guard isActive else { return }
        // Stop recording first — otherwise the audio engine stays live after deactivation.
        if state == .recording {
            voiceInput.stopRecording()
        }
        #if os(macOS)
        stopPTTMonitoring()
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
        logger.info("Headset remote control deactivated")
    }

    func reclaimNowPlaying() {
        guard settings.headsetModeEnabled else { return }
        updateNowPlayingState()
        logger.info("Headset: reclaimed now-playing slot")
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
            playbackState = .paused

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
            switch self.state {
            case .ready:
                self.startRecording()
            case .recording:
                self.stopRecordingAndSend()
            case .speaking:
                self.performInterrupt()
            case .sending:
                break
            }
        }
    }

    private func handlePlay() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.state == .ready {
                self.startRecording()
            }
        }
    }

    private func handlePause() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.state == .recording {
                self.stopRecordingAndSend()
            }
        }
    }

    private func handleInterrupt() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
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
        logger.info("Headset interrupt: stopped TTS")
    }

    // MARK: - Recording Lifecycle

    private func startRecording() {
        guard client.isConnected else {
            logger.warning("Headset record ignored: not connected")
            return
        }
        state = .recording
        updateNowPlayingState()
        voiceInput.startRecording()
        logger.info("Headset: recording started")
    }

    private func stopRecordingAndSend() {
        voiceInput.stopRecording()
        #if os(iOS)
        // Re-assert playback session now that .record is released.
        // Without this, MPRemoteCommandCenter loses our app as the delivery
        // target during the sending/ready gap before TTS starts.
        activateAudioSession()
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
                logger.info("Headset: empty transcription, returning to ready")
                self.state = .ready
                self.updateNowPlayingState()
                return
            }

            if self.settings.headsetAutoSend {
                self.sendToActiveSession(text)
            } else {
                self.state = .ready
                self.updateNowPlayingState()
            }
            logger.info("Headset: recording stopped, text length=\(text.count)")
        }
    }

    private func sendToActiveSession(_ text: String) {
        guard let (sessionId, workingDirectory) = resolveActiveSession() else {
            logger.warning("Headset: no active session for auto-send")
            state = .ready
            updateNowPlayingState()
            return
        }

        let sessionIdStr = sessionId.uuidString.lowercased()

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
        logger.info("Headset: sent prompt to session \(sessionIdStr)")
    }
}

// MARK: - iOS Audio Session Keep-Alive

#if os(iOS)
extension HeadsetRemoteCommandManager {

    func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setActive(true)
            startKeepAlive()
            logger.info("Headset: iOS audio session activated (.playback + .mixWithOthers)")
        } catch {
            logger.error("Headset: failed to activate audio session: \(error.localizedDescription)")
        }
    }

    func deactivateAudioSession() {
        stopKeepAlive()
        do {
            try AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation
            )
            logger.info("Headset: iOS audio session deactivated")
        } catch {
            logger.error("Headset: failed to deactivate audio session: \(error.localizedDescription)")
        }
    }

    private func startKeepAlive() {
        stopKeepAlive()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: true) { [weak self] _ in
            self?.keepAlivePlayer?.play()
        }
    }

    private func stopKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }

    private func setupKeepAlive() {
        // 100ms silent PCM buffer — identical to VoiceOutputManager.setupSilencePlayer()
        let sampleRate: Double = 44100.0
        let frameCount = UInt32(0.1 * sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("headset_silence.caf")
        do {
            let file = try AVAudioFile(forWriting: tempURL, settings: format.settings)
            try file.write(from: buffer)
            keepAlivePlayer = try AVAudioPlayer(contentsOf: tempURL)
            keepAlivePlayer?.prepareToPlay()
        } catch {
            logger.error("Headset: failed to create silence player: \(error.localizedDescription)")
        }
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
