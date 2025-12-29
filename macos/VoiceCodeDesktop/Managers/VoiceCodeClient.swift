// VoiceCodeClient.swift
// macOS-specific VoiceCodeClient with NSApplication lifecycle observers

import Foundation
import AppKit
import Combine
import OSLog
import VoiceCodeShared

private let logger = Logger(subsystem: "dev.910labs.voice-code-desktop", category: "VoiceCodeClient")

/// macOS-specific VoiceCodeClient with NSApplication lifecycle observers
@MainActor
final class VoiceCodeClient: VoiceCodeClientCore {

    // MARK: - Platform-specific Properties

    private var appSettings: AppSettings?
    private var voiceOutputManager: VoiceOutputManager?
    private var syncDelegate: VoiceCodeSyncDelegate?

    // MARK: - Initialization

    init(
        serverURL: String,
        voiceOutputManager: VoiceOutputManager? = nil,
        sessionSyncManager: SessionSyncManager? = nil,
        appSettings: AppSettings? = nil,
        persistenceController: PersistenceController? = nil,
        setupObservers: Bool = true
    ) {
        self.appSettings = appSettings
        self.voiceOutputManager = voiceOutputManager

        super.init(
            serverURL: serverURL,
            sessionSyncManager: sessionSyncManager,
            persistenceController: persistenceController,
            setupObservers: setupObservers
        )

        // Set up the delegate for platform-specific callbacks
        let delegate = VoiceCodeSyncDelegate(
            voiceOutputManager: voiceOutputManager,
            appSettings: appSettings
        )
        self.syncDelegate = delegate
        self.sessionSyncManager.delegate = delegate
    }

    // MARK: - Lifecycle Observers

    override func setupLifecycleObservers() {
        // Reconnect when app becomes active (returns from background/hidden)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if !self.isConnected {
                    logger.info("App became active, attempting reconnection")
                    self.retryConnection()
                }
            }
        }

        // Handle app going to background/hidden
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                logger.info("App resigned active")
                // Unlike iOS, we don't need to handle background mode differently
                // macOS apps continue running when not active
            }
        }

        // Handle app termination
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                logger.info("App will terminate, disconnecting")
                self.disconnect()
            }
        }

        // Handle system sleep
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                logger.info("System will sleep, disconnecting")
                self.disconnect()
            }
        }

        // Handle system wake
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                logger.info("System woke up, reconnecting")
                self.connect()
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}

// MARK: - VoiceCodeSyncDelegate

/// Bridge between SessionSyncManager and macOS-specific functionality
final class VoiceCodeSyncDelegate: SessionSyncDelegate {
    nonisolated(unsafe) private weak var voiceOutputManager: VoiceOutputManager?
    nonisolated(unsafe) private weak var appSettings: AppSettings?

    nonisolated init(voiceOutputManager: VoiceOutputManager?, appSettings: AppSettings?) {
        self.voiceOutputManager = voiceOutputManager
        self.appSettings = appSettings
    }

    @MainActor
    func isSessionActive(_ sessionId: UUID) -> Bool {
        ActiveSessionManager.shared.isActive(sessionId)
    }

    @MainActor
    func speakAssistantMessages(_ messages: [String], workingDirectory: String) {
        guard let voiceOutput = voiceOutputManager else { return }

        let combinedText = messages.joined(separator: " ")
        if !combinedText.isEmpty {
            voiceOutput.speak(combinedText, respectSilentMode: true, workingDirectory: workingDirectory)
        }
    }

    @MainActor
    func postNotification(text: String, sessionId: String, sessionName: String, workingDirectory: String) {
        Task { @MainActor in
            await NotificationManager.shared.postResponseNotification(
                text: text,
                sessionId: sessionId,
                sessionName: sessionName,
                workingDirectory: workingDirectory
            )
        }
    }

    @MainActor
    var isPriorityQueueEnabled: Bool {
        appSettings?.priorityQueueEnabled ?? false
    }
}
