//
//  AppCommands.swift
//  VoiceCodeDesktop
//
//  Keyboard shortcuts and menu commands per Appendix G of macos-desktop-design.md
//

import SwiftUI
import VoiceCodeShared
import AppKit

// MARK: - Focused Value Keys

/// Focused value key for message input text
struct MessageInputKey: FocusedValueKey {
    typealias Value = Binding<String>
}

/// Focused value key for triggering message send
struct SendMessageActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

/// Focused value key for showing session info
struct ShowSessionInfoKey: FocusedValueKey {
    typealias Value = () -> Void
}

/// Focused value key for sessions list (for navigation)
struct SessionsListKey: FocusedValueKey {
    typealias Value = [CDBackendSession]
}

/// Focused value key for session selection binding
struct SelectedSessionBindingKey: FocusedValueKey {
    typealias Value = Binding<CDBackendSession?>
}

extension FocusedValues {
    var messageInput: Binding<String>? {
        get { self[MessageInputKey.self] }
        set { self[MessageInputKey.self] = newValue }
    }

    var sendMessageAction: (() -> Void)? {
        get { self[SendMessageActionKey.self] }
        set { self[SendMessageActionKey.self] = newValue }
    }

    var showSessionInfoAction: (() -> Void)? {
        get { self[ShowSessionInfoKey.self] }
        set { self[ShowSessionInfoKey.self] = newValue }
    }

    var sessionsList: [CDBackendSession]? {
        get { self[SessionsListKey.self] }
        set { self[SessionsListKey.self] = newValue }
    }

    var selectedSessionBinding: Binding<CDBackendSession?>? {
        get { self[SelectedSessionBindingKey.self] }
        set { self[SelectedSessionBindingKey.self] = newValue }
    }
}

// MARK: - AppCommands

/// Main commands structure for the application menu bar
/// Implements File, Edit, Session, View, and Window menu commands per Appendix G
struct AppCommands: Commands {
    @FocusedValue(\.selectedSession) var selectedSession
    @FocusedValue(\.voiceCodeClient) var client
    @FocusedValue(\.messageInput) var messageInput
    @FocusedValue(\.sendMessageAction) var sendMessageAction
    @FocusedValue(\.showSessionInfoAction) var showSessionInfoAction
    @FocusedValue(\.sessionsList) var sessionsList
    @FocusedValue(\.selectedSessionBinding) var selectedSessionBinding

    var body: some Commands {
        // File menu - replace default new item with our session actions
        FileMenuCommands()

        // Edit menu additions - Find command
        EditMenuCommands()

        // Session menu - custom menu for session operations
        SessionMenuCommands(
            selectedSession: selectedSession,
            client: client,
            messageInput: messageInput,
            sendMessageAction: sendMessageAction,
            showSessionInfoAction: showSessionInfoAction
        )

        // View menu additions - Queue toggles and session navigation
        ViewMenuCommands(
            sessionsList: sessionsList,
            selectedSessionBinding: selectedSessionBinding
        )

        // Window menu - session 1-9 shortcuts
        WindowMenuCommands(
            sessionsList: sessionsList,
            selectedSessionBinding: selectedSessionBinding
        )
    }
}

// MARK: - File Menu Commands

/// File menu: New Session, New Window
struct FileMenuCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") {
                NotificationCenter.default.post(
                    name: .requestNewSession,
                    object: nil
                )
            }
            .keyboardShortcut("n")

            Button("New Window") {
                NotificationCenter.default.post(
                    name: .requestNewWindow,
                    object: nil
                )
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }
}

// MARK: - Edit Menu Commands

/// Edit menu additions: Find
struct EditMenuCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()

            Button("Find...") {
                NotificationCenter.default.post(
                    name: .requestFind,
                    object: nil
                )
            }
            .keyboardShortcut("f")
        }
    }
}

// MARK: - Session Menu Commands

/// Session menu: Send, Refresh, Compact, Kill, Delete, Info, Copy ID
struct SessionMenuCommands: Commands {
    let selectedSession: CDBackendSession?
    let client: VoiceCodeClient?
    let messageInput: Binding<String>?
    let sendMessageAction: (() -> Void)?
    let showSessionInfoAction: (() -> Void)?

    private var hasSession: Bool {
        selectedSession != nil && client != nil
    }

