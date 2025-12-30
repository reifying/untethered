// WorkstreamConversationView.swift
// Displays conversation for a workstream with lazy loading

import SwiftUI
import CoreData
import os.log

private let logger = Logger(subsystem: "dev.910labs.voice-code", category: "WorkstreamConversationView")

struct WorkstreamConversationView: View {
    @ObservedObject var workstream: CDWorkstream
    @ObservedObject var client: VoiceCodeClient
    @ObservedObject var voiceOutput: VoiceOutputManager
    @ObservedObject var voiceInput: VoiceInputManager
    @ObservedObject var settings: AppSettings
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var draftManager: DraftManager

    @State private var isLoading = false
    @State private var hasLoadedMessages = false
    @State private var promptText = ""
    @State private var isVoiceMode = true
    @State private var showingRenameSheet = false
    @State private var newWorkstreamName = ""
    @State private var showingCopyConfirmation = false
    @State private var copyConfirmationMessage = "Conversation copied to clipboard"
    @State private var showingCompactConfirmation = false
    @State private var showingAlreadyCompactedAlert = false
    @State private var isCompacting = false
    @State private var compactSuccessMessage: String?
    @State private var showingKillConfirmation = false
    @State private var showingWorkstreamInfo = false
    @State private var showingRecipeMenu = false
    @State private var showingClearContextConfirmation = false
    @State private var isClearingContext = false

    // Compaction feedback state
    @State private var wasRecentlyCompacted: Bool = false
    @State private var compactionTimestamps: [UUID: Date] = [:]

    // Auto-scroll state
    @State private var hasPerformedInitialScroll = false
    @State private var autoScrollEnabled = true
    @State private var scrollProxy: ScrollViewProxy?

    // Fetch messages for this workstream's active Claude session
    @FetchRequest private var messages: FetchedResults<CDMessage>

    init(workstream: CDWorkstream, client: VoiceCodeClient, voiceOutput: VoiceOutputManager, voiceInput: VoiceInputManager = VoiceInputManager(), settings: AppSettings) {
        _workstream = ObservedObject(wrappedValue: workstream)
        self.client = client
        _voiceOutput = ObservedObject(wrappedValue: voiceOutput)
        _voiceInput = ObservedObject(wrappedValue: voiceInput)
        self.settings = settings

        // Setup fetch request for this workstream's active Claude session messages
        // If no active session, this will fetch nothing (cleared state)
        if let activeClaudeSessionId = workstream.activeClaudeSessionId {
            _messages = FetchRequest(
                fetchRequest: CDMessage.fetchMessages(sessionId: activeClaudeSessionId),
                animation: nil
            )
        } else {
            // No active session - fetch nothing (use impossible UUID)
            _messages = FetchRequest(
                fetchRequest: CDMessage.fetchMessages(sessionId: UUID()),
                animation: nil
            )
        }
    }

    // Check if current workstream is locked
    private var isWorkstreamLocked: Bool {
        let workstreamId = workstream.id.uuidString.lowercased()
        return client.lockedSessions.contains(workstreamId)
    }

    // Active recipe for this workstream
    private var activeRecipe: ActiveRecipe? {
        client.activeRecipes[workstream.id.uuidString.lowercased()]
    }

    // Manual unlock function
    private func manualUnlock() {
        let workstreamId = workstream.id.uuidString.lowercased()
        client.lockedSessions.remove(workstreamId)
        logger.info("🔓 [Manual] User manually unlocked workstream: \(workstreamId)")
    }

    // Stable function reference for infer name
    private func handleInferName(_ messageText: String) {
        // Use workstream ID for infer name requests
        client.requestInferredName(sessionId: workstream.id.uuidString.lowercased(), messageText: messageText)
    }

