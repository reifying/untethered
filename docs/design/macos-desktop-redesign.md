# macOS Desktop Redesign

## Overview

### Problem Statement

The macOS desktop app achieves feature parity with iOS but not UX parity. Users experience an iOS app on a larger screen rather than a native desktop application. The current drill-down navigation, modal presentations, and tap-centric interactions feel foreign to macOS users who expect persistent navigation, keyboard-driven workflows, and information density.

### Goals

1. Implement desktop-native navigation with persistent sidebar (NavigationSplitView)
2. Enable seamless voice input via push-to-talk keyboard shortcut
3. Add command palette for keyboard-driven actions (Cmd+K)
4. Convert Settings to proper macOS Settings scene
5. Add menu bar quick access for voice capture without opening full app
6. Increase information density appropriate for desktop displays
7. Maintain voice-first identity—voice interaction remains primary modality

### Non-goals

- iOS changes (this is macOS-only redesign)
- Backend protocol changes
- New features beyond desktop adaptation
- Always-listening wake word detection (complexity vs. value tradeoff)

## Background & Context

### Current State

The macOS app shares most code with iOS via SwiftUI. Platform differentiation exists but is limited to:

| Implemented | Missing |
|-------------|---------|
| Keyboard shortcuts (Cmd+., Cmd+K, etc.) | NavigationSplitView sidebar |
| `.help()` tooltips on toolbar buttons | Settings scene (uses sheet) |
| `.formStyle(.grouped)` on forms | Command palette (Cmd+K overlay) |
| Trackpad swipe-to-back gesture | Push-to-talk keyboard shortcut |
| Return key sends prompt | Menu bar quick access |
| Mute toggle in menu bar | Information density adjustments |
| Platform-specific form sizing | Hover states on interactive rows |
| TextEditor for system prompt | Multi-window support |

The navigation model is the most significant gap. The current `NavigationStack` provides iOS-style drill-down where users lose context when navigating deeper. Desktop users expect to see their session list while viewing a conversation.

### Why Now

Desktop users represent a significant portion of voice-code usage. The current experience creates friction that undermines the app's productivity promise. These changes transform "iOS app on Mac" into "native Mac app."

### Related Work

- @docs/design/desktop-ux-improvements.md - Prior desktop polish (keyboard shortcuts, tooltips)
- @STANDARDS.md - Platform conventions and WebSocket protocol
- @ios/VoiceCode/VoiceCodeApp.swift - Current app structure

## Detailed Design

### 1. Navigation Architecture: Persistent Sidebar

**Problem:** Users lose context when navigating. Switching sessions requires multiple back-navigations.

**Solution:** Replace `NavigationStack` with `NavigationSplitView` on macOS.

#### Current Structure

```
NavigationStack
├── DirectoryListView (root)
│   → tap directory → SessionsForDirectoryView
│       → tap session → ConversationView
```

#### New Structure

```
NavigationSplitView (two-column)
├── Sidebar: SessionSidebarView
│   ├── Recent sessions (collapsible)
│   ├── Projects grouped by directory (collapsible)
│   ├── Commands section (collapsible)
│   └── + New Session button
└── Detail: ConversationView (or empty state)
```

#### Implementation

**File:** `ios/VoiceCode/VoiceCodeApp.swift`

```swift
#if os(macOS)
struct MacOSRootView: View {
    @EnvironmentObject var client: VoiceCodeClient
    @EnvironmentObject var settings: AppSettings
    @State private var selectedSessionId: UUID?
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            SessionSidebarView(selectedSessionId: $selectedSessionId)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
        } detail: {
            if let sessionId = selectedSessionId {
                ConversationView(sessionId: sessionId)
            } else {
                EmptyDetailView()
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

struct EmptyDetailView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("Select a session or create a new one")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("⌘N to create new session")
                .font(.caption)
                .foregroundColor(.tertiary)
        }
    }
}
#endif
```

**File:** `ios/VoiceCode/Views/SessionSidebarView.swift` (new file)

