// MessageView.swift
// Message bubble view for displaying conversations

import SwiftUI

struct MessageView: View {
    let message: Message
    @ObservedObject var voiceOutput: VoiceOutputManager

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer()
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                // Message text
                Text(message.text)
                    .padding(12)
                    .background(backgroundColor)
                    .foregroundColor(textColor)
                    .cornerRadius(16)
                    .textSelection(.enabled)
                    .contextMenu {
                        Button(action: {
                            UIPasteboard.general.string = message.text
                        }) {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        
                        Button(action: {
                            voiceOutput.speak(message.text)
                        }) {
                            Label("Read Aloud", systemImage: "speaker.wave.2.fill")
                        }
                    }

                // Metadata
                HStack(spacing: 8) {
                    // Timestamp
                    Text(formatTimestamp(message.timestamp))
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    // Usage info (for assistant messages)
                    if message.role == .assistant, let usage = message.usage {
                        if let inputTokens = usage.inputTokens, let outputTokens = usage.outputTokens {
                            Text("•")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("\(inputTokens + outputTokens) tokens")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        if let cost = message.cost {
                            Text("•")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(String(format: "$%.4f", cost))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    // Error indicator
                    if let error = message.error {
                        Text("•")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                }
                .padding(.horizontal, 4)

                // Error message (if any)
                if let error = message.error {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal, 4)
                }
            }

            if message.role == .assistant || message.role == .system {
                Spacer()
            }
        }
    }

    private var backgroundColor: Color {
        switch message.role {
        case .user:
            return Color.blue
        case .assistant:
            return Color.gray.opacity(0.2)
        case .system:
            return Color.yellow.opacity(0.2)
        }
    }

    private var textColor: Color {
        switch message.role {
        case .user:
            return .white
        case .assistant, .system:
            return .primary
        }
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Preview

struct MessageView_Previews: PreviewProvider {
    static var previews: some View {
        let voiceOutput = VoiceOutputManager()
        
        VStack(spacing: 12) {
            MessageView(
                message: Message(
                    role: .user,
                    text: "What files are in this directory?"
                ),
                voiceOutput: voiceOutput
            )

            MessageView(
                message: Message(
                    role: .assistant,
                    text: "There are 5 files in this directory:\n1. main.swift\n2. ContentView.swift\n3. Models.swift\n4. README.md\n5. Package.swift",
                    usage: Usage(inputTokens: 100, outputTokens: 50, cacheReadTokens: 0, cacheWriteTokens: 0),
                    cost: 0.0025
                ),
                voiceOutput: voiceOutput
            )

            MessageView(
                message: Message(
                    role: .assistant,
                    text: "Error occurred",
                    error: "Connection timeout"
                ),
                voiceOutput: voiceOutput
            )
        }
        .padding()
    }
}
