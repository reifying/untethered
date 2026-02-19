// VoiceCodeApp.swift
// Main app entry point for voice-code iOS and macOS app

import SwiftUI
import OSLog
import UserNotifications
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

private let logger = Logger(subsystem: "com.travisbrown.VoiceCode", category: "RootView")

// MARK: - Navigation Targets

enum ResourcesNavigationTarget: Hashable {
    case list
    case share
}

@main
struct VoiceCodeApp: App {
    let persistenceController = PersistenceController.shared
    @StateObject private var settings = AppSettings()
    @StateObject private var draftManager = DraftManager()
    @StateObject private var voiceOutput: VoiceOutputManager
    @StateObject private var client: VoiceCodeClient
    @StateObject private var resourcesManager: ResourcesManager

    init() {
        // Create instances in correct dependency order
        let settings = AppSettings()
        let voiceManager = VoiceOutputManager(appSettings: settings)
        let voiceClient = VoiceCodeClient(
            serverURL: settings.fullServerURL,
            voiceOutputManager: voiceManager,
            appSettings: settings
        )
        let resManager = ResourcesManager(voiceCodeClient: voiceClient, appSettings: settings)

        // Initialize StateObjects
        _settings = StateObject(wrappedValue: settings)
        _draftManager = StateObject(wrappedValue: DraftManager())
        _voiceOutput = StateObject(wrappedValue: voiceManager)
        _client = StateObject(wrappedValue: voiceClient)
        _resourcesManager = StateObject(wrappedValue: resManager)
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                settings: settings,
                voiceOutput: voiceOutput,
                client: client,
                resourcesManager: resourcesManager
            )
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environmentObject(draftManager)
        }
        #if os(macOS)
        .commands {
            // Edit menu additions
            CommandGroup(after: .textEditing) {
                Button("Stop Speaking") {
                    voiceOutput.stop()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!voiceOutput.isSpeaking)

                Button(voiceOutput.isMuted ? "Unmute Voice" : "Mute Voice") {
                    voiceOutput.isMuted.toggle()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Divider()

                Button("Command Palette") {
                    NotificationCenter.default.post(name: .showCommandPalette, object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command])
            }

            // View menu additions
            CommandGroup(after: .toolbar) {
                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(name: .toggleSidebar, object: nil)
                }
                .keyboardShortcut("0", modifiers: [.command])

                Button("Focus Sidebar") {
                    NotificationCenter.default.post(name: .focusSidebar, object: nil)
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button("Focus Conversation") {
                    NotificationCenter.default.post(name: .focusConversation, object: nil)
                }
                .keyboardShortcut("2", modifiers: [.command])
            }

            // Session menu
            CommandMenu("Session") {
                Button("New Session") {
                    NotificationCenter.default.post(name: .createNewSession, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Refresh Session") {
                    NotificationCenter.default.post(name: .refreshSession, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Compact Session") {
                    NotificationCenter.default.post(name: .compactSession, object: nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button("Session Info") {
                    NotificationCenter.default.post(name: .showSessionInfo, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command])

                Divider()

                Button("Previous Session") {
                    NotificationCenter.default.post(name: .selectPreviousSession, object: nil)
                }
                .keyboardShortcut("[", modifiers: [.command])

                Button("Next Session") {
                    NotificationCenter.default.post(name: .selectNextSession, object: nil)
                }
                .keyboardShortcut("]", modifiers: [.command])
            }
        }
        #endif

        #if os(macOS)
        Settings {
            MacSettingsView()
                .environmentObject(settings)
                .environmentObject(client)
                .environmentObject(voiceOutput)
        }

        VoiceCodeMenuBarExtra(
            client: client,
            settings: settings,
            voiceOutput: voiceOutput
        )
        #endif
    }
}

// MARK: - Root View

struct RootView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var voiceOutput: VoiceOutputManager
    @ObservedObject var client: VoiceCodeClient
    @ObservedObject var resourcesManager: ResourcesManager
    @State private var showingSettings = false
    @State private var navigationPath = NavigationPath()
    @State private var recentSessions: [RecentSession] = []
    @Environment(\.managedObjectContext) private var viewContext

    #if os(macOS)
    @State private var selectedSessionId: UUID?
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var showCommandPalette = false
    @State private var sessions: [CDBackendSession] = []
    #endif

    var body: some View {
        navigationContent
            .onAppear {
                logger.info("🔵 RootView appeared, setting up recent sessions callback")

                // Set up NotificationManager with VoiceOutputManager
                NotificationManager.shared.setVoiceOutputManager(voiceOutput)

                // Request notification permissions
                Task {
                    let authorized = await NotificationManager.shared.requestAuthorization()
                    if authorized {
                        logger.info("✅ Notifications enabled for 'Read Aloud' feature")
                    }
                }

                // Pre-load voices asynchronously to avoid Settings view hangs
                AppSettings.preloadVoices()

                // Set up callback for recent_sessions before connecting
                client.onRecentSessionsReceived = { sessions in
                    logger.info("📥 Received \(sessions.count) recent sessions from backend")

                    // Debug: log first session JSON keys
                    if let firstSession = sessions.first {
                        logger.info("🔍 First session keys: \(firstSession.keys.sorted())")
                        logger.info("🔍 First session JSON: \(firstSession)")
                    }

                    // Backend provides session names directly - no CoreData lookup needed
                    let parsed = RecentSession.parseRecentSessions(sessions)
                    logger.info("✅ Successfully parsed \(parsed.count) of \(sessions.count) sessions from backend")

                    // Defer state update to avoid SwiftUI update conflicts
                    DispatchQueue.main.async {
                        self.recentSessions = parsed
                        logger.info("🔄 Updated recentSessions state array, count: \(self.recentSessions.count)")
                    }
                }
                logger.info("🔌 Connecting to backend...")
                client.connect()

                // Process pending uploads after connection
                logger.info("📂 Checking for pending resource uploads...")
                resourcesManager.updatePendingCount()
            }
            #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                logger.info("🔄 App entering foreground, checking for pending uploads...")
                resourcesManager.updatePendingCount()
                if client.isConnected {
                    resourcesManager.processPendingUploads()
                }
            }
            #elseif os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                logger.info("🔄 App became active, checking for pending uploads...")
                resourcesManager.updatePendingCount()
                if client.isConnected {
                    resourcesManager.processPendingUploads()
                }
            }
            #endif
    }

    // MARK: - Platform Navigation Content

    @ViewBuilder
    private var navigationContent: some View {
        #if os(macOS)
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            SessionSidebarView(
                client: client,
                settings: settings,
                selectedSessionId: $selectedSessionId,
                recentSessions: $recentSessions
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
        } detail: {
            if let sessionId = selectedSessionId {
                SessionLookupView(
                    sessionId: sessionId,
                    client: client,
                    voiceOutput: voiceOutput,
                    settings: settings
                )
            } else {
                EmptyDetailView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .overlay {
            if showCommandPalette {
                CommandPaletteOverlay(
                    client: client,
                    voiceOutput: voiceOutput,
                    isPresented: $showCommandPalette,
                    onAction: { action in
                        handleCommandPaletteAction(action)
                    }
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showCommandPalette)) { _ in
            showCommandPalette.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
            withAnimation {
                sidebarVisibility = sidebarVisibility == .all ? .detailOnly : .all
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSidebar)) { _ in
            withAnimation {
                sidebarVisibility = .all
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusConversation)) { _ in
            // Keep sidebar visible but focus is conceptual; no-op beyond ensuring detail is visible
        }
        .onReceive(NotificationCenter.default.publisher(for: .createNewSession)) { _ in
            NotificationCenter.default.post(name: .sidebarCreateNewSession, object: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectPreviousSession)) { _ in
            selectAdjacentSession(direction: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectNextSession)) { _ in
            selectAdjacentSession(direction: 1)
        }
        .task {
            loadSessionsForNavigation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionListDidUpdate)) { _ in
            loadSessionsForNavigation()
        }
        #else
        NavigationStack(path: $navigationPath) {
            DirectoryListView(client: client, settings: settings, voiceOutput: voiceOutput, showingSettings: $showingSettings, recentSessions: $recentSessions, navigationPath: $navigationPath, resourcesManager: resourcesManager)
                .navigationDestination(for: String.self) { workingDirectory in
                    SessionsForDirectoryView(
                        workingDirectory: workingDirectory,
                        client: client,
                        settings: settings,
                        voiceOutput: voiceOutput,
                        showingSettings: $showingSettings,
                        navigationPath: $navigationPath
                    )
                }
                .navigationDestination(for: UUID.self) { sessionId in
                    SessionLookupView(
                        sessionId: sessionId,
                        client: client,
                        voiceOutput: voiceOutput,
                        settings: settings
                    )
                }
                .navigationDestination(for: ResourcesNavigationTarget.self) { target in
                    switch target {
                    case .list:
                        ResourcesView(resourcesManager: resourcesManager, client: client)
                    case .share:
                        ResourceShareView(resourcesManager: resourcesManager)
                    }
                }
        }
        .sheet(isPresented: $showingSettings) {
            settingsView
        }
        #endif
    }

    // MARK: - Shared Settings View

    private var settingsView: some View {
        SettingsView(
            settings: settings,
            onServerChange: { newURL in
                client.updateServerURL(newURL)
            },
            onMaxMessageSizeChange: { sizeKB in
                client.sendMaxMessageSize(sizeKB)
            },
            voiceOutputManager: voiceOutput,
            onAPIKeyChanged: {
                // Reconnect with new key
                client.disconnect()
                client.connect()
            }
        )
    }

    // MARK: - macOS Session Navigation

    #if os(macOS)
    private func loadSessionsForNavigation() {
        do {
            sessions = try CDBackendSession.fetchActiveSessions(context: viewContext)
        } catch {
            logger.error("Failed to load sessions for navigation: \(error)")
        }
    }

    private func selectAdjacentSession(direction: Int) {
        let sortedSessions = sessions.sorted { $0.lastModified > $1.lastModified }
        guard !sortedSessions.isEmpty else { return }

        if let currentId = selectedSessionId,
           let currentIndex = sortedSessions.firstIndex(where: { $0.id == currentId }) {
            let newIndex = currentIndex + direction
            if newIndex >= 0 && newIndex < sortedSessions.count {
                selectedSessionId = sortedSessions[newIndex].id
            }
        } else {
            // No session selected, select first
            selectedSessionId = sortedSessions.first?.id
        }
    }

    private func handleCommandPaletteAction(_ action: CommandPaletteAction) {
        switch action {
        case .newSession:
            NotificationCenter.default.post(name: .sidebarCreateNewSession, object: nil)
        case .refreshSession:
            NotificationCenter.default.post(name: .refreshSession, object: nil)
        case .compactSession:
            NotificationCenter.default.post(name: .compactSession, object: nil)
        case .sessionInfo:
            NotificationCenter.default.post(name: .showSessionInfo, object: nil)
        case .stopSpeaking:
            voiceOutput.stop()
        case .toggleMute:
            voiceOutput.isMuted.toggle()
        case .toggleSidebar:
            withAnimation {
                sidebarVisibility = sidebarVisibility == .all ? .detailOnly : .all
            }
        case .runCommand(let commandId):
            NotificationCenter.default.post(name: .executeCommand, object: commandId)
        }
    }
    #endif
}

// MARK: - Command Notifications

#if os(macOS)
extension Notification.Name {
    static let showCommandPalette = Notification.Name("showCommandPalette")
    static let toggleSidebar = Notification.Name("toggleSidebar")
    static let focusSidebar = Notification.Name("focusSidebar")
    static let focusConversation = Notification.Name("focusConversation")
    static let createNewSession = Notification.Name("createNewSession")
    static let sidebarCreateNewSession = Notification.Name("sidebarCreateNewSession")
    static let refreshSession = Notification.Name("refreshSession")
    static let compactSession = Notification.Name("compactSessionCommand")
    static let showSessionInfo = Notification.Name("showSessionInfo")
    static let selectPreviousSession = Notification.Name("selectPreviousSession")
    static let selectNextSession = Notification.Name("selectNextSession")
    static let executeCommand = Notification.Name("executeCommand")
}
#endif