```swift
#if os(macOS)
import SwiftUI

struct SessionSidebarView: View {
    @EnvironmentObject var client: VoiceCodeClient
    @Binding var selectedSessionId: UUID?

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \CDBackendSession.lastModified, ascending: false)],
        animation: .default
    )
    private var allSessions: FetchedResults<CDBackendSession>

    @State private var recentExpanded = true
    @State private var projectsExpanded = true
    @State private var commandsExpanded = false

    private var recentSessions: [CDBackendSession] {
        Array(allSessions.prefix(10))
    }

    private var sessionsByDirectory: [String: [CDBackendSession]] {
        Dictionary(grouping: allSessions) { $0.workingDirectory ?? "Unknown" }
    }

    var body: some View {
        List(selection: $selectedSessionId) {
            // Recent Sessions
            Section(isExpanded: $recentExpanded) {
                ForEach(recentSessions, id: \.id) { session in
                    SessionSidebarRow(session: session, isLocked: client.lockedSessions.contains(session.sessionId ?? ""))
                        .tag(session.id)
                }
            } header: {
                Label("Recent", systemImage: "clock")
            }

            // Projects grouped by directory
            Section(isExpanded: $projectsExpanded) {
                ForEach(sessionsByDirectory.keys.sorted(), id: \.self) { directory in
                    DisclosureGroup {
                        ForEach(sessionsByDirectory[directory] ?? [], id: \.id) { session in
                            SessionSidebarRow(session: session, isLocked: client.lockedSessions.contains(session.sessionId ?? ""))
                                .tag(session.id)
                        }
                    } label: {
                        Label(URL(fileURLWithPath: directory).lastPathComponent, systemImage: "folder")
                    }
                }
            } header: {
                Label("Projects", systemImage: "folder.badge.gearshape")
            }

            // Commands quick access
            if !client.availableCommands.isEmpty {
                Section(isExpanded: $commandsExpanded) {
                    ForEach(client.sortedProjectCommands.prefix(5), id: \.id) { command in
                        CommandSidebarRow(command: command)
                    }
                } header: {
                    Label("Commands", systemImage: "terminal")
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { /* create new session */ }) {
                    Image(systemName: "plus")
                }
                .keyboardShortcut("n", modifiers: [.command])
                .help("New Session (⌘N)")
            }
        }
    }
}

struct SessionSidebarRow: View {
    let session: CDBackendSession
    let isLocked: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(session.workingDirectory?.components(separatedBy: "/").suffix(2).joined(separator: "/") ?? "")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            if (session.unreadCount ?? 0) > 0 {
                Text("\(session.unreadCount ?? 0)")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 2)
    }
}
#endif
```

#### Sidebar Behavior

| Action | Behavior |
|--------|----------|
| Click session | Load in detail pane |
| Double-click session | Open in new window (Phase 4) |
| Right-click session | Context menu (copy ID, delete, etc.) |
| Drag session | Reorder in priority queue |
| Cmd+0 | Toggle sidebar visibility |
| Cmd+1 | Focus sidebar |
| Cmd+2 | Focus detail pane |

---

### 2. Push-to-Talk Voice Input

**Problem:** Voice input on desktop requires clicking a button. Keyboard users want hands-on-keyboard voice access.

**Solution:** Implement push-to-talk with configurable keyboard shortcut.

#### Interaction Design

| Input | Behavior |
|-------|----------|
| Click mic button | Toggle recording (existing) |
| Hold mic button | Push-to-talk (record while held) |
| Hold Option+Space | Push-to-talk (keyboard) |
| Release | Stop recording, show transcription |
| Enter | Send transcription |
| Escape | Cancel recording |

#### Implementation

**File:** `ios/VoiceCode/Views/ConversationView.swift`

```swift
#if os(macOS)
struct PushToTalkModifier: ViewModifier {
    @EnvironmentObject var voiceInput: VoiceInputManager
    @State private var isHolding = false

    let keyCombination: KeyEquivalent = " " // Space
    let modifiers: EventModifiers = .option  // Option+Space

    func body(content: Content) -> some View {
        content
            .onKeyPress(keyCombination, phases: [.down, .up]) { press in
                guard press.modifiers == modifiers else { return .ignored }

                if press.phase == .down && !isHolding {
                    isHolding = true
                    voiceInput.startRecording()
                    return .handled
                } else if press.phase == .up && isHolding {
                    isHolding = false
                    voiceInput.stopRecording()
                    return .handled
                }
                return .ignored
            }
    }
}

extension View {
    func pushToTalk() -> some View {
        modifier(PushToTalkModifier())
    }
}
#endif
```

**Usage in ConversationView:**

```swift
var body: some View {
    VStack {
        // ... message list and input
    }
    #if os(macOS)
    .pushToTalk()
    #endif
}
```

#### Visual Feedback

When push-to-talk is active:
- Input field border pulses with accent color
- Mic icon animates
- Status text shows "Recording... (release to stop)"
- Optional: audio waveform visualization

