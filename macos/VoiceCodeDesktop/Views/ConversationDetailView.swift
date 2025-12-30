// ConversationDetailView.swift
// Message list and input area per Section 11.6

import SwiftUI
import CoreData
import OSLog
import UniformTypeIdentifiers
import VoiceCodeShared

private let logger = Logger(subsystem: "dev.910labs.voice-code-desktop", category: "ConversationDetailView")

// MARK: - ConversationDetailView

/// Main conversation view with message list and input area
struct ConversationDetailView: View {
    @ObservedObject var session: CDBackendSession
    @ObservedObject var client: VoiceCodeClient
    @ObservedObject var resourcesManager: ResourcesManager
    let settings: AppSettings

    @Environment(\.managedObjectContext) private var viewContext

    // Voice output for TTS
    @StateObject private var voiceOutput: VoiceOutputManager

    // Messages fetched via CoreData @FetchRequest
    @FetchRequest private var messages: FetchedResults<CDMessage>

    // Input state
    @State private var draftText: String = ""

    // Auto-scroll state
    @State private var autoScrollEnabled = true

    // Compaction state
    @State private var showingCompactConfirmation = false
    @State private var showingAlreadyCompactedAlert = false
    @State private var isCompacting = false
    @State private var compactSuccessMessage: String?
    @State private var showingSuccessMessage = false
    @State private var wasRecentlyCompacted = false
    @State private var compactionTimestamp: Date?
    @State private var isErrorMessage = false  // Distinguish success from error in overlay

    // Kill confirmation state
    @State private var showingKillConfirmation = false

    // Session info inspector state
    @State private var showingSessionInfo = false

    // Drag-and-drop state
    @State private var isDragOver = false

    // Track if sending to disable input
    // Session is locked if the session's backend ID is in the locked set
    private var isSessionLocked: Bool {
        client.lockedSessions.contains(session.backendSessionId)
    }

    init(session: CDBackendSession, client: VoiceCodeClient, resourcesManager: ResourcesManager, settings: AppSettings) {
        self.session = session
        self.client = client
        self.resourcesManager = resourcesManager
        self.settings = settings

        // Initialize voice output manager
        _voiceOutput = StateObject(wrappedValue: VoiceOutputManager(appSettings: settings))

        // Initialize fetch request for messages
        _messages = FetchRequest(
            fetchRequest: CDMessage.fetchMessages(sessionId: session.id),
            animation: nil  // Prevent animation-related layout issues
        )
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Message list with ScrollViewReader for auto-scroll
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(messages) { message in
                                MessageRowView(
                                    message: message,
                                    voiceOutput: voiceOutput,
                                    workingDirectory: session.workingDirectory,
                                    onInferName: { messageText in
                                        client.requestInferredName(
                                            sessionId: session.backendSessionId,
                                            messageText: messageText
                                        )
                                    }
                                )
                                .id(message.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: messages.count) { oldCount, newCount in
                        guard newCount > oldCount, autoScrollEnabled else { return }

                        // Capture target ID before async delay (per Appendix R)
                        guard let targetId = messages.last?.id else { return }

                        // Debounce scroll to avoid layout thrashing (300ms per spec)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            guard self.autoScrollEnabled else { return }
                            // Verify message still exists (may have been pruned)
                            guard messages.contains(where: { $0.id == targetId }) else { return }
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(targetId, anchor: .bottom)
                            }
                        }
                    }
                    .onAppear {
                        // Scroll to last message on appear
                        if let lastId = messages.last?.id {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }

                Divider()

                // Input area
                MessageInputView(
                    text: $draftText,
                    isLocked: isSessionLocked,
                    onSend: sendMessage
                )
            }

            // Drag-and-drop overlay
            if isDragOver {
                ConversationDragOverlayView()
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
            handleDrop(providers: providers)
        }
        .navigationTitle(session.displayName(context: viewContext))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // Kill session button (only visible when session is locked)
                if isSessionLocked {
                    Button(action: {
                        showingKillConfirmation = true
                    }) {
                        Image(systemName: "stop.circle.fill")
                            .foregroundColor(.red)
                    }
                    .help("Kill session process")
                    .accessibilityLabel("Kill session")
                }

