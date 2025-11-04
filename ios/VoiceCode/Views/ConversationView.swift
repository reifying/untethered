// ConversationView.swift
// Displays conversation for a selected CoreData session with lazy loading

import SwiftUI
import CoreData

struct ConversationView: View {
    @ObservedObject var session: CDSession
    @ObservedObject var client: VoiceCodeClient
    @StateObject var voiceOutput: VoiceOutputManager
    @StateObject var voiceInput: VoiceInputManager
    @ObservedObject var settings: AppSettings
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject var draftManager: DraftManager

    @State private var isLoading = false
    @State private var hasLoadedMessages = false
    @State private var promptText = ""
    @State private var isVoiceMode = true
    @State private var showingRenameSheet = false
    @State private var newSessionName = ""
    @State private var showingCopyConfirmation = false
    @State private var copyConfirmationMessage = "Conversation copied to clipboard"
    @State private var showingCompactConfirmation = false
    @State private var showingAlreadyCompactedAlert = false
    @State private var isCompacting = false
    @State private var compactSuccessMessage: String?
    
    // Compaction feedback state
    @State private var wasRecentlyCompacted: Bool = false
    @State private var lastCompactionStats: VoiceCodeClient.CompactionResult?
    @State private var compactionTimestamps: [UUID: Date] = [:]
    @State private var recentCompactionsBySession: [UUID: VoiceCodeClient.CompactionResult] = [:]
    
    // Auto-scroll state
    @State private var hasPerformedInitialScroll = false
    @State private var autoScrollEnabled = true  // Auto-scroll on by default
    @State private var scrollProxy: ScrollViewProxy?

    // Fetch messages for this session
    @FetchRequest private var messages: FetchedResults<CDMessage>

