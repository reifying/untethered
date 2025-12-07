// MenuBarCommands.swift
// Menu bar and keyboard shortcut definitions for macOS

import SwiftUI

// MARK: - Focused Values

struct FocusedConversationKey: FocusedValueKey {
    typealias Value = ConversationActions
}

extension FocusedValues {
    var conversationActions: FocusedConversationKey.Value? {
        get { self[FocusedConversationKey.self] }
        set { self[FocusedConversationKey.self] = newValue }
    }
}

// MARK: - Conversation Actions Protocol

protocol ConversationActions {
    func sendPrompt()
    func stopTurn()
    func copySessionID()
    func toggleRecording()
    func cancelInput()
    func compactSession()
    func showCommandMenu()
}

// MARK: - Command Menu Commands

struct SessionCommands: Commands {
    @FocusedValue(\.conversationActions) var conversationActions

    var body: some Commands {
        CommandMenu("Session") {
            Button("Send Prompt") {
                conversationActions?.sendPrompt()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(conversationActions == nil)

            Button("Stop Turn") {
                conversationActions?.stopTurn()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(conversationActions == nil)

            Divider()

            Button("Execute Command...") {
                conversationActions?.showCommandMenu()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(conversationActions == nil)

            Divider()

            Button("Compact Session") {
                conversationActions?.compactSession()
            }
            .disabled(conversationActions == nil)

            Divider()

            Button("Copy Session ID") {
                conversationActions?.copySessionID()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(conversationActions == nil)
        }
    }
}

struct VoiceCommands: Commands {
    @FocusedValue(\.conversationActions) var conversationActions

    var body: some Commands {
        CommandMenu("Voice") {
            Button("Toggle Recording") {
                conversationActions?.toggleRecording()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(conversationActions == nil)

            Button("Stop Speaking") {
                NotificationCenter.default.post(name: .stopSpeaking, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button("Cancel Input") {
                conversationActions?.cancelInput()
            }
            .keyboardShortcut(.escape)
            .disabled(conversationActions == nil)
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let stopSpeaking = Notification.Name("stopSpeaking")
}
