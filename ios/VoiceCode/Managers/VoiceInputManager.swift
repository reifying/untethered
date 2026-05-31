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

    var onTranscriptionComplete: ((String) -> Void)?

    init(voiceOutputManager: VoiceOutputManager? = nil) {
        self.voiceOutputManager = voiceOutputManager
        super.init()
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        authorizationStatus = SFSpeechRecognizer.authorizationStatus()
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
        // Check authorization
        guard authorizationStatus == .authorized else {
            LogManager.shared.log("Speech recognition not authorized", category: "VoiceInput")
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
            let msg = "VoiceInput: audio session → .playAndRecord/.default (was \(prevCategory)/\(prevMode)) route=\(audioSession.currentRoute.inputs.map(\.portName))"
            LogManager.shared.log(msg, category: "VoiceInput")
            // Notify caller that session is in .playAndRecord context. Dispatched
            // async on main so it runs after this function returns and after
            // audioEngine.start() — but still in the .playAndRecord session.
            // HeadsetRemoteCommandManager uses this to reconstruct the silence player
            // in the new session context so it actually starts outputting audio.
            DispatchQueue.main.async { onSessionReady?() }
        } catch {
            let msg = "VoiceInput: failed to configure audio session: \(error.localizedDescription) (was \(prevCategory)/\(prevMode))"
            LogManager.shared.log("❌ \(msg)", category: "VoiceInput")
            return
        }
        #endif
        // macOS: AVAudioEngine handles audio routing automatically

        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            LogManager.shared.log("Unable to create recognition request", category: "VoiceInput")
            return
        }

        recognitionRequest.shouldReportPartialResults = true

        // Create audio engine
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else {
            LogManager.shared.log("Unable to create audio engine", category: "VoiceInput")
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
            LogManager.shared.log("Failed to start audio engine: \(error)", category: "VoiceInput")
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
                LogManager.shared.log("VoiceInput: recognition ended with error: \(error.localizedDescription), isFinal=\(result?.isFinal ?? false)", category: "VoiceInput")
                self.stopRecording()
            } else if result?.isFinal == true {
                LogManager.shared.log("VoiceInput: recognition finalized, text='\(result?.bestTranscription.formattedString ?? "")'", category: "VoiceInput")
                self.stopRecording()
            }
        }

        let startMsg = "VoiceInput: recording started — engine running, route=\(audioEngine.inputNode.outputFormat(forBus: 0).sampleRate)Hz"
        LogManager.shared.log(startMsg, category: "VoiceInput")
        DispatchQueue.main.async {
            self.isRecording = true
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
        let sessionMsg = "VoiceInput: stopRecording — session left active, category=\(AVAudioSession.sharedInstance().category.rawValue)"
        LogManager.shared.log(sessionMsg, category: "VoiceInput")
        #endif

        LogManager.shared.log("VoiceInput: recording stopped", category: "VoiceInput")
        DispatchQueue.main.async {
            self.isRecording = false
        }
    }

    // MARK: - Cleanup

    deinit {
        if isRecording {
            stopRecording()
        }
    }
}
