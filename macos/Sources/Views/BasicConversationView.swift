// BasicConversationView.swift
// Basic conversation interface for testing WebSocket connectivity

import SwiftUI
import UntetheredCore

struct BasicConversationView: View {
    @EnvironmentObject var client: VoiceCodeClient
    @State private var promptText = ""
    @State private var messages: [DisplayMessage] = []
    @State private var currentSessionId: String?

    // Create a stable iOS session ID for this conversation
    private let iosSessionId = UUID().uuidString.lowercased()

    var body: some View {
        VStack(spacing: 0) {
            // Message list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            MessageRow(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _ in
                    if let lastMessage = messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Input area
            HStack(spacing: 12) {
                TextField("Enter prompt...", text: $promptText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(8)
                    .lineLimit(1...5)
                    .onSubmit {
                        sendPrompt()
                    }

                Button(action: sendPrompt) {
                    Image(systemName: "paperplane.fill")
                        .foregroundColor(.white)
                }
                .buttonStyle(.borderedProminent)
                .disabled(promptText.isEmpty || !client.isConnected)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .onAppear {
            setupMessageHandler()
        }
    }

    private func setupMessageHandler() {
        client.onMessageReceived = { message, receivedIosSessionId in
            guard receivedIosSessionId == iosSessionId else { return }

            let displayMessage = DisplayMessage(
                id: message.id,
                role: message.role,
                text: message.text,
                timestamp: message.timestamp
            )

            Task { @MainActor in
                messages.append(displayMessage)
            }
        }

        client.onSessionIdReceived = { sessionId in
            Task { @MainActor in
                currentSessionId = sessionId
            }
        }
    }

    private func sendPrompt() {
        guard !promptText.isEmpty else { return }

        let userMessage = DisplayMessage(
            id: UUID(),
            role: .user,
            text: promptText,
            timestamp: Date()
        )
        messages.append(userMessage)

        client.sendPrompt(
            promptText,
            iosSessionId: iosSessionId,
            sessionId: currentSessionId,
            workingDirectory: nil
        )

        promptText = ""
    }
}

// Local model for display (to avoid conflicts with UntetheredCore.Message)
struct DisplayMessage: Identifiable {
    let id: UUID
    let role: MessageRole
    let text: String
    let timestamp: Date
}

struct MessageRow: View {
    let message: DisplayMessage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Role indicator
            Image(systemName: message.role == .user ? "person.fill" : "cpu")
                .foregroundColor(message.role == .user ? .blue : .green)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(message.role == .user ? "You" : "Assistant")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                Text(message.text)
                    .textSelection(.enabled)

                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
