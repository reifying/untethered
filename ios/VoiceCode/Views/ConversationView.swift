// ConversationView.swift
// Displays conversation for a selected CoreData session with lazy loading

import SwiftUI
import CoreData
import os.log
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

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
    @State private var hasSubscribedThisAppear = false  // Tracks if we've already subscribed this onAppear cycle
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
    @State private var showingRecipeMenu = false
    @State private var isRefreshingMessages = false

    // Compaction feedback state
    @State private var wasRecentlyCompacted: Bool = false
    @State private var compactionTimestamps: [UUID: Date] = [:]

    // Provider selection for new sessions
    @State private var selectedProvider: String = "claude"

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

    // Active recipe for this session
    private var activeRecipe: ActiveRecipe? {
        client.activeRecipes[session.id.uuidString.lowercased()]
    }

    // Stable function reference for infer name - prevents closure recreation on each render
    private func handleInferName(_ messageText: String) {
        client.requestInferredName(sessionId: session.id.uuidString.lowercased(), messageText: messageText)
    }

    /// Pruned-gap alert for this session, if any. Driven by the
    /// `SessionSyncDelegate.didDetectPrunedGap` hook in VoiceCodeClient.
    private var prunedGap: SessionHistoryPayload.Gap? {
        client.prunedGaps[session.id.uuidString.lowercased()]
    }

    /// Stalled chain cursor for this session, if any. Set when SessionSyncManager
    /// aborts an `is_complete:false` (v0.4.0) or `end_of_file:false` (v0.5.0)
    /// chain because the server's cursor is not advancing — typically a single
    /// message whose JSON encoding exceeds the per-window byte budget.
    private var stalledChainCursor: Int64? {
        client.stalledChains[session.id.uuidString.lowercased()]
    }

    var body: some View {
        let _ = RenderTracker.count(Self.self)
        let _ = RenderLoopDetector.shared.recordRender()
        VStack(spacing: 0) {
            // Pruned-gap warning — local state is partial. User-driven
            // (no automatic reload); they may keep browsing or compact/reload.
            if let gap = prunedGap {
                PrunedGapBanner(gap: gap) {
                    client.dismissPrunedGap(sessionId: session.id.uuidString.lowercased())
                }
            }

            // Stalled chain warning — history loading stopped because the server
            // could not advance past a single oversized message. Older history
            // above the cursor is unavailable in this session.
            if let cursor = stalledChainCursor {
                StalledChainBanner(cursor: cursor) {
                    client.dismissStalledChain(sessionId: session.id.uuidString.lowercased())
                }
            }

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
                } else if messages.isEmpty && hasSubscribedThisAppear {
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
                            // Perform initial scroll when ScrollViewReader appears with cached messages
                            // This handles the case where messages are already loaded from CoreData
                            if !hasPerformedInitialScroll && !messages.isEmpty {
                                hasPerformedInitialScroll = true
                                if let lastMessage = messages.last {
                                    logger.debug("📨 Initial scroll on ScrollViewReader appear")
                                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                }
                            }
                        }
                        .onChange(of: messages.count) { oldCount, newCount in
                            // Hide loading indicator when messages arrive
                            if isLoading && newCount > 0 {
                                logger.info("⏱️ Messages arrived (\(newCount)), hiding loading indicator")
                                isLoading = false
                            }

                            // Show spinner instead of "No messages yet" when a file_replaced purge
                            // empties the local cache while we are subscribed. Without this the
                            // ~300 ms gap before the auto-resubscribe delivers fresh messages shows
                            // "No messages yet". The timeout fallback clears isLoading if the
                            // resubscribe never arrives (mirrors loadSessionIfNeeded's timeout, which
                            // was already scheduled before this isLoading=true transition happened).
                            if !isLoading && newCount == 0 && oldCount > 0 && hasSubscribedThisAppear {
                                logger.info("⏱️ Messages purged (\(oldCount) → 0) while subscribed, showing loading indicator")
                                isLoading = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                                    if self.isLoading {
                                        logger.info("⏱️ Purge-recovery loading indicator hidden (5s timeout fallback)")
                                        self.isLoading = false
                                    }
                                }
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
                // Provider picker for new sessions (shown only before first prompt)
                // Use messageCount == 0 to detect new sessions (backendName is always set on creation)
                if session.messageCount == 0 {
                    Picker("Provider", selection: $selectedProvider) {
                        Text("Claude").tag("claude")
                        Text("Copilot").tag("copilot")
                        Text("Cursor").tag("cursor")
                        Text("OpenCode").tag("opencode")
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                }

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
                    #if os(macOS)
                    .help(isVoiceMode ? "Switch to text input" : "Switch to voice input")
                    #endif

                    Spacer()

                    Button(action: {
                        client.forceReconnect()
                    }) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(client.isConnected ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(client.isConnected ? "Connected" : "Disconnected")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    #if os(macOS)
                    .help("Click to reconnect")
                    #endif
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
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                        .onTapGesture {
                            copyErrorToClipboard(error)
                        }
                }
            }
            .padding(.vertical, 12)
            .background(Color.systemBackground)
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    Button(action: {
                        showingKillConfirmation = true
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                    }

                    // Recipe button - shows active recipe or opens menu
                    if let active = activeRecipe {
                        // Show active recipe with exit option
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
                        // Show button to start a recipe
                        Button(action: {
                            showingRecipeMenu = true
                        }) {
                            Image(systemName: "list.bullet.clipboard")
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
                    .disabled(isCompacting)

                    Button(action: {
                        isRefreshingMessages = true
                        Task {
                            await client.requestSessionRefresh(sessionId: session.id.uuidString.lowercased())
                            await MainActor.run { isRefreshingMessages = false }
                        }
                    }) {
                        if isRefreshingMessages {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isRefreshingMessages)

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
            #else
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 16) {
                    // Stop speech button (only visible when speaking)
                    if voiceOutput.isSpeaking {
                        Button(action: { voiceOutput.stop() }) {
                            Image(systemName: "speaker.slash.fill")
                                .foregroundColor(.red)
                        }
                        .help("Stop speaking (Cmd+.)")
                        .keyboardShortcut(".", modifiers: [.command])
                    }

                    // Kill session button
                    Button(action: {
                        showingKillConfirmation = true
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                    }
                    .help("Cancel prompt (Cmd+K)")
                    .keyboardShortcut("k", modifiers: [.command])

                    // Recipe button - shows active recipe or opens menu
                    if let active = activeRecipe {
                        // Show active recipe with exit option
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
                        .help("Active recipe menu")
                    } else {
                        // Show button to start a recipe
                        Button(action: {
                            showingRecipeMenu = true
                        }) {
                            Image(systemName: "list.bullet.clipboard")
                        }
                        .help("Run recipe (Cmd+Shift+R)")
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                    }

                    // Session info button
                    Button(action: {
                        showingSessionInfo = true
                    }) {
                        Image(systemName: "info.circle")
                    }
                    .help("Session info (Cmd+I)")
                    .keyboardShortcut("i", modifiers: [.command])

                    // Auto-scroll toggle button (always visible)
                    Button(action: {
                        toggleAutoScroll()
                    }) {
                        Image(systemName: autoScrollEnabled ? "arrow.down.circle.fill" : "arrow.down.circle")
                            .foregroundColor(autoScrollEnabled ? .blue : .gray)
                    }
                    .help("Toggle auto-scroll")

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
                    .disabled(isCompacting)
                    .help("Compact session history")

                    Button(action: {
                        isRefreshingMessages = true
                        Task {
                            await client.requestSessionRefresh(sessionId: session.id.uuidString.lowercased())
                            await MainActor.run { isRefreshingMessages = false }
                        }
                    }) {
                        if isRefreshingMessages {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isRefreshingMessages)
                    .help("Refresh session (Cmd+R)")
                    .keyboardShortcut("r", modifiers: [.command])

                    // Queue remove button
                    if settings.queueEnabled && session.isInQueue {
                        Button(action: {
                            removeFromQueue(session)
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.orange)
                        }
                        .help("Remove from queue")
                    }

                }
            }
            #endif
        }
        // Clear the loading spinner as soon as messages arrive, regardless of
        // which branch the ZStack is showing. The onChange(of: messages.count)
        // inside the List only fires when the List is in the hierarchy (i.e.,
        // when isLoading == false), so without this outer observer messages can
        // arrive and sit in the @FetchRequest while the spinner stays visible
        // for the full 5-second timeout. See tmux-untethered-cho.
        .onChange(of: messages.count) { _, newCount in
            if isLoading && newCount > 0 {
                logger.info("⏱️ [ConversationView] Messages arrived (\(newCount)) while loading, hiding spinner")
                isLoading = false
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
                Text("This session was compacted \(timestamp.relativeFormatted()).\n\nCompact again?")
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
            SessionInfoView(session: session, settings: settings, client: client)
                .environment(\.managedObjectContext, viewContext)
        }
        .sheet(isPresented: $showingRecipeMenu) {
            RecipeMenuView(client: client, sessionId: session.id.uuidString.lowercased(), workingDirectory: session.workingDirectory, settings: settings)
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

            // Initialize provider selection from settings default
            selectedProvider = settings.defaultProvider
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

            // Reset flag so next onAppear triggers a fresh subscribe
            // This ensures messages are refreshed when navigating back to session
            hasSubscribedThisAppear = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionHistoryDidUpdate)) { notification in
            // Refresh view when session_history adds new messages (e.g., after backend reconnection)
            // This ensures UI updates even when @FetchRequest doesn't auto-refresh
            if let notificationSessionId = notification.userInfo?["sessionId"] as? String,
               notificationSessionId == session.id.uuidString.lowercased() {
                logger.info("📚 [ConversationView] Received sessionHistoryDidUpdate for current session, refreshing context")
                viewContext.refresh(session, mergeChanges: true)
            }
        }
        // iOS foreground return: onDisappear does NOT fire when the app is
        // backgrounded, so hasSubscribedThisAppear stays true and blocks the
        // re-subscribe that onAppear would otherwise issue. Drive it here
        // instead via scenePhase so messages accumulated in the background
        // are fetched without the user having to hit refresh.
        .onChange(of: scenePhase) { oldPhase, newPhase in
            guard newPhase == .active, oldPhase != .active else { return }
            guard !(session.isLocallyCreated && session.messageCount == 0) else { return }
            guard hasSubscribedThisAppear else { return }
            hasSubscribedThisAppear = false
            client.refreshSubscription(sessionId: session.id.uuidString.lowercased())
            // Restore so the next foreground return also triggers a refresh.
            hasSubscribedThisAppear = true
        }
        // macOS NavigationSplitView session switch: SwiftUI reuses the same
        // ConversationView instance when the user clicks a different sidebar
        // entry — onDisappear/onAppear do NOT fire, so hasSubscribedThisAppear
        // stays true and the new session never gets subscribed.
        .onChange(of: session.id) { oldId, newId in
            client.unsubscribe(sessionId: oldId.uuidString.lowercased())
            hasSubscribedThisAppear = false
            loadSessionIfNeeded()
        }
        .swipeToBack()
        #if os(macOS)
        .pushToTalk(voiceInput: voiceInput)
        #endif
    }
    
    private func setupVoiceInput() {
        voiceInput.requestAuthorization { authorized in
            if !authorized {
                print("Speech recognition not authorized")
            }
        }
    }

    private func loadSessionIfNeeded() {
        // Guard against redundant subscribes within the same onAppear cycle
        // This prevents duplicate subscriptions when SwiftUI re-renders
        guard !hasSubscribedThisAppear else {
            logger.debug("⏱️ loadSessionIfNeeded SKIPPED - already subscribed this appear cycle")
            return
        }

        let loadStart = Date()

        logger.info("⏱️ loadSessionIfNeeded START - session: \(self.session.id.uuidString.lowercased().prefix(8))... (existing messages: \(self.messages.count))")

        hasSubscribedThisAppear = true

        // If messages already exist in CoreData, skip loading indicator
        // Initial scroll is handled by ScrollViewReader's .onAppear handler
        if !messages.isEmpty {
            let elapsedMs = Int(Date().timeIntervalSince(loadStart) * 1000)
            logger.info("⏱️ +\(elapsedMs)ms - messages already cached (\(self.messages.count)), skipping loading indicator")
            isLoading = false
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

        // Subscribe unless this is a brand-new locally-created session that
        // hasn't been pushed to backend yet. The "Session not found" branch
        // the old `messageCount > 0` gate was avoiding only fires for sessions
        // the backend has never seen, which is exactly `isLocallyCreated &&
        // messageCount == 0`. Backend-known sessions can have messageCount=0
        // locally (recent_sessions hadn't merged into CoreData yet, never
        // opened, etc.) and the old gate silently dropped them — leaving
        // backend writes ungated and the iPhone never seeing replies. See
        // tmux-untethered-9o9.
        let subscribeMs = Int(Date().timeIntervalSince(loadStart) * 1000)
        let skipSubscribe = session.isLocallyCreated && session.messageCount == 0
        if !skipSubscribe {
            logger.info("⏱️ +\(subscribeMs)ms - subscribing (messageCount=\(self.session.messageCount), locallyCreated=\(self.session.isLocallyCreated))")
            client.subscribe(sessionId: session.id.uuidString.lowercased())
        } else {
            logger.info("⏱️ +\(subscribeMs)ms - skipping subscribe (locally-created new session, no backend file yet)")
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

        let sessionId = session.id.uuidString.lowercased()

        // Clear draft after successful send
        draftManager.clearDraft(sessionID: sessionId)

        // Add to queue if enabled
        if settings.queueEnabled {
            addToQueue(session)
        }

        // Note: Priority queue auto-add now happens in VoiceCodeClient.turn_complete handler
        // This ensures sessions are only added after successful response (no ghost sessions)

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
            message["provider"] = selectedProvider
            print("📤 [ConversationView] Sending prompt with new_session_id: \(sessionId), provider: \(selectedProvider)")
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
        ClipboardUtility.copy(session.id.uuidString.lowercased())

        // Trigger haptic feedback
        ClipboardUtility.triggerSuccessHaptic()

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
        ClipboardUtility.copy(exportText)

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
        ClipboardUtility.copy(error)

        // Trigger haptic feedback
        ClipboardUtility.triggerSuccessHaptic()

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

        // Trigger haptic feedback (warning uses success haptic as fallback on macOS)
        ClipboardUtility.triggerSuccessHaptic()

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
                    Task {
                        await client.requestSessionRefresh(sessionId: session.id.uuidString.lowercased())
                    }

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

            if let proxy = scrollProxy, let lastMessage = messages.last {
                print("🔘 [AutoScroll] Scrolling to last message")
                // Note: Removed withAnimation wrapper to prevent multiple layout passes
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            } else {
                print("🔘 [AutoScroll] No scroll proxy or messages available")
            }
        }
    }

    // MARK: - Recipe Orchestration

    private func exitRecipe() {
        client.exitRecipe(sessionId: session.id.uuidString.lowercased())

        // Show confirmation
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


// Note: Date.relativeFormatted() is defined in Utils/RelativeTimeText.swift

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
        NavigationController(minWidth: 500, minHeight: 400) {
            messageDetailContent
        }
    }

    private var messageDetailContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                SelectableText(text: message.text)
                    .padding()
            }

            Divider()

            // Action buttons at bottom for better accessibility
            HStack(spacing: 20) {
                Button(action: {
                    ClipboardUtility.copy(message.text)

                    // Haptic feedback
                    ClipboardUtility.triggerSuccessHaptic()

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
                    if voiceOutput.isSpeaking {
                        voiceOutput.stop()
                    } else {
                        let processedText = TextProcessor.prepareForSpeech(from: message.text)
                        voiceOutput.speak(processedText, workingDirectory: message.session?.workingDirectory, sessionId: message.session?.id)
                    }
                }) {
                    VStack(spacing: 4) {
                        Image(systemName: voiceOutput.isSpeaking ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.title2)
                            .foregroundColor(voiceOutput.isSpeaking ? .red : .primary)
                        Text(voiceOutput.isSpeaking ? "Stop" : "Read Aloud")
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
            .background(Color.systemBackground)
        }
        .navigationTitle("Full Message")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarBuilder.doneButton { dismiss() }
        }
    }
}

// MARK: - Rename Session View

struct RenameSessionView: View {
    @Binding var sessionName: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationController(minWidth: 400, minHeight: 200) {
            renameForm
        }
    }

    private var renameForm: some View {
        Form {
            Section(header: Text("Session Name")) {
                HStack {
                    TextField("Enter session name", text: $sessionName)
                        #if os(iOS)
                        .textInputAutocapitalization(.words)
                        #endif

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
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("Rename Session")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarBuilder.cancelAndConfirm(
                confirmTitle: "Save",
                isConfirmDisabled: sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                onCancel: onCancel,
                onConfirm: onSave
            )
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
                    voiceInput.startRecording()
                }) {
                    VStack {
                        Image(systemName: "mic")
                            .font(.system(size: 40))
                            .foregroundColor(.blue)
                        Text("Tap to Speak")
                            .font(.caption)
                            .foregroundColor(.primary)
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
        let _ = RenderLoopDetector.shared.recordRender()
        HStack {
            TextField("Type your message...", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                #if os(macOS)
                .onKeyPress(.return, phases: .down) { press in
                    // Shift+Return inserts newline (let default behavior handle it)
                    if press.modifiers.contains(.shift) {
                        return .ignored
                    }
                    // Return sends the prompt
                    if !text.isEmpty {
                        onSend()
                        return .handled
                    }
                    return .ignored
                }
                #endif

            Button(action: {
                onSend()
            }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(text.isEmpty ? .gray : .blue)
            }
            .disabled(text.isEmpty)
        }
        .padding(.horizontal)
    }
}

/// Warning banner shown when an `is_complete:false` / `end_of_file:false`
/// resubscribe chain stalls — the server's cursor is not advancing, typically
/// because a single message exceeds the per-window byte budget. The chain has
/// been aborted; older history above `cursor` is not loading automatically.
/// Informational only — the user may dismiss or manually trigger a reload.
struct StalledChainBanner: View {
    let cursor: Int64
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Some earlier messages could not load")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("A message in this conversation is too large to load automatically. Older history may be incomplete.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss warning")
            .accessibilityIdentifier("stalledChainBannerDismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.yellow.opacity(0.12))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color.yellow.opacity(0.4)),
            alignment: .bottom
        )
        .accessibilityIdentifier("stalledChainBanner")
    }
}

/// Warning banner shown when the backend reports a pruned gap for the session
/// currently on screen. Informational only — the user decides how to respond
/// (dismiss and keep browsing, or trigger a reload elsewhere in the app).
struct PrunedGapBanner: View {
    let gap: SessionHistoryPayload.Gap
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Earlier messages unavailable")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("The server no longer has the earlier part of this conversation. Local history for this session may be incomplete.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss warning")
            .accessibilityIdentifier("prunedGapBannerDismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color.orange.opacity(0.4)),
            alignment: .bottom
        )
        .accessibilityIdentifier("prunedGapBanner")
    }
}