    init(session: CDSession, client: VoiceCodeClient, voiceOutput: VoiceOutputManager = VoiceOutputManager(), voiceInput: VoiceInputManager = VoiceInputManager(), settings: AppSettings) {
        _session = ObservedObject(wrappedValue: session)
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

    // Check if current session is locked
    private var isSessionLocked: Bool {
        let claudeSessionId = session.id.uuidString.lowercased()
        return client.lockedSessions.contains(claudeSessionId)
    }

    // Manual unlock function
    private func manualUnlock() {
        let claudeSessionId = session.id.uuidString.lowercased()
        client.lockedSessions.remove(claudeSessionId)
        print("🔓 [Manual] User manually unlocked session: \(claudeSessionId)")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Messages area
            ZStack(alignment: .bottomTrailing) {
                ScrollViewReader { proxy in
                    Color.clear
                        .frame(height: 0)
                        .onAppear {
                            scrollProxy = proxy
                        }
                    
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
                            VStack(spacing: 0) {
                                LazyVStack(spacing: 12) {
                                    ForEach(messages) { message in
                                        CDMessageView(
                                            message: message,
                                            voiceOutput: voiceOutput,
                                            settings: settings,
                                            onInferName: { messageText in
                                                client.requestInferredName(sessionId: session.id.uuidString.lowercased(), messageText: messageText)
                                            }
                                        )
                                        .id(message.id)
                                    }
                                }
                                .padding()

                                // Invisible anchor at the bottom for scroll detection
                                // Outside LazyVStack to ensure it's always in view hierarchy
                                Color.clear
                                    .frame(height: 1)
                                    .id("bottom")
                                    .onAppear {
                                        // User has scrolled to bottom, re-enable auto-scroll
                                        print("🔵 [AutoScroll] Bottom anchor appeared (user at bottom)")
                                        if !autoScrollEnabled {
                                            print("🔵 [AutoScroll] Re-enabling auto-scroll")
                                            autoScrollEnabled = true
                                        } else {
                                            print("🔵 [AutoScroll] Already enabled, no change")
                                        }
                                    }
                                    .onDisappear {
                                        // User has scrolled away from bottom, disable auto-scroll
                                        print("⚪️ [AutoScroll] Bottom anchor disappeared (user scrolled up)")
                                        if autoScrollEnabled {
                                            print("⚪️ [AutoScroll] Disabling auto-scroll")
                                            autoScrollEnabled = false
                                        } else {
                                            print("⚪️ [AutoScroll] Already disabled, no change")
                                        }
                                    }
                            }
                        }
                    }
                    .onChange(of: messages.count) { oldCount, newCount in
                        // Auto-scroll to new messages if enabled
                        guard newCount > oldCount else { return }

                        print("📨 [AutoScroll] New messages: \(oldCount) -> \(newCount), auto-scroll: \(autoScrollEnabled ? "enabled" : "disabled")")

                        if autoScrollEnabled {
                            if let lastMessage = messages.last {
                                print("📨 [AutoScroll] Scrolling to last message: \(lastMessage.id)")
                                withAnimation {
                                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                }
                            } else {
                                print("📨 [AutoScroll] No last message to scroll to")
                            }
                        } else {
                            print("📨 [AutoScroll] Skipping auto-scroll (disabled)")
                        }
                    }
                    .onChange(of: isLoading) { wasLoading, nowLoading in
                        // When loading finishes, perform initial scroll to bottom
                        if wasLoading && !nowLoading && !hasPerformedInitialScroll {
                            hasPerformedInitialScroll = true
                            if let lastMessage = messages.last {
                                // Non-animated for immediate positioning
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
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
                        isDisabled: isSessionLocked,
                        onTranscriptionComplete: { text in
                            sendPromptText(text)
                        },
                        onManualUnlock: manualUnlock
                    )
                } else {
                    // Text mode
                    ConversationTextInputView(
                        text: $promptText,
                        isDisabled: isSessionLocked,
                        onSend: {
                            sendPromptText(promptText)
                            promptText = ""
                        },
                        onManualUnlock: manualUnlock
                    )
                }
                
                // Error display
                if let error = client.currentError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                        .onTapGesture {
                            copyErrorToClipboard(error)
                        }
                }
            }
            .padding(.vertical, 12)
            .background(Color(UIColor.systemBackground))
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    // Auto-scroll toggle button (always visible)
                    Button(action: {
                        toggleAutoScroll()
                    }) {
                        Image(systemName: autoScrollEnabled ? "arrow.down.circle.fill" : "arrow.down.circle")
                            .foregroundColor(autoScrollEnabled ? .blue : .gray)
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
                        } else {
                            Image(systemName: "rectangle.compress.vertical")
                                .foregroundColor(wasRecentlyCompacted ? .green : .primary)
                        }
                    }
                    .disabled(isCompacting || client.lockedSessions.contains(session.id.uuidString.lowercased()))

