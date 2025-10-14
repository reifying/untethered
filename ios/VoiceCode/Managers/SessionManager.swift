// SessionManager.swift
// Manages session persistence with UserDefaults

import Foundation
import Combine

class SessionManager: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var currentSession: Session?

    private let sessionsKey = "voice_code_sessions"
    private let currentSessionKey = "voice_code_current_session"

    init() {
        loadSessions()
    }

    // MARK: - Session Management

    func createSession(name: String, workingDirectory: String? = nil) -> Session {
        let session = Session(name: name, workingDirectory: workingDirectory)
        sessions.append(session)
        currentSession = session
        print("🆕 [SessionManager] Created NEW iOS session: \(session.id) ('\(session.name)') - claudeSessionId: nil")
        saveSessions()
        return session
    }

    func selectSession(_ session: Session) {
        print("🔄 [SessionManager] Switching to iOS session: \(session.id) ('\(session.name)') - claudeSessionId: \(session.claudeSessionId ?? "nil")")
        currentSession = session
        saveCurrentSessionId()
    }

    func updateSession(_ session: Session) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
            if currentSession?.id == session.id {
                currentSession = session
            }
            saveSessions()
        }
    }

    func deleteSession(_ session: Session) {
        sessions.removeAll { $0.id == session.id }
        if currentSession?.id == session.id {
            currentSession = sessions.first
        }
        saveSessions()
    }

    func addMessage(to session: Session, message: Message) {
        var updatedSession = session
        updatedSession.addMessage(message)
        updateSession(updatedSession)
    }

    func updateClaudeSessionId(for session: Session, sessionId: String) {
        print("💾 [SessionManager] Updating iOS session \(session.id) ('\(session.name)') claudeSessionId: \(session.claudeSessionId ?? "nil") -> \(sessionId)")
        var updatedSession = session
        updatedSession.updateClaudeSessionId(sessionId)
        updateSession(updatedSession)
    }

    // MARK: - Persistence

    private func loadSessions() {
        if let data = UserDefaults.standard.data(forKey: sessionsKey) {
            if let decoded = try? JSONDecoder().decode([Session].self, from: data) {
                sessions = decoded
            }
        }

        // Load current session
        if let currentId = UserDefaults.standard.string(forKey: currentSessionKey),
           let uuid = UUID(uuidString: currentId) {
            currentSession = sessions.first { $0.id == uuid }
        }

        // Create default session if none exist
        if sessions.isEmpty {
            let defaultSession = createSession(name: "Default Session")
            currentSession = defaultSession
        }
    }

    private func saveSessions() {
        if let encoded = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(encoded, forKey: sessionsKey)
        }
        saveCurrentSessionId()
    }

    private func saveCurrentSessionId() {
        if let currentId = currentSession?.id.uuidString {
            UserDefaults.standard.set(currentId, forKey: currentSessionKey)
        }
    }
}