```swift
#if os(macOS)
struct RecordingIndicator: View {
    @EnvironmentObject var voiceInput: VoiceInputManager

    var body: some View {
        if voiceInput.isRecording {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .opacity(pulseAnimation ? 1 : 0.5)
                    .animation(.easeInOut(duration: 0.5).repeatForever(), value: pulseAnimation)
                Text("Recording... (release Option+Space to stop)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.red.opacity(0.1))
            .cornerRadius(8)
        }
    }

    @State private var pulseAnimation = false
}
#endif
```

---

### 3. Command Palette (Cmd+K)

**Problem:** Desktop users expect quick keyboard access to actions without clicking through menus.

**Solution:** Implement a Spotlight-style command palette.

#### Design

```
┌─────────────────────────────────────────────────────┐
│ 🔍 Type a command...                                │
├─────────────────────────────────────────────────────┤
│ Sessions                                            │
│   ▶ New session                          ⌘N        │
│   ▶ Refresh current session              ⌘R        │
│   ▶ Compact session history              ⌘⇧C       │
│   ▶ Session info                         ⌘I        │
├─────────────────────────────────────────────────────┤
│ Project Commands                                    │
│   ▶ make build                                      │
│   ▶ make test                                       │
│   ▶ make lint                                       │
├─────────────────────────────────────────────────────┤
│ Voice                                               │
│   ▶ Stop speaking                        ⌘.        │
│   ▶ Mute voice output                    ⌘⇧M       │
└─────────────────────────────────────────────────────┘
```

#### Implementation

**File:** `ios/VoiceCode/Views/CommandPaletteView.swift` (new file)

```swift
#if os(macOS)
import SwiftUI

struct CommandPaletteView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var client: VoiceCodeClient
    @EnvironmentObject var voiceOutput: VoiceOutputManager

    @State private var searchText = ""
    @State private var selectedIndex = 0
    @FocusState private var isSearchFocused: Bool

    let onAction: (CommandPaletteAction) -> Void

    private var filteredCommands: [CommandPaletteItem] {
        let all = allCommands
        if searchText.isEmpty { return all }
        return all.filter { $0.matches(searchText) }
    }

    private var allCommands: [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []

        // Session commands
        items.append(contentsOf: [
            CommandPaletteItem(title: "New session", shortcut: "⌘N", category: "Sessions", action: .newSession),
            CommandPaletteItem(title: "Refresh current session", shortcut: "⌘R", category: "Sessions", action: .refreshSession),
            CommandPaletteItem(title: "Compact session history", shortcut: "⌘⇧C", category: "Sessions", action: .compactSession),
            CommandPaletteItem(title: "Session info", shortcut: "⌘I", category: "Sessions", action: .sessionInfo),
        ])

        // Voice commands
        items.append(contentsOf: [
            CommandPaletteItem(title: "Stop speaking", shortcut: "⌘.", category: "Voice", action: .stopSpeaking),
            CommandPaletteItem(title: voiceOutput.isMuted ? "Unmute voice" : "Mute voice", shortcut: "⌘⇧M", category: "Voice", action: .toggleMute),
        ])

        // Project commands from backend
        for command in client.sortedProjectCommands {
            items.append(CommandPaletteItem(
                title: command.label,
                shortcut: nil,
                category: "Project Commands",
                action: .runCommand(command.id)
            ))
        }

        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Type a command...", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onSubmit { executeSelected() }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Results list
            ScrollViewReader { proxy in
                List(selection: Binding(
                    get: { selectedIndex < filteredCommands.count ? filteredCommands[selectedIndex].id : nil },
                    set: { _ in }
                )) {
                    ForEach(groupedCommands, id: \.key) { category, commands in
                        Section(header: Text(category).font(.caption).foregroundColor(.secondary)) {
                            ForEach(commands) { item in
                                CommandPaletteRow(item: item)
                                    .id(item.id)
                                    .onTapGesture { execute(item) }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .onChange(of: selectedIndex) { newIndex in
                    if newIndex < filteredCommands.count {
                        proxy.scrollTo(filteredCommands[newIndex].id)
                    }
                }
            }
        }
        .frame(width: 500, height: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.3), radius: 20)
        .onAppear { isSearchFocused = true }
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private var groupedCommands: [(key: String, value: [CommandPaletteItem])] {
        Dictionary(grouping: filteredCommands) { $0.category }
            .sorted { $0.key < $1.key }
    }

    private func moveSelection(_ delta: Int) {
        let newIndex = selectedIndex + delta
        if newIndex >= 0 && newIndex < filteredCommands.count {
            selectedIndex = newIndex
        }
    }

    private func executeSelected() {
        guard selectedIndex < filteredCommands.count else { return }
        execute(filteredCommands[selectedIndex])
    }

    private func execute(_ item: CommandPaletteItem) {
        onAction(item.action)
        dismiss()
    }
}

struct CommandPaletteItem: Identifiable {
    let id = UUID()
    let title: String
    let shortcut: String?
    let category: String
    let action: CommandPaletteAction

    func matches(_ query: String) -> Bool {
        title.localizedCaseInsensitiveContains(query)
    }
}

enum CommandPaletteAction {
    case newSession
    case refreshSession
    case compactSession
    case sessionInfo
    case stopSpeaking
    case toggleMute
    case runCommand(String)
}

struct CommandPaletteRow: View {
    let item: CommandPaletteItem

    var body: some View {
        HStack {
            Image(systemName: "play.fill")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(item.title)
            Spacer()
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.caption)
                    .foregroundColor(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(4)
            }
        }
        .padding(.vertical, 4)
    }
}
#endif
```