                    Button(action: {
                        client.requestSessionRefresh(sessionId: session.id.uuidString.lowercased())
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }

                    Button(action: exportSessionToPlainText) {
                        Image(systemName: "doc.on.clipboard")
                    }

                    Button(action: {
                        newSessionName = session.localName ?? session.backendName
                        showingRenameSheet = true
                    }) {
                        Image(systemName: "pencil")
                    }
                    
                    Button(action: {
                        copySessionID()
                    }) {
                        Image(systemName: "number")
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if showingCopyConfirmation {
                Text(compactSuccessMessage ?? copyConfirmationMessage)
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

        .alert("Compact Session?", isPresented: $showingCompactConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Compact", role: .destructive) {
                compactSession()
            }
        } message: {
            VStack(spacing: 8) {
                Text("This will summarize your conversation history to reduce file size and improve performance.")
                Text("\(session.messageCount) messages")
                Text("⚠️ This cannot be undone")
            }
        }
        .alert("Session Already Compacted", isPresented: $showingAlreadyCompactedAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Compact Again", role: .destructive) {
                showingCompactConfirmation = true
            }
        } message: {
            if let stats = lastCompactionStats,
               let timestamp = compactionTimestamps[session.id] {
                Text("This session was compacted \(timestamp.relativeTimeString()).\n• Removed \(stats.messagesRemoved) messages\n• Saved \(stats.preTokens.map { formatTokenCount($0) + " tokens" } ?? "tokens")")
            } else {
                Text("This session was recently compacted.\n\nCompact again?")
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
            // Reset scroll flags when view appears (handles navigation back to session)
            print("👁️ [AutoScroll] View appeared, resetting state")
            hasPerformedInitialScroll = false
            autoScrollEnabled = true  // Re-enable auto-scroll on view appear
            print("👁️ [AutoScroll] Auto-scroll enabled on view appear")

            loadSessionIfNeeded()
            setupVoiceInput()

            // Restore draft text for this session
            let sessionID = session.id.uuidString.lowercased()
            promptText = draftManager.getDraft(sessionID: sessionID)
            
            // Restore compaction state for this session
            if let stats = recentCompactionsBySession[session.id],
               let timestamp = compactionTimestamps[session.id] {
                wasRecentlyCompacted = true
                lastCompactionStats = stats
            } else {
                wasRecentlyCompacted = false
                lastCompactionStats = nil
            }
        }
        .onChange(of: promptText) { oldValue, newValue in
            // Auto-save draft as user types
            let sessionID = session.id.uuidString.lowercased()
            draftManager.saveDraft(sessionID: sessionID, text: newValue)
        }
        .onDisappear {
            // Clear active session for smart speaking
            ActiveSessionManager.shared.clearActiveSession()

            // Unsubscribe when leaving the conversation
            client.unsubscribe(sessionId: session.id.uuidString.lowercased())
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
        // Skip subscribe for new sessions (messageCount == 0) to avoid "session not found" error
        // The session will be created when the first prompt is sent
        if session.messageCount > 0 {
            client.subscribe(sessionId: session.id.uuidString.lowercased())
        } else {
            print("📝 [ConversationView] Skipping subscribe for new session (no messages yet)")
        }

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

        // Reset compaction feedback state when user sends a message
        wasRecentlyCompacted = false
        lastCompactionStats = nil

        // Clear draft after successful send
        let sessionID = session.id.uuidString.lowercased()
        draftManager.clearDraft(sessionID: sessionID)

        // Optimistically lock the session before sending
        // Use session.id (iOS UUID) for locking since that's what backend echoes in turn_complete
        let sessionId = session.id.uuidString.lowercased()
        client.lockedSessions.insert(sessionId)
        print("🔒 [ConversationView] Optimistically locked session: \(sessionId)")

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
            message["new_session_id"] = sessionId
            print("📤 [ConversationView] Sending prompt with new_session_id: \(sessionId)")
            // Note: Subscribe will happen when we receive turn_complete (after backend creates session)
        } else {
            message["resume_session_id"] = sessionId
            print("📤 [ConversationView] Sending prompt with resume_session_id: \(sessionId)")
        }

        client.sendMessage(message)
    }
    
    private func copySessionID() {
        // Copy session ID to clipboard
        UIPasteboard.general.string = session.id.uuidString.lowercased()
        
        // Trigger haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        
        // Show confirmation banner with specific message
        copyConfirmationMessage = "Session ID copied to clipboard"
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
    
    private func exportSessionToPlainText() {
        // Format session header
        var exportText = "# \(session.displayName)\n"
        exportText += "Session ID: \(session.id.uuidString.lowercased())\n"
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
    
    private func copyErrorToClipboard(_ error: String) {
        // Copy error to clipboard
        UIPasteboard.general.string = error
        
        // Trigger haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        
        // Show confirmation banner
        copyConfirmationMessage = "Error copied to clipboard"
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

    private func compactSession() {
        isCompacting = true

        Task {
            do {
                let result = try await client.compactSession(sessionId: session.id.uuidString.lowercased())

                await MainActor.run {
                    isCompacting = false

                    // Set green state and store stats
                    wasRecentlyCompacted = true
                    lastCompactionStats = result
                    compactionTimestamps[session.id] = Date()
                    recentCompactionsBySession[session.id] = result

                    // Show success message
                    let message = "Session compacted\nRemoved \(result.messagesRemoved) messages"
                    if let preTokens = result.preTokens {
                        compactSuccessMessage = "\(message), saved \(formatTokenCount(preTokens)) tokens"
                    } else {
                        compactSuccessMessage = message
                    }

                    withAnimation {
                        showingCopyConfirmation = true
                    }

                    // Refresh session to update message count
                    client.requestSessionRefresh(sessionId: session.id.uuidString.lowercased())

                    // Hide confirmation after 3 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        withAnimation {
                            showingCopyConfirmation = false
                            compactSuccessMessage = nil
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    isCompacting = false
                    print("❌ [ConversationView] Compaction failed: \(error.localizedDescription)")
                    // Could show error alert here
                }
            }
        }
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1000 {
            let k = Double(count) / 1000.0
            return String(format: "%.1fK", k)
        }
        return "\(count)"
    }
    
    private func toggleAutoScroll() {
        print("🔘 [AutoScroll] Toggle button tapped, current state: \(autoScrollEnabled ? "enabled" : "disabled")")
        if autoScrollEnabled {
            // Disable auto-scroll
            print("🔘 [AutoScroll] Disabling via manual toggle")
            autoScrollEnabled = false
        } else {
            // Re-enable auto-scroll and jump to bottom
            print("🔘 [AutoScroll] Re-enabling via manual toggle and jumping to bottom")
            autoScrollEnabled = true

            if let proxy = scrollProxy, let lastMessage = messages.last {
                print("🔘 [AutoScroll] Scrolling to last message: \(lastMessage.id)")
                withAnimation(.spring()) {
                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                }
            } else {
                print("🔘 [AutoScroll] No proxy or last message to scroll to")
            }
        }
    }
}


// MARK: - Relative Time Formatting

extension Date {
    func relativeTimeString() -> String {
        let now = Date()
        let interval = now.timeIntervalSince(self)
        
        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days) day\(days == 1 ? "" : "s") ago"
        }
    }
}

// MARK: - CoreData Message View

struct CDMessageView: View {
    @ObservedObject var message: CDMessage
    @ObservedObject var voiceOutput: VoiceOutputManager
    @ObservedObject var settings: AppSettings
    let onInferName: (String) -> Void

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
                            let processedText = TextProcessor.removeCodeBlocks(from: message.text)
                            voiceOutput.speak(processedText)
                        }) {
                            Label("Read Aloud", systemImage: "speaker.wave.2.fill")
                        }