    private var canSendMessage: Bool {
        guard let input = messageInput?.wrappedValue else { return false }
        return !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some Commands {
        CommandMenu("Session") {
            Button("Send Message") {
                sendMessageAction?()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSendMessage)

            Divider()

            Button("Refresh Session") {
                guard let session = selectedSession, let client = client else { return }
                client.requestSessionRefresh(sessionId: session.backendSessionId)
            }
            .keyboardShortcut("r")
            .disabled(!hasSession)

            Button("Compact Session...") {
                guard let session = selectedSession else { return }
                NotificationCenter.default.post(
                    name: .requestSessionCompaction,
                    object: nil,
                    userInfo: ["sessionId": session.backendSessionId]
                )
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!hasSession)

            Button("Kill Session") {
                guard let session = selectedSession else { return }
                NotificationCenter.default.post(
                    name: .requestSessionKill,
                    object: nil,
                    userInfo: ["sessionId": session.backendSessionId]
                )
            }
            .disabled(!hasSession)

            Divider()

            Button("Delete Session...", role: .destructive) {
                guard let session = selectedSession else { return }
                NotificationCenter.default.post(
                    name: .requestSessionDeletion,
                    object: nil,
                    userInfo: ["sessionId": session.id]
                )
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(selectedSession == nil)

            Divider()

            Button("Session Info") {
                showSessionInfoAction?()
            }
            .keyboardShortcut("i")
            .disabled(!hasSession)

            Button("Copy Session ID") {
                guard let session = selectedSession else { return }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(session.backendSessionId, forType: .string)
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(!hasSession)
        }
    }
}

// MARK: - View Menu Commands

/// View menu additions: Queue toggles, Previous/Next Session
struct ViewMenuCommands: Commands {
    let sessionsList: [CDBackendSession]?
    let selectedSessionBinding: Binding<CDBackendSession?>?

    private var sessions: [CDBackendSession] {
        sessionsList ?? []
    }

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()

            Button("Toggle Queue") {
                NotificationCenter.default.post(
                    name: .toggleQueueVisibility,
                    object: nil
                )
            }
            .keyboardShortcut("q", modifiers: [.command, .shift])

            Button("Toggle Priority Queue") {
                NotificationCenter.default.post(
                    name: .togglePriorityQueueVisibility,
                    object: nil
                )
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Divider()

            Button("Previous Session") {
                navigateSession(direction: .previous)
            }
            .keyboardShortcut("[")
            .disabled(sessions.isEmpty)

            Button("Next Session") {
                navigateSession(direction: .next)
            }
            .keyboardShortcut("]")
            .disabled(sessions.isEmpty)
        }
    }

    private enum NavigationDirection {
        case previous, next
    }

    private func navigateSession(direction: NavigationDirection) {
        guard !sessions.isEmpty,
              let binding = selectedSessionBinding else { return }

        // Sort sessions by last modified for consistent ordering
        let sortedSessions = sessions.sorted { $0.lastModified > $1.lastModified }

        if let currentSession = binding.wrappedValue,
           let currentIndex = sortedSessions.firstIndex(where: { $0.id == currentSession.id }) {
            // Navigate relative to current session
            let newIndex: Int
            switch direction {
            case .previous:
                newIndex = currentIndex > 0 ? currentIndex - 1 : sortedSessions.count - 1
            case .next:
                newIndex = currentIndex < sortedSessions.count - 1 ? currentIndex + 1 : 0
            }
            binding.wrappedValue = sortedSessions[newIndex]
        } else {
            // No current selection - select first or last
            switch direction {
            case .previous:
                binding.wrappedValue = sortedSessions.last
            case .next:
                binding.wrappedValue = sortedSessions.first
            }
        }
    }
}

// MARK: - Window Menu Commands

/// Window menu: Session 1-9 shortcuts
struct WindowMenuCommands: Commands {
    let sessionsList: [CDBackendSession]?
    let selectedSessionBinding: Binding<CDBackendSession?>?

    private var sessions: [CDBackendSession] {
        sessionsList ?? []
    }

    var body: some Commands {
        CommandGroup(before: .windowList) {
            // Session 1-9 shortcuts
            ForEach(0..<min(9, sessions.count), id: \.self) { index in
                let session = sortedSessions[index]
                Button("Session \(index + 1): \(sessionName(session))") {
                    selectedSessionBinding?.wrappedValue = session
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }

            if !sessions.isEmpty {
                Divider()
            }
        }
    }

    private var sortedSessions: [CDBackendSession] {
        sessions.sorted { $0.lastModified > $1.lastModified }
    }

    private func sessionName(_ session: CDBackendSession) -> String {
        // Use backend name or truncated ID
        if !session.backendName.isEmpty {
            return String(session.backendName.prefix(20))
        }
        return String(session.id.uuidString.lowercased().prefix(8))
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Request to open a new session
    static let requestNewSession = Notification.Name("requestNewSession")

    /// Request to open a new window
    static let requestNewWindow = Notification.Name("requestNewWindow")

    /// Request to show find interface
    static let requestFind = Notification.Name("requestFind")

    /// Toggle queue section visibility
    static let toggleQueueVisibility = Notification.Name("toggleQueueVisibility")

    /// Toggle priority queue section visibility
    static let togglePriorityQueueVisibility = Notification.Name("togglePriorityQueueVisibility")

    /// Open a specific session (from notification tap)
    /// userInfo contains "sessionId" key
    static let openSession = Notification.Name("openSession")

    /// Request to delete a session (soft delete with confirmation)
    /// userInfo contains "sessionId" key (UUID)
    static let requestSessionDeletion = Notification.Name("requestSessionDeletion")
}
