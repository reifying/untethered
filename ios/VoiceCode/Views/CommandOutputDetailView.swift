// CommandOutputDetailView.swift
// Detail view for displaying full command output

import SwiftUI

struct CommandOutputDetailView: View {
    @ObservedObject var client: VoiceCodeClient
    let session: CommandHistorySession
    @State private var isLoading = true
    @State private var showShareSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Metadata section
                metadataSection

                Divider()

                // Output section
                if isLoading {
                    ProgressView("Loading output...")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                } else if let output = client.commandOutputFull {
                    outputSection(output)
                } else {
                    Text("Failed to load output")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                }
            }
            .padding()
        }
        .navigationTitle("Command Output")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(action: copyOutput) {
                        Label("Copy Output", systemImage: "doc.on.doc")
                    }
                    Button(action: { showShareSheet = true }) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(client.commandOutputFull == nil)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let output = client.commandOutputFull {
                ShareSheet(items: [shareText(output)])
            }
        }
        .onAppear {
            loadOutput()
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Command
            VStack(alignment: .leading, spacing: 4) {
                Text("Command")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(session.shellCommand)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
            }

            // Working directory
            VStack(alignment: .leading, spacing: 4) {
                Text("Directory")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(session.workingDirectory)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // Status and timing
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Status")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 4) {
                        if let exitCode = session.exitCode {
                            Image(systemName: exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(exitCode == 0 ? .green : .red)
                            Text("Exit \(exitCode)")
                                .font(.body)
                                .foregroundColor(exitCode == 0 ? .green : .red)
                        } else {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Running")
                                .font(.body)
                                .foregroundColor(.blue)
                        }
                    }
                }

                if let durationMs = session.durationMs {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Duration")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(formatDuration(durationMs))
                            .font(.body)
                    }
                }

                Spacer()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Started")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(formatTimestamp(session.timestamp))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func outputSection(_ output: CommandOutputFull) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output")
                .font(.caption)
                .foregroundColor(.secondary)

            if output.output.isEmpty {
                Text("No output")
                    .foregroundColor(.secondary)
                    .italic()
                    .padding()
            } else {
                Text(output.output)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(8)
            }
        }
    }

    private func loadOutput() {
        isLoading = true
        client.getCommandOutput(commandSessionId: session.commandSessionId)
        
        // Wait a bit for response (simple approach for MVP)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            isLoading = false
        }
    }

    private func copyOutput() {
        guard let output = client.commandOutputFull else { return }
        ClipboardUtility.copy(output.output)
    }

    private func shareText(_ output: CommandOutputFull) -> String {
        var text = "Command: \(output.shellCommand)\n"
        text += "Directory: \(output.workingDirectory)\n"
        text += "Exit Code: \(output.exitCode)\n"
        text += "Duration: \(formatDuration(output.durationMs))\n"
        text += "Started: \(formatTimestamp(output.timestamp))\n\n"
        text += "Output:\n\(output.output)"
        return text
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
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

// ShareSheet helper for UIActivityViewController
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct CommandOutputDetailView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            CommandOutputDetailView(
                client: VoiceCodeClient(serverURL: "ws://localhost:3000", sessionSyncManager: SessionSyncManager()),
                session: CommandHistorySession(
                    commandSessionId: "cmd-123",
                    commandId: "build",
                    shellCommand: "make build",
                    workingDirectory: "/Users/user/project",
                    timestamp: Date(),
                    exitCode: 0,
                    durationMs: 1234,
                    outputPreview: "Building..."
                )
            )
        }
    }
}