                // Compact button
                Button(action: {
                    if wasRecentlyCompacted {
                        showingAlreadyCompactedAlert = true
                    } else {
                        showingCompactConfirmation = true
                    }
                }) {
                    if isCompacting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "rectangle.compress.vertical")
                            .foregroundColor(wasRecentlyCompacted ? .green : nil)
                    }
                }
                .help("Compact session (⌘⇧C)")
                .disabled(isCompacting || isSessionLocked)
                .accessibilityLabel("Compact session")

                // Refresh button
                Button(action: refreshSession) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh session (⌘R)")
                .accessibilityLabel("Refresh session")

                // Auto-scroll toggle
                Button(action: {
                    autoScrollEnabled.toggle()
                }) {
                    Image(systemName: autoScrollEnabled ? "arrow.down.circle.fill" : "arrow.down.circle")
                }
                .help(autoScrollEnabled ? "Disable auto-scroll" : "Enable auto-scroll")
                .keyboardShortcut(.downArrow, modifiers: .command)
                .accessibilityLabel(autoScrollEnabled ? "Disable auto-scroll" : "Enable auto-scroll")

                // Session info button
                Button(action: {
                    showingSessionInfo = true
                }) {
                    Image(systemName: "info.circle")
                }
                .help("Session Info (⌘I)")
                .keyboardShortcut("i")
                .accessibilityLabel("Session info")
            }
        }
        // Success/error message overlay
        .overlay(alignment: .top) {
            if showingSuccessMessage, let message = compactSuccessMessage {
                Text(message)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isErrorMessage ? Color.red.opacity(0.9) : Color.green.opacity(0.9))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // Compact confirmation alert
        .alert("Compact Session?", isPresented: $showingCompactConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Compact", role: .destructive) {
                compactSession()
            }
        } message: {
            Text("This will summarize the conversation history to reduce context size. This cannot be undone.")
        }
        // Already compacted alert
        .alert("Session Already Compacted", isPresented: $showingAlreadyCompactedAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Compact Again", role: .destructive) {
                showingCompactConfirmation = true
            }
        } message: {
            if let timestamp = compactionTimestamp {
                Text("This session was compacted \(timestamp.relativeFormatted()).\n\nCompact again?")
            } else {
                Text("This session was recently compacted.\n\nCompact again?")
            }
        }
        // Kill confirmation alert
        .alert("Kill Session?", isPresented: $showingKillConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Kill", role: .destructive) {
                killSession()
            }
        } message: {
            Text("This will terminate the current Claude process. The session will be unlocked and you can send a new prompt.")
        }
        // Session info inspector sheet
        .sheet(isPresented: $showingSessionInfo) {
            SessionInfoView(session: session, settings: settings)
        }
        // Set focused values for menu commands
        .focusedSceneValue(\.selectedSession, session)
        .focusedSceneValue(\.voiceCodeClient, client)
        .focusedSceneValue(\.showSessionInfoAction, showSessionInfo)
        // Handle menu command notifications
        .onReceive(NotificationCenter.default.publisher(for: .requestSessionCompaction)) { notification in
            guard let sessionId = notification.userInfo?["sessionId"] as? String,
                  sessionId == session.backendSessionId else { return }
            if wasRecentlyCompacted {
                showingAlreadyCompactedAlert = true
            } else {
                showingCompactConfirmation = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestSessionKill)) { notification in
            guard let sessionId = notification.userInfo?["sessionId"] as? String,
                  sessionId == session.backendSessionId else { return }
            showingKillConfirmation = true
        }
        .onAppear {
            loadDraft()
            // Mark session as active for TTS routing
            ActiveSessionManager.shared.setActiveSession(session.id)
            // Clear unread count when viewing session
            if session.unreadCount > 0 {
                session.unreadCount = 0
                try? viewContext.save()
            }
            // Reset compaction state when view appears (handles session switching)
            wasRecentlyCompacted = false
            compactionTimestamp = nil
            isCompacting = false
            showingSuccessMessage = false
            compactSuccessMessage = nil
        }
        .onDisappear {
            saveDraft()
            ActiveSessionManager.shared.clearActiveSession()
        }
        .onChange(of: draftText) {
            // Debounced save handled by MessageInputView
        }
    }

    // MARK: - Session Actions

    /// Show session info - exposed for focused value
    private var showSessionInfo: () -> Void {
        { [self] in showingSessionInfo = true }
    }

    private func refreshSession() {
        logger.info("🔄 Refreshing session: \(session.backendSessionId)")
        client.requestSessionRefresh(sessionId: session.backendSessionId)
    }

    private func compactSession() {
        isCompacting = true
        logger.info("📦 Compacting session: \(session.backendSessionId)")

        Task {
            do {
                _ = try await client.compactSession(sessionId: session.backendSessionId)

                await MainActor.run {
                    isCompacting = false
                    wasRecentlyCompacted = true
                    compactionTimestamp = Date()

                    // Show success message
                    isErrorMessage = false
                    compactSuccessMessage = "Session compacted"
                    withAnimation {
                        showingSuccessMessage = true
                    }

                    logger.info("✅ Session compacted successfully")

                    // Hide success message after 3 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        withAnimation {
                            showingSuccessMessage = false
                            compactSuccessMessage = nil
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    isCompacting = false
                    logger.error("❌ Compaction failed: \(error.localizedDescription)")
                    // Show error message
                    isErrorMessage = true
                    compactSuccessMessage = "Compaction failed: \(error.localizedDescription)"
                    withAnimation {
                        showingSuccessMessage = true
                    }

                    // Hide error message after 5 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                        withAnimation {
                            showingSuccessMessage = false
                            compactSuccessMessage = nil
                        }
                    }
                }
            }
        }
    }

    private func killSession() {
        logger.info("🛑 Killing session: \(session.backendSessionId)")
        client.killSession(sessionId: session.backendSessionId)
    }

    // MARK: - Actions

    private func sendMessage() {
        let trimmedText = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        // Clear draft before sending
        draftText = ""
        clearDraft()

        // Re-enable auto-scroll on user message
        autoScrollEnabled = true

        // Create optimistic message
        let optimisticMessage = CDMessage(context: viewContext)
        optimisticMessage.id = UUID()
        optimisticMessage.sessionId = session.id
        optimisticMessage.role = "user"
        optimisticMessage.text = trimmedText
        optimisticMessage.timestamp = Date()
        optimisticMessage.messageStatus = .sending

        // Update session's last modified and message count
        session.lastModified = Date()
        session.messageCount += 1

        // Save optimistic message
        do {
            try viewContext.save()
        } catch {
            logger.error("❌ Failed to save optimistic message: \(error)")
        }

        // Send to backend
        // Use backendSessionId as both iosSessionId and sessionId
        client.sendPrompt(
            trimmedText,
            iosSessionId: session.backendSessionId,
            sessionId: session.backendSessionId,
            workingDirectory: session.workingDirectory,
            systemPrompt: settings.systemPrompt.isEmpty ? nil : settings.systemPrompt
        )

        logger.info("📤 Sent prompt for session \(session.id.uuidString.prefix(8))")
    }

    // MARK: - Draft Persistence

    private var draftKey: String {
        "draft_\(session.id.uuidString.lowercased())"
    }

    private func loadDraft() {
        draftText = UserDefaults.standard.string(forKey: draftKey) ?? ""
    }

    private func saveDraft() {
        if draftText.isEmpty {
            UserDefaults.standard.removeObject(forKey: draftKey)
        } else {
            UserDefaults.standard.set(draftText, forKey: draftKey)
        }
    }

    private func clearDraft() {
        UserDefaults.standard.removeObject(forKey: draftKey)
    }

    // MARK: - Drop Handling

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []

        let group = DispatchGroup()

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    defer { group.leave() }

                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(url)
                    } else if let url = item as? URL {
                        urls.append(url)
                    }
                }
            }
        }

        group.notify(queue: .main) {
            if !urls.isEmpty {
                logger.info("📥 Dropped \(urls.count) file(s) onto conversation view")
                resourcesManager.uploadFiles(urls)
            }
        }

        return true
    }
}