                        Button(action: {
                            onInferName(message.text)
                        }) {
                            Label("Infer Name", systemImage: "sparkles.rectangle.stack")
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
                    HStack {
                        TextField("Enter session name", text: $sessionName)
                            .textInputAutocapitalization(.words)
                        
                        if !sessionName.isEmpty {
                            Button(action: {
                                sessionName = ""
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
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
    let isDisabled: Bool
    let onTranscriptionComplete: (String) -> Void
    let onManualUnlock: () -> Void

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
                    if isDisabled {
                        onManualUnlock()
                    } else {
                        voiceInput.startRecording()
                    }
                }) {
                    VStack {
                        Image(systemName: "mic")
                            .font(.system(size: 40))
                            .foregroundColor(isDisabled ? .gray : .blue)
                        Text(isDisabled ? "Tap to Unlock" : "Tap to Speak")
                            .font(.caption)
                            .foregroundColor(isDisabled ? .gray : .primary)
                    }
                    .frame(width: 100, height: 100)
                    .background((isDisabled ? Color.gray : Color.blue).opacity(0.1))
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
    let isDisabled: Bool
    let onSend: () -> Void
    let onManualUnlock: () -> Void

    var body: some View {
        HStack {
            TextField(isDisabled ? "Session locked - tap to unlock" : "Type your message...", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .disabled(isDisabled)
                .opacity(isDisabled ? 0.5 : 1.0)
                .onTapGesture {
                    if isDisabled {
                        onManualUnlock()
                    }
                }

            Button(action: {
                if isDisabled {
                    onManualUnlock()
                } else {
                    onSend()
                }
            }) {
                Image(systemName: isDisabled ? "lock.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(isDisabled ? .orange : (text.isEmpty ? .gray : .blue))
            }
            .disabled(text.isEmpty && !isDisabled)
        }
        .padding(.horizontal)
    }
}
