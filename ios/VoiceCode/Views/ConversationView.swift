// ConversationView.swift
// Displays conversation for a selected CoreData session with lazy loading

import SwiftUI
import CoreData

struct ConversationView: View {
    let session: CDSession
    @ObservedObject var client: VoiceCodeClient
    @Environment(\.managedObjectContext) private var viewContext
    
    @State private var isLoading = false
    @State private var hasLoadedMessages = false
    
    // Fetch messages for this session
    @FetchRequest private var messages: FetchedResults<CDMessage>
    
    init(session: CDSession, client: VoiceCodeClient) {
        self.session = session
        self.client = client
        
        // Setup fetch request for this session's messages
        _messages = FetchRequest(
            fetchRequest: CDMessage.fetchMessages(sessionId: session.id),
            animation: .default
        )
    }
    
    var body: some View {
        ScrollViewReader { proxy in
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
                    LazyVStack(spacing: 12) {
                        ForEach(messages) { message in
                            CDMessageView(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
            }
            .onChange(of: messages.count) { _ in
                // Auto-scroll to bottom on new message
                if let lastMessage = messages.last {
                    withAnimation {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
        }
        .navigationTitle(session.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadSessionIfNeeded()
        }
        .onDisappear {
            // Unsubscribe when leaving the conversation
            client.unsubscribe(sessionId: session.id.uuidString)
        }
    }
    
    private func loadSessionIfNeeded() {
        guard !hasLoadedMessages else { return }
        
        isLoading = true
        hasLoadedMessages = true
        
        // Subscribe to the session to load full history
        client.subscribe(sessionId: session.id.uuidString)
        
        // Stop loading indicator after a delay (messages will populate via CoreData sync)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            isLoading = false
        }
    }
}

// MARK: - CoreData Message View

struct CDMessageView: View {
    @ObservedObject var message: CDMessage
    
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