// MARK: - ConversationDragOverlayView

/// Overlay shown when dragging files over the conversation view
struct ConversationDragOverlayView: View {
    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.1)

            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                .padding(16)

            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.accentColor)

                Text("Drop files to upload")
                    .font(.headline)
                    .foregroundColor(.accentColor)
            }
        }
    }
}

// MARK: - MessageRowView

/// Individual message row with role-based styling
struct MessageRowView: View {
    @ObservedObject var message: CDMessage
    @ObservedObject var voiceOutput: VoiceOutputManager
    let workingDirectory: String
    let onInferName: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Role indicator
            roleIcon
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                // Role label with timestamp
                HStack {
                    Text(roleLabel)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(roleColor)

                    Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    // Status indicator for sending/error states
                    if message.messageStatus == .sending {
                        ProgressView()
                            .controlSize(.mini)
                    } else if message.messageStatus == .error {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                    }

                    Spacer()
                }

                // Message text (using displayText for truncation)
                Text(message.displayText)
                    .font(.body)
                    .textSelection(.enabled)
                    .foregroundColor(.primary)

                // Truncation indicator
                if message.isTruncated {
                    Text("Message truncated for display")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .italic()
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(messageBackground)
        .cornerRadius(8)
        .contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            if message.isTruncated {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                } label: {
                    Label("Copy Full Message", systemImage: "doc.on.doc.fill")
                }
            }

