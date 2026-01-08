// CommandHistoryView.swift
// View for displaying command history

import SwiftUI

struct CommandHistoryView: View {
    @ObservedObject var client: VoiceCodeClient
    let workingDirectory: String?
    @State private var isRefreshing = false

    var body: some View {
        List {
            ForEach(client.commandHistory) { session in
                NavigationLink(destination: CommandOutputDetailView(client: client, session: session)) {
                    CommandHistoryRowView(session: session)
                }
            }
        }
        .navigationTitle("Command History")
        .refreshable {
            await refresh()
        }
        .onAppear {
            loadHistory()
        }
        .swipeToBack()
    }

    private func loadHistory() {
        client.getCommandHistory(workingDirectory: workingDirectory, limit: 50)
    }

    private func refresh() async {
        isRefreshing = true
        client.getCommandHistory(workingDirectory: workingDirectory, limit: 50)
        // Wait a bit for the response
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        isRefreshing = false
    }
}

struct CommandHistoryRowView: View {
    let session: CommandHistorySession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Command info
            HStack {
                Text(session.shellCommand)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
                Spacer()
                statusBadge
            }

            // Metadata
            HStack(spacing: 12) {
                // Timestamp
                Label(formatTimestamp(session.timestamp), systemImage: "clock")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Duration
                if let durationMs = session.durationMs {
                    Label(formatDuration(durationMs), systemImage: "timer")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Exit code
                if let exitCode = session.exitCode {
                    Label("Exit: \(exitCode)", systemImage: exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(exitCode == 0 ? .green : .red)
                }
            }

            // Output preview
            if !session.outputPreview.isEmpty {
                Text(session.outputPreview)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusBadge: some View {
        Group {
            if let exitCode = session.exitCode {
                Image(systemName: exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(exitCode == 0 ? .green : .red)
            } else {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func formatDuration(_ ms: Int) -> String {
        let seconds = Double(ms) / 1000.0
        if seconds < 1.0 {
            return "\(ms)ms"
        } else if seconds < 60.0 {
            return String(format: "%.1fs", seconds)
        } else {
            let minutes = Int(seconds / 60)
            let remainingSeconds = Int(seconds.truncatingRemainder(dividingBy: 60))
            return "\(minutes)m \(remainingSeconds)s"
        }
    }
}

struct CommandHistoryView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            CommandHistoryView(
                client: VoiceCodeClient(serverURL: "ws://localhost:3000", sessionSyncManager: SessionSyncManager()),
                workingDirectory: nil
            )
        }
    }
}
