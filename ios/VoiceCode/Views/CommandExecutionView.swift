// CommandExecutionView.swift
// Display running and completed command executions with streaming output

import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct CommandExecutionView: View {
    @ObservedObject var client: VoiceCodeClient
    let commandSessionId: String

    @State private var autoScrollEnabled = true
    @State private var scrollProxy: ScrollViewProxy?

    private var execution: CommandExecution? {
        client.runningCommands[commandSessionId]
    }

    var body: some View {
        VStack(spacing: 0) {
            if let execution = execution {
                // Header with status and metadata
                VStack(spacing: 8) {
                    HStack {
                        statusIcon(for: execution.status)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(execution.shellCommand)
                                .font(.headline)
                            HStack(spacing: 12) {
                                Text(execution.commandId)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if let duration = execution.duration {
                                    Text(formatDuration(duration))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                if let exitCode = execution.exitCode {
                                    exitCodeBadge(exitCode)
                                }
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
                .background(Color.secondarySystemBackground)

                Divider()

                // Output area with auto-scroll
                ZStack(alignment: .bottomTrailing) {
                    ScrollViewReader { proxy in
                        Color.clear
                            .frame(height: 0)
                            .onAppear {
                                scrollProxy = proxy
                            }

                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(execution.output) { line in
                                    outputLineView(line)
                                        .id(line.id)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                        .onChange(of: execution.output.count) { _ in
                            if autoScrollEnabled, let lastLine = execution.output.last {
                                withAnimation {
                                    scrollProxy?.scrollTo(lastLine.id, anchor: .bottom)
                                }
                            }
                        }
                    }

                    // Auto-scroll toggle
                    if !execution.output.isEmpty {
                        Button(action: {
                            autoScrollEnabled.toggle()
                        }) {
                            Image(systemName: autoScrollEnabled ? "arrow.down.circle.fill" : "arrow.down.circle")
                                .font(.title2)
                                .foregroundColor(autoScrollEnabled ? .blue : .gray)
                                .background(
                                    Circle()
                                        .fill(Color.systemBackground)
                                        .shadow(radius: 2)
                                )
                        }
                        .padding()
                    }
                }
            } else {
                // Execution not found
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Command execution not found")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Command Output")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .swipeToBack()
    }

    // MARK: - View Components

    private func statusIcon(for status: CommandExecution.ExecutionStatus) -> some View {
        Group {
            switch status {
            case .running:
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title2)
            case .error:
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.title2)
            }
        }
    }

    private func exitCodeBadge(_ exitCode: Int) -> some View {
        Text("Exit: \(exitCode)")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(exitCode == 0 ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
            .foregroundColor(exitCode == 0 ? .green : .red)
            .cornerRadius(4)
    }

    private func outputLineView(_ line: CommandExecution.OutputLine) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Stream indicator
            Circle()
                .fill(line.stream == .stdout ? Color.blue : Color.orange)
                .frame(width: 6, height: 6)
                .padding(.top, 6)

            // Text content
            Text(line.text)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(line.stream == .stdout ? .primary : .orange)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1.0 {
            return String(format: "%.0fms", duration * 1000)
        } else if duration < 60.0 {
            return String(format: "%.1fs", duration)
        } else {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            return "\(minutes)m \(seconds)s"
        }
    }
}

// MARK: - Active Commands List View

struct ActiveCommandsListView: View {
    @ObservedObject var client: VoiceCodeClient

    var body: some View {
        List {
            if client.runningCommands.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "terminal")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No active commands")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Text("Execute commands from the command menu")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .padding(.top, 50)
            } else {
                ForEach(Array(client.runningCommands.values.sorted(by: { $0.startTime > $1.startTime }))) { execution in
                    NavigationLink(destination: CommandExecutionView(client: client, commandSessionId: execution.id)) {
                        CommandExecutionRowView(execution: execution)
                    }
                }
            }
        }
        .navigationTitle("Active Commands")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

struct CommandExecutionRowView: View {
    let execution: CommandExecution

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                statusIcon(for: execution.status)
                Text(execution.shellCommand)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if let duration = execution.duration {
                    Text(formatDuration(duration))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 12) {
                Text(execution.commandId)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let exitCode = execution.exitCode {
                    Text("Exit: \(exitCode)")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(exitCode == 0 ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                        .foregroundColor(exitCode == 0 ? .green : .red)
                        .cornerRadius(4)
                }

                if !execution.output.isEmpty {
                    Text("\(execution.output.count) lines")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Show last output line as preview
            if let lastLine = execution.output.last {
                Text(lastLine.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(lastLine.stream == .stdout ? .secondary : .orange)
                    .lineLimit(1)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }

    private func statusIcon(for status: CommandExecution.ExecutionStatus) -> some View {
        Group {
            switch status {
            case .running:
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(0.8)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            case .error:
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
            }
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1.0 {
            return String(format: "%.0fms", duration * 1000)
        } else if duration < 60.0 {
            return String(format: "%.1fs", duration)
        } else {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            return "\(minutes)m \(seconds)s"
        }
    }
}
