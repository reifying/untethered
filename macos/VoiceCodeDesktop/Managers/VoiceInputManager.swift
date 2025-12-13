// VoiceInputManager.swift
// Speech-to-text using Apple Speech Framework for macOS

import Foundation
import Speech
import Combine
import OSLog

private let logger = Logger(subsystem: "dev.910labs.voice-code-desktop", category: "VoiceInputManager")

@MainActor
class VoiceInputManager: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var transcribedText = ""
    @Published var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined

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
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                self?.authorizationStatus = status
                completion(status == .authorized)
            }
        }
    }

    // MARK: - Recording

    func startRecording() {
        // Check authorization
        guard authorizationStatus == .authorized else {
            logger.warning("Speech recognition not authorized")
            return
        }

        // Cancel any ongoing recognition
        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
        }

        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            logger.error("Unable to create recognition request")
            return
        }

        recognitionRequest.shouldReportPartialResults = true

        // Start recognition task with default microphone input
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self = self else { return }

                if let result = result {
                    let transcription = result.bestTranscription.formattedString
                    self.transcribedText = transcription
                }

                if error != nil || result?.isFinal == true {
                    self.stopRecording()
                }
            }
        }

        isRecording = true
        transcribedText = ""
    }

    func stopRecording() {
        recognitionRequest?.endAudio()
        isRecording = false
    }

    // MARK: - Cleanup

    nonisolated private func cleanupOnDeinit() {
        Task { @MainActor in
            // No-op, deinit happens automatically
        }
    }

    deinit {
        // Let stopRecording be called implicitly when recognitionRequest is deallocated
        recognitionRequest?.endAudio()
    }
}
