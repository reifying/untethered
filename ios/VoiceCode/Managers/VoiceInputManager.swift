// VoiceInputManager.swift
// Speech-to-text using Apple Speech Framework

import Foundation
import Speech
import AVFoundation

class VoiceInputManager: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var transcribedText = ""
    @Published var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined

    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Reference to voice output manager for muting TTS during recording
    private weak var voiceOutputManager: VoiceOutputManager?

    /// True while THIS instance holds the recording-active gate raised on the
    /// shared VoiceOutputManager. Multiple VoiceInputManagers share one
    /// VoiceOutputManager (one per ConversationView, plus the macOS menu-bar
    /// instance), so deinit must release ONLY the gate this instance owns —
    /// clearing unconditionally would let a non-recording manager's deallocation
    /// wipe the gate another manager raised while actively recording, re-opening
    /// the TTS-into-open-mic feedback loop. Tracked in lockstep with
    /// `voiceOutputManager.isRecordingActive`. Internal (not private) so the
    /// ownership invariant can be exercised in tests, mirroring `isRecordingActive`.
    var didRaiseRecordingGate = false

    var onTranscriptionComplete: ((String) -> Void)?

    init(voiceOutputManager: VoiceOutputManager? = nil) {
        self.voiceOutputManager = voiceOutputManager
        super.init()
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        authorizationStatus = SFSpeechRecognizer.authorizationStatus()
    }

    private func log(_ message: String) {
        LogManager.shared.log(message, category: "VoiceInput")
    }

    // MARK: - Authorization

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        // Skip permission prompts during UI tests to prevent blocking automation
        if TestingEnvironment.isUITesting {
            completion(false)
            return
        }

        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                self.authorizationStatus = status
                completion(status == .authorized)
            }
        }
    }

    // MARK: - Recording

    /// Start recording.
    ///
    /// `onSessionReady` is called (on the main queue) immediately after the iOS
    /// audio session has been switched to `.playAndRecord` — before the audio
    /// engine starts. This lets the caller (e.g. `HeadsetRemoteCommandManager`)
    /// restart any audio-output keep-alive player in the correct session context,
    /// so it doesn't lose the Now Playing slot mid-recording.
    func startRecording(onSessionReady: (() -> Void)? = nil) {
        // Gate up FIRST — blocks any new speech (e.g. WebSocket-delivered
        // assistant messages auto-spoken by SessionSyncManager) from being
        // enqueued during the async window between here and audio session
        // configuration. Cleared in stopRecording() or on any error exit below.
        voiceOutputManager?.isRecordingActive = true
        didRaiseRecordingGate = true

        // Stop TTS first so the mic doesn't pick up speech output AND so the
        // synthesizer fully releases the audio session before we flip it to
        // .record. Without waiting, the first tap of the mic during TTS would
        // configure the session while AVSpeechSynthesizer was still tearing
        // down, and the audio engine would start without producing audio
        // buffers — the user had to tap stop and tap mic again to recover.
        if let voiceOutputManager = voiceOutputManager, voiceOutputManager.isSpeaking {
            voiceOutputManager.stop { [weak self] in
                self?.startRecordingAfterTTSStopped(onSessionReady: onSessionReady)
            }
        } else {
            voiceOutputManager?.stop()
            startRecordingAfterTTSStopped(onSessionReady: onSessionReady)
        }
    }

    private func startRecordingAfterTTSStopped(onSessionReady: (() -> Void)? = nil) {
        // Clear the recording-active gate on any early/error return below; only
        // the successful path keeps it raised. A single defer covers every
        // current and future error path automatically — no per-exit cleanup to
        // forget (a stuck-true flag would suppress all TTS until app relaunch).
        var recordingStarted = false
        defer {
            if !recordingStarted {
                voiceOutputManager?.isRecordingActive = false
                didRaiseRecordingGate = false
            }
        }

        // Check authorization
        guard authorizationStatus == .authorized else {
            log("Speech recognition not authorized")
            return
        }

        // Cancel any ongoing recognition
        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
        }

        #if os(iOS)
        // iOS requires explicit audio session configuration.
        // .playAndRecord keeps the app in the Now Playing slot so MPRemoteCommandCenter
        // continues delivering AirPod/headset button events during recording.
        // .record alone loses playback capability and causes the second button press
        // to be routed to another app instead of ours.
        // .allowBluetooth enables the Bluetooth HFP mic (AirPods, headsets) for input.
        let audioSession = AVAudioSession.sharedInstance()
        let prevCategory = audioSession.category.rawValue
        let prevMode = audioSession.mode.rawValue
        do {
            // No .allowBluetooth — that forces AirPods into HFP mode which breaks
            // MPRemoteCommandCenter stem-press delivery. Device mic is used instead,
            // which gives better quality than HFP's 16kHz anyway.
            // No .mixWithOthers — it disqualifies us from being the Now Playing app,
            // which means iOS stops delivering AVRCP commands (AirPod stem clicks)
            // to our MPRemoteCommandCenter handlers.
            // .allowBluetoothA2DP: without this, .playAndRecord routes output to
            // the earpiece [Receiver] rather than AirPods. Our silence keep-alive
            // player must output to AirPods via A2DP or they route stem presses
            // elsewhere. Does NOT activate HFP — AirPods stay in A2DP mode.
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP])
            try audioSession.setActive(true)
            log("VoiceInput: audio session → .playAndRecord/.default (was \(prevCategory)/\(prevMode)) route=\(audioSession.currentRoute.inputs.map(\.portName))")
            // Notify caller that session is in .playAndRecord context. Dispatched
            // async on main so it runs after this function returns and after
            // audioEngine.start() — but still in the .playAndRecord session.
            // HeadsetRemoteCommandManager uses this to reconstruct the silence player
            // in the new session context so it actually starts outputting audio.
            DispatchQueue.main.async { onSessionReady?() }
        } catch {
            log("❌ VoiceInput: failed to configure audio session: \(error.localizedDescription) (was \(prevCategory)/\(prevMode))")
            return
        }
        #endif
        // macOS: AVAudioEngine handles audio routing automatically

        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            log("Unable to create recognition request")
            return
        }

        recognitionRequest.shouldReportPartialResults = true

        // Create audio engine
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else {
            log("Unable to create audio engine")
            return
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            recognitionRequest.append(buffer)
        }

        audioEngine.prepare()

        do {
            try audioEngine.start()
        } catch {
            log("Failed to start audio engine: \(error)")
            return
        }

        // Start recognition task
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let transcription = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.transcribedText = transcription
                }
            }

            if let error = error {
                self.log("VoiceInput: recognition ended with error: \(error.localizedDescription), isFinal=\(result?.isFinal ?? false)")
                self.stopRecording()
            } else if result?.isFinal == true {
                self.log("VoiceInput: recognition finalized, text='\(result?.bestTranscription.formattedString ?? "")'")
                self.stopRecording()
            }
        }

        recordingStarted = true
        log("VoiceInput: recording started — engine running, route=\(audioEngine.inputNode.outputFormat(forBus: 0).sampleRate)Hz")
        DispatchQueue.main.async {
            self.isRecording = true
            // Keep the gate consistent with isRecording: if stopRecording() ran
            // during the async stop-completion window and cleared the flag,
            // re-raise it so TTS stays suppressed while the mic is actually open.
            self.voiceOutputManager?.isRecordingActive = true
            self.didRaiseRecordingGate = true
            self.transcribedText = ""
        }
    }

    func stopRecording() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()

        #if os(iOS)
        // Do NOT deactivate the audio session here. HeadsetRemoteCommandManager re-asserts
        // .playAndRecord immediately after calling stopRecording(), and deactivating first
        // creates a race window where another app can seize the Now Playing slot. For
        // non-headset usage the session staying active in .playAndRecord is harmless.
        log("VoiceInput: stopRecording — session left active, category=\(AVAudioSession.sharedInstance().category.rawValue)")
        #endif

        log("VoiceInput: recording stopped")
        DispatchQueue.main.async {
            self.isRecording = false
            // Gate down — allow TTS to resume now that the mic is closed.
            self.voiceOutputManager?.isRecordingActive = false
            self.didRaiseRecordingGate = false
            // Note: onTranscriptionComplete callback is never set - handled by view layer instead
        }
    }

    // MARK: - Cleanup

    deinit {
        // Release the recording gate ONLY if this instance currently owns it.
        // stopRecording() clears it via an async main-queue hop, but only when
        // isRecording is true; if we are deallocated during the stop-completion
        // window — after startRecording() raised the gate but before isRecording
        // flipped true — neither path runs and the gate would stick true on the
        // (surviving) VoiceOutputManager, suppressing ALL TTS until app relaunch.
        // The ownership check is essential because multiple VoiceInputManagers
        // share one VoiceOutputManager: an unconditional clear here would let a
        // non-recording manager's deallocation wipe the gate another manager
        // raised while actively recording, re-opening the feedback loop.
        if didRaiseRecordingGate {
            voiceOutputManager?.isRecordingActive = false
        }
        if isRecording {
            stopRecording()
        }
    }
}
