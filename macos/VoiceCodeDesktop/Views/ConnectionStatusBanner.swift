// ConnectionStatusBanner.swift
// Connection status banner overlay per Appendix Z.7

import SwiftUI
import VoiceCodeShared

/// Wrapper view that shows reconnection banners
/// Displays a brief "Connection restored" banner when connection is reestablished
struct ConnectionStatusBanner<Content: View>: View {
    @ObservedObject var client: VoiceCodeClient
    let content: Content
    @State private var showingReconnectedBanner = false

    init(client: VoiceCodeClient, @ViewBuilder content: () -> Content) {
        self.client = client
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Main content
            content

            // Reconnection banner
            if showingReconnectedBanner {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Connection restored")
                }
                .padding(8)
                .background(.green.opacity(0.1))
                .cornerRadius(8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.top, 8)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .connectionRestored)) { _ in
            withAnimation {
                showingReconnectedBanner = true
            }

            // Auto-hide after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation {
                    showingReconnectedBanner = false
                }
            }
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        let settings = AppSettings()
        @StateObject private var mockClient: VoiceCodeClient

        init() {
            let settings = AppSettings()
            _mockClient = StateObject(wrappedValue: VoiceCodeClient(
                serverURL: "ws://localhost:8080",
                appSettings: settings,
                setupObservers: false
            ))
        }

        var body: some View {
            ConnectionStatusBanner(client: mockClient) {
                VStack {
                    Text("Main Content")
                    Button("Simulate Reconnection") {
                        NotificationCenter.default.post(name: .connectionRestored, object: nil)
                    }
                }
                .frame(width: 400, height: 300)
            }
        }
    }

    return PreviewWrapper()
}