    var body: some View {
        let _ = RenderTracker.count(Self.self)
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
                        Image(systemName: workstream.isCleared ? "plus.circle" : "message")
                            .font(.system(size: 64))
                            .foregroundColor(.secondary)
                        Text(workstream.isCleared ? "Ready to start" : "No messages yet")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        Text(workstream.isCleared ? "Send a prompt to begin a new conversation." : "Start a conversation to see messages here.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 100)
                } else if scenePhase == .active {
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
                            if isLoading && newCount > 0 {
                                logger.info("⏱️ Messages arrived (\(newCount)), hiding loading indicator")
                                isLoading = false
                            }

                            guard newCount > oldCount else { return }

                            logger.debug("📨 New messages: \(oldCount) -> \(newCount)")

                            if autoScrollEnabled {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    guard self.autoScrollEnabled, let lastMessage = self.messages.last else { return }
                                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                }
                            }
                        }
                        .onChange(of: isLoading) { wasLoading, nowLoading in
                            if wasLoading && !nowLoading && !hasPerformedInitialScroll, let lastMessage = messages.last {
                                hasPerformedInitialScroll = true
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                } else {
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
                        isDisabled: isWorkstreamLocked,
                        onTranscriptionComplete: { text in
                            sendPromptText(text)
                        },
                        onManualUnlock: manualUnlock
                    )
                } else {
                    // Text mode
                    ConversationTextInputView(
                        text: $promptText,
                        isDisabled: isWorkstreamLocked,
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
                    // Kill session button (only visible when workstream is locked)
                    if isWorkstreamLocked {
                        Button(action: {
                            showingKillConfirmation = true
                        }) {
                            Image(systemName: "stop.circle.fill")
                                .foregroundColor(.red)
                        }
                    }

                    // Recipe button
                    if let active = activeRecipe {
                        Menu {
                            Text("\(active.recipeLabel) - Step \(active.stepCount)")
                            Text("Current: \(active.currentStep)")
                            Divider()
                            Button(role: .destructive) {
                                exitRecipe()
                            } label: {
                                Label("Exit Recipe", systemImage: "stop.circle")
                            }
                        } label: {
                            Image(systemName: "list.bullet.clipboard.fill")
                                .foregroundColor(.green)
                        }
                    } else {
                        Button(action: {
                            showingRecipeMenu = true
                        }) {
                            Image(systemName: "list.bullet.clipboard")
                        }
                    }

                    // Workstream info button
                    Button(action: {
                        showingWorkstreamInfo = true
                    }) {
                        Image(systemName: "info.circle")
                    }

                    // Auto-scroll toggle
                    Button(action: {
                        toggleAutoScroll()
                    }) {
                        Image(systemName: autoScrollEnabled ? "arrow.down.circle.fill" : "arrow.down.circle")
                            .foregroundColor(autoScrollEnabled ? .blue : .gray)
                    }

                    // Clear context button (only if there's an active session)
                    if workstream.activeClaudeSessionId != nil {
                        Button(action: {
                            showingClearContextConfirmation = true
                        }) {
                            if isClearingContext {
                                ProgressView()
                            } else {
                                Image(systemName: "trash")
                                    .foregroundColor(.orange)
                            }
                        }
                        .disabled(isClearingContext || isWorkstreamLocked)
                    }

                    // Compact button (only if there's an active session)
                    if workstream.activeClaudeSessionId != nil {
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
                        .disabled(isCompacting || isWorkstreamLocked)
                    }

                    // Refresh button
                    Button(action: {
                        client.requestSessionRefresh(sessionId: workstream.id.uuidString.lowercased())
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }

                    // Queue remove button
                    if settings.priorityQueueEnabled && workstream.isInPriorityQueue {
                        Button(action: {
                            removeFromPriorityQueue(workstream)
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
            Text("This will terminate the current Claude process. The workstream will be unlocked and you can send a new prompt.")
        }
        // Clear context confirmation
        .alert("Clear Context?", isPresented: $showingClearContextConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                clearContext()
            }
        } message: {
            Text("This will clear the conversation history and start fresh. The workstream name and queue position will be preserved.")
        }
        // Compact confirmation
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
            if let timestamp = compactionTimestamps[workstream.id] {
                Text("This session was compacted \(timestamp.relativeTimeString()).\n\nCompact again?")
            } else {
                Text("This session was recently compacted.\n\nCompact again?")
            }
        }
        .sheet(isPresented: $showingRenameSheet) {
            RenameSessionView(
                sessionName: $newWorkstreamName,
                onSave: {
                    renameWorkstream(newName: newWorkstreamName)
                    showingRenameSheet = false
                },
                onCancel: {
                    showingRenameSheet = false
                }
            )
        }
        .sheet(isPresented: $showingWorkstreamInfo) {
            WorkstreamInfoView(workstream: workstream, settings: settings, client: client)
                .environment(\.managedObjectContext, viewContext)
        }
        .sheet(isPresented: $showingRecipeMenu) {
            RecipeMenuView(client: client, sessionId: workstream.id.uuidString.lowercased(), workingDirectory: workstream.workingDirectory)
        }
        .task {
            await MainActor.run {
                hasPerformedInitialScroll = false
                autoScrollEnabled = true

                loadWorkstreamIfNeeded()
                setupVoiceInput()

                // Restore draft text
                let workstreamID = workstream.id.uuidString.lowercased()
                let draftText = draftManager.getDraft(sessionID: workstreamID)

                if !draftText.isEmpty {
                    promptText = draftText
                }

                // Restore compaction state
                if compactionTimestamps[workstream.id] != nil {
                    wasRecentlyCompacted = true
                } else {
                    wasRecentlyCompacted = false
                }
            }
        }
        .onChange(of: promptText) { oldValue, newValue in
            guard oldValue != newValue else { return }

            let workstreamID = workstream.id.uuidString.lowercased()
            draftManager.saveDraft(sessionID: workstreamID, text: newValue)
        }
        .onChange(of: workstream.activeClaudeSessionId) { oldSessionId, newSessionId in
            // When activeClaudeSessionId changes (e.g., first prompt on cleared workstream),
            // subscribe to the new Claude session to receive messages
            if let oldId = oldSessionId {
                logger.info("🔄 activeClaudeSessionId changed, unsubscribing from old: \(oldId.uuidString.lowercased().prefix(8))...")
                client.unsubscribe(sessionId: oldId.uuidString.lowercased())
            }
            if let newId = newSessionId {
                logger.info("🔄 activeClaudeSessionId changed, subscribing to new: \(newId.uuidString.lowercased().prefix(8))...")
                client.subscribe(sessionId: newId.uuidString.lowercased())
                // Update active session for smart speaking
                ActiveSessionManager.shared.setActiveSession(newId)
            } else {
                // Session cleared
                ActiveSessionManager.shared.clearActiveSession()
            }
        }
        .onAppear {
            // Re-set active session on every appear (not just first load)
            // This handles the case where user navigates away and back
            if let activeSessionId = workstream.activeClaudeSessionId {
                ActiveSessionManager.shared.setActiveSession(activeSessionId)
            }
        }
        .onDisappear {
            ActiveSessionManager.shared.clearActiveSession()
            if let activeSessionId = workstream.activeClaudeSessionId {
                client.unsubscribe(sessionId: activeSessionId.uuidString.lowercased())
            }
        }
    }

    private func setupVoiceInput() {
        voiceInput.requestAuthorization { authorized in
            if !authorized {
                logger.warning("Speech recognition not authorized")
            }
        }
    }

    private func loadWorkstreamIfNeeded() {
        guard !hasLoadedMessages else { return }

        let loadStart = Date()
        logger.info("⏱️ loadWorkstreamIfNeeded START - workstream: \(self.workstream.id.uuidString.lowercased().prefix(8))... (existing messages: \(self.messages.count))")

        hasLoadedMessages = true

        // If messages already exist in CoreData, skip loading indicator
        if !messages.isEmpty {
            let elapsedMs = Int(Date().timeIntervalSince(loadStart) * 1000)
            logger.info("⏱️ +\(elapsedMs)ms - messages already cached (\(self.messages.count))")
            isLoading = false
            DispatchQueue.main.async {
                if !self.hasPerformedInitialScroll {
                    self.hasPerformedInitialScroll = true
                    self.scrollProxy?.scrollTo("bottom", anchor: .bottom)
                }
            }
        } else {
            // Show loading for non-cleared workstreams
            isLoading = workstream.activeClaudeSessionId != nil
        }

        // Mark Claude session as active for smart speaking
        // Must use activeClaudeSessionId (not workstream.id) because SessionSyncManager
        // checks isActive(claudeSessionId) when deciding whether to speak messages
        if let activeSessionId = workstream.activeClaudeSessionId {
            ActiveSessionManager.shared.setActiveSession(activeSessionId)
        } else {
            // Cleared workstream - no active Claude session yet
            ActiveSessionManager.shared.clearActiveSession()
        }

        // Clear unread count
        workstream.unreadCount = 0
        try? viewContext.save()

        // Prune old messages if there's an active session
        if let activeSessionId = workstream.activeClaudeSessionId {
            PersistenceController.shared.performBackgroundTask { backgroundContext in
                let pruneStart = Date()
                let deletedCount = CDMessage.pruneOldMessages(sessionId: activeSessionId, in: backgroundContext)
                let pruneMs = Int(Date().timeIntervalSince(pruneStart) * 1000)
                if deletedCount > 0 {
                    try? backgroundContext.save()
                    logger.info("⏱️ Pruned \(deletedCount) messages in \(pruneMs)ms")
                }
            }
        }

        // Subscribe to the Claude session to load full history
        // Skip subscribe for cleared workstreams (no active session)
        if let activeSessionId = workstream.activeClaudeSessionId {
            logger.info("⏱️ Subscribing to Claude session (workstream has active session)")
            client.subscribe(sessionId: activeSessionId.uuidString.lowercased())
        } else {
            logger.info("⏱️ Skipping subscribe (cleared workstream, no active session)")
        }

        // Fallback timeout
        if isLoading {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                if self.isLoading {
                    logger.info("⏱️ Loading indicator hidden (5s timeout fallback)")
                    self.isLoading = false
                }
            }
        }
    }

    private func renameWorkstream(newName: String) {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        workstream.name = trimmedName
        workstream.lastModified = Date()

        // Also update CDUserSession for compatibility
        let fetchRequest = CDUserSession.fetchUserSession(id: workstream.id)
        let userSession: CDUserSession
        if let existing = try? viewContext.fetch(fetchRequest).first {
            userSession = existing
        } else {
            userSession = CDUserSession(context: viewContext)
            userSession.id = workstream.id
            userSession.createdAt = Date()
        }
        userSession.customName = trimmedName

        do {
            try viewContext.save()
            logger.info("📝 Renamed workstream to: \(trimmedName)")
        } catch {
            logger.error("❌ Failed to rename workstream: \(error)")
        }
    }

    private func sendPromptText(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        // Reset compaction feedback
        wasRecentlyCompacted = false

        // Clear draft
        let workstreamID = workstream.id.uuidString.lowercased()
        draftManager.clearDraft(sessionID: workstreamID)

        // Auto-add to priority queue if enabled
        if settings.priorityQueueEnabled && !workstream.isInPriorityQueue {
            addToPriorityQueue(workstream)
        }

        // Optimistically lock the workstream before sending
        DispatchQueue.main.async {
            self.client.lockedSessions.insert(workstreamID)
            logger.info("🔒 Optimistically locked workstream: \(workstreamID)")
        }

        // Create optimistic message if there's an active session.
        // For cleared workstreams (activeClaudeSessionId is nil), we skip the optimistic message
        // because we don't know the new session ID yet - the backend assigns it.
        // The view will recreate via .id(activeClaudeSessionId) when the backend responds
        // with workstream_updated, and messages will then display correctly.
        if let activeSessionId = workstream.activeClaudeSessionId {
            client.sessionSyncManager.createOptimisticMessage(sessionId: activeSessionId, text: trimmedText) { messageId in
                logger.info("Created optimistic message: \(messageId)")
            }
        }

        // Send prompt using workstream_id (new protocol)
        client.sendPrompt(
            text: trimmedText,
            workstreamId: workstream.id,
            workingDirectory: workstream.workingDirectory,
            systemPrompt: settings.systemPrompt.isEmpty ? nil : settings.systemPrompt
        )

        logger.info("📤 Sent prompt to workstream: \(workstreamID)")
    }

    private func copyErrorToClipboard(_ error: String) {
        UIPasteboard.general.string = error

        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        copyConfirmationMessage = "Error copied to clipboard"
        withAnimation {
            showingCopyConfirmation = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                showingCopyConfirmation = false
            }
        }
    }

