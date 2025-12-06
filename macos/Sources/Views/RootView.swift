// RootView.swift
// Main window view for macOS app

import SwiftUI
import UntetheredCore

struct RootView: View {
    @EnvironmentObject var client: VoiceCodeClient
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        NavigationStack {
            BasicConversationView()
                .navigationTitle("Untethered")
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        ConnectionStatusView()
                    }
                }
        }
        .onAppear {
            client.connect(sessionId: nil)
        }
    }
}

struct ConnectionStatusView: View {
    @EnvironmentObject var client: VoiceCodeClient

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(client.isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(client.isConnected ? "Connected" : "Disconnected")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
