// VoiceInputManager.swift
// Speech-to-text using Apple Speech Framework

import Foundation
import Speech
import AVFoundation
import os.log

private let logger = Logger(subsystem: "dev.910labs.voice-code", category: "VoiceInput")

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

    func startRecording() {
        // Stop TTS first so the mic doesn't pick up speech output AND so the
        // synthesizer fully releases the audio session before we flip it to
        // .record. Without waiting, the first tap of the mic during TTS would
        // configure the session while AVSpeechSynthesizer was still tearing
        // down, and the audio engine would start without producing audio
        // buffers — the user had to tap stop and tap mic again to recover.
        if let voiceOutputManager = voiceOutputManager, voiceOutputManager.isSpeaking {
            voiceOutputManager.stop { [weak self] in
                self?.startRecordingAfterTTSStopped()
            }
        } else {
            voiceOutputManager?.stop()
            startRecordingAfterTTSStopped()
        }
    }

    private func startRecordingAfterTTSStopped() {
        // Check authorization
        guard authorizationStatus == .authorized else {
            print("Speech recognition not authorized")
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
            // .mixWithOthers instead of .duckOthers: ducking the audiobook causes it
            // to react and reclaim the Now Playing slot, so AirPod presses stop
            // reaching our MPRemoteCommandCenter handlers after the first press.
            try audioSession.setCategory(.playAndRecord, mode: .default, options: .mixWithOthers)
            try audioSession.setActive(true)
            let msg = "VoiceInput: audio session → .playAndRecord/.default/.mixWithOthers (was \(prevCategory)/\(prevMode)) route=\(audioSession.currentRoute.inputs.map(\.portName))"
            logger.info("\(msg, privacy: .public)")
            LogManager.shared.log(msg, category: "VoiceInput")
        } catch {
            let msg = "VoiceInput: failed to configure audio session: \(error.localizedDescription) (was \(prevCategory)/\(prevMode))"
            logger.error("\(msg, privacy: .public)")
            LogManager.shared.log("❌ \(msg)", category: "VoiceInput")
            return
        }
        #endif
        // macOS: AVAudioEngine handles audio routing automatically

        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            print("Unable to create recognition request")
            return
        }

        recognitionRequest.shouldReportPartialResults = true

        // Create audio engine
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else {
            print("Unable to create audio engine")
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
            print("Failed to start audio engine: \(error)")
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
                logger.warning("VoiceInput: recognition ended with error: \(error.localizedDescription), isFinal=\(result?.isFinal ?? false)")
                self.stopRecording()
            } else if result?.isFinal == true {
                logger.info("VoiceInput: recognition finalized, text='\(result?.bestTranscription.formattedString ?? "")'")
                self.stopRecording()
            }
        }

        let startMsg = "VoiceInput: recording started — engine running, route=\(audioEngine.inputNode.outputFormat(forBus: 0).sampleRate)Hz"
        logger.info("\(startMsg, privacy: .public)")
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
        // .playback immediately after calling stopRecording(), and deactivating first creates
        // a race window where another app can seize the Now Playing slot. For non-headset
        // usage the session staying active in .playAndRecord until the next action is harmless.
        let sessionMsg = "VoiceInput: stopRecording — session left active, category=\(AVAudioSession.sharedInstance().category.rawValue)"
        logger.info("\(sessionMsg, privacy: .public)")
        LogManager.shared.log(sessionMsg, category: "VoiceInput")
        #endif

        logger.info("VoiceInput: recording stopped")
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