    private func killSession() {
        let workstreamId = workstream.id.uuidString.lowercased()
        logger.info("🛑 Killing session for workstream: \(workstreamId)")

        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.warning)

        client.killSession(sessionId: workstreamId)

        copyConfirmationMessage = "Session stopped"
        withAnimation {
            showingCopyConfirmation = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                showingCopyConfirmation = false
            }
        }
    }

    private func compactSession() {
        guard let activeSessionId = workstream.activeClaudeSessionId else { return }

        isCompacting = true

        Task {
            do {
                let _ = try await client.compactSession(sessionId: activeSessionId.uuidString.lowercased())

                await MainActor.run {
                    isCompacting = false
                    wasRecentlyCompacted = true
                    compactionTimestamps[workstream.id] = Date()

                    compactSuccessMessage = "Session compacted"

                    withAnimation {
                        showingCopyConfirmation = true
                    }

                    client.requestSessionRefresh(sessionId: workstream.id.uuidString.lowercased())

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
                    logger.error("❌ Compaction failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func clearContext() {
        isClearingContext = true

        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.warning)

        // Call the VoiceCodeClient method to send clear_context message
        client.clearContext(workstreamId: workstream.id)

        logger.info("🧹 Clearing context for workstream: \(workstream.id.uuidString.lowercased().prefix(8))...")

        // Reset compaction state since we're starting fresh
        wasRecentlyCompacted = false
        compactionTimestamps.removeValue(forKey: workstream.id)

        // Show confirmation
        compactSuccessMessage = "Context cleared"
        withAnimation {
            showingCopyConfirmation = true
        }

        // The actual clearing will happen when we receive context_cleared from the backend
        // via WorkstreamSyncManager.handleContextCleared
        // For now, just reset the loading state after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            isClearingContext = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation {
                    showingCopyConfirmation = false
                    compactSuccessMessage = nil
                }
            }
        }
    }

    private func toggleAutoScroll() {
        if autoScrollEnabled {
            autoScrollEnabled = false
        } else {
            autoScrollEnabled = true
            if let proxy = scrollProxy {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: - Recipe Orchestration

    private func exitRecipe() {
        client.exitRecipe(sessionId: workstream.id.uuidString.lowercased())

        compactSuccessMessage = "Recipe exited"
        withAnimation {
            showingCopyConfirmation = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                showingCopyConfirmation = false
                compactSuccessMessage = nil
            }
        }
    }

    // MARK: - Priority Queue Management

    private func addToPriorityQueue(_ workstream: CDWorkstream) {
        guard !workstream.isInPriorityQueue else { return }

        let fetchRequest = CDWorkstream.fetchQueuedWorkstreams()
        if let existingWorkstreams = try? viewContext.fetch(fetchRequest) {
            let maxOrder = existingWorkstreams.map { $0.priorityOrder }.max() ?? 0
            workstream.priorityOrder = maxOrder + 1
        }

        workstream.isInPriorityQueue = true
        workstream.priorityQueuedAt = Date()

        do {
            try viewContext.save()
            logger.info("✅ Added workstream to priority queue: \(workstream.id.uuidString.lowercased())")
        } catch {
            logger.error("❌ Failed to add to priority queue: \(error)")
        }
    }

    private func removeFromPriorityQueue(_ workstream: CDWorkstream) {
        guard workstream.isInPriorityQueue else { return }

        let removedOrder = workstream.priorityOrder
        workstream.isInPriorityQueue = false
        workstream.priorityOrder = 0
        workstream.priorityQueuedAt = nil

        // Reorder remaining items
        let fetchRequest = CDWorkstream.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "isInPriorityQueue == YES AND priorityOrder > %f", removedOrder)

        let workstreamsToReorder = (try? viewContext.fetch(fetchRequest)) ?? []
        for ws in workstreamsToReorder {
            ws.priorityOrder -= 1
        }

        do {
            try viewContext.save()
            logger.info("✅ Removed workstream from priority queue, reordered \(workstreamsToReorder.count) workstreams")
        } catch {
            logger.error("❌ Failed to remove from priority queue: \(error)")
        }
    }
}