#### Invocation

```swift
// In VoiceCodeApp.swift, add to .commands {}:
#if os(macOS)
.commands {
    CommandGroup(after: .textEditing) {
        Button("Command Palette") {
            showCommandPalette = true
        }
        .keyboardShortcut("k", modifiers: [.command])
    }
}
#endif
```

---

### 4. Settings as macOS Settings Scene

**Problem:** Settings presented as a sheet blocks the main window and doesn't follow macOS conventions.

**Solution:** Use SwiftUI `Settings` scene with tabbed preferences.

#### Implementation

**File:** `ios/VoiceCode/VoiceCodeApp.swift`

```swift
@main
struct VoiceCodeApp: App {
    // ... existing properties

    var body: some Scene {
        WindowGroup {
            // ... existing root view
        }

        #if os(macOS)
        Settings {
            MacSettingsView()
                .environmentObject(settings)
                .environmentObject(client)
                .environmentObject(voiceOutput)
        }
        #endif
    }
}
```

**File:** `ios/VoiceCode/Views/MacSettingsView.swift` (new file)

```swift
#if os(macOS)
import SwiftUI

struct MacSettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            ConnectionSettingsTab()
                .tabItem {
                    Label("Connection", systemImage: "network")
                }

            VoiceSettingsTab()
                .tabItem {
                    Label("Voice", systemImage: "waveform")
                }

            AdvancedSettingsTab()
                .tabItem {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }
        }
        .frame(width: 500, height: 400)
    }
}

struct GeneralSettingsTab: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Recent Sessions") {
                Stepper("Show \(settings.recentSessionsLimit) recent sessions", value: $settings.recentSessionsLimit, in: 1...20)
            }

            Section("Queue") {
                Toggle("Enable session queue", isOn: $settings.queueEnabled)
                Toggle("Enable priority queue", isOn: $settings.priorityQueueEnabled)
            }

            Section("Resources") {
                TextField("Storage location", text: $settings.resourceStorageLocation)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding()
    }
}

struct ConnectionSettingsTab: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var client: VoiceCodeClient
    @State private var testResult: ConnectionTestResult?

    var body: some View {
        Form {
            Section("Server") {
                TextField("Server address", text: $settings.serverAddress)
                    .textFieldStyle(.roundedBorder)
                TextField("Port", value: $settings.serverPort, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)

                Text("URL: \(settings.fullServerURL)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Authentication") {
                SecureField("API Key", text: $settings.apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            Section {
                HStack {
                    Button("Test Connection") {
                        testConnection()
                    }

                    if let result = testResult {
                        Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(result.success ? .green : .red)
                        Text(result.message)
                            .font(.caption)
                    }
                }
            }
        }
        .padding()
    }

    private func testConnection() {
        // ... test connection logic
    }
}

struct VoiceSettingsTab: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var voiceOutput: VoiceOutputManager

    var body: some View {
        Form {
            Section("Voice Selection") {
                Picker("Voice", selection: $settings.selectedVoice) {
                    Text("System Default").tag("system")
                    Text("All Premium Voices").tag("premium-rotation")
                    Divider()
                    ForEach(voiceOutput.availableVoices, id: \.identifier) { voice in
                        Text(voice.name).tag(voice.identifier)
                    }
                }

                Button("Preview Voice") {
                    voiceOutput.speak("This is a preview of the selected voice.", workingDirectory: nil)
                }
            }

            Section("Keyboard Shortcut") {
                HStack {
                    Text("Push-to-talk:")
                    Text("Option + Space")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                    // Future: Allow customization
                }
            }
        }
        .padding()
    }
}

struct AdvancedSettingsTab: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Message Size") {
                Stepper("Max size: \(settings.maxMessageSizeKB) KB", value: $settings.maxMessageSizeKB, in: 50...250, step: 10)
                Text("Large responses will be truncated")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("System Prompt") {
                TextEditor(text: $settings.systemPrompt)
                    .frame(minHeight: 100)
                    .font(.body)
                Text("Custom instructions appended to Claude's system prompt")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }
}

struct ConnectionTestResult {
    let success: Bool
    let message: String
}
#endif
```

