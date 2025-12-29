// CommandOutputWindow.swift
// macOS Command Output Window per Appendix J.3 specification:
// - Monospace font (SF Mono or system monospace)
// - ANSI color support
// - Auto-scroll (toggleable)
// - Search within output (⌘F)
// - Copy all / Copy selection
// - Re-run same command
// - Clear output
// - Window stays on top option

import SwiftUI
import AppKit
import OSLog
import VoiceCodeShared

private let logger = Logger(subsystem: "dev.910labs.voice-code-desktop", category: "CommandOutputWindow")

// MARK: - CommandOutputWindow

struct CommandOutputWindow: View {
    @ObservedObject var client: VoiceCodeClientCore
    let commandSessionId: String
    let workingDirectory: String

    @State private var autoScrollEnabled = true
    @State private var searchText = ""
    @State private var isSearchVisible = false
    @State private var staysOnTop = false
    @FocusState private var isSearchFocused: Bool

    private var execution: CommandExecution? {
        client.runningCommands[commandSessionId]
    }

    // MARK: - Computed Properties

    private var filteredOutput: [CommandExecution.OutputLine] {
        guard let execution = execution else { return [] }
        guard !searchText.isEmpty else { return execution.output }
        return execution.output.filter {
            $0.text.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var matchCount: Int {
        guard !searchText.isEmpty else { return 0 }
        return filteredOutput.count
    }

    private var formattedDuration: String? {
        guard let duration = execution?.duration else { return nil }
        return CommandOutputWindow.formatDuration(duration)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Search bar (shown when ⌘F pressed)
            if isSearchVisible {
                searchBar
            }

            if let execution = execution {
                // Command header
                commandHeader(execution)

                Divider()

                // Output area
                outputArea(execution)

                Divider()

                // Footer with actions
                commandFooter(execution)
            } else {
                emptyState
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .background {
            // Hidden button for ⌘F keyboard shortcut
            Button("") {
                isSearchVisible = true
                isSearchFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .allowsHitTesting(false)

            // Hidden button for Escape to dismiss search
            Button("") {
                if isSearchVisible {
                    isSearchVisible = false
                    searchText = ""
                }
            }
            .keyboardShortcut(.escape, modifiers: [])
            .opacity(0)
            .allowsHitTesting(false)
        }
        .onAppear {
            logger.info("📺 CommandOutputWindow opened for session: \(commandSessionId)")
        }
    }

    // MARK: - Subviews

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            TextField("Search output...", text: $searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)

            if !searchText.isEmpty {
                Text("\(matchCount) matches")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Button(action: {
                isSearchVisible = false
                searchText = ""
            }) {
                Text("Done")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func commandHeader(_ execution: CommandExecution) -> some View {
        HStack(spacing: 12) {
            statusIcon(for: execution.status)

            VStack(alignment: .leading, spacing: 2) {
                Text("$ \(execution.shellCommand)")
                    .font(.system(.headline, design: .monospaced))

                HStack(spacing: 12) {
                    Text(execution.commandId)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let duration = formattedDuration {
                        Text(duration)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let exitCode = execution.exitCode {
                        exitCodeBadge(exitCode)
                    }
                }
            }

            Spacer()

            // Stays on top toggle
            Toggle(isOn: $staysOnTop) {
                Image(systemName: staysOnTop ? "pin.fill" : "pin")
            }
            .toggleStyle(.button)
            .help("Keep window on top")
            .onChange(of: staysOnTop) { newValue in
                updateWindowLevel(staysOnTop: newValue)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func outputArea(_ execution: CommandExecution) -> some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredOutput) { line in
                            outputLineView(line)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(.body, design: .monospaced))
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: execution.output.count) { _ in
                    // Only auto-scroll when not searching (filtered view has different items)
                    if autoScrollEnabled && searchText.isEmpty, let lastLine = execution.output.last {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(lastLine.id, anchor: .bottom)
                        }
                    }
                }
            }

            // Auto-scroll toggle button
            if !execution.output.isEmpty {
                Button(action: { autoScrollEnabled.toggle() }) {
                    Image(systemName: autoScrollEnabled ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .font(.title2)
                        .foregroundColor(autoScrollEnabled ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .padding()
                .help(autoScrollEnabled ? "Disable auto-scroll" : "Enable auto-scroll")
            }
        }
    }

    private func commandFooter(_ execution: CommandExecution) -> some View {
        HStack(spacing: 16) {
            // Status info
            HStack(spacing: 8) {
                if let exitCode = execution.exitCode {
                    Text("Exit: \(exitCode)")
                        .font(.caption)
                        .foregroundColor(exitCode == 0 ? .green : .red)
                }

                if let duration = formattedDuration {
                    Text("Duration: \(duration)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Text("\(execution.output.count) lines")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Action buttons
            HStack(spacing: 8) {
                Button(action: { clearOutput() }) {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(execution.output.isEmpty)
                .help("Clear output")

                Button(action: { copyAllOutput(execution) }) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(execution.output.isEmpty)
                .help("Copy all output")

                Button(action: { rerunCommand(execution) }) {
                    Label("Re-run", systemImage: "arrow.clockwise")
                }
                .disabled(execution.status == .running)
                .help("Re-run this command")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("Command Not Found")
                .font(.title3)
                .foregroundColor(.secondary)

            Text("The command execution may have been cleared.")
                .font(.body)
                .foregroundColor(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Output Line View

    private func outputLineView(_ line: CommandExecution.OutputLine) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Stream indicator
            Circle()
                .fill(line.stream == .stdout ? Color.blue : Color.orange)
                .frame(width: 6, height: 6)
                .padding(.top, 6)

            // Parse ANSI codes and render text
            ANSITextView(text: line.text, streamType: line.stream)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
    }

    private func statusIcon(for status: CommandExecution.ExecutionStatus) -> some View {
        Group {
            switch status {
            case .running:
                ProgressView()
                    .controlSize(.small)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title3)
            case .error:
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.title3)
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

    // MARK: - Actions

    private func copyAllOutput(_ execution: CommandExecution) {
        let text = execution.output.map { $0.text }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        logger.info("📋 Copied \(execution.output.count) lines to clipboard")
    }

    private func rerunCommand(_ execution: CommandExecution) {
        logger.info("🔄 Re-running command: \(execution.commandId)")
        Task {
            let newSessionId = await client.executeCommand(
                commandId: execution.commandId,
                workingDirectory: workingDirectory
            )
            logger.info("✅ New command session started: \(newSessionId)")
        }
    }

    private func clearOutput() {
        guard var execution = client.runningCommands[commandSessionId] else { return }
        execution.output.removeAll()
        client.runningCommands[commandSessionId] = execution
        logger.info("🗑️ Cleared output for session: \(commandSessionId)")
    }

    private func updateWindowLevel(staysOnTop: Bool) {
        // Use the key window which is the currently focused window containing this view
        guard let window = NSApplication.shared.keyWindow else {
            logger.warning("⚠️ No key window available for window level change")
            return
        }
        window.level = staysOnTop ? .floating : .normal
        logger.info("📌 Window level set to: \(staysOnTop ? "floating" : "normal")")
    }

    // MARK: - Helpers

    static func formatDuration(_ duration: TimeInterval) -> String {
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

// MARK: - ANSITextView

/// View that parses and renders ANSI escape codes
struct ANSITextView: View {
    let text: String
    let streamType: CommandExecution.OutputLine.StreamType

    var body: some View {
        // Parse ANSI codes and create attributed text
        Text(parseANSI(text))
            .foregroundColor(streamType == .stdout ? .primary : .orange)
    }

    /// Parse ANSI escape codes and return AttributedString
    private func parseANSI(_ input: String) -> AttributedString {
        var result = AttributedString()
        var currentIndex = input.startIndex
        var currentForeground: Color?
        var currentBackground: Color?
        var isBold = false
        var isItalic = false
        var isUnderline = false

        // Regex pattern for ANSI escape sequences
        // Matches: ESC[<params>m where params are semicolon-separated numbers
        let pattern = #"\x1B\[([0-9;]*)m"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])

        guard let regex = regex else {
            // If regex fails, return plain text
            result.append(AttributedString(input))
            return result
        }

        let nsString = input as NSString
        let matches = regex.matches(in: input, options: [], range: NSRange(location: 0, length: nsString.length))

        for match in matches {
            // Add text before this match
            let matchRange = Range(match.range, in: input)!
            let textBeforeMatch = input[currentIndex..<matchRange.lowerBound]
            if !textBeforeMatch.isEmpty {
                var attrStr = AttributedString(String(textBeforeMatch))
                applyStyle(to: &attrStr, foreground: currentForeground, background: currentBackground, bold: isBold, italic: isItalic, underline: isUnderline)
                result.append(attrStr)
            }

            // Parse the escape code
            if let paramsRange = Range(match.range(at: 1), in: input) {
                let params = input[paramsRange]
                let codes = params.split(separator: ";").compactMap { Int($0) }

                for code in codes {
                    switch code {
                    case 0:  // Reset
                        currentForeground = nil
                        currentBackground = nil
                        isBold = false
                        isItalic = false
                        isUnderline = false
                    case 1:
                        isBold = true
                    case 3:
                        isItalic = true
                    case 4:
                        isUnderline = true
                    case 22:
                        isBold = false
                    case 23:
                        isItalic = false
                    case 24:
                        isUnderline = false
                    case 30...37:  // Standard foreground colors
                        currentForeground = ansiColor(code - 30)
                    case 38:
                        // Extended foreground color (not fully implemented)
                        break
                    case 39:  // Default foreground
                        currentForeground = nil
                    case 40...47:  // Standard background colors
                        currentBackground = ansiColor(code - 40)
                    case 48:
                        // Extended background color (not fully implemented)
                        break
                    case 49:  // Default background
                        currentBackground = nil
                    case 90...97:  // Bright foreground colors
                        currentForeground = ansiBrightColor(code - 90)
                    case 100...107:  // Bright background colors
                        currentBackground = ansiBrightColor(code - 100)
                    default:
                        break
                    }
                }
            }

            currentIndex = matchRange.upperBound
        }

        // Add remaining text after last match
        if currentIndex < input.endIndex {
            var attrStr = AttributedString(String(input[currentIndex...]))
            applyStyle(to: &attrStr, foreground: currentForeground, background: currentBackground, bold: isBold, italic: isItalic, underline: isUnderline)
            result.append(attrStr)
        }

        // If no matches, return plain text
        if matches.isEmpty {
            result.append(AttributedString(input))
        }

        return result
    }

    private func applyStyle(to attrStr: inout AttributedString, foreground: Color?, background: Color?, bold: Bool, italic: Bool, underline: Bool) {
        if let fg = foreground {
            attrStr.foregroundColor = fg
        }
        if let bg = background {
            attrStr.backgroundColor = bg
        }
        if underline {
            attrStr.underlineStyle = .single
        }
        // Bold and italic would need font changes, which is more complex
        // Skipping for now as monospace fonts don't always have bold/italic variants
    }

    private func ansiColor(_ code: Int) -> Color {
        switch code {
        case 0: return .black
        case 1: return .red
        case 2: return .green
        case 3: return .yellow
        case 4: return .blue
        case 5: return .purple
        case 6: return .cyan
        case 7: return .white
        default: return .primary
        }
    }

    private func ansiBrightColor(_ code: Int) -> Color {
        switch code {
        case 0: return Color(nsColor: .darkGray)
        case 1: return Color(nsColor: NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1.0))
        case 2: return Color(nsColor: NSColor(red: 0.3, green: 1.0, blue: 0.3, alpha: 1.0))
        case 3: return Color(nsColor: NSColor(red: 1.0, green: 1.0, blue: 0.3, alpha: 1.0))
        case 4: return Color(nsColor: NSColor(red: 0.3, green: 0.3, blue: 1.0, alpha: 1.0))
        case 5: return Color(nsColor: NSColor(red: 1.0, green: 0.3, blue: 1.0, alpha: 1.0))
        case 6: return Color(nsColor: NSColor(red: 0.3, green: 1.0, blue: 1.0, alpha: 1.0))
        case 7: return .white
        default: return .primary
        }
    }
}

// MARK: - Preview

#Preview("Command Output - Running") {
    let client = VoiceCodeClient(
        serverURL: "ws://localhost:8080",
        setupObservers: false
    )

    // Mock a running command
    var execution = CommandExecution(
        id: "cmd-test-123",
        commandId: "build",
        shellCommand: "make build"
    )
    execution.appendOutput(stream: .stdout, text: "$ make build")
    execution.appendOutput(stream: .stdout, text: "Building project...")
    execution.appendOutput(stream: .stdout, text: "Compiling main.swift")
    execution.appendOutput(stream: .stderr, text: "warning: unused variable 'x'")
    execution.appendOutput(stream: .stdout, text: "Compiling utils.swift")
    client.runningCommands["cmd-test-123"] = execution

    return CommandOutputWindow(
        client: client,
        commandSessionId: "cmd-test-123",
        workingDirectory: "/Users/test/project"
    )
    .frame(width: 800, height: 500)
}

#Preview("Command Output - Completed") {
    let client = VoiceCodeClient(
        serverURL: "ws://localhost:8080",
        setupObservers: false
    )

    // Mock a completed command
    var execution = CommandExecution(
        id: "cmd-test-456",
        commandId: "test",
        shellCommand: "make test"
    )
    execution.appendOutput(stream: .stdout, text: "$ make test")
    execution.appendOutput(stream: .stdout, text: "Running tests...")
    execution.appendOutput(stream: .stdout, text: "✅ 42 tests passed")
    execution.appendOutput(stream: .stdout, text: "\u{001B}[32mAll tests passed!\u{001B}[0m")
    execution.complete(exitCode: 0, duration: 2.345)
    client.runningCommands["cmd-test-456"] = execution

    return CommandOutputWindow(
        client: client,
        commandSessionId: "cmd-test-456",
        workingDirectory: "/Users/test/project"
    )
    .frame(width: 800, height: 500)
}

#Preview("Command Output - Error") {
    let client = VoiceCodeClient(
        serverURL: "ws://localhost:8080",
        setupObservers: false
    )

    // Mock a failed command
    var execution = CommandExecution(
        id: "cmd-test-789",
        commandId: "build",
        shellCommand: "make build"
    )
    execution.appendOutput(stream: .stdout, text: "$ make build")
    execution.appendOutput(stream: .stdout, text: "Building project...")
    execution.appendOutput(stream: .stderr, text: "\u{001B}[31merror: missing semicolon\u{001B}[0m")
    execution.appendOutput(stream: .stderr, text: "Build failed with 1 error")
    execution.complete(exitCode: 1, duration: 0.876)
    client.runningCommands["cmd-test-789"] = execution

    return CommandOutputWindow(
        client: client,
        commandSessionId: "cmd-test-789",
        workingDirectory: "/Users/test/project"
    )
    .frame(width: 800, height: 500)
}

#Preview("Command Output - Empty") {
    let client = VoiceCodeClient(
        serverURL: "ws://localhost:8080",
        setupObservers: false
    )

    return CommandOutputWindow(
        client: client,
        commandSessionId: "nonexistent",
        workingDirectory: "/Users/test/project"
    )
    .frame(width: 800, height: 500)
}
