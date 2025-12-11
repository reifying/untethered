// ConversationView.swift
// Displays conversation for a selected CoreData session with lazy loading

import SwiftUI
import CoreData
import os.log

private let logger = Logger(subsystem: "dev.910labs.voice-code", category: "ConversationView")

// Render loop detector - tracks renders per second
private class RenderLoopDetector {
    static let shared = RenderLoopDetector()
    private var renderCount = 0
    private var windowStart = Date()
    private let windowSize: TimeInterval = 1.0  // 1 second window
    private let threshold = 50  // More than 50 renders/sec is suspicious

    func recordRender() {
        let now = Date()
        if now.timeIntervalSince(windowStart) > windowSize {
            // Check if we exceeded threshold in the last window
            if renderCount > threshold {
                logger.error("🚨 RENDER LOOP DETECTED: \(self.renderCount) renders in 1 second!")
            }
            // Reset window
            renderCount = 1
            windowStart = now
        } else {
            renderCount += 1
            // Log warning at multiples of threshold while in same window
            if renderCount == threshold || renderCount == threshold * 2 {
                logger.warning("⚠️ High render rate: \(self.renderCount) renders in <1s")
            }
        }
    }
}

struct ConversationView: View {
    @ObservedObject var session: CDBackendSession
    @ObservedObject var client: VoiceCodeClient
    @StateObject var voiceOutput: VoiceOutputManager
    @StateObject var voiceInput: VoiceInputManager
    @ObservedObject var settings: AppSettings
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.scenePhase) private var scenePhase
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
    @State private var showingKillConfirmation = false
    @State private var showingSessionInfo = false

    // Compaction feedback state
    @State private var wasRecentlyCompacted: Bool = false
    @State private var compactionTimestamps: [UUID: Date] = [:]
    
    // Auto-scroll state
    @State private var hasPerformedInitialScroll = false
    @State private var autoScrollEnabled = true  // Auto-scroll on by default
    @State private var scrollProxy: ScrollViewProxy?

    // Fetch messages for this session
    @FetchRequest private var messages: FetchedResults<CDMessage>

    init(session: CDBackendSession, client: VoiceCodeClient, voiceOutput: VoiceOutputManager = VoiceOutputManager(), voiceInput: VoiceInputManager = VoiceInputManager(), settings: AppSettings) {
        _session = ObservedObject(wrappedValue: session)
        self.client = client
        _voiceOutput = StateObject(wrappedValue: voiceOutput)
        _voiceInput = StateObject(wrappedValue: voiceInput)
        self.settings = settings

        // Setup fetch request for this session's messages
        // Note: animation: nil prevents SwiftUI from triggering animated transitions
        // for every CoreData change, reducing render cycles significantly
        _messages = FetchRequest(
            fetchRequest: CDMessage.fetchMessages(sessionId: session.id),
            animation: nil
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

    // Stable function reference for infer name - prevents closure recreation on each render
    private func handleInferName(_ messageText: String) {
        client.requestInferredName(sessionId: session.id.uuidString.lowercased(), messageText: messageText)
    }

    var body: some View {
        let _ = RenderTracker.count(Self.self)
        let _ = RenderLoopDetector.shared.recordRender()
        VStack(spacing: 0) {
            // Messages area
            ZStack(alignment: .bottomTrailing) {
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
                } else if scenePhase == .active {
                    // Use List instead of LazyVStack for native cell reuse and 10x better performance
                    // List uses UICollectionView (iOS 16+) with proper view recycling
                    ScrollViewReader { proxy in
                        List {
                            ForEach(messages) { message in
                                CDMessageView(
                                    message: message,
                                    voiceOutput: voiceOutput,
                                    onInferName: handleInferName
                                )
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                .listRowSeparator(.hidden)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .onAppear {
                            scrollProxy = proxy
                        }
                        .onChange(of: messages.count) { oldCount, newCount in
                            // Hide loading indicator when messages arrive
                            if isLoading && newCount > 0 {
                                logger.info("⏱️ Messages arrived (\(newCount)), hiding loading indicator")
                                isLoading = false
                            }

                            // Auto-scroll to new messages if enabled
                            guard newCount > oldCount else { return }

                            logger.debug("📨 New messages: \(oldCount) -> \(newCount), auto-scroll: \(self.autoScrollEnabled ? "enabled" : "disabled")")

                            // Debounce scroll to avoid triggering during layout calculations
                            if autoScrollEnabled {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    // Re-check autoScrollEnabled after delay in case user disabled it
                                    guard self.autoScrollEnabled, let lastMessage = self.messages.last else { return }
                                    logger.debug("📨 Scrolling to last message (debounced)")
                                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                }
                            } else {
                                logger.debug("📨 Skipping auto-scroll (disabled)")
                            }
                        }
                        .onChange(of: isLoading) { wasLoading, nowLoading in
                            // When loading finishes, perform initial scroll to bottom
                            if wasLoading && !nowLoading && !hasPerformedInitialScroll, let lastMessage = messages.last {
                                hasPerformedInitialScroll = true
                                // Non-animated for immediate positioning
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                } else {
                    // Show placeholder when backgrounded to prevent layout loops
                    Color.clear
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
                    // Kill session button (only visible when session is locked)
                    if isSessionLocked {
                        Button(action: {
                            showingKillConfirmation = true
                        }) {
                            Image(systemName: "stop.circle.fill")
                                .foregroundColor(.red)
                        }
                    }

                    // Session info button
                    Button(action: {
                        showingSessionInfo = true
                    }) {
                        Image(systemName: "info.circle")
                    }

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

                    // Queue remove button
                    if settings.queueEnabled && session.isInQueue {
                        Button(action: {
                            removeFromQueue(session)
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.orange)
                        }
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

        // Kill session confirmation
        .alert("Stop Session?", isPresented: $showingKillConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Stop", role: .destructive) {
                killSession()
            }
        } message: {
            Text("This will terminate the current Claude process. The session will be unlocked and you can send a new prompt.")
        }

        // Simple confirmation to prevent accidental compaction (buttons are crowded in toolbar)
        .alert("Compact Session?", isPresented: $showingCompactConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Compact", role: .destructive) {
                compactSession()
            }
        }
        .alert("Session Already Compacted", isPresented: $showingAlreadyCompactedAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Compact Again", role: .destructive) {
                showingCompactConfirmation = true
            }
        } message: {
            if let timestamp = compactionTimestamps[session.id] {
                Text("This session was compacted \(timestamp.relativeTimeString()).\n\nCompact again?")
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
        .sheet(isPresented: $showingSessionInfo) {
            SessionInfoView(session: session, settings: settings)
                .environment(\.managedObjectContext, viewContext)
        }
        .task {
            // Defer state initialization to after view is fully mounted
            // This prevents AttributeGraph crashes from state mutations during onAppear
            await MainActor.run {
                // Reset scroll flags when view appears (handles navigation back to session)
                print("👁️ [AutoScroll] View appeared, resetting state")
                hasPerformedInitialScroll = false
                autoScrollEnabled = true  // Re-enable auto-scroll on view appear
                print("👁️ [AutoScroll] Auto-scroll enabled on view appear")

                loadSessionIfNeeded()
                setupVoiceInput()

                // Restore draft text for this session
                let sessionID = session.id.uuidString.lowercased()
                let draftText = draftManager.getDraft(sessionID: sessionID)

                // Only set if there's actual draft text to avoid triggering onChange unnecessarily
                if !draftText.isEmpty {
                    promptText = draftText
                }

                // Restore compaction state for this session
                if compactionTimestamps[session.id] != nil {
                    wasRecentlyCompacted = true
                } else {
                    wasRecentlyCompacted = false
                }
            }
        }
        .onChange(of: promptText) { oldValue, newValue in
            // Only save draft if value actually changed (prevents duplicate saves on restoration)
            guard oldValue != newValue else { return }

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

        let loadStart = Date()
        logger.info("⏱️ loadSessionIfNeeded START - session: \(self.session.id.uuidString.lowercased().prefix(8))... (existing messages: \(self.messages.count))")

        hasLoadedMessages = true

        // If messages already exist in CoreData, skip loading indicator and scroll immediately
        if !messages.isEmpty {
            let elapsedMs = Int(Date().timeIntervalSince(loadStart) * 1000)
            logger.info("⏱️ +\(elapsedMs)ms - messages already cached (\(self.messages.count)), skipping loading indicator")
            isLoading = false
            // Scroll to bottom on next run loop (after view is laid out)
            DispatchQueue.main.async {
                if !self.hasPerformedInitialScroll {
                    self.hasPerformedInitialScroll = true
                    self.scrollProxy?.scrollTo("bottom", anchor: .bottom)
                }
            }
        } else {
            isLoading = true
        }

        // Mark session as active for smart speaking
        ActiveSessionManager.shared.setActiveSession(session.id)
        let activeSessionMs = Int(Date().timeIntervalSince(loadStart) * 1000)
        logger.info("⏱️ +\(activeSessionMs)ms - setActiveSession complete")

        // Clear unread count when opening session
        session.unreadCount = 0
        try? viewContext.save()
        let clearedUnreadMs = Int(Date().timeIntervalSince(loadStart) * 1000)
        logger.info("⏱️ +\(clearedUnreadMs)ms - cleared unread count")

        // Prune old messages on background context before loading
        // iOS only needs recent messages; backend retains full history
        let sessionId = session.id
        PersistenceController.shared.performBackgroundTask { backgroundContext in
            let pruneStart = Date()
            let deletedCount = CDMessage.pruneOldMessages(sessionId: sessionId, in: backgroundContext)
            let pruneMs = Int(Date().timeIntervalSince(pruneStart) * 1000)
            if deletedCount > 0 {
                try? backgroundContext.save()
                logger.info("⏱️ Pruned \(deletedCount) messages in \(pruneMs)ms")
            } else {
                logger.info("⏱️ No pruning needed (\(pruneMs)ms)")
            }
        }

        // Subscribe to the session to load full history
        // Skip subscribe for new sessions (messageCount == 0) to avoid "session not found" error
        // The session will be created when the first prompt is sent
        let subscribeMs = Int(Date().timeIntervalSince(loadStart) * 1000)
        if session.messageCount > 0 {
            logger.info("⏱️ +\(subscribeMs)ms - subscribing to session (messageCount: \(self.session.messageCount))")
            client.subscribe(sessionId: session.id.uuidString.lowercased())
        } else {
            logger.info("⏱️ +\(subscribeMs)ms - skipping subscribe (new session)")
        }

        // Fallback timeout to hide loading indicator if messages don't arrive
        // Only needed when isLoading was set to true (no cached messages)
        if isLoading {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                if self.isLoading {
                    let timeoutMs = Int(Date().timeIntervalSince(loadStart) * 1000)
                    logger.info("⏱️ +\(timeoutMs)ms - loading indicator hidden (5s timeout fallback)")
                    self.isLoading = false
                }
            }
        }
    }
    
    private func renameSession(newName: String) {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        // Create or update CDUserSession with custom name
        let fetchRequest = CDUserSession.fetchUserSession(id: session.id)
        let userSession: CDUserSession
        if let existing = try? viewContext.fetch(fetchRequest).first {
            userSession = existing
        } else {
            userSession = CDUserSession(context: viewContext)
            userSession.id = session.id
            userSession.createdAt = Date()
        }
        userSession.customName = trimmedName

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

        // Clear draft after successful send
        let sessionID = session.id.uuidString.lowercased()
        draftManager.clearDraft(sessionID: sessionID)

        // Add to queue if enabled
        if settings.queueEnabled {
            addToQueue(session)
        }

        // Note: Priority queue auto-add now happens in VoiceCodeClient.turn_complete handler
        // This ensures sessions are only added after successful response (no ghost sessions)

        // Optimistically lock the session before sending
        // Use session.id (iOS UUID) for locking since that's what backend echoes in turn_complete
        let sessionId = session.id.uuidString.lowercased()

        // Defer lock to avoid SwiftUI update conflicts
        DispatchQueue.main.async {
            self.client.lockedSessions.insert(sessionId)
            print("🔒 [ConversationView] Optimistically locked session: \(sessionId)")
        }

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

        // Include system prompt if configured and non-empty
        print("🔍 [ConversationView] System prompt value: '\(settings.systemPrompt)'")
        print("🔍 [ConversationView] System prompt isEmpty: \(settings.systemPrompt.isEmpty)")
        if !settings.systemPrompt.isEmpty {
            message["system_prompt"] = settings.systemPrompt
            print("✅ [ConversationView] Including system_prompt in message")
        } else {
            print("⚠️ [ConversationView] NOT including system_prompt (empty)")
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
        var exportText = "# \(session.displayName(context: viewContext))\n"
        exportText += "Session ID: \(session.id.uuidString.lowercased())\n"
        exportText += "Working Directory: \(session.workingDirectory)\n"

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        exportText += "Exported: \(dateFormatter.string(from: Date()))\n"
        exportText += "\n---\n\n"

        // Fetch ALL messages for export (not just the displayed 50)
        let exportFetchRequest = CDMessage.fetchRequest()
        exportFetchRequest.predicate = NSPredicate(format: "sessionId == %@", session.id as CVarArg)
        exportFetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CDMessage.timestamp, ascending: true)]

        do {
            let allMessages = try viewContext.fetch(exportFetchRequest)
            exportText += "Message Count: \(allMessages.count)\n\n"

            // Add all messages in chronological order
            for message in allMessages {
                let roleLabel = message.role == "user" ? "User" : "Assistant"
                exportText += "[\(roleLabel)]\n"
                exportText += "\(message.text)\n\n"
            }
        } catch {
            print("❌ Failed to fetch messages for export: \(error)")
            exportText += "Error: Failed to export messages\n"
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

    private func killSession() {
        let sessionId = session.id.uuidString.lowercased()
        print("🛑 [ConversationView] Killing session: \(sessionId)")

        // Trigger haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.warning)

        // Send kill request
        client.killSession(sessionId: sessionId)

        // Show confirmation banner
        copyConfirmationMessage = "Session stopped"
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

                    // Set green state
                    wasRecentlyCompacted = true
                    compactionTimestamps[session.id] = Date()

                    // Show success message
                    compactSuccessMessage = "Session compacted"

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

            if let proxy = scrollProxy {
                print("🔘 [AutoScroll] Scrolling to bottom anchor")
                // Note: Removed withAnimation wrapper to prevent multiple layout passes
                proxy.scrollTo("bottom", anchor: .bottom)
            } else {
                print("🔘 [AutoScroll] No scroll proxy available")
            }
        }
    }

    // MARK: - Queue Management

    private func addToQueue(_ session: CDBackendSession) {
        if session.isInQueue {
            // Already in queue - move to end
            let currentPosition = session.queuePosition
            let fetchRequest = CDBackendSession.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "isInQueue == YES")
            fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CDBackendSession.queuePosition, ascending: false)]
            fetchRequest.fetchLimit = 1

            guard let maxPosition = (try? viewContext.fetch(fetchRequest).first?.queuePosition) else { return }

            // Decrement positions between current and max
            let reorderRequest = CDBackendSession.fetchRequest()
            reorderRequest.predicate = NSPredicate(
                format: "isInQueue == YES AND queuePosition > %d AND id != %@",
                currentPosition,
                session.id as CVarArg
            )

            if let sessionsToReorder = try? viewContext.fetch(reorderRequest) {
                for s in sessionsToReorder {
                    s.queuePosition -= 1
                }
            }

            session.queuePosition = maxPosition
            session.queuedAt = Date()
        } else {
            // New to queue - add at end
            let fetchRequest = CDBackendSession.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "isInQueue == YES")
            fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CDBackendSession.queuePosition, ascending: false)]
            fetchRequest.fetchLimit = 1

            let maxPosition = (try? viewContext.fetch(fetchRequest).first?.queuePosition) ?? 0

            session.isInQueue = true
            session.queuePosition = maxPosition + 1
            session.queuedAt = Date()
        }

        do {
            try viewContext.save()
            print("✅ [Queue] Added session to queue at position \(session.queuePosition)")
        } catch {
            print("❌ [Queue] Failed to add session to queue: \(error)")
        }
    }

    private func removeFromQueue(_ session: CDBackendSession) {
        guard session.isInQueue else { return }

        let removedPosition = session.queuePosition
        session.isInQueue = false
        session.queuePosition = 0
        session.queuedAt = nil

        // Reorder remaining queue items
        let fetchRequest = CDBackendSession.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "isInQueue == YES AND queuePosition > %d", removedPosition)

        let sessionsToReorder = (try? viewContext.fetch(fetchRequest)) ?? []
        for s in sessionsToReorder {
            s.queuePosition -= 1
        }

        do {
            try viewContext.save()
            print("✅ [Queue] Removed session from queue, reordered \(sessionsToReorder.count) sessions")
        } catch {
            print("❌ [Queue] Failed to remove session from queue: \(error)")
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
    let message: CDMessage
    let voiceOutput: VoiceOutputManager
    let onInferName: (String) -> Void

    @State private var showFullMessage = false

    var body: some View {
        let _ = RenderTracker.count(Self.self)
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

                // Message text (truncated for display)
                // Removed .textSelection and .contextMenu to reduce layout overhead
                // Users can tap "View Full" button to access full text and actions
                Text(message.displayText)
                    .font(.body)
                    .lineLimit(20)  // Hard limit to prevent excessive layout calculations

                // Show expand button for truncated messages OR for quick actions
                Button(action: { showFullMessage = true }) {
                    HStack(spacing: 4) {
                        if message.isTruncated {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption2)
                            Text("View Full")
                                .font(.caption)
                        } else {
                            Image(systemName: "ellipsis.circle")
                                .font(.caption2)
                            Text("Actions")
                                .font(.caption)
                        }
                    }
                    .foregroundColor(.blue)
                }

                // Simplified status and timestamp
                HStack(spacing: 8) {
                    if message.messageStatus == .sending {
                        Image(systemName: "clock")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else if message.messageStatus == .error {
                        Image(systemName: "exclamationmark.triangle.fill")
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
        .padding(12)  // Explicit padding value instead of default
        .background(Color(message.role == "user" ? .systemBlue : .systemGreen).opacity(0.1))
        .cornerRadius(12)
        .sheet(isPresented: $showFullMessage) {
            MessageDetailView(message: message, voiceOutput: voiceOutput, onInferName: onInferName)
        }
    }
}

// MARK: - Message Detail View

struct MessageDetailView: View {
    @ObservedObject var message: CDMessage
    @ObservedObject var voiceOutput: VoiceOutputManager
    let onInferName: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showCopiedConfirmation = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView {
                    Text(message.text)
                        .font(.body)
                        .textSelection(.enabled)
                        .padding()
                }

                Divider()

                // Action buttons at bottom for better accessibility
                HStack(spacing: 20) {
                    Button(action: {
                        UIPasteboard.general.string = message.text

                        // Haptic feedback
                        let generator = UINotificationFeedbackGenerator()
                        generator.notificationOccurred(.success)

                        // Show confirmation
                        withAnimation {
                            showCopiedConfirmation = true
                        }

                        // Hide after 1.5 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation {
                                showCopiedConfirmation = false
                            }
                        }
                    }) {
                        VStack(spacing: 4) {
                            Image(systemName: showCopiedConfirmation ? "checkmark.circle.fill" : "doc.on.doc")
                                .font(.title2)
                                .foregroundColor(showCopiedConfirmation ? .green : .primary)
                            Text(showCopiedConfirmation ? "Copied!" : "Copy")
                                .font(.caption)
                                .foregroundColor(showCopiedConfirmation ? .green : .primary)
                        }
                    }

                    Button(action: {
                        let processedText = TextProcessor.removeCodeBlocks(from: message.text)
                        voiceOutput.speak(processedText, workingDirectory: message.session?.workingDirectory)
                    }) {
                        VStack(spacing: 4) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.title2)
                            Text("Read Aloud")
                                .font(.caption)
                        }
                    }

                    Button(action: {
                        onInferName(message.text)
                        dismiss()
                    }) {
                        VStack(spacing: 4) {
                            Image(systemName: "sparkles.rectangle.stack")
                                .font(.title2)
                            Text("Infer Name")
                                .font(.caption)
                        }
                    }
                }
                .padding()
                .background(Color(UIColor.systemBackground))
            }
            .navigationTitle("Full Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
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

                    // Defer completion callback to avoid re-entrant SwiftUI updates
                    // stopRecording() sets isRecording=false which triggers a view update
                    // We need to wait for that update to complete before calling onTranscriptionComplete
                    if !voiceInput.transcribedText.isEmpty {
                        let text = voiceInput.transcribedText
                        DispatchQueue.main.async {
                            onTranscriptionComplete(text)
                        }
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
        let _ = RenderLoopDetector.shared.recordRender()
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
