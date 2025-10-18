// ConversationView.swift
// Displays conversation for a selected CoreData session with lazy loading

import SwiftUI
import CoreData

struct ConversationView: View {
    let session: CDSession
    @ObservedObject var client: VoiceCodeClient
    @StateObject var voiceOutput: VoiceOutputManager
    @StateObject var voiceInput: VoiceInputManager
    @ObservedObject var settings: AppSettings
    @Environment(\.managedObjectContext) private var viewContext

    @State private var isLoading = false
    @State private var hasLoadedMessages = false
    @State private var promptText = ""
    @State private var isVoiceMode = true
    @State private var showingRenameSheet = false
    @State private var newSessionName = ""
    @State private var showingCopyConfirmation = false

    // Fetch messages for this session
    @FetchRequest private var messages: FetchedResults<CDMessage>

    init(session: CDSession, client: VoiceCodeClient, voiceOutput: VoiceOutputManager = VoiceOutputManager(), voiceInput: VoiceInputManager = VoiceInputManager(), settings: AppSettings) {
        self.session = session
        self.client = client
        _voiceOutput = StateObject(wrappedValue: voiceOutput)
        _voiceInput = StateObject(wrappedValue: voiceInput)
        self.settings = settings

        // Setup fetch request for this session's messages
        _messages = FetchRequest(
            fetchRequest: CDMessage.fetchMessages(sessionId: session.id),
            animation: .default
        )
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Messages area
            ScrollViewReader { proxy in
                ScrollView {
                    if isLoading {
                        VStack(spacing: 16) {
                            ProgressView()
                            Text("Loading conversation...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 100)
                    } else if messages.isEmpty && hasLoadedMessages {
                        VStack(spacing: 16) {
                            Image(systemName: "message")
                                .font(.system(size: 64))
                                .foregroundColor(.secondary)
                            Text("No messages yet")
                                .font(.title2)
                                .foregroundColor(.secondary)
                            Text("Start a conversation to see messages here.")
                                .font(.body)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 100)
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(messages) { message in
                                CDMessageView(message: message, voiceOutput: voiceOutput, settings: settings)
                                    .id(message.id)
                            }
                        }
                        .padding()
                    }
                }
                .onChange(of: messages.count) { _ in
                    // Auto-scroll to bottom on new message
                    if let lastMessage = messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }
            
            Divider()
            
            // Input area
            VStack(spacing: 12) {
                // Mode toggle and connection status
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
                    
                    HStack(spacing: 4) {
                        Circle()
                            .fill(client.isConnected ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(client.isConnected ? "Connected" : "Disconnected")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)
                
                // Voice mode
                if isVoiceMode {
                    ConversationVoiceInputView(
                        voiceInput: voiceInput,
                        onTranscriptionComplete: { text in
                            sendPromptText(text)
                        }
                    )
                } else {
                    // Text mode
                    ConversationTextInputView(
                        text: $promptText,
                        onSend: {
                            sendPromptText(promptText)
                            promptText = ""
                        }
                    )
                }
                
                // Error display
                if let error = client.currentError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                }
            }
            .padding(.vertical, 12)
            .background(Color(UIColor.systemBackground))
        }
        .navigationTitle(session.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    Button(action: exportSessionToPlainText) {
                        Image(systemName: "doc.on.clipboard")
                    }
                    
                    Button(action: {
                        newSessionName = session.localName ?? session.backendName
                        showingRenameSheet = true
                    }) {
                        Image(systemName: "pencil")
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if showingCopyConfirmation {
                Text("Conversation copied to clipboard")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.9))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showingRenameSheet) {
            RenameSessionView(
                sessionName: $newSessionName,
                onSave: {
                    renameSession(newName: newSessionName)
                    showingRenameSheet = false
                },
                onCancel: {
                    showingRenameSheet = false
                }
            )
        }
        .onAppear {
            loadSessionIfNeeded()
            setupVoiceInput()
        }
        .onDisappear {
            // Clear active session for smart speaking
            ActiveSessionManager.shared.clearActiveSession()

            // Unsubscribe when leaving the conversation
            client.unsubscribe(sessionId: session.id.uuidString)
        }
    }
    
    private func setupVoiceInput() {
        voiceInput.requestAuthorization { authorized in
            if !authorized {
                print("Speech recognition not authorized")
            }
        }
    }
    
    private func loadSessionIfNeeded() {
        guard !hasLoadedMessages else { return }

        isLoading = true
        hasLoadedMessages = true

        // Mark session as active for smart speaking
        ActiveSessionManager.shared.setActiveSession(session.id)

        // Clear unread count when opening session
        session.unreadCount = 0
        try? viewContext.save()

        // Subscribe to the session to load full history
        client.subscribe(sessionId: session.id.uuidString)

        // Stop loading indicator after a delay (messages will populate via CoreData sync)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            isLoading = false
        }
    }
    