---

### 5. Menu Bar Quick Access

**Problem:** Users want quick voice queries without opening the full app.

**Solution:** Menu bar extra with voice input and recent sessions.

#### Design

```
┌────────────────────────────────┐
│  📁 ~/projects/webapp      ▼  │  ← Last used directory (dropdown)
├────────────────────────────────┤
│                                │
│         🎤                     │  ← Click or Space to record
│   Click or press Space         │
│                                │
│  ─────────────────────────────│
│  Transcription appears here    │
│  [Send]              [Cancel]  │
│                                │
├────────────────────────────────┤
│  Recent Sessions               │
│    Session 1           2m ago  │
│    Session 2          15m ago  │
├────────────────────────────────┤
│  Open VoiceCode         ⌘O     │
│  Settings               ⌘,     │
│  Quit                   ⌘Q     │
└────────────────────────────────┘
```

#### Implementation

**File:** `ios/VoiceCode/MenuBarExtra.swift` (new file)

```swift
#if os(macOS)
import SwiftUI

struct VoiceCodeMenuBarExtra: Scene {
    @ObservedObject var client: VoiceCodeClient
    @ObservedObject var settings: AppSettings
    @ObservedObject var voiceInput: VoiceInputManager

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(client: client, settings: settings, voiceInput: voiceInput)
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
    @ObservedObject var voiceInput: VoiceInputManager

    @State private var selectedDirectory: String
    @State private var transcription: String = ""
    @State private var response: String?
    @State private var isProcessing = false

    init(client: VoiceCodeClient, settings: AppSettings, voiceInput: VoiceInputManager) {
        self.client = client
        self.settings = settings
        self.voiceInput = voiceInput
        self._selectedDirectory = State(initialValue: settings.lastUsedDirectory ?? "~")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Directory selector
            HStack {
                Image(systemName: "folder")
                Menu {
                    ForEach(settings.recentDirectories, id: \.self) { dir in
                        Button(dir) { selectedDirectory = dir }
                    }
                    Divider()
                    Button("Browse...") { browseDirectory() }
                } label: {
                    Text(selectedDirectory.components(separatedBy: "/").suffix(2).joined(separator: "/"))
                        .lineLimit(1)
                }
            }
            .padding()

            Divider()

            // Voice input area
            VStack(spacing: 12) {
                Button(action: toggleRecording) {
                    Image(systemName: voiceInput.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(voiceInput.isRecording ? .red : .accentColor)
                }
                .buttonStyle(.plain)

                Text(voiceInput.isRecording ? "Recording... (click to stop)" : "Click or press Space")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .onKeyPress(.space, phases: .down) { _ in
                toggleRecording()
                return .handled
            }

            // Transcription / Response area
            if !transcription.isEmpty || response != nil {
                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !transcription.isEmpty {
                            Text(transcription)
                                .padding(8)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(8)
                        }

                        if let response = response {
                            Text(response)
                                .padding(8)
                                .background(Color.green.opacity(0.1))
                                .cornerRadius(8)
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(maxHeight: 200)

                if !transcription.isEmpty && response == nil {
                    HStack {
                        Button("Send") { sendPrompt() }
                            .keyboardShortcut(.return, modifiers: [])
                        Button("Cancel") { clearTranscription() }
                            .keyboardShortcut(.escape, modifiers: [])
                    }
                    .padding()
                }
            }

            Divider()

            // Recent sessions
            VStack(alignment: .leading, spacing: 4) {
                Text("Recent Sessions")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)

                ForEach(client.recentSessions.prefix(3), id: \.sessionId) { session in
                    Button(action: { openSession(session) }) {
                        HStack {
                            Text(session.name ?? "Unnamed")
                                .lineLimit(1)
                            Spacer()
                            Text(session.relativeTimestamp)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
            }
            .padding(.vertical, 8)

            Divider()

            // Footer actions
            VStack(spacing: 0) {
                Button("Open VoiceCode") { openMainWindow() }
                    .keyboardShortcut("o", modifiers: [.command])
                Button("Settings...") { openSettings() }
                    .keyboardShortcut(",", modifiers: [.command])
                Divider()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q", modifiers: [.command])
            }
            .buttonStyle(.plain)
            .padding()
        }
        .frame(width: 300)
    }

    private func toggleRecording() {
        if voiceInput.isRecording {
            voiceInput.stopRecording()
            transcription = voiceInput.transcription
        } else {
            voiceInput.startRecording()
            response = nil
        }
    }

    private func sendPrompt() {
        isProcessing = true
        // Create new session in selectedDirectory and send prompt
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
        if panel.runModal() == .OK, let url = panel.url {
            selectedDirectory = url.path
        }
    }

    private func openSession(_ session: RecentSession) {
        // Open main window with this session selected
        NSWorkspace.shared.open(URL(string: "voicecode://session/\(session.sessionId)")!)
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // Open/focus main window
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
#endif
```

