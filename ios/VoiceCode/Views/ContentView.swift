// ContentView.swift
// Main UI for voice-code app

import SwiftUI

struct ContentView: View {
    @StateObject private var sessionManager = SessionManager()
    @StateObject private var voiceInput = VoiceInputManager()
    @StateObject private var voiceOutput = VoiceOutputManager()
    @StateObject private var settings = AppSettings()

    @State private var client: VoiceCodeClient?
    @State private var inputText = ""
    @State private var isVoiceMode = true
    @State private var showingSettings = false
    @State private var showingSessions = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Message list
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            if let session = sessionManager.currentSession {
                                ForEach(session.messages) { message in
                                    MessageView(message: message)
                                }
                            }
                        }
                        .padding()
                    }
                    .onChange(of: sessionManager.currentSession?.messages.count) { _ in
                        // Auto-scroll to bottom on new message
                        if let lastMessage = sessionManager.currentSession?.messages.last {
                            withAnimation {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                }

                Divider()

                // Input area
                VStack(spacing: 12) {
                    // Mode toggle
                    HStack {
                        Button(action: { isVoiceMode.toggle() }) {
                            HStack {
                                Image(systemName: isVoiceMode ? "mic.fill" : "keyboard")
                                Text(isVoiceMode ? "Voice Mode" : "Text Mode")
                            }
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(8)
                        }

                        Spacer()

                        if let client = client {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(client.isConnected ? Color.green : Color.red)
                                    .frame(width: 8, height: 8)
                                Text(client.isConnected ? "Connected" : "Disconnected")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal)

                    // Voice mode
                    if isVoiceMode {
                        VoiceInputView(
                            voiceInput: voiceInput,
                            onTranscriptionComplete: { text in
                                sendPrompt(text)
                            }
                        )
                    } else {
                        // Text mode
                        TextInputView(
                            text: $inputText,
                            onSend: {
                                sendPrompt(inputText)
                                inputText = ""
                            }
                        )
                    }

                    // Error display
                    if let error = client?.currentError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical, 12)
                .background(Color(UIColor.systemBackground))
            }
            .navigationTitle(sessionManager.currentSession?.name ?? "Voice Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { showingSessions = true }) {
                        Image(systemName: "list.bullet")
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gear")
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(
                settings: settings,
                onServerChange: { newURL in
                    // Update client with new server URL
                    client?.updateServerURL(newURL)
                },
                voiceOutputManager: voiceOutput
            )
        }
        .sheet(isPresented: $showingSessions) {
            SessionsView(sessionManager: sessionManager)
        }
        .onAppear {
            setupClient()
            setupVoiceInput()
        }
    }

    // MARK: - Setup

    private func setupClient() {
        let client = VoiceCodeClient(serverURL: settings.fullServerURL)

        client.onMessageReceived = { message in
            if let session = sessionManager.currentSession {
                sessionManager.addMessage(to: session, message: message)

                // Speak the response using selected voice
                voiceOutput.speak(message.text, voiceIdentifier: settings.selectedVoiceIdentifier)
            }
        }

        client.onSessionIdReceived = { sessionId in
            if let session = sessionManager.currentSession {
                print("💾 [ContentView] Storing session_id '\(sessionId)' to iOS session: \(session.id) ('\(session.name)')")
                sessionManager.updateClaudeSessionId(for: session, sessionId: sessionId)
            } else {
                print("⚠️ [ContentView] Received session_id but no current session!")
            }
        }

        client.onReplayReceived = { message in
            if let session = sessionManager.currentSession {
                print("🔄 [ContentView] Adding replayed message to session")
                sessionManager.addMessage(to: session, message: message)
            }
        }

        // Connect with iOS session UUID
        if let session = sessionManager.currentSession {
            print("🔌 [ContentView] Connecting with iOS session UUID: \(session.id)")
            client.connect(sessionId: session.id.uuidString)
        } else {
            print("⚠️ [ContentView] No current session, connecting without session ID")
            client.connect()
        }

        self.client = client
    }

    private func setupVoiceInput() {
        voiceInput.requestAuthorization { authorized in
            if !authorized {
                print("Speech recognition not authorized")
            }
        }
    }

    // MARK: - Actions

    private func sendPrompt(_ text: String) {
        guard let session = sessionManager.currentSession else { return }

        print("📝 [ContentView] Sending prompt from iOS session: \(session.id)")
        print("📝 [ContentView] iOS session name: '\(session.name)'")
        print("📝 [ContentView] claudeSessionId: \(session.claudeSessionId ?? "nil")")
        print("📝 [ContentView] workingDirectory: \(session.workingDirectory ?? "nil")")

        // Add user message
        let userMessage = Message(role: .user, text: text)
        sessionManager.addMessage(to: session, message: userMessage)

        // Send to backend
        client?.sendPrompt(
            text,
            sessionId: session.claudeSessionId,
            workingDirectory: session.workingDirectory
        )
    }
}

// MARK: - Voice Input View

struct VoiceInputView: View {
    @ObservedObject var voiceInput: VoiceInputManager
    let onTranscriptionComplete: (String) -> Void

    var body: some View {
        VStack {
            if voiceInput.isRecording {
                Button(action: {
                    voiceInput.stopRecording()
                    if !voiceInput.transcribedText.isEmpty {
                        onTranscriptionComplete(voiceInput.transcribedText)
                    }
                }) {
                    VStack {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.red)
                        Text("Tap to Stop")
                            .font(.caption)
                    }
                    .frame(width: 100, height: 100)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(50)
                }
            } else {
                Button(action: {
                    voiceInput.startRecording()
                }) {
                    VStack {
                        Image(systemName: "mic")
                            .font(.system(size: 40))
                        Text("Tap to Speak")
                            .font(.caption)
                    }
                    .frame(width: 100, height: 100)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(50)
                }
            }

            if !voiceInput.transcribedText.isEmpty {
                Text(voiceInput.transcribedText)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .padding()
            }
        }
    }
}

// MARK: - Text Input View

struct TextInputView: View {
    @Binding var text: String
    let onSend: () -> Void

    var body: some View {
        HStack {
            TextField("Type your message...", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)

            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(text.isEmpty ? .gray : .blue)
            }
            .disabled(text.isEmpty)
        }
        .padding(.horizontal)
    }
}