// MARK: - Workstream Info View

struct WorkstreamInfoView: View {
    @ObservedObject var workstream: CDWorkstream
    @ObservedObject var settings: AppSettings
    @ObservedObject var client: VoiceCodeClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    @State private var showCopyConfirmation = false
    @State private var copyMessage = ""

    var body: some View {
        NavigationView {
            List {
                Section("Workstream") {
                    LabeledContent("Name", value: workstream.name)
                    LabeledContent("ID") {
                        Text(workstream.id.uuidString.lowercased())
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .contextMenu {
                        Button {
                            copyToClipboard(workstream.id.uuidString.lowercased(), label: "Workstream ID")
                        } label: {
                            Label("Copy ID", systemImage: "doc.on.clipboard")
                        }
                    }
                    LabeledContent("Working Directory") {
                        Text(workstream.workingDirectory)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .contextMenu {
                        Button {
                            copyToClipboard(workstream.workingDirectory, label: "Working Directory")
                        } label: {
                            Label("Copy Path", systemImage: "doc.on.clipboard")
                        }
                    }
                }

                Section("Active Session") {
                    if let activeSessionId = workstream.activeClaudeSessionId {
                        LabeledContent("Claude Session ID") {
                            Text(activeSessionId.uuidString.lowercased())
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .contextMenu {
                            Button {
                                copyToClipboard(activeSessionId.uuidString.lowercased(), label: "Claude Session ID")
                            } label: {
                                Label("Copy ID", systemImage: "doc.on.clipboard")
                            }
                        }
                        LabeledContent("Message Count", value: "\(workstream.messageCount)")
                        if let preview = workstream.preview, !preview.isEmpty {
                            LabeledContent("Preview") {
                                Text(preview)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    } else {
                        Text("No active session (cleared)")
                            .foregroundColor(.orange)
                            .italic()
                    }
                }

                Section("Status") {
                    LabeledContent("Created", value: workstream.createdAt.formatted())
                    LabeledContent("Last Modified", value: workstream.lastModified.formatted())
                    if workstream.isInPriorityQueue {
                        LabeledContent("Queue Priority", value: workstream.queuePriority)
                        LabeledContent("Queue Order", value: "\(Int(workstream.priorityOrder))")
                    }
                }
            }
            .navigationTitle("Workstream Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .overlay(alignment: .top) {
                if showCopyConfirmation {
                    Text(copyMessage)
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
        }
    }

    private func copyToClipboard(_ text: String, label: String) {
        UIPasteboard.general.string = text

        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        copyMessage = "\(label) copied"
        withAnimation {
            showCopyConfirmation = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                showCopyConfirmation = false
            }
        }
    }
}
