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
    @StateObject private var voiceInputManager = VoiceInputManager()
    @StateObject private var voiceOutputManager: VoiceOutputManager
    @State private var isSpaceBarPressed = false
    @State private var showPermissionAlert = false
    @State private var permissionAlertMessage = ""
    @State private var conversationActionsImpl: ConversationActionsImpl?
    @State private var showCommandMenu = false

    // Fetch messages for this session
    @FetchRequest private var messages: FetchedResults<CDMessage>

    init(session: CDBackendSession) {
        _session = ObservedObject(wrappedValue: session)
        _messages = FetchRequest(
            fetchRequest: CDMessage.fetchMessages(sessionId: session.id),
            animation: nil
        )
        // Initialize voice output manager with app settings
        // Note: settings not available yet in init, will be passed via environment
        _voiceOutputManager = StateObject(wrappedValue: VoiceOutputManager())
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

                // Voice status indicator
                if voiceInputManager.isRecording {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                        Text("Listening...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if isSessionLocked {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Processing...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Stop speaking button (visible when TTS is playing)
                if voiceOutputManager.isSpeaking {
                    Button(action: {
                        voiceOutputManager.stop()
                    }) {
                        Image(systemName: "stop.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Stop speaking (⌘⇧S)")
                }

                // Microphone button
                Button(action: toggleRecording) {
                    Image(systemName: voiceInputManager.isRecording ? "mic.fill" : "mic")
                        .foregroundColor(voiceInputManager.isRecording ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(isSessionLocked || !client.isConnected)
                .help("Voice input (Hold Space bar)")
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
                            MessageRowView(message: message, voiceOutputManager: voiceOutputManager)
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

                        // Auto-play assistant responses if enabled
                        if settings.autoPlayResponses && lastMessage.role == "assistant" {
                            voiceOutputManager.speak(lastMessage.displayText)
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
        .onAppear {
            // Request microphone and speech recognition permissions on first use
            if voiceInputManager.authorizationStatus == .notDetermined {
                voiceInputManager.requestAuthorization { granted in
                    if !granted {
                        permissionAlertMessage = "Microphone and speech recognition permissions are required for voice input."
                        showPermissionAlert = true
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stopSpeaking)) { _ in
            voiceOutputManager.stop()
        }
        .onChange(of: voiceInputManager.transcribedText) { newText in
            // When transcription completes, populate the input field
            if !newText.isEmpty && !voiceInputManager.isRecording {
                promptText = newText
            }
        }
        .alert("Permission Required", isPresented: $showPermissionAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(permissionAlertMessage)
        }
        .focusedValue(\.conversationActions, conversationActionsImpl)
        .sheet(isPresented: $showCommandMenu) {
            CommandMenuSheet(workingDirectory: session.workingDirectory ?? "")
                .environmentObject(client)
        }
        .onAppear {
            // Create actions implementation with closures
            conversationActionsImpl = ConversationActionsImpl(
                sendPrompt: { [self] in sendPrompt() },
                stopTurn: { [self] in stopTurn() },
                copySessionID: { [self] in copySessionID() },
                toggleRecording: { [self] in toggleRecording() },
                cancelInput: { [self] in cancelInput() },
                compactSession: { [self] in compactSession() },
                showCommandMenu: { [self] in showCommandMenu = true }
            )
        }
        // Keyboard shortcuts - Note: Space bar push-to-talk is a future enhancement
        // macOS SwiftUI doesn't support key down/up events easily
        // For now, users can click the mic button or use voice commands
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

    // MARK: - Voice Input

    private func toggleRecording() {
        if voiceInputManager.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard !isSessionLocked, client.isConnected else { return }

        // Check permissions
        guard voiceInputManager.authorizationStatus == .authorized else {
            voiceInputManager.requestAuthorization { granted in
                if granted {
                    voiceInputManager.startRecording()
                } else {
                    permissionAlertMessage = "Microphone and speech recognition permissions are required for voice input. Please grant access in System Settings."
                    showPermissionAlert = true
                }
            }
            return
        }

        voiceInputManager.startRecording()
    }

    private func stopRecording() {
        voiceInputManager.stopRecording()
    }

    // MARK: - Menu Actions

    fileprivate func copySessionID() {
        let sessionId = session.id.uuidString.lowercased()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sessionId, forType: .string)
    }

    fileprivate func stopTurn() {
        // TODO: Implement stop turn (Cmd+.)
        // This will require backend support to interrupt Claude CLI execution
        print("Stop turn requested (not yet implemented)")
    }

    fileprivate func cancelInput() {
        if voiceInputManager.isRecording {
            stopRecording()
        }
        promptText = ""
    }

    fileprivate func compactSession() {
        let sessionId = session.id.uuidString.lowercased()
        Task {
            do {
                _ = try await client.compactSession(sessionId: sessionId)
                print("Session compacted successfully")
            } catch {
                print("Failed to compact session: \(error)")
            }
        }
    }
}

// MARK: - Conversation Actions Implementation

class ConversationActionsImpl: ConversationActions {
    var sendPromptAction: () -> Void
    var stopTurnAction: () -> Void
    var copySessionIDAction: () -> Void
    var toggleRecordingAction: () -> Void
    var cancelInputAction: () -> Void
    var compactSessionAction: () -> Void
    var showCommandMenuAction: () -> Void

    init(
        sendPrompt: @escaping () -> Void,
        stopTurn: @escaping () -> Void,
        copySessionID: @escaping () -> Void,
        toggleRecording: @escaping () -> Void,
        cancelInput: @escaping () -> Void,
        compactSession: @escaping () -> Void,
        showCommandMenu: @escaping () -> Void
    ) {
        self.sendPromptAction = sendPrompt
        self.stopTurnAction = stopTurn
        self.copySessionIDAction = copySessionID
        self.toggleRecordingAction = toggleRecording
        self.cancelInputAction = cancelInput
        self.compactSessionAction = compactSession
        self.showCommandMenuAction = showCommandMenu
    }

    func sendPrompt() {
        sendPromptAction()
    }

    func stopTurn() {
        stopTurnAction()
    }

    func copySessionID() {
        copySessionIDAction()
    }

    func toggleRecording() {
        toggleRecordingAction()
    }

    func cancelInput() {
        cancelInputAction()
    }

    func compactSession() {
        compactSessionAction()
    }

    func showCommandMenu() {
        showCommandMenuAction()
    }
}

// MARK: - Message Row

struct MessageRowView: View {
    @ObservedObject var message: CDMessage
    @EnvironmentObject var settings: AppSettings
    var voiceOutputManager: VoiceOutputManager?

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

                    // Play button for assistant messages
                    if message.role == "assistant", let voiceManager = voiceOutputManager {
                        Button(action: {
                            voiceManager.speak(message.displayText)
                        }) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Play message")
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
