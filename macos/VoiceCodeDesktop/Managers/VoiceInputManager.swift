// VoiceInputManager.swift
// Speech-to-text using Apple Speech Framework for macOS

import Foundation
import Speech
import AVFoundation
import Combine
import OSLog

private let logger = Logger(subsystem: "dev.910labs.voice-code-desktop", category: "VoiceInputManager")

@MainActor
class VoiceInputManager: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var transcribedText = ""
    @Published var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined

    // macOS-specific: real-time audio levels for waveform visualization
    @Published var audioLevels: [Float] = []

    // macOS-specific: partial transcription for live preview
    @Published var partialTranscription = ""

    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // Number of audio level samples to keep for waveform display
    private let maxAudioLevelSamples = 50

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
                let authorized = status == .authorized
                if authorized {
                    logger.info("Speech recognition authorized")
                } else {
                    logger.warning("Speech recognition not authorized, status: \(String(describing: status))")
                }
                completion(authorized)
            }
        }
    }

    /// Request microphone access (required on macOS for AVAudioEngine)
    func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                if granted {
                    logger.info("Microphone access granted")
                } else {
                    logger.warning("Microphone access denied")
                }
                completion(granted)
            }
        }
    }

    // MARK: - Recording

    func startRecording() {
        // Prevent double-start which would install multiple audio taps
        guard !isRecording else {
            logger.debug("startRecording called while already recording, ignoring")
            return
        }

        // Check authorization
        guard authorizationStatus == .authorized else {
            logger.warning("Speech recognition not authorized, status: \(String(describing: self.authorizationStatus))")
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

        // Create audio engine
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else {
            logger.error("Unable to create audio engine")
            return
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Validate recording format
        guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
            logger.error("Invalid recording format: sampleRate=\(recordingFormat.sampleRate), channels=\(recordingFormat.channelCount)")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            recognitionRequest.append(buffer)

            // Calculate audio level for waveform visualization
            Task { @MainActor [weak self] in
                self?.processAudioBuffer(buffer)
            }
        }

        audioEngine.prepare()

        do {
            try audioEngine.start()
            logger.info("Audio engine started successfully")
        } catch {
            logger.error("Failed to start audio engine: \(error.localizedDescription)")
            cleanupAudioEngine()
            return
        }

        // Start recognition task
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self = self else { return }

                if let error = error {
                    // Check if it's a cancellation (not a real error)
                    let nsError = error as NSError
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                        // User cancelled - not an error
                        logger.debug("Recognition cancelled by user")
                    } else {
                        logger.error("Recognition error: \(error.localizedDescription)")
                    }
                }

                if let result = result {
                    let transcription = result.bestTranscription.formattedString
                    self.transcribedText = transcription

                    if result.isFinal {
                        // Final transcription
                        logger.info("Final transcription received: \(transcription.prefix(50))...")
                        self.partialTranscription = ""
                        self.stopRecording()
                        self.onTranscriptionComplete?(transcription)
                    } else {
                        // Partial transcription for live preview
                        self.partialTranscription = transcription
                    }
                } else if error != nil {
                    self.stopRecording()
                }
            }
        }

        isRecording = true
        transcribedText = ""
        partialTranscription = ""
        audioLevels = []
        logger.info("Recording started")
    }

    func stopRecording() {
        guard isRecording else { return }

        cleanupAudioEngine()
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        isRecording = false
        logger.info("Recording stopped")
    }

    // MARK: - Audio Processing

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        // Calculate RMS (root mean square) for audio level
        var sum: Float = 0
        for i in 0..<frameCount {
            let sample = channelData[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameCount))

        // Normalize to 0-1 range (assuming typical voice levels)
        // RMS values for voice are typically 0.01-0.3
        let normalizedLevel = min(1.0, rms * 5.0)

        audioLevels.append(normalizedLevel)

        // Keep only the most recent samples
        if audioLevels.count > maxAudioLevelSamples {
            audioLevels.removeFirst(audioLevels.count - maxAudioLevelSamples)
        }
    }

    // MARK: - Cleanup

    private func cleanupAudioEngine() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
    }

    deinit {
        // Note: This runs on whatever thread deallocates the manager
        // The audio engine will be cleaned up automatically when deallocated
        recognitionRequest?.endAudio()
    }
}