            Divider()

            Button {
                // Remove code blocks for better TTS experience
                let processedText = TextProcessor.removeCodeBlocks(from: message.text)
                voiceOutput.speak(processedText, workingDirectory: workingDirectory)
            } label: {
                Label("Read Aloud", systemImage: "speaker.wave.2")
            }

            if voiceOutput.isSpeaking {
                Button {
                    voiceOutput.stop()
                } label: {
                    Label("Stop Speaking", systemImage: "speaker.slash")
                }
            }

            Divider()

            Button {
                onInferName(message.text)
            } label: {
                Label("Infer Session Name", systemImage: "sparkles.rectangle.stack")
            }
        }
    }

    private var roleIcon: some View {
        Group {
            if message.role == "user" {
                Image(systemName: "person.circle.fill")
                    .foregroundColor(.blue)
            } else {
                Image(systemName: "sparkles")
                    .foregroundColor(.purple)
            }
        }
        .font(.title3)
    }

    private var roleLabel: String {
        message.role == "user" ? "You" : "Claude"
    }

    private var roleColor: Color {
        message.role == "user" ? .blue : .purple
    }

    private var messageBackground: Color {
        if message.role == "user" {
            return Color.blue.opacity(0.1)
        } else {
            return Color.secondary.opacity(0.1)
        }
    }
}

// MARK: - MessageInputView

/// Multi-line text input with Cmd+Enter to send
struct MessageInputView: View {
    @Binding var text: String
    let isLocked: Bool
    let onSend: () -> Void

    // Focus state for text editor
    @FocusState private var isTextEditorFocused: Bool

    // Debounced draft save
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 8) {
            // Lock indicator
            if isLocked {
                HStack {
                    Image(systemName: "lock.fill")
                        .foregroundColor(.orange)
                    Text("Session is processing...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }

            HStack(alignment: .bottom, spacing: 12) {
                // Text editor for multi-line input
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 36, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .focused($isTextEditorFocused)
                    .disabled(isLocked)
                    .accessibilityLabel("Message input")
                    .accessibilityHint("Press Command+Return to send")

                // Send button
                Button(action: onSend) {
                    Image(systemName: "paperplane.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLocked || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send message (⌘⏎)")
                .accessibilityLabel("Send message")
            }
            .padding()
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: text) {
            // Debounced draft save (0.5s)
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                // Draft is saved by parent view's onDisappear
            }
        }
    }
}

// MARK: - Preview

#Preview {
    let controller = PersistenceController(inMemory: true)
    let context = controller.container.viewContext

    // Create a test session
    let session = CDBackendSession(context: context)
    session.id = UUID()
    session.workingDirectory = "/Users/test/project"
    session.backendName = session.id.uuidString.lowercased()
    session.lastModified = Date()

    // Create test messages
    let userMessage = CDMessage(context: context)
    userMessage.id = UUID()
    userMessage.sessionId = session.id
    userMessage.role = "user"
    userMessage.text = "Hello, Claude!"
    userMessage.timestamp = Date().addingTimeInterval(-60)
    userMessage.messageStatus = .confirmed

    let assistantMessage = CDMessage(context: context)
    assistantMessage.id = UUID()
    assistantMessage.sessionId = session.id
    assistantMessage.role = "assistant"
    assistantMessage.text = "Hello! How can I help you today?"
    assistantMessage.timestamp = Date()
    assistantMessage.messageStatus = .confirmed

    try? context.save()

    let settings = AppSettings()
    let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
    let resourcesManager = ResourcesManager(client: client, appSettings: settings)

    return ConversationDetailView(
        session: session,
        client: client,
        resourcesManager: resourcesManager,
        settings: settings
    )
    .environment(\.managedObjectContext, context)
    .frame(width: 600, height: 400)
}
