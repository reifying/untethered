// ConversationDetailView.swift
// Main conversation view for a selected session

import SwiftUI
import CoreData
import UntetheredCore

struct ConversationDetailView: View {
    @ObservedObject var session: CDBackendSession
    @EnvironmentObject var client: VoiceCodeClient
    @EnvironmentObject var settings: AppSettings
    @Environment(\.managedObjectContext) private var viewContext

    @State private var promptText = ""
    @State private var hasPerformedInitialScroll = false

    // Fetch messages for this session
    @FetchRequest private var messages: FetchedResults<CDMessage>

    init(session: CDBackendSession) {
        _session = ObservedObject(wrappedValue: session)
        _messages = FetchRequest(
            fetchRequest: CDMessage.fetchMessages(sessionId: session.id),
            animation: nil
        )
    }

    // Check if session is locked
    private var isSessionLocked: Bool {
        let claudeSessionId = session.id.uuidString.lowercased()
        return client.lockedSessions.contains(claudeSessionId)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text(session.displayName(context: viewContext))
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                if isSessionLocked {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Processing...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Messages area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            MessageRowView(message: message)
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
                .onAppear {
                    if !hasPerformedInitialScroll, let lastMessage = messages.last {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        hasPerformedInitialScroll = true
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
                    .disabled(isSessionLocked || !client.isConnected)

                Button(action: sendPrompt) {
                    Image(systemName: "paperplane.fill")
                        .foregroundColor(.white)
                }
                .buttonStyle(.borderedProminent)
                .disabled(promptText.isEmpty || isSessionLocked || !client.isConnected)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    private func sendPrompt() {
        guard !promptText.isEmpty, !isSessionLocked else { return }

        // Create optimistic user message in CoreData
        let userMessage = CDMessage(context: viewContext)
        userMessage.id = UUID()
        userMessage.sessionId = session.id
        userMessage.role = "user"
        userMessage.text = promptText
        userMessage.timestamp = Date()
        userMessage.messageStatus = .sending
        userMessage.session = session

        do {
            try viewContext.save()
        } catch {
            print("Failed to save user message: \(error)")
        }

        // Send prompt to backend
        let claudeSessionId = session.id.uuidString.lowercased()
        client.sendPrompt(
            promptText,
            iosSessionId: session.id.uuidString.lowercased(),
            sessionId: claudeSessionId,
            workingDirectory: session.workingDirectory
        )

        promptText = ""
    }
}

// MARK: - Message Row

struct MessageRowView: View {
    @ObservedObject var message: CDMessage

    private var roleIcon: String {
        message.role == "user" ? "person.fill" : "cpu"
    }

    private var roleColor: Color {
        message.role == "user" ? .blue : .green
    }

    private var roleName: String {
        message.role == "user" ? "You" : "Assistant"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Role indicator
            Image(systemName: roleIcon)
                .foregroundColor(roleColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(roleName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    if message.messageStatus == .sending {
                        ProgressView()
                            .scaleEffect(0.6)
                    }
                }

                Text(message.displayText)
                    .textSelection(.enabled)

                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