    private func renameSession(newName: String) {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        // Set localName to the custom name
        session.localName = trimmedName

        // Save to CoreData
        do {
            try viewContext.save()
            print("📝 [ConversationView] Renamed session to: \(trimmedName)")
        } catch {
            print("❌ [ConversationView] Failed to rename session: \(error)")
        }
    }

    private func sendPromptText(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        // Create optimistic message
        client.sessionSyncManager.createOptimisticMessage(sessionId: session.id, text: trimmedText) { messageId in
            print("Created optimistic message: \(messageId)")
        }

        // Determine if this is a new session (no messages yet) or existing session
        let isNewSession = session.messageCount == 0

        // Send prompt to backend
        // - New sessions: use new_session_id (backend will create .jsonl file)
        // - Existing sessions: use resume_session_id (backend appends to existing file)
        var message: [String: Any] = [
            "type": "prompt",
            "text": trimmedText,
            "working_directory": session.workingDirectory
        ]

        if isNewSession {
            message["new_session_id"] = session.id.uuidString
            print("📤 [ConversationView] Sending prompt with new_session_id: \(session.id.uuidString)")
        } else {
            message["resume_session_id"] = session.id.uuidString
            print("📤 [ConversationView] Sending prompt with resume_session_id: \(session.id.uuidString)")
        }

        client.sendMessage(message)
    }
    
    private func exportSessionToPlainText() {
        // Format session header
        var exportText = "# \(session.displayName)\n"
        exportText += "Working Directory: \(session.workingDirectory)\n"
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        exportText += "Exported: \(dateFormatter.string(from: Date()))\n"
        exportText += "\n---\n\n"
        
        // Add all messages in chronological order
        for message in messages {
            let roleLabel = message.role == "user" ? "User" : "Assistant"
            exportText += "[\(roleLabel)]\n"
            exportText += "\(message.text)\n\n"
        }
        
        // Copy to clipboard
        UIPasteboard.general.string = exportText
        
        // Show confirmation banner
        withAnimation {
            showingCopyConfirmation = true
        }
        
        // Hide confirmation after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                showingCopyConfirmation = false
            }
        }
    }
}

// MARK: - CoreData Message View

struct CDMessageView: View {
    @ObservedObject var message: CDMessage
    @ObservedObject var voiceOutput: VoiceOutputManager
    @ObservedObject var settings: AppSettings

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Role indicator
            Image(systemName: message.role == "user" ? "person.circle.fill" : "cpu")
                .font(.title3)
                .foregroundColor(message.role == "user" ? .blue : .green)

            VStack(alignment: .leading, spacing: 4) {
                // Role label
                Text(message.role.capitalized)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                // Message text
                Text(message.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .contextMenu {
                        Button(action: {
                            UIPasteboard.general.string = message.text
                        }) {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        
                        Button(action: {
                            voiceOutput.speak(message.text, voiceIdentifier: settings.selectedVoiceIdentifier)
                        }) {
                            Label("Read Aloud", systemImage: "speaker.wave.2.fill")
                        }
                    }
                
                // Status and timestamp
                HStack(spacing: 8) {
                    if message.messageStatus == .sending {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Sending...")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else if message.messageStatus == .error {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundColor(.red)
                        Text("Failed to send")
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                    
                    Spacer()
                    
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(message.role == "user" ? Color.blue.opacity(0.1) : Color.green.opacity(0.1))
        )
    }
}

// MARK: - Rename Session View

struct RenameSessionView: View {
    @Binding var sessionName: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Session Name")) {
                    TextField("Enter session name", text: $sessionName)
                        .textInputAutocapitalization(.words)
                }
            }
            .navigationTitle("Rename Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", action: onCancel)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        onSave()
                    }
                    .disabled(sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - Voice Input View

struct ConversationVoiceInputView: View {
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

struct ConversationTextInputView: View {
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
