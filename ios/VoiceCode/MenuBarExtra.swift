// MenuBarExtra.swift
// Menu bar extra for quick voice capture on macOS

#if os(macOS)
import SwiftUI

struct VoiceCodeMenuBarExtra: Scene {
    @ObservedObject var client: VoiceCodeClient
    @ObservedObject var settings: AppSettings
    @ObservedObject var voiceOutput: VoiceOutputManager

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(client: client, settings: settings, voiceOutput: voiceOutput)
        } label: {
            Image(systemName: client.isConnected ? "waveform.circle.fill" : "waveform.circle")
                .symbolRenderingMode(.hierarchical)
                .foregroundColor(client.isConnected ? .green : .red)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarContentView: View {
    @ObservedObject var client: VoiceCodeClient
    @ObservedObject var settings: AppSettings
    @ObservedObject var voiceOutput: VoiceOutputManager
    @StateObject private var voiceInput: VoiceInputManager

    @State private var selectedDirectory: String
    @State private var transcription: String = ""
    @State private var response: String?
    @State private var isProcessing = false

    init(client: VoiceCodeClient, settings: AppSettings, voiceOutput: VoiceOutputManager) {
        self.client = client
        self.settings = settings
        self.voiceOutput = voiceOutput
        self._voiceInput = StateObject(wrappedValue: VoiceInputManager(voiceOutputManager: voiceOutput))
        self._selectedDirectory = State(initialValue: settings.lastUsedDirectory ?? NSHomeDirectory())
    }

    var body: some View {
        VStack(spacing: 0) {
            directorySelector
            Divider()
            voiceInputArea
            transcriptionArea
            Divider()
            recentSessionsList
            Divider()
            footerActions
        }
        .frame(width: 300)
    }

    // MARK: - Directory Selector

    private var directorySelector: some View {
        HStack {
            Image(systemName: "folder")
                .foregroundColor(.secondary)
            Menu {
                ForEach(settings.recentDirectories, id: \.self) { dir in
                    Button(abbreviatePath(dir)) {
                        selectedDirectory = dir
                        settings.lastUsedDirectory = dir
                    }
                }
                if !settings.recentDirectories.isEmpty {
                    Divider()
                }
                Button("Browse...") { browseDirectory() }
            } label: {
                Text(abbreviatePath(selectedDirectory))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }

    // MARK: - Voice Input Area

    private var voiceInputArea: some View {
        VStack(spacing: 12) {
            Button(action: toggleRecording) {
                Image(systemName: voiceInput.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(voiceInput.isRecording ? .red : .accentColor)
            }
            .buttonStyle(.plain)
            .disabled(!client.isConnected)
            .keyboardShortcut(.space, modifiers: [])

            Text(voiceInput.isRecording ? "Recording... (click to stop)" : "Click or press Space")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    // MARK: - Transcription / Response Area

    @ViewBuilder
    private var transcriptionArea: some View {
        if !transcription.isEmpty || response != nil {
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !transcription.isEmpty {
                        Text(transcription)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(8)
                    }

                    if let response = response {
                        Text(response)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(8)
                    }

                    if isProcessing {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Processing...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(8)
                    }
                }
                .padding(.horizontal)
            }
            .frame(maxHeight: 200)

            if !transcription.isEmpty && response == nil && !isProcessing {
                HStack {
                    Button("Send") { sendPrompt() }
                        .keyboardShortcut(.return, modifiers: [])
                    Button("Cancel") { clearTranscription() }
                        .keyboardShortcut(.escape, modifiers: [])
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Recent Sessions

    private var recentSessionsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent Sessions")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            if client.parsedRecentSessions.isEmpty {
                Text("No recent sessions")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            } else {
                ForEach(Array(client.parsedRecentSessions.prefix(3)), id: \.sessionId) { session in
                    HStack {
                        Text(session.name)
                            .lineLimit(1)
                        Spacer()
                        Text(relativeTimestamp(session.lastModified))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Footer Actions

    private var footerActions: some View {
        VStack(spacing: 2) {
            Button(action: openMainWindow) {
                Text("Open VoiceCode")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 4)

            Button(action: openSettings) {
                Text("Settings...")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 4)

            Divider()

            Button(action: { NSApplication.shared.terminate(nil) }) {
                Text("Quit")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func toggleRecording() {
        if voiceInput.isRecording {
            voiceInput.stopRecording()
            transcription = voiceInput.transcribedText
        } else {
            voiceInput.startRecording()
            response = nil
        }
    }

    private func sendPrompt() {
        guard !transcription.isEmpty else { return }
        isProcessing = true
        settings.lastUsedDirectory = selectedDirectory
        client.sendQuickPrompt(text: transcription, directory: selectedDirectory) { result in
            isProcessing = false
            response = result
        }
    }

    private func clearTranscription() {
        transcription = ""
        response = nil
    }

    private func browseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            selectedDirectory = url.path
            settings.lastUsedDirectory = url.path
        }
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    // MARK: - Helpers

    private func abbreviatePath(_ path: String) -> String {
        MenuBarHelpers.abbreviatePath(path)
    }

    private func relativeTimestamp(_ date: Date) -> String {
        MenuBarHelpers.relativeTimestamp(date)
    }
}

// MARK: - Testable Helpers

enum MenuBarHelpers {
    /// Abbreviate path to last 2 components (e.g. /Users/test/projects/webapp → projects/webapp)
    static func abbreviatePath(_ path: String) -> String {
        let components = path.components(separatedBy: "/").filter { !$0.isEmpty }
        if components.count <= 2 {
            return path
        }
        return components.suffix(2).joined(separator: "/")
    }

    /// Format a date as relative timestamp (e.g. "2m ago", "1h ago")
    static func relativeTimestamp(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }
}
#endif