**Integration in VoiceCodeApp.swift:**

```swift
@main
struct VoiceCodeApp: App {
    var body: some Scene {
        WindowGroup {
            // ... main window
        }

        #if os(macOS)
        Settings {
            MacSettingsView()
        }

        VoiceCodeMenuBarExtra(client: client, settings: settings, voiceInput: voiceInput)
        #endif
    }
}
```

---

### 6. Information Density Adjustments

**Problem:** Desktop screens can display more information but the app uses mobile-sized spacing.

**Solution:** Platform-specific padding, font sizes, and truncation thresholds.

#### Implementation

**File:** `ios/VoiceCode/Utils/DesktopDensity.swift` (new file)

```swift
#if os(macOS)
import SwiftUI

struct DesktopDensity {
    // Spacing
    static let listRowVerticalPadding: CGFloat = 4
    static let listRowHorizontalPadding: CGFloat = 8
    static let sectionSpacing: CGFloat = 8

    // Typography
    static let bodyFont: Font = .system(size: 13)
    static let captionFont: Font = .system(size: 11)
    static let messageFont: Font = .system(size: 13)

    // Truncation
    static let messagePreviewLines: Int = 3
    static let messageTruncationThreshold: Int = 2000  // vs 500 on iOS

    // Sizing
    static let minRowHeight: CGFloat = 28
    static let iconSize: CGFloat = 14
}

extension View {
    @ViewBuilder
    func desktopDensity() -> some View {
        #if os(macOS)
        self
            .font(DesktopDensity.bodyFont)
        #else
        self
        #endif
    }

    @ViewBuilder
    func desktopListRow() -> some View {
        #if os(macOS)
        self
            .padding(.vertical, DesktopDensity.listRowVerticalPadding)
            .padding(.horizontal, DesktopDensity.listRowHorizontalPadding)
        #else
        self
        #endif
    }
}
#endif
```

**Usage in views:**

```swift
// SessionSidebarRow
var body: some View {
    HStack {
        // ... content
    }
    .desktopListRow()
    .desktopDensity()
}

// MessageView - adjust truncation
var displayText: String {
    #if os(macOS)
    let threshold = DesktopDensity.messageTruncationThreshold
    #else
    let threshold = 500
    #endif

    if text.count > threshold {
        return String(text.prefix(threshold / 2)) + "\n\n... [\(text.count - threshold) chars truncated] ...\n\n" + String(text.suffix(threshold / 2))
    }
    return text
}
```

---

### 7. Complete Keyboard Shortcut Map

**File:** `ios/VoiceCode/VoiceCodeApp.swift` (in `.commands {}`)

```swift
#if os(macOS)
.commands {
    // Edit menu additions
    CommandGroup(after: .textEditing) {
        Button("Stop Speaking") {
            voiceOutput.stop()
        }
        .keyboardShortcut(".", modifiers: [.command])

        Button(voiceOutput.isMuted ? "Unmute Voice" : "Mute Voice") {
            voiceOutput.isMuted.toggle()
        }
        .keyboardShortcut("m", modifiers: [.command, .shift])

        Divider()

        Button("Command Palette") {
            showCommandPalette = true
        }
        .keyboardShortcut("k", modifiers: [.command])
    }

    // View menu
    CommandGroup(after: .toolbar) {
        Button("Toggle Sidebar") {
            withAnimation {
                sidebarVisibility = sidebarVisibility == .all ? .detailOnly : .all
            }
        }
        .keyboardShortcut("0", modifiers: [.command])

        Button("Focus Sidebar") {
            focusSidebar()
        }
        .keyboardShortcut("1", modifiers: [.command])

        Button("Focus Conversation") {
            focusConversation()
        }
        .keyboardShortcut("2", modifiers: [.command])
    }

    // Session menu (new)
    CommandMenu("Session") {
        Button("New Session") {
            createNewSession()
        }
        .keyboardShortcut("n", modifiers: [.command])

        Button("Refresh Session") {
            refreshCurrentSession()
        }
        .keyboardShortcut("r", modifiers: [.command])

        Button("Compact Session") {
            compactCurrentSession()
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])

        Button("Session Info") {
            showSessionInfo()
        }
        .keyboardShortcut("i", modifiers: [.command])

        Divider()

        Button("Previous Session") {
            selectPreviousSession()
        }
        .keyboardShortcut("[", modifiers: [.command])

        Button("Next Session") {
            selectNextSession()
        }
        .keyboardShortcut("]", modifiers: [.command])
    }
}
#endif
```

