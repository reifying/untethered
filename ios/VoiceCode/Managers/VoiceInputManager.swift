// VoiceInputManager.swift
// Speech-to-text using Apple Speech Framework

import Foundation
import Speech
import AVFoundation

/// Manages speech recognition for voice input
///
/// Thread Safety: This class is isolated to the main actor since it updates
/// @Published properties for UI state. Speech recognition callbacks automatically
/// dispatch to the main thread.
@MainActor
class VoiceInputManager: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var transcribedText = ""
    @Published var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined

    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    var onTranscriptionComplete: ((String) -> Void)?

    override init() {
        super.init()
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        authorizationStatus = SFSpeechRecognizer.authorizationStatus()
    }

    // MARK: - Authorization

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                self.authorizationStatus = status
                completion(status == .authorized)
            }
        }
    }

    // MARK: - Recording

    func startRecording() {
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

        // Configure audio session
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("Failed to setup audio session: \(error)")
            return
        }

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

            if error != nil || result?.isFinal == true {
                self.stopRecording()
            }
        }

        DispatchQueue.main.async {
            self.isRecording = true
            self.transcribedText = ""
        }
    }

    func stopRecording() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()

        DispatchQueue.main.async {
            self.isRecording = false

            // Notify completion
            if !self.transcribedText.isEmpty {
                self.onTranscriptionComplete?(self.transcribedText)
            }
        }

        // Reset audio session
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Cleanup

    // deinit is nonisolated, so we can't safely call stopRecording() from here
    deinit {
        // Note: We can't safely call stopRecording() from deinit since it's not isolated to the main actor.
        // The audio engine and recognition task will be cleaned up when released.
        // This is acceptable since VoiceInputManager is typically a singleton that lives for the app lifetime.
    }
}
