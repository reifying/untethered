// DebugLogsView.swift
// Console-style view for viewing app logs per Appendix I.6
// - File-based log display from ~/Library/Logs/VoiceCode/
// - Daily log file selection
// - Search within logs (⌘F)
// - Copy/export functionality
// - Category filtering

import SwiftUI
import OSLog
import VoiceCodeShared

private let logger = Logger(subsystem: "dev.910labs.voice-code-desktop", category: "DebugLogsView")

// MARK: - DebugLogsView

struct DebugLogsView: View {
    @State private var logFiles: [URL] = []
    @State private var selectedLogFile: URL?
    @State private var logContent: [LogLine] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    @State private var searchText = ""
    @State private var isSearchVisible = false
    @State private var selectedCategories: Set<String> = []
    @State private var availableCategories: Set<String> = []
    @State private var autoScrollEnabled = true
    @State private var showingExportPanel = false

    @FocusState private var isSearchFocused: Bool

    // MARK: - Computed Properties

    private var filteredContent: [LogLine] {
        var result = logContent

        // Filter by search text
        if !searchText.isEmpty {
            result = result.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
        }

        // Filter by selected categories (if any selected)
        if !selectedCategories.isEmpty {
            result = result.filter { selectedCategories.contains($0.category) }
        }

        return result
    }