#### Complete Shortcut Reference

| Shortcut | Action | Context |
|----------|--------|---------|
| Option+Space (hold) | Push-to-talk | Anywhere |
| ⌘Enter | Send prompt | Text input focused |
| Return | Send prompt | Text input focused, no newline |
| Shift+Return | Insert newline | Text input focused |
| ⌘. | Stop speaking | Anywhere |
| ⌘K | Command palette | Anywhere |
| ⌘N | New session | Anywhere |
| ⌘R | Refresh session | Conversation view |
| ⌘⇧C | Compact session | Conversation view |
| ⌘I | Session info | Conversation view |
| ⌘⇧M | Mute/unmute voice | Anywhere |
| ⌘0 | Toggle sidebar | Anywhere |
| ⌘1 | Focus sidebar | Anywhere |
| ⌘2 | Focus conversation | Anywhere |
| ⌘[ | Previous session | Anywhere |
| ⌘] | Next session | Anywhere |
| ⌘, | Open settings | Anywhere |
| ⌘W | Close window | Anywhere |
| Escape | Cancel/dismiss | Context-dependent |
| ↑/↓ | Navigate sidebar | Sidebar focused |

---

## Verification Strategy

### Testing Approach

#### Unit Tests

1. **SessionSidebarView data grouping** - Verify sessions group by directory correctly
2. **CommandPaletteView filtering** - Verify fuzzy search matches
3. **Push-to-talk modifier** - Verify key events handled correctly
4. **Settings tabs** - Verify bindings update settings

#### Integration Tests

1. **Navigation flow** - Sidebar selection updates detail view
2. **Command palette execution** - Actions trigger correctly
3. **Menu bar quick capture** - Voice → transcription → send → response
4. **Settings persistence** - Changes survive app restart

#### Manual Testing Checklist

| Feature | Test Case | Expected Result |
|---------|-----------|-----------------|
| Sidebar | Launch app | Sessions visible in sidebar |
| Sidebar | Click session | Conversation loads in detail |
| Sidebar | Cmd+0 | Sidebar toggles visibility |
| Push-to-talk | Hold Option+Space | Recording starts |
| Push-to-talk | Release Option+Space | Recording stops, transcription shows |
| Command palette | Cmd+K | Palette opens |
| Command palette | Type "new" | "New session" filtered to top |
| Command palette | Press Enter | Action executes, palette closes |
| Settings | Cmd+, | Settings window opens (not sheet) |
| Settings | Change voice | Setting persists |
| Menu bar | Click icon | Popover appears |
| Menu bar | Click mic | Recording starts |
| Menu bar | Send prompt | Response appears in popover |

### Acceptance Criteria

1. Sidebar persists while viewing conversation (NavigationSplitView)
2. Push-to-talk works with Option+Space anywhere in app
3. Command palette opens with Cmd+K and supports fuzzy search
4. Settings opens as separate window via Cmd+,
5. Menu bar icon shows connection status and enables quick voice capture
6. Information density is higher than iOS (smaller spacing, more visible content)
7. All keyboard shortcuts documented in menu items
8. iOS functionality remains unchanged (no regressions)
9. Session switching possible without losing conversation context
10. Voice input works seamlessly via both click and keyboard

## Alternatives Considered

### 1. Three-Column NavigationSplitView

**Approach:** Directories → Sessions → Conversation in three columns.

**Pros:**
- Full hierarchy visible at once
- Matches Finder/Mail three-pane layout

**Cons:**
- Excessive for typical usage (most users work in 1-2 directories)
- Wastes horizontal space
- More complex implementation

**Decision:** Rejected. Two-column with grouped sidebar is sufficient.

### 2. Global Hotkey for Voice (not just in-app)

**Approach:** System-wide hotkey that activates voice input even when app is backgrounded.

**Pros:**
- True hands-free access from any app
- Consistent with Raycast/Alfred patterns

**Cons:**
- Requires accessibility permissions
- More complex implementation
- May conflict with other apps

**Decision:** Deferred. Menu bar quick access covers the primary use case without system-wide hooks.

### 3. Wake Word Detection ("Hey Claude")

