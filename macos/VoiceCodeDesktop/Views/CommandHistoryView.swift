// CommandHistoryView.swift
// macOS command history view with table, output preview, and exit codes
// Accessible as sheet from clock button per design spec

import SwiftUI
import AppKit
import OSLog
import VoiceCodeShared

private let logger = Logger(subsystem: "dev.910labs.voice-code-desktop", category: "CommandHistoryView")

// MARK: - Shared Formatting Helpers

private enum CommandHistoryFormatters {
    static func formatDuration(_ ms: Int?) -> String {
        guard let ms = ms else { return "-" }
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

    static func abbreviateDirectory(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    static func formatRelativeTimestamp(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func formatAbsoluteTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

// MARK: - CommandHistoryView

struct CommandHistoryView: View {
    @ObservedObject var client: VoiceCodeClientCore
    let workingDirectory: String?
    @Environment(\.dismiss) private var dismiss

    @State private var selectedSessionId: String?
    @State private var isRefreshing = false

    private var selectedSession: CommandHistorySession? {
        guard let id = selectedSessionId else { return nil }
        return client.commandHistory.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            toolbar

            Divider()

            // Main content: table and detail
            HSplitView {
                // History table
                historyTable
                    .frame(minWidth: 400)

                // Detail panel
                detailPanel
                    .frame(minWidth: 300)
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .onAppear {
            loadHistory()
        }
    }

    // MARK: - Subviews

    private var toolbar: some View {
        HStack(spacing: 16) {
            Text("Command History")
                .font(.headline)

            Spacer()

            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }

            Button(action: { refresh() }) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(isRefreshing)

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var historyTable: some View {
        Table(client.commandHistory, selection: $selectedSessionId) {
            TableColumn("Status") { session in
                StatusBadge(session: session)
            }
            .width(min: 50, ideal: 60, max: 80)

            TableColumn("Command") { session in
                Text(session.shellCommand)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .width(min: 150, ideal: 200)

            TableColumn("Exit") { session in
                ExitCodeBadge(exitCode: session.exitCode)
            }
            .width(min: 50, ideal: 60, max: 80)

            TableColumn("Duration") { session in
                Text(CommandHistoryFormatters.formatDuration(session.durationMs))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .width(min: 60, ideal: 80, max: 100)

            TableColumn("Time") { session in
                Text(CommandHistoryFormatters.formatRelativeTimestamp(session.timestamp))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .width(min: 80, ideal: 120)

            TableColumn("Directory") { session in
                Text(CommandHistoryFormatters.abbreviateDirectory(session.workingDirectory))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(session.workingDirectory)
            }
            .width(min: 100, ideal: 150)
        }
        .contextMenu(forSelectionType: String.self) { sessionIds in
            if let sessionId = sessionIds.first,
               let session = client.commandHistory.first(where: { $0.id == sessionId }) {
                Button(action: { copyCommand(session) }) {
                    Label("Copy Command", systemImage: "doc.on.doc")
                }

                Button(action: { rerunCommand(session) }) {
                    Label("Re-run Command", systemImage: "arrow.clockwise")
                }
                .disabled(session.exitCode == nil) // Can't re-run if still running

                Divider()

                Button(action: { openInTerminal(session) }) {
                    Label("Open in Terminal", systemImage: "terminal")
                }
            }
        } primaryAction: { sessionIds in
            // Double-click action: show full output
            if let sessionId = sessionIds.first {
                selectedSessionId = sessionId
            }
        }
    }

    @ViewBuilder
    private var detailPanel: some View {
        if let session = selectedSession {
            CommandHistoryDetailPanel(
                client: client,
                session: session,
                onRerun: { rerunCommand(session) }
            )
        } else {
            emptyDetailState
        }
    }

    private var emptyDetailState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("Select a command")
                .font(.title3)
                .foregroundColor(.secondary)

            Text("Click a row to see output details")
                .font(.body)
                .foregroundColor(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Actions

    private func loadHistory() {
        logger.info("Loading command history")
        client.getCommandHistory(workingDirectory: workingDirectory, limit: 50)
    }

    private func refresh() {
        isRefreshing = true
        loadHistory()

        // Reset after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            isRefreshing = false
        }
    }

    private func copyCommand(_ session: CommandHistorySession) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.shellCommand, forType: .string)
        logger.info("Copied command: \(session.shellCommand)")
    }

    private func rerunCommand(_ session: CommandHistorySession) {
        logger.info("Re-running command: \(session.commandId)")
        Task {
            let newSessionId = await client.executeCommand(
                commandId: session.commandId,
                workingDirectory: session.workingDirectory
            )
            logger.info("Started new command session: \(newSessionId)")
        }
    }

    private func openInTerminal(_ session: CommandHistorySession) {
        // Escape single quotes in path to prevent AppleScript injection
        // A single quote becomes: end string, escaped quote, start string
        let escapedPath = session.workingDirectory.replacingOccurrences(of: "'", with: "'\\''")

        let script = """
        tell application "Terminal"
            activate
            do script "cd '\(escapedPath)'"
        end tell
        """

        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
            if let error = error {
                logger.error("Failed to open Terminal: \(error)")
            }
        }
    }
}

// MARK: - StatusBadge

struct StatusBadge: View {
    let session: CommandHistorySession

    var body: some View {
        Group {
            if let exitCode = session.exitCode {
                Image(systemName: exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(exitCode == 0 ? .green : .red)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - ExitCodeBadge

struct ExitCodeBadge: View {
    let exitCode: Int?

    var body: some View {
        Group {
            if let code = exitCode {
                Text("\(code)")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(code == 0 ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                    .foregroundColor(code == 0 ? .green : .red)
                    .cornerRadius(4)
            } else {
                Text("-")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - CommandHistoryDetailPanel

struct CommandHistoryDetailPanel: View {
    @ObservedObject var client: VoiceCodeClientCore
    let session: CommandHistorySession
    let onRerun: () -> Void

    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            detailHeader

            Divider()

            // Output content
            outputContent

            Divider()

            // Action bar
            actionBar
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            loadOutput()
        }
        .onChange(of: session.id) { oldValue, newValue in
            loadOutput()
        }
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Command
            Text("$ \(session.shellCommand)")
                .font(.system(.headline, design: .monospaced))

            // Metadata
            HStack(spacing: 16) {
                // Directory
                Label(CommandHistoryFormatters.abbreviateDirectory(session.workingDirectory), systemImage: "folder")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .help(session.workingDirectory)

                // Timestamp
                Label(CommandHistoryFormatters.formatAbsoluteTimestamp(session.timestamp), systemImage: "clock")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                // Exit code and duration
                if let exitCode = session.exitCode {
                    ExitCodeBadge(exitCode: exitCode)
                }

                if let durationMs = session.durationMs {
                    Text(CommandHistoryFormatters.formatDuration(durationMs))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var outputContent: some View {
        ScrollView {
            if isLoading {
                VStack(spacing: 16) {
                    Spacer()
                    ProgressView("Loading output...")
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let output = client.commandOutputFull,
                      output.commandSessionId == session.commandSessionId {
                if output.output.isEmpty {
                    Text("No output")
                        .foregroundColor(.secondary)
                        .italic()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                } else {
                    Text(output.output)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else {
                // Preview while loading full output
                VStack(alignment: .leading, spacing: 8) {
                    Text("Preview:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(session.outputPreview.isEmpty ? "No output preview" : session.outputPreview)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(session.outputPreview.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Spacer()

            Button(action: { copyOutput() }) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(client.commandOutputFull?.commandSessionId != session.commandSessionId)

            Button(action: onRerun) {
                Label("Re-run", systemImage: "arrow.clockwise")
            }
            .disabled(session.exitCode == nil)
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Actions

    private func loadOutput() {
        isLoading = true
        client.getCommandOutput(commandSessionId: session.commandSessionId)

        // Reset loading state after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            isLoading = false
        }
    }

    private func copyOutput() {
        guard let output = client.commandOutputFull,
              output.commandSessionId == session.commandSessionId else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output.output, forType: .string)
        logger.info("Copied output for session: \(session.commandSessionId)")
    }
}

// MARK: - Previews

#Preview("Command History View") {
    let client = VoiceCodeClient(
        serverURL: "ws://localhost:8080",
        setupObservers: false
    )

    // Mock some history data
    let sessions = [
        CommandHistorySession(
            commandSessionId: "cmd-1",
            commandId: "build",
            shellCommand: "make build",
            workingDirectory: "/Users/test/project",
            timestamp: Date().addingTimeInterval(-300),
            exitCode: 0,
            durationMs: 2345,
            outputPreview: "Building project...\nCompile succeeded"
        ),
        CommandHistorySession(
            commandSessionId: "cmd-2",
            commandId: "test",
            shellCommand: "make test",
            workingDirectory: "/Users/test/project",
            timestamp: Date().addingTimeInterval(-600),
            exitCode: 1,
            durationMs: 5678,
            outputPreview: "Running tests...\n2 tests failed"
        ),
        CommandHistorySession(
            commandSessionId: "cmd-3",
            commandId: "git.status",
            shellCommand: "git status",
            workingDirectory: "/Users/test/project",
            timestamp: Date().addingTimeInterval(-900),
            exitCode: 0,
            durationMs: 123,
            outputPreview: "On branch main\nnothing to commit"
        ),
        CommandHistorySession(
            commandSessionId: "cmd-4",
            commandId: "deploy",
            shellCommand: "make deploy",
            workingDirectory: "/Users/test/project",
            timestamp: Date(),
            exitCode: nil,
            durationMs: nil,
            outputPreview: "Deploying to production..."
        )
    ]

    // Note: In real usage, sessions would be populated via WebSocket messages
    // For preview, we'd need to inject them directly, but VoiceCodeClientCore
    // schedules updates so we show the empty state in preview

    return CommandHistoryView(
        client: client,
        workingDirectory: nil
    )
    .frame(width: 1000, height: 600)
}

#Preview("Empty History") {
    let client = VoiceCodeClient(
        serverURL: "ws://localhost:8080",
        setupObservers: false
    )

    return CommandHistoryView(
        client: client,
        workingDirectory: nil
    )
    .frame(width: 1000, height: 600)
}

#Preview("Status Badge - Success") {
    StatusBadge(session: CommandHistorySession(
        commandSessionId: "cmd-1",
        commandId: "build",
        shellCommand: "make build",
        workingDirectory: "/Users/test",
        timestamp: Date(),
        exitCode: 0,
        durationMs: 1234,
        outputPreview: "Done"
    ))
    .padding()
}

#Preview("Status Badge - Error") {
    StatusBadge(session: CommandHistorySession(
        commandSessionId: "cmd-2",
        commandId: "test",
        shellCommand: "make test",
        workingDirectory: "/Users/test",
        timestamp: Date(),
        exitCode: 1,
        durationMs: 5678,
        outputPreview: "Failed"
    ))
    .padding()
}

#Preview("Status Badge - Running") {
    StatusBadge(session: CommandHistorySession(
        commandSessionId: "cmd-3",
        commandId: "deploy",
        shellCommand: "make deploy",
        workingDirectory: "/Users/test",
        timestamp: Date(),
        exitCode: nil,
        durationMs: nil,
        outputPreview: "In progress..."
    ))
    .padding()
}

#Preview("Exit Code Badges") {
    HStack(spacing: 20) {
        ExitCodeBadge(exitCode: 0)
        ExitCodeBadge(exitCode: 1)
        ExitCodeBadge(exitCode: 127)
        ExitCodeBadge(exitCode: nil)
    }
    .padding()
}