    private var matchCount: Int {
        guard !searchText.isEmpty else { return 0 }
        return filteredContent.count
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Search bar (shown when ⌘F pressed)
            if isSearchVisible {
                searchBar
            }

            // Toolbar with file picker and controls
            toolbar

            Divider()

            // Main content
            if isLoading {
                loadingView
            } else if let error = errorMessage {
                errorView(error)
            } else if logContent.isEmpty {
                emptyStateView
            } else {
                logContentView
            }

            Divider()

            // Footer with stats and actions
            footer
        }
        .frame(minWidth: 700, minHeight: 500)
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
            loadLogFiles()
        }
        .fileExporter(
            isPresented: $showingExportPanel,
            document: LogExportDocument(content: exportContent),
            contentType: .plainText,
            defaultFilename: exportFilename
        ) { result in
            switch result {
            case .success(let url):
                logger.info("📤 Exported logs to: \(url.path)")
            case .failure(let error):
                logger.error("❌ Export failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Subviews

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            TextField("Search logs...", text: $searchText)
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

    private var toolbar: some View {
        HStack(spacing: 12) {
            // Log file picker
            Picker("Log File:", selection: $selectedLogFile) {
                if logFiles.isEmpty {
                    Text("No log files").tag(nil as URL?)
                } else {
                    ForEach(logFiles, id: \.self) { file in
                        Text(file.lastPathComponent).tag(file as URL?)
                    }
                }
            }
            .pickerStyle(.menu)
            .frame(width: 200)
            .onChange(of: selectedLogFile) { newValue in
                if let file = newValue {
                    loadLogContent(from: file)
                }
            }

            // Category filter
            if !availableCategories.isEmpty {
                Menu {
                    Button("All Categories") {
                        selectedCategories.removeAll()
                    }

                    Divider()

                    ForEach(Array(availableCategories).sorted(), id: \.self) { category in
                        Button {
                            if selectedCategories.contains(category) {
                                selectedCategories.remove(category)
                            } else {
                                selectedCategories.insert(category)
                            }
                        } label: {
                            HStack {
                                Text(category)
                                if selectedCategories.contains(category) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label(
                        selectedCategories.isEmpty ? "All Categories" : "\(selectedCategories.count) Selected",
                        systemImage: "line.3.horizontal.decrease.circle"
                    )
                }
            }

            Spacer()

            // Auto-scroll toggle
            Toggle(isOn: $autoScrollEnabled) {
                Image(systemName: autoScrollEnabled ? "arrow.down.circle.fill" : "arrow.down.circle")
            }
            .toggleStyle(.button)
            .help(autoScrollEnabled ? "Disable auto-scroll" : "Enable auto-scroll")

            // Refresh button
            Button(action: refreshLogs) {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh log files")

            // Reveal in Finder
            Button(action: revealInFinder) {
                Image(systemName: "folder")
            }
            .help("Show logs in Finder")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Loading logs...")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Error Loading Logs")
                .font(.title3)

            Text(message)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Try Again") {
                if let file = selectedLogFile {
                    loadLogContent(from: file)
                } else {
                    loadLogFiles()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text(selectedLogFile == nil ? "No Log Files" : "No Log Entries")
                .font(.title3)

            Text(selectedLogFile == nil
                 ? "Enable debug logging in Settings > Advanced to start collecting logs."
                 : "This log file is empty.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if selectedLogFile == nil {
                Button("Open Settings") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var logContentView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredContent) { line in
                        logLineView(line)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(.body, design: .monospaced))
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: logContent.count) { _ in
                if autoScrollEnabled && searchText.isEmpty, let lastLine = logContent.last {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(lastLine.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func logLineView(_ line: LogLine) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Timestamp
            Text(line.timestamp)
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .leading)

            // Category badge
            Text(line.category)
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(categoryColor(line.category).opacity(0.2))
                .foregroundColor(categoryColor(line.category))
                .cornerRadius(4)
                .frame(width: 120, alignment: .leading)

            // Message
            Text(line.message)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            // Stats
            HStack(spacing: 8) {
                Text("\(filteredContent.count) lines")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if !searchText.isEmpty || !selectedCategories.isEmpty {
                    Text("(\(logContent.count) total)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let file = selectedLogFile {
                    Text("•")
                        .foregroundColor(.secondary)
                    Text(fileSize(for: file))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Action buttons
            HStack(spacing: 8) {
                Button(action: copyToClipboard) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(filteredContent.isEmpty)
                .help("Copy filtered logs to clipboard")

                Button(action: { showingExportPanel = true }) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(filteredContent.isEmpty)
                .help("Export filtered logs to file")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Actions

    private func loadLogFiles() {
        let logDir = LogManager.shared.logDirectory

        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: logDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            )

            logFiles = files
                .filter { $0.pathExtension == "log" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent } // Most recent first

            // Select most recent file by default
            if selectedLogFile == nil, let first = logFiles.first {
                selectedLogFile = first
                loadLogContent(from: first)
            }

            logger.info("📁 Found \(logFiles.count) log files")
        } catch {
            // Directory may not exist yet
            logFiles = []
            logger.info("📁 No log directory found: \(error.localizedDescription)")
        }
    }

    private func loadLogContent(from file: URL) {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let content = try String(contentsOf: file, encoding: .utf8)
                let lines = content.components(separatedBy: .newlines)
                    .filter { !$0.isEmpty }
                    .enumerated()
                    .map { index, line in
                        LogLine(id: index, text: line)
                    }

                // Extract available categories
                let categories = Set(lines.map { $0.category })

                await MainActor.run {
                    logContent = lines
                    availableCategories = categories
                    isLoading = false
                    logger.info("📄 Loaded \(lines.count) log lines from \(file.lastPathComponent)")
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                    logger.error("❌ Failed to load log file: \(error.localizedDescription)")
                }
            }
        }
    }

    private func refreshLogs() {
        loadLogFiles()
        if let file = selectedLogFile {
            loadLogContent(from: file)
        }
    }

    private func revealInFinder() {
        let logDir = LogManager.shared.logDirectory
        NSWorkspace.shared.selectFile(selectedLogFile?.path, inFileViewerRootedAtPath: logDir.path)
    }

    private func copyToClipboard() {
        let text = filteredContent.map { $0.text }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        logger.info("📋 Copied \(filteredContent.count) lines to clipboard")
    }

    private var exportContent: String {
        filteredContent.map { $0.text }.joined(separator: "\n")
    }

    private var exportFilename: String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        return "voicecode-logs-\(timestamp).txt"
    }

    private func fileSize(for url: URL) -> String {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? Int64 {
                return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            }
        } catch {
            // Ignore
        }
        return ""
    }

    private func categoryColor(_ category: String) -> Color {
        // Consistent colors for common categories
        switch category.lowercased() {
        case "voicecodeclient": return .blue
        case "conversationdetailview": return .green
        case "mainwindowview": return .purple
        case "commandoutputwindow": return .orange
        case "floatingvoicepanel": return .cyan
        case "voiceinputmanager": return .pink
        case "globalhotkeymanager": return .yellow
        case "resourcesmanager": return .teal
        case "general": return .gray
        default:
            // Generate consistent color from category name
            let hash = abs(category.hashValue)
            let hue = Double(hash % 360) / 360.0
            return Color(hue: hue, saturation: 0.6, brightness: 0.8)
        }
    }
}

// MARK: - LogLine Model

struct LogLine: Identifiable {
    let id: Int
    let text: String

    // Parsed components
    let timestamp: String
    let category: String
    let message: String

    init(id: Int, text: String) {
        self.id = id
        self.text = text

        // Parse log line format: [HH:mm:ss.SSS] [Category] Message
        let pattern = #"\[([^\]]+)\]\s*\[([^\]]+)\]\s*(.*)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let timestampRange = Range(match.range(at: 1), in: text),
           let categoryRange = Range(match.range(at: 2), in: text),
           let messageRange = Range(match.range(at: 3), in: text) {
            self.timestamp = String(text[timestampRange])
            self.category = String(text[categoryRange])
            self.message = String(text[messageRange])
        } else {
            // Fallback for unparseable lines
            self.timestamp = ""
            self.category = "Unknown"
            self.message = text
        }
    }
}

// MARK: - Log Export Document

struct LogExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    let content: String

    init(content: String) {
        self.content = content
    }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            content = String(data: data, encoding: .utf8) ?? ""
        } else {
            content = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = content.data(using: .utf8) ?? Data()
        return FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - UTType Extension

import UniformTypeIdentifiers

// MARK: - Preview

#Preview("Debug Logs - With Content") {
    DebugLogsView()
        .frame(width: 900, height: 600)
}

#Preview("Debug Logs - Empty") {
    DebugLogsView()
        .frame(width: 900, height: 600)
}
