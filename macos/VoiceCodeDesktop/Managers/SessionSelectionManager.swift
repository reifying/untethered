// SessionSelectionManager.swift
// Persists session selection across app launches per Appendix AB.1

import Foundation
import Combine
import OSLog
import VoiceCodeShared
import CoreData

private let logger = Logger(subsystem: "dev.910labs.voice-code-desktop", category: "SessionSelectionManager")

/// Manages session selection persistence across app launches.
/// Uses UserDefaults to remember the last selected session UUID.
class SessionSelectionManager: ObservableObject {
    private let sessionKey = "lastSelectedSessionId"
    private let directoryKey = "lastSelectedDirectory"

    /// Currently selected session ID (stored as lowercase UUID string)
    @Published var selectedSessionId: UUID? {
        didSet {
            if let id = selectedSessionId {
                let idString = id.uuidString.lowercased()
                UserDefaults.standard.set(idString, forKey: sessionKey)
                logger.info("📍 Session selection saved: \(idString.prefix(8))...")
            } else {
                UserDefaults.standard.removeObject(forKey: sessionKey)
                logger.info("📍 Session selection cleared")
            }
        }
    }

    /// Currently selected directory (for project-based navigation)
    @Published var selectedDirectory: String? {
        didSet {
            if let dir = selectedDirectory {
                UserDefaults.standard.set(dir, forKey: directoryKey)
                logger.info("📍 Directory selection saved: \(dir)")
            } else {
                UserDefaults.standard.removeObject(forKey: directoryKey)
                logger.info("📍 Directory selection cleared")
            }
        }
    }

    init() {
        // Restore session selection from UserDefaults
        if let idString = UserDefaults.standard.string(forKey: sessionKey),
           let id = UUID(uuidString: idString) {
            selectedSessionId = id
            logger.info("📍 Restored session selection: \(idString.prefix(8))...")
        }

        // Restore directory selection from UserDefaults
        if let dir = UserDefaults.standard.string(forKey: directoryKey) {
            selectedDirectory = dir
            logger.info("📍 Restored directory selection: \(dir)")
        }
    }

    /// Validate selection against available sessions.
    /// Clears selection if the session no longer exists.
    /// - Parameter sessions: Array of available sessions
    func validateSelection(against sessions: [CDBackendSession]) {
        if let id = selectedSessionId,
           !sessions.contains(where: { $0.id == id }) {
            logger.info("📍 Session \(id.uuidString.prefix(8))... no longer exists, clearing selection")
            selectedSessionId = nil
        }
    }

    /// Validate directory selection against available sessions.
    /// Clears selection if no sessions exist in the directory.
    /// - Parameter sessions: Array of available sessions
    func validateDirectorySelection(against sessions: [CDBackendSession]) {
        if let dir = selectedDirectory,
           !sessions.contains(where: { $0.workingDirectory == dir }) {
            logger.info("📍 Directory '\(dir)' no longer has sessions, clearing selection")
            selectedDirectory = nil
        }
    }

    /// Clear all selection state
    func clearSelection() {
        selectedSessionId = nil
        selectedDirectory = nil
    }
}
