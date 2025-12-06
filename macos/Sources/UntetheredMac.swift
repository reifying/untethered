// UntetheredMac.swift
// Main entry point for Untethered macOS app

import SwiftUI
import UntetheredCore

@main
struct UntetheredMacApp: App {
    @StateObject private var client: VoiceCodeClient
    @StateObject private var settings = AppSettings()

    // CoreData persistence
    let persistenceController = PersistenceController.shared
    let sessionSyncManager: SessionSyncManager

    init() {
        let appSettings = AppSettings()
        let persistence = PersistenceController.shared
        let sessionSync = SessionSyncManager(persistenceController: persistence)

        let client = VoiceCodeClient(
            serverURL: appSettings.serverURL,
            appSettings: appSettings,
            setupObservers: true
        )

        self.sessionSyncManager = sessionSync
        _client = StateObject(wrappedValue: client)

        // Wire up WebSocket message handlers
        client.onRecentSessionsReceived = { sessions in
            Task {
                await sessionSync.handleSessionList(sessions)
            }
        }

        client.onMessageReceived = { message, iosSessionId in
            Task { @MainActor in
                guard let sessionId = UUID(uuidString: iosSessionId) else { return }

                let context = persistence.container.viewContext

                // Save message to CoreData
                let cdMessage = CDMessage(context: context)
                cdMessage.id = message.id
                cdMessage.sessionId = sessionId
                cdMessage.role = message.role.rawValue
                cdMessage.text = message.text
                cdMessage.timestamp = message.timestamp
                cdMessage.messageStatus = .confirmed

                do {
                    try context.save()
                } catch {
                    print("Failed to save message: \(error)")
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environmentObject(client)
                .environmentObject(settings)
        }
        .defaultSize(width: 800, height: 600)
    }
}
