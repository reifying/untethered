// VoicePanelManager.swift
// Coordinates global hotkey with floating voice panel activation

import Combine
import Foundation
import OSLog

private let logger = Logger(subsystem: "dev.910labs.voice-code-desktop", category: "VoicePanelManager")

/// Coordinates the global hotkey with the floating voice panel.
/// Handles hotkey press to show/hide the panel and delivers transcriptions to the active context.
@MainActor
class VoicePanelManager: ObservableObject {
    // MARK: - Published Properties

    /// Whether the voice panel is currently visible
    @Published private(set) var isPanelVisible = false

    /// Error message from hotkey registration (nil if successful)
    @Published var hotkeyError: String? {
        didSet {
            if let error = hotkeyError {
                logger.warning("Hotkey error: \(error)")
            }
        }
    }

    // MARK: - Dependencies

    private let hotkeyManager: GlobalHotkeyManager
    private let voiceInput: VoiceInputManager
    private let panelController: FloatingVoicePanelController

    // MARK: - Callbacks

    /// Called when voice transcription is complete and accepted by the user.
    /// The String parameter contains the transcribed text.
    var onTranscriptionComplete: ((String) -> Void)?

    // MARK: - Initialization

    init(hotkeyManager: GlobalHotkeyManager, voiceInput: VoiceInputManager) {
        self.hotkeyManager = hotkeyManager
        self.voiceInput = voiceInput
        self.panelController = FloatingVoicePanelController(voiceInput: voiceInput)

        setupBindings()
        logger.debug("VoicePanelManager initialized")
    }

    /// Convenience initializer that creates its own managers
    convenience init() {
        self.init(hotkeyManager: GlobalHotkeyManager(), voiceInput: VoiceInputManager())
    }

    /// Convenience initializer that uses AppSettings for hotkey configuration.
    /// The GlobalHotkeyManager will automatically sync with settings changes.
    convenience init(appSettings: AppSettings) {
        self.init(
            hotkeyManager: GlobalHotkeyManager(appSettings: appSettings),
            voiceInput: VoiceInputManager()
        )
    }

    // MARK: - Setup

    private func setupBindings() {
        // Listen for hotkey presses
        hotkeyManager.onHotkeyPressed = { [weak self] in
            self?.handleHotkeyPressed()
        }

        // Forward transcription completions
        panelController.onTranscriptionComplete = { [weak self] text in
            self?.handleTranscriptionComplete(text)
        }

        // Track panel visibility
        panelController.$isVisible
            .assign(to: &$isPanelVisible)

        // Track hotkey errors
        hotkeyManager.$registrationError
            .assign(to: &$hotkeyError)
    }

    // MARK: - Public API

    /// Start the voice panel system by registering the global hotkey.
    /// Call this when the app is ready to accept voice input.
    func start() {
        logger.info("Starting VoicePanelManager")
        hotkeyManager.register()

        if hotkeyManager.isRegistered {
            logger.info("Global hotkey registered: \(self.hotkeyManager.hotkeyDescription)")
        } else if let error = hotkeyManager.registrationError {
            logger.warning("Failed to register hotkey: \(error)")
        }
    }

    /// Stop the voice panel system and unregister the global hotkey.
    func stop() {
        logger.info("Stopping VoicePanelManager")
        panelController.hide()
        hotkeyManager.invalidate()
    }

    /// Manually show the floating voice panel.
    func showPanel() {
        panelController.show()
    }

    /// Manually hide the floating voice panel.
    func hidePanel() {
        panelController.hide()
    }

    /// Toggle the floating voice panel visibility.
    func togglePanel() {
        panelController.toggle()
    }

    /// Check if voice input is authorized and ready.
    /// - Returns: true if speech recognition is authorized
    var isVoiceInputAuthorized: Bool {
        voiceInput.authorizationStatus == .authorized
    }

    /// Request voice input authorization (speech recognition + microphone).
    /// - Parameter completion: Called with true if both permissions are granted
    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        voiceInput.requestAuthorization { [weak self] speechGranted in
            guard speechGranted else {
                completion(false)
                return
            }

            self?.voiceInput.requestMicrophoneAccess { micGranted in
                completion(micGranted)
            }
        }
    }

    // MARK: - Private

    private func handleHotkeyPressed() {
        logger.debug("Hotkey pressed, toggling panel")
        togglePanel()
    }

    private func handleTranscriptionComplete(_ text: String) {
        guard !text.isEmpty else {
            logger.debug("Empty transcription ignored")
            return
        }

        logger.info("Transcription complete: \(text.prefix(50))...")
        onTranscriptionComplete?(text)
    }

    // MARK: - Cleanup

    deinit {
        // Note: MainActor deinit - cleanup handled by stop()
    }
}
