// VoiceCodeApp.swift
// Main app entry point for voice-code iOS app

import SwiftUI

@main
struct VoiceCodeApp: App {
    let persistenceController = PersistenceController.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