**Approach:** Always-listening mode with voice activation phrase.

**Pros:**
- True hands-free operation
- Familiar from Siri/Alexa

**Cons:**
- Battery/CPU intensive (continuous audio processing)
- Requires ML model for wake word
- Desktop context has audio conflicts (meetings, music)
- High false positive rate is frustrating

**Decision:** Rejected. Push-to-talk is more appropriate for desktop context.

### 4. Electron-Based Desktop App

**Approach:** Build desktop app with web technologies instead of native SwiftUI.

**Pros:**
- Faster iteration
- Same codebase as potential web version

**Cons:**
- Higher resource usage
- Doesn't feel native
- Loses SwiftUI integrations (Settings scene, menu bar extra, etc.)

**Decision:** Rejected. Native SwiftUI provides the best macOS experience.

## Risks & Mitigations

### 1. Risk: NavigationSplitView Complexity

**Risk:** Migrating from NavigationStack to NavigationSplitView may introduce navigation bugs.

**Mitigation:**
- Implement incrementally (sidebar first, then detail binding)
- Extensive testing of navigation edge cases
- Keep NavigationStack as fallback for iOS

### 2. Risk: Push-to-Talk Key Conflicts

**Risk:** Option+Space may conflict with other apps or accessibility features.

**Mitigation:**
- Make shortcut configurable in settings
- Test with common apps (browsers, IDEs, terminals)
- Document the shortcut and how to change it

### 3. Risk: Menu Bar Extra Resource Usage

**Risk:** Menu bar app running continuously may impact battery/performance.

**Mitigation:**
- Lazy initialization of voice components
- Only maintain WebSocket connection when main app is open
- Menu bar extra operates in "quick capture" mode with minimal state

### 4. Risk: Settings Migration

**Risk:** Existing users may lose settings when migrating from sheet to Settings scene.

**Mitigation:**
- Settings are already in UserDefaults (no migration needed)
- Settings scene reads same underlying storage
- Test upgrade path from current version

### Rollback Strategy

1. All macOS changes are behind `#if os(macOS)` guards
2. iOS code paths unchanged
3. Can ship iOS-only update while fixing macOS issues
4. Individual features can be disabled by commenting out commands/modifiers
5. No backend changes required

## Implementation Phases

### Phase 1: Navigation Foundation
- Replace NavigationStack with NavigationSplitView
- Implement SessionSidebarView
- Add sidebar toggle (Cmd+0)
- Estimated files: 4-5 new/modified

### Phase 2: Settings & Keyboard
- Convert Settings to Settings scene
- Add Session menu with shortcuts
- Implement all keyboard shortcuts
- Estimated files: 2-3 new/modified

### Phase 3: Push-to-Talk
- Implement PushToTalkModifier
- Add visual recording feedback
- Wire up transcription flow
- Estimated files: 2-3 modified

### Phase 4: Command Palette
- Implement CommandPaletteView
- Add Cmd+K shortcut
- Wire up action handlers
- Estimated files: 1-2 new

### Phase 5: Menu Bar Extra
- Implement MenuBarContentView
- Add VoiceCodeMenuBarExtra scene
- Quick capture flow
- Estimated files: 1-2 new

### Phase 6: Polish
- Information density adjustments
- Hover states
- Multi-window support (stretch goal)
- Estimated files: 3-4 modified

## Files Summary

### New Files

| File | Purpose |
|------|---------|
| `Views/SessionSidebarView.swift` | Sidebar navigation component |
| `Views/CommandPaletteView.swift` | Cmd+K command overlay |
| `Views/MacSettingsView.swift` | Tabbed settings for macOS |
| `MenuBarExtra.swift` | Menu bar quick access |
| `Utils/DesktopDensity.swift` | Platform-specific sizing constants |
| `Utils/PushToTalkModifier.swift` | Keyboard voice input |

### Modified Files

| File | Changes |
|------|---------|
| `VoiceCodeApp.swift` | Add NavigationSplitView, Settings scene, MenuBarExtra, .commands |
| `ConversationView.swift` | Add push-to-talk modifier, adjust for detail pane context |
| `VoiceCodeClient.swift` | Add `sendQuickPrompt()` for menu bar |
| `AppSettings.swift` | Add `lastUsedDirectory`, `recentDirectories` |

## Open Questions

1. **Push-to-talk shortcut** - Option+Space vs. other options. Need user testing.
2. **Menu bar always visible?** - Should it be optional in settings?
3. **Multi-window priority** - Include in Phase 6 or defer to future work?
4. **Transcription editing** - Should quick capture allow editing before send, or send immediately?
