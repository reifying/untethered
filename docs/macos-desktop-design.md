# macOS Desktop Design Document

## Executive Summary

This document outlines the design and implementation plan for adding a macOS desktop equivalent to the voice-code iOS app. The desktop version will share the Clojure backend while providing a native macOS experience with full voice I/O support (speech recognition + TTS), multi-window management, and desktop-class file system integration.

---

## Table of Contents

1. [Current Architecture](#current-architecture)
2. [Code Sharing Strategy](#code-sharing-strategy)
3. [macOS UX Adaptations](#macos-ux-adaptations)
4. [Repository Structure Changes](#repository-structure-changes)
5. [Shared Components](#shared-components)
6. [Platform-Specific Components](#platform-specific-components)
7. [Build System Changes](#build-system-changes)
8. [Implementation Phases](#implementation-phases)
9. [Technical Decisions](#technical-decisions)
10. [Risk Assessment](#risk-assessment)
11. [Feature Deep Dives](#feature-deep-dives)
    - Voice Features
    - Priority Queue System
    - Command Execution System
    - Resources/File Upload System
    - Session Management
    - Conversation View Details
    - AppSettings Configuration
    - Auto-Scroll Behavior
    - Legacy Queue System
    - Smart Speaking
    - Session Name Inference
12. [Testing Strategy for macOS](#testing-strategy-for-macos)
13. [Detailed WebSocket Protocol](#detailed-websocket-protocol)
14. [macOS-Specific Considerations](#macos-specific-considerations)

**Appendices:**
- [A: File Migration Checklist](#appendix-a-file-migration-checklist)
- [B: macOS Minimum Requirements](#appendix-b-macos-minimum-requirements)
- [C: References](#appendix-c-references)
- [D: iOS View Hierarchy Reference](#appendix-d-ios-view-hierarchy-reference)
- [E: CoreData Schema Details](#appendix-e-coredata-schema-details)
- [F: Backend Namespace Summary](#appendix-f-backend-namespace-summary)
- [G: Keyboard Shortcuts Implementation](#appendix-g-keyboard-shortcuts-implementation)
- [H: Estimated Code Distribution](#appendix-h-estimated-code-distribution)
- [I: Implementation Patterns (iOS Reference)](#appendix-i-implementation-patterns-ios-reference)
- [J: Specific macOS View Specifications](#appendix-j-specific-macos-view-specifications)
- [K: Edge Cases and Limits](#appendix-k-edge-cases-and-limits)
- [L: Threading and Concurrency Patterns](#appendix-l-threading-and-concurrency-patterns)
- [M: Debounce Coordination](#appendix-m-debounce-coordination)
- [N: Session Lock State Machine](#appendix-n-session-lock-state-machine)
- [O: Priority Queue Renormalization](#appendix-o-priority-queue-renormalization)
- [P: FetchRequest Safety Checklist](#appendix-p-fetchrequest-safety-checklist)
- [Q: UUID Case Sensitivity](#appendix-q-uuid-case-sensitivity)
- [R: Auto-Scroll Fix](#appendix-r-auto-scroll-fix)
- [S: Smart Speaking for macOS](#appendix-s-smart-speaking-for-macos)
- [T: Render Loop Detection](#appendix-t-render-loop-detection)
- [U: First-Run Onboarding](#appendix-u-first-run-onboarding)
- [V: Backend Connection State Machine](#appendix-v-backend-connection-state-machine)
- [W: WebSocket Message Handling](#appendix-w-websocket-message-handling)
- [X: Voice Hash Stability Note](#appendix-x-voice-hash-stability-note)
- [Y: Global Hotkey for Voice Input](#appendix-y-global-hotkey-for-voice-input)
- [Z: Error Recovery Patterns](#appendix-z-error-recovery-patterns)
- [AA: CoreData Schema Migration](#appendix-aa-coredata-schema-migration)
- [AB: State Persistence](#appendix-ab-state-persistence)
- [AC: Dark Mode Support](#appendix-ac-dark-mode-support)
- [AD: Edge Case Clarifications](#appendix-ad-edge-case-clarifications)

---

## 1. Current Architecture

### Overview

The voice-code system consists of three layers:

```
┌─────────────────────────────────────────────────────────────┐
│                    iOS App (SwiftUI)                        │
│  - 41 Swift files (~10K LOC)                               │
│  - CoreData persistence                                     │
│  - Voice I/O (Speech Recognition + TTS)                    │
│  - WebSocket client                                         │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ WebSocket (JSON, snake_case)
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                 Clojure Backend Server                      │
│  - 7 namespaces (~3.6K LOC)                                │
│  - http-kit WebSocket server                               │
│  - Session management                                       │
│  - Filesystem watching                                      │
│  - Command execution                                        │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ Subprocess
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      Claude CLI                             │
│  - ~/.claude/projects/<project>/<session>.jsonl            │
└─────────────────────────────────────────────────────────────┘
```

### iOS App Components

#### Managers (Business Logic)
| File | Lines | iOS-Specific | Shareable |
|------|-------|--------------|-----------|
| VoiceCodeClient.swift | 1142 | UIKit imports | 90% (WebSocket logic) |
| SessionSyncManager.swift | 826 | None | 100% |
| AppSettings.swift | 377 | AVFoundation | 70% (core settings) |
| VoiceOutputManager.swift | 220 | AVFoundation | 60% (core logic shareable, audio session differs) |
| VoiceInputManager.swift | 138 | Speech framework | 70% (SFSpeechRecognizer works on both) |
| ResourcesManager.swift | 331 | App Groups | 80% (file handling differs) |
| PersistenceController.swift | 152 | None | 100% |
| NotificationManager.swift | 217 | UserNotifications | 50% (macOS uses different APIs) |
| DraftManager.swift | 52 | None | 100% |
| LogManager.swift | 130 | None | 100% |
| ActiveSessionManager.swift | 35 | None | 100% |
| DeviceAudioSessionManager.swift | 38 | AVAudioSession | 0% (iOS-only) |

#### Models (Data Structures)
| File | Lines | iOS-Specific | Shareable |
|------|-------|--------------|-----------|
| CDBackendSession.swift | 110 | None | 100% |
| CDBackendSession+PriorityQueue.swift | 242 | None | 100% |
| CDMessage.swift | 188 | None | 100% |
| CDUserSession.swift | 30 | None | 100% |
| Command.swift | 258 | None | 100% |
| Message.swift | 46 | None | 100% |
| RecentSession.swift | 61 | None | 100% |
| Resource.swift | 53 | None | 100% |

#### Views (UI)
| File | Lines | iOS-Specific | macOS Adaptation |
|------|-------|--------------|------------------|
| VoiceCodeApp.swift | 162 | WindowGroup | Multi-window support |
| ConversationView.swift | 1214 | UIKit haptics | Keyboard shortcuts |
| DirectoryListView.swift | 879 | UIKit clipboard | Sidebar layout |
| SessionsForDirectoryView.swift | 390 | None | List with detail pane |
| SessionsView.swift | 120 | None | Sidebar section |
| SessionLookupView.swift | 98 | None | Navigation helper |
| SettingsView.swift | 252 | iOS Form style | macOS Settings window |
| CommandExecutionView.swift | 290 | None | Terminal-style output |
| CommandMenuView.swift | 225 | None | Menu bar integration |
| CommandHistoryView.swift | 132 | None | Table view |
| CommandOutputDetailView.swift | 229 | None | Resizable panel |
| ResourcesView.swift | 203 | None | Drag-and-drop |
| ResourceShareView.swift | 193 | None | Share sheet |
| ResourceSessionPickerView.swift | 44 | None | Picker dialog |
| SessionInfoView.swift | 296 | None | Inspector panel |
| DebugLogsView.swift | 219 | None | Console-style view |

### Backend (Unchanged)

The Clojure backend requires **no modifications** for macOS support. It:
- Serves WebSocket connections from any client
- Manages Claude CLI sessions
- Watches filesystem for changes
- Executes shell commands

---

## 2. Code Sharing Strategy

### Recommended Approach: Shared Swift Package

Create a shared Swift Package for platform-agnostic code:

```
voice-code/
├── Shared/                          # NEW: Swift Package
│   ├── Package.swift
│   └── Sources/
│       └── VoiceCodeShared/
│           ├── Models/              # All model files
│           ├── Managers/            # Platform-agnostic managers
│           ├── Networking/          # WebSocket client (refactored)
│           └── Utilities/           # Text processing, etc.
├── ios/                             # iOS app
│   └── VoiceCode/
│       ├── Views/                   # iOS-specific views
│       ├── Managers/                # iOS-specific managers
│       └── VoiceCodeApp.swift
├── macos/                           # NEW: macOS app
│   └── VoiceCodeDesktop/
│       ├── Views/                   # macOS-specific views
│       ├── Managers/                # macOS-specific managers
│       └── VoiceCodeDesktopApp.swift
└── backend/                         # Unchanged
```

### Code Classification

#### Fully Shareable (Move to Shared Package)

```swift
// Models - 100% shareable
CDBackendSession.swift
CDBackendSession+PriorityQueue.swift
CDMessage.swift
CDUserSession.swift
Command.swift
Message.swift
RecentSession.swift
Resource.swift

// Managers - Require refactoring to remove UIKit
SessionSyncManager.swift          // Remove UIKit import
DraftManager.swift                // Already platform-agnostic
LogManager.swift                  // Already platform-agnostic
ActiveSessionManager.swift        // Already platform-agnostic
PersistenceController.swift       // Already platform-agnostic

// Utilities
TextProcessor.swift               // Already platform-agnostic
CommandSorter.swift               // Already platform-agnostic
GitBranchDetector.swift           // Already platform-agnostic
RenderTracker.swift               // Already platform-agnostic
```

#### Requires Abstraction (Protocol + Platform Implementations)

```swift
// VoiceCodeClient.swift
// Issue: Uses UIKit for lifecycle notifications
// Solution: Extract protocol, platform-specific implementations

protocol VoiceCodeClientProtocol: ObservableObject {
    var isConnected: Bool { get }
    var lockedSessions: Set<String> { get }
    var availableCommands: AvailableCommands? { get }
    // ... other published properties

    func connect(sessionId: String?)
    func disconnect()
    func sendPrompt(_ text: String, iosSessionId: String, sessionId: String?, ...)
    func subscribe(sessionId: String)
    func unsubscribe(sessionId: String)
    // ... other methods
}

// Shared implementation handles WebSocket logic
// Platform-specific subclasses handle lifecycle observers
```

```swift
// AppSettings.swift
// Issue: AVFoundation voice APIs, App Group container
// Solution: Platform-specific settings managers

protocol AppSettingsProtocol: ObservableObject {
    var serverURL: String { get set }
    var serverPort: String { get set }
    var fullServerURL: String { get }
    var isServerConfigured: Bool { get }
    var systemPrompt: String { get set }
    // ... shared settings
}

// Voice settings are platform-specific
// macOS uses NSSpeechSynthesizer or AVSpeechSynthesizer differently
```

#### Platform-Specific (Separate Implementations)

| Component | iOS | macOS |
|-----------|-----|-------|
| VoiceOutputManager | AVSpeechSynthesizer + AVAudioSession | AVSpeechSynthesizer (no audio session) |
| VoiceInputManager | SFSpeechRecognizer + AVAudioEngine | SFSpeechRecognizer + AVAudioEngine |
| DeviceAudioSessionManager | AVAudioSession | Not needed |
| NotificationManager | UserNotifications | NSUserNotificationCenter / UNUserNotificationCenter |
| ResourcesManager | App Groups | Standard file system |
| Lifecycle Observers | UIApplication notifications | NSApplication notifications |

---

## 3. macOS UX Adaptations

### Navigation Model

**iOS (Current):**
```
NavigationStack
├── DirectoryListView (root)
│   ├── SessionsForDirectoryView
│   │   └── ConversationView
│   └── ResourcesView
└── SettingsView (sheet)
```

**macOS (Proposed):**
```
Window(s)
├── Main Window (NavigationSplitView)
│   ├── Sidebar: Projects/Sessions list
│   ├── Content: Session list for selected project
│   └── Detail: Conversation view
├── Command Output Window(s) - detachable
├── Settings Window (Preferences)
└── Quick Entry Window (optional, floating)
```

### Key UX Differences

| Feature | iOS | macOS |
|---------|-----|-------|
| Navigation | Stack-based, sequential | Split view, multi-pane |
| Input | Voice + touch | Voice + keyboard/mouse |
| Windows | Single window | Multiple windows |
| Settings | Sheet overlay | Preferences window (⌘,) |
| Copy/Paste | Long-press menu | ⌘C/⌘V |
| Quick Actions | Swipe gestures | Right-click context menu |
| Search | Pull-down search | ⌘F, toolbar search |
| Session Switching | Navigation stack | Sidebar click, ⌘1-9 |

### Keyboard Shortcuts (macOS)

| Shortcut | Action |
|----------|--------|
| ⌘N | New session |
| ⌘W | Close window |
| ⌘, | Preferences |
| ⌘K | Clear conversation |
| ⌘⏎ | Send message |
| ⌘⇧C | Compact session |
| ⌘R | Refresh session |
| ⌘1-9 | Switch to session 1-9 |
| ⌘[ / ⌘] | Previous/Next session |
| ⌃⌘F | Toggle fullscreen |
| ⌘F | Search in conversation |

### Menu Bar Integration

```
File
├── New Session (⌘N)
├── New Window (⌘⇧N)
├── Close Window (⌘W)
└── Close Session

Edit
├── Copy (⌘C)
├── Paste (⌘V)
├── Select All (⌘A)
└── Find... (⌘F)

Session
├── Send Message (⌘⏎)
├── Refresh (⌘R)
├── Compact (⌘⇧C)
├── Kill Process
└── Session Info (⌘I)

View
├── Show Sidebar (⌘⇧S)
├── Show Queue (⌘⇧Q)
├── Show Priority Queue (⌘⇧P)
└── Toggle Command Output

Window
├── Minimize (⌘M)
├── Zoom
└── [Window list]

Help
└── Voice Code Help
```

### Visual Design Differences

| Aspect | iOS | macOS |
|--------|-----|-------|
| Touch targets | 44pt minimum | Smaller, precise |
| Typography | iOS system fonts | macOS system fonts |
| Colors | iOS semantic colors | macOS semantic colors |
| Toolbars | Navigation bar | Window toolbar |
| Lists | Full-width cells | Table with columns |
| Spacing | Touch-friendly | Denser |
| Scrollbars | Hidden, gesture | Visible, standard |

### Window Types

1. **Main Window** - Primary three-column interface
   - Sidebar: Projects and sessions
   - Content: Session list with search
   - Detail: Conversation view

2. **Conversation Window** - Detached conversation (optional)
   - Can pop out conversations to separate windows
   - Useful for multi-monitor setups

3. **Command Output Window** - Terminal-like output
   - Streaming command execution results
   - Can be kept visible while working

4. **Preferences Window** - Standard macOS preferences
   - Server configuration
   - Voice settings (if retained)
   - Keyboard shortcuts
   - Appearance options

5. **Quick Entry Panel** (optional) - Floating panel
   - Global hotkey activation
   - Quick prompt entry without switching to main window

---

## 4. Repository Structure Changes

### Proposed Directory Layout

```
voice-code-desktop2/
├── Shared/                              # NEW: Swift Package
│   ├── Package.swift
│   ├── Sources/
│   │   └── VoiceCodeShared/
│   │       ├── Models/
│   │       │   ├── CDBackendSession.swift
│   │       │   ├── CDBackendSession+PriorityQueue.swift
│   │       │   ├── CDMessage.swift
│   │       │   ├── CDUserSession.swift
│   │       │   ├── Command.swift
│   │       │   ├── Message.swift
│   │       │   ├── RecentSession.swift
│   │       │   └── Resource.swift
│   │       ├── Managers/
│   │       │   ├── VoiceCodeClientCore.swift    # Platform-agnostic WebSocket
│   │       │   ├── SessionSyncManager.swift
│   │       │   ├── DraftManager.swift
│   │       │   ├── LogManager.swift
│   │       │   ├── ActiveSessionManager.swift
│   │       │   └── PersistenceController.swift
│   │       ├── Networking/
│   │       │   ├── WebSocketManager.swift       # Extracted from VoiceCodeClient
│   │       │   └── MessageProtocol.swift
│   │       ├── CoreData/
│   │       │   └── VoiceCode.xcdatamodeld       # Shared CoreData model
│   │       └── Utilities/
│   │           ├── TextProcessor.swift
│   │           ├── CommandSorter.swift
│   │           └── DateFormatters.swift
│   └── Tests/
│       └── VoiceCodeSharedTests/
│
├── ios/                                  # MODIFIED: Uses Shared package
│   ├── VoiceCode/
│   │   ├── App/
│   │   │   └── VoiceCodeApp.swift
│   │   ├── Views/                        # iOS-specific views (unchanged)
│   │   │   ├── ConversationView.swift
│   │   │   ├── DirectoryListView.swift
│   │   │   └── ...
│   │   ├── Managers/                     # iOS-specific managers
│   │   │   ├── VoiceCodeClient+iOS.swift # iOS lifecycle extensions
│   │   │   ├── VoiceOutputManager.swift
│   │   │   ├── VoiceInputManager.swift
│   │   │   ├── AppSettings+iOS.swift
│   │   │   ├── NotificationManager+iOS.swift
│   │   │   └── DeviceAudioSessionManager.swift
│   │   └── Resources/
│   │       └── Assets.xcassets
│   ├── VoiceCodeTests/
│   ├── VoiceCodeShareExtension/
│   └── project.yml
│
├── macos/                                # NEW: macOS app
│   ├── VoiceCodeDesktop/
│   │   ├── App/
│   │   │   └── VoiceCodeDesktopApp.swift
│   │   ├── Views/
│   │   │   ├── MainWindow/
│   │   │   │   ├── MainWindowView.swift
│   │   │   │   ├── SidebarView.swift
│   │   │   │   ├── SessionListView.swift
│   │   │   │   └── ConversationDetailView.swift
│   │   │   ├── Settings/
│   │   │   │   └── SettingsView.swift
│   │   │   ├── Commands/
│   │   │   │   ├── CommandOutputWindow.swift
│   │   │   │   └── CommandMenuView.swift
│   │   │   └── Components/
│   │   │       ├── MessageRow.swift
│   │   │       ├── SessionRow.swift
│   │   │       └── StatusBar.swift
│   │   ├── Managers/
│   │   │   ├── VoiceCodeClient+macOS.swift
│   │   │   ├── AppSettings+macOS.swift
│   │   │   ├── NotificationManager+macOS.swift
│   │   │   └── KeyboardShortcutManager.swift
│   │   ├── Commands/
│   │   │   └── AppCommands.swift         # Menu bar commands
│   │   └── Resources/
│   │       ├── Assets.xcassets
│   │       └── VoiceCodeDesktop.entitlements
│   ├── VoiceCodeDesktopTests/
│   └── project.yml
│
├── backend/                              # UNCHANGED
│   └── ...
│
├── docs/
│   ├── macos-desktop-design.md          # This document
│   ├── ios-navigation-architecture.md
│   └── ...
│
├── Makefile                              # Updated with macOS targets
├── CLAUDE.md
├── STANDARDS.md
└── README.md
```

---

## 5. Shared Components

### Swift Package Definition

```swift
// Shared/Package.swift
// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "VoiceCodeShared",
    platforms: [
        .iOS(.v18),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "VoiceCodeShared",
            targets: ["VoiceCodeShared"]
        ),
    ],
    targets: [
        .target(
            name: "VoiceCodeShared",
            resources: [
                .process("CoreData/VoiceCode.xcdatamodeld")
            ]
        ),
        .testTarget(
            name: "VoiceCodeSharedTests",
            dependencies: ["VoiceCodeShared"]
        ),
    ]
)
```

### Shared CoreData Model

The CoreData model (`VoiceCode.xcdatamodeld`) is already platform-agnostic and can be shared:

**Entities:**
- `CDBackendSession` - Claude session metadata
- `CDMessage` - Conversation messages
- `CDUserSession` - User customizations (names, deleted flags)

**Relationships:**
- `CDBackendSession` → `CDMessage` (one-to-many)

### Shared Networking Layer

Extract WebSocket handling from `VoiceCodeClient`:

```swift
// VoiceCodeShared/Networking/WebSocketManager.swift

import Foundation

/// Platform-agnostic WebSocket management
class WebSocketManager: NSObject {
    private var webSocket: URLSessionWebSocketTask?
    private var reconnectionTimer: DispatchSourceTimer?

    var onMessage: ((String) -> Void)?
    var onConnect: (() -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    func connect(url: URL) { ... }
    func disconnect() { ... }
    func send(_ message: [String: Any]) { ... }
}
```

```swift
// VoiceCodeShared/Managers/VoiceCodeClientCore.swift

import Foundation
import Combine

/// Available commands from backend for current working directory
struct AvailableCommands {
    let workingDirectory: String
    let projectCommands: [CommandItem]   // Makefile targets
    let generalCommands: [CommandItem]   // Always-available commands like git.status
}

struct CommandItem: Identifiable {
    let id: String           // e.g., "git.status", "docker.up", "build"
    let label: String        // e.g., "Git Status", "Up", "Build"
    let type: String         // "command" or "group"
    var children: [CommandItem]?  // For groups only
}

/// Core client logic shared between iOS and macOS
open class VoiceCodeClientCore: ObservableObject {
    @Published public var isConnected = false
    @Published public var lockedSessions = Set<String>()
    @Published public var availableCommands: AvailableCommands?
    // ... other published properties

    private let webSocketManager: WebSocketManager
    public let sessionSyncManager: SessionSyncManager

    // Subclasses override to add platform-specific lifecycle handling
    open func setupLifecycleObservers() { }

    // Message handling is shared
    internal func handleMessage(_ text: String) { ... }

    // Public API
    public func sendPrompt(_ text: String, ...) { ... }
    public func subscribe(sessionId: String) { ... }
}
```

---

## 6. Platform-Specific Components

### iOS-Specific

```swift
// ios/VoiceCode/Managers/VoiceCodeClient+iOS.swift

import UIKit

class VoiceCodeClient: VoiceCodeClientCore {
    override func setupLifecycleObservers() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleAppForeground()
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleAppBackground()
        }
    }
}
```

### macOS-Specific

```swift
// macos/VoiceCodeDesktop/Managers/VoiceCodeClient+macOS.swift

import AppKit

class VoiceCodeClient: VoiceCodeClientCore {
    override func setupLifecycleObservers() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleAppActive()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleAppResignActive()
        }
    }
}
```

### macOS Main Window

```swift
// macos/VoiceCodeDesktop/Views/MainWindow/MainWindowView.swift

import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var client: VoiceCodeClient
    @EnvironmentObject var settings: AppSettings
    @State private var selectedProject: String?
    @State private var selectedSession: UUID?

    var body: some View {
        NavigationSplitView {
            // Sidebar: Projects
            SidebarView(
                selectedProject: $selectedProject,
                client: client
            )
        } content: {
            // Content: Sessions for selected project
            if let project = selectedProject {
                SessionListView(
                    workingDirectory: project,
                    selectedSession: $selectedSession,
                    client: client
                )
            } else {
                Text("Select a project")
                    .foregroundColor(.secondary)
            }
        } detail: {
            // Detail: Conversation
            if let sessionId = selectedSession {
                ConversationDetailView(
                    sessionId: sessionId,
                    client: client,
                    settings: settings
                )
            } else {
                Text("Select a session")
                    .foregroundColor(.secondary)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: { /* new session */ }) {
                    Label("New Session", systemImage: "plus")
                }
                Button(action: { /* refresh */ }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }
}
```

### macOS App Entry Point

```swift
// macos/VoiceCodeDesktop/App/VoiceCodeDesktopApp.swift

import SwiftUI

@main
struct VoiceCodeDesktopApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var client: VoiceCodeClient

    init() {
        let settings = AppSettings()
        let client = VoiceCodeClient(serverURL: settings.fullServerURL)
        _settings = StateObject(wrappedValue: settings)
        _client = StateObject(wrappedValue: client)
    }

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environmentObject(client)
                .environmentObject(settings)
                .environment(\.managedObjectContext,
                    PersistenceController.shared.container.viewContext)
        }
        .commands {
            AppCommands(client: client, settings: settings)
        }

        Settings {
            SettingsView(settings: settings, client: client)
        }

        // Optional: Command output window type
        WindowGroup("Command Output", for: String.self) { $commandSessionId in
            if let id = commandSessionId {
                CommandOutputWindow(commandSessionId: id, client: client)
            }
        }
    }
}
```

### macOS Menu Commands

```swift
// macos/VoiceCodeDesktop/Commands/AppCommands.swift

import SwiftUI

struct AppCommands: Commands {
    @ObservedObject var client: VoiceCodeClient
    @ObservedObject var settings: AppSettings

    var body: some Commands {
        // Replace default New Document command
        CommandGroup(replacing: .newItem) {
            Button("New Session") {
                // Create new session
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        // Session menu
        CommandMenu("Session") {
            Button("Send Message") {
                // Focus input and send
            }
            .keyboardShortcut(.return, modifiers: .command)

            Divider()

            Button("Refresh") {
                // Refresh current session
            }
            .keyboardShortcut("r", modifiers: .command)

            Button("Compact") {
                // Compact current session
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Divider()

            Button("Session Info") {
                // Show session info
            }
            .keyboardShortcut("i", modifiers: .command)
        }

        // View menu additions
        CommandGroup(after: .sidebar) {
            Button("Show Queue") {
                // Toggle queue visibility
            }
            .keyboardShortcut("q", modifiers: [.command, .shift])

            Button("Show Priority Queue") {
                // Toggle priority queue
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }
}
```

---

## 7. Build System Changes

### Updated Makefile

```makefile
# Add to existing Makefile

# macOS Configuration
MACOS_SCHEME := VoiceCodeDesktop
MACOS_DIR := macos
MACOS_DESTINATION := 'platform=macOS'

.PHONY: macos-generate macos-build macos-test macos-run macos-clean

# macOS targets
macos-help:
	@echo "macOS targets:"
	@echo "  macos-generate  - Generate Xcode project from project.yml"
	@echo "  macos-build     - Build macOS app"
	@echo "  macos-test      - Run macOS tests"
	@echo "  macos-run       - Build and run macOS app"
	@echo "  macos-clean     - Clean macOS build artifacts"
	@echo "  macos-archive   - Create macOS archive"

macos-generate:
	@echo "Generating macOS Xcode project..."
	cd $(MACOS_DIR) && xcodegen generate
	@echo "✅ macOS project generated"

macos-build: macos-generate
	$(WRAP) bash -c "cd $(MACOS_DIR) && xcodebuild build \
		-scheme $(MACOS_SCHEME) \
		-destination $(MACOS_DESTINATION)"

macos-test: macos-generate
	$(WRAP) bash -c "cd $(MACOS_DIR) && xcodebuild test \
		-scheme $(MACOS_SCHEME) \
		-destination $(MACOS_DESTINATION)"

macos-run: macos-generate
	$(WRAP) bash -c "cd $(MACOS_DIR) && xcodebuild build \
		-scheme $(MACOS_SCHEME) \
		-destination $(MACOS_DESTINATION) && \
		open build/Build/Products/Debug/VoiceCodeDesktop.app"

macos-clean:
	cd $(MACOS_DIR) && xcodebuild clean -scheme $(MACOS_SCHEME)
	rm -rf ~/Library/Developer/Xcode/DerivedData/VoiceCodeDesktop-*

# Combined targets
all-generate: generate-project macos-generate
all-build: build macos-build
all-test: test macos-test
all-clean: clean macos-clean
```

### macOS project.yml

```yaml
# macos/project.yml
name: VoiceCodeDesktop

options:
  bundleIdPrefix: dev.910labs
  deploymentTarget:
    macOS: "14.0"
  developmentLanguage: en
  createIntermediateGroups: true

settings:
  base:
    DEVELOPMENT_TEAM: REDACTED_TEAM_ID_2
    CODE_SIGN_STYLE: Automatic
    MARKETING_VERSION: "1.0"
    CURRENT_PROJECT_VERSION: 1
    MACOSX_DEPLOYMENT_TARGET: "14.0"

packages:
  VoiceCodeShared:
    path: ../Shared

targets:
  VoiceCodeDesktop:
    type: application
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - path: VoiceCodeDesktop
        excludes:
          - "*.md"
    dependencies:
      - package: VoiceCodeShared
    info:
      path: VoiceCodeDesktop/Info.plist
      properties:
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        CFBundleDisplayName: Voice Code
        CFBundleIconName: AppIcon
        LSMinimumSystemVersion: $(MACOSX_DEPLOYMENT_TARGET)
        # NSLocalNetworkUsageDescription only needed if using Bonjour/mDNS discovery
        # For direct IP/hostname connections, this can be omitted
        # NSLocalNetworkUsageDescription: Voice Code needs to discover backend servers on your local network.
        NSSpeechRecognitionUsageDescription: Voice Code uses speech recognition for voice input.
        NSMicrophoneUsageDescription: Voice Code uses the microphone for voice input.
    entitlements:
      path: VoiceCodeDesktop/VoiceCodeDesktop.entitlements
      properties:
        com.apple.security.app-sandbox: true
        com.apple.security.network.client: true
        com.apple.security.files.user-selected.read-write: true
        com.apple.security.device.microphone: true
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.910labs.voice-code-desktop
        INFOPLIST_FILE: VoiceCodeDesktop/Info.plist

  VoiceCodeDesktopTests:
    type: bundle.unit-test
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - VoiceCodeDesktopTests
    dependencies:
      - target: VoiceCodeDesktop

schemes:
  VoiceCodeDesktop:
    build:
      targets:
        VoiceCodeDesktop: all
    run:
      config: Debug
    test:
      config: Debug
      targets:
        - name: VoiceCodeDesktopTests
    profile:
      config: Release
    archive:
      config: Release
```

---

## 8. Implementation Phases

### Phase 1: Foundation (Shared Package)

**Goal:** Extract shareable code into Swift Package without breaking iOS

**Tasks:**
1. Create `Shared/` directory with Package.swift
2. Move model files to Shared package
3. Move platform-agnostic managers to Shared package
4. Extract WebSocket logic from VoiceCodeClient
5. Update iOS project to use Shared package
6. Ensure all iOS tests pass

**Critical References:**
- See [Appendix L](#appendix-l-threading-and-concurrency-patterns) for CoreData threading patterns
- See [Appendix L.3](#l3-swift-package-coredata-bundle) for Bundle.module setup
- See [Appendix Q](#appendix-q-uuid-case-sensitivity) for UUID handling

**Deliverables:**
- Working Shared Swift Package
- iOS app using Shared package
- All existing iOS tests passing

### Phase 2: macOS Skeleton

**Goal:** Basic macOS app that connects to backend

**Tasks:**
1. Create `macos/` directory structure
2. Create project.yml for macOS
3. Implement minimal VoiceCodeDesktopApp
4. Implement macOS-specific VoiceCodeClient extension
5. Implement basic MainWindowView with NavigationSplitView
6. Connect to backend and display session list
7. **Implement first-run onboarding flow**

**Critical References:**
- See [Appendix U](#appendix-u-first-run-onboarding) for onboarding flow design
- See [Appendix V](#appendix-v-backend-connection-state-machine) for connection handling

**Deliverables:**
- macOS app that builds and runs
- Connects to backend successfully
- Displays session list in sidebar
- First-run experience guides user to configure server

### Phase 3: Core Functionality

**Goal:** Feature parity for conversation viewing and sending

**Tasks:**
1. Implement ConversationDetailView for macOS
2. Implement message input with ⌘⏎ to send
3. Implement session locking UI
4. Implement session creation
5. Implement session refresh/compact
6. Implement keyboard shortcuts
7. Implement auto-scroll with captured message ID

**Critical References:**
- See [Appendix N](#appendix-n-session-lock-state-machine) for lock state management
- See [Appendix P](#appendix-p-fetchrequest-safety-checklist) for FetchRequest patterns
- See [Appendix R](#appendix-r-auto-scroll-fix) for auto-scroll implementation
- See [Appendix M](#appendix-m-debounce-coordination) for debounce patterns

**Deliverables:**
- Can view conversations
- Can send messages
- Can create new sessions
- Basic keyboard shortcuts working

### Phase 4: Advanced Features

**Goal:** Complete feature parity with iOS

**Tasks:**
1. Implement command execution views
2. Implement command history
3. Implement priority queue with renormalization
4. Implement resources management (drag-and-drop)
5. Implement settings/preferences
6. Implement notifications (optional)
7. Implement smart speaking with window focus tracking

**Critical References:**
- See [Appendix O](#appendix-o-priority-queue-renormalization) for queue renormalization
- See [Appendix S](#appendix-s-smart-speaking-for-macos) for window-based speaking
- See [Appendix W](#appendix-w-websocket-message-handling) for message type handling

**Deliverables:**
- All iOS features available on macOS
- macOS-specific UX polish

### Phase 5: macOS Polish

**Goal:** Native macOS experience

**Tasks:**
1. Menu bar polish and completeness
2. Multi-window support
3. Drag and drop for files
4. Full keyboard navigation
5. Global hotkey for voice input
6. Spotlight/Finder integration (optional)
7. Touch Bar support (optional)
8. Performance optimization

**Critical References:**
- See [Appendix Y](#appendix-y-global-hotkey-for-voice-input) for global hotkey implementation
- See [Appendix Z](#appendix-z-error-recovery-patterns) for error recovery
- See [Appendix T](#appendix-t-render-loop-detection) for performance monitoring

**Deliverables:**
- Production-ready macOS app
- App Store submission ready

---

## 9. Technical Decisions

### Decision: Voice I/O on macOS

**Options:**
1. **Full voice support** - Implement speech recognition and TTS for macOS
2. **TTS only** - Keep text-to-speech, skip speech recognition
3. **No voice** - Keyboard-only interface

**Recommendation:** Option 1 (Full voice support)

**Rationale:**
- Feature parity with iOS is required
- Voice input is a core differentiator of the app
- `SFSpeechRecognizer` is available on macOS 10.15+
- Both platforms should be equally speech-focused
- Users dictating prompts benefit from hands-free workflow

### Decision: Shared Package vs Conditional Compilation

**Options:**
1. **Swift Package** - Separate package with shared code
2. **Conditional compilation** - `#if os(iOS)` / `#if os(macOS)` in same files
3. **Copy code** - Duplicate shared code in both projects

**Recommendation:** Option 1 (Swift Package)

**Rationale:**
- Cleaner separation of concerns
- Easier to test shared code independently
- Reduces risk of platform-specific bugs in shared code
- Industry standard approach for multi-platform apps

### Decision: Window Management

**Options:**
1. **Single window** - Three-column split view only
2. **Multi-window** - Allow multiple conversation windows
3. **Hybrid** - Main window + optional detached windows

**Recommendation:** Option 3 (Hybrid)

**Rationale:**
- Single main window covers most use cases
- Option to detach conversations for multi-monitor users
- Follows macOS conventions (Safari, Mail, etc.)

### Decision: Settings Storage

**Options:**
1. **UserDefaults only** - Same as iOS
2. **Defaults + files** - UserDefaults for simple settings, files for complex
3. **File-based** - JSON/plist file in Application Support

**Recommendation:** Option 1 (UserDefaults only)

**Rationale:**
- Consistency with iOS
- Automatic iCloud sync (if enabled)
- Simple implementation
- Sufficient for current settings complexity

---

## 10. Risk Assessment

### High Risk

| Risk | Impact | Mitigation | Reference |
|------|--------|------------|-----------|
| CoreData schema divergence | Data corruption | Single shared schema in Shared package | [Appendix L](#appendix-l-threading-and-concurrency-patterns) |
| WebSocket protocol changes | Both platforms break | Protocol tests in Shared package | [Appendix W](#appendix-w-websocket-message-handling) |
| Breaking iOS during refactor | App Store issues | Incremental changes with CI testing | Phase 1 |
| CoreData threading violations | Crashes, data loss | Follow background context patterns | [Appendix L.1](#l1-coredata-background-context-threading) |
| Session lock state machine bugs | Stuck UI, user frustration | Complete unlock trigger coverage | [Appendix N](#appendix-n-session-lock-state-machine) |
| FetchRequest animation storms | Performance issues, battery drain | Always use animation: nil | [Appendix P](#appendix-p-fetchrequest-safety-checklist) |

### Medium Risk

| Risk | Impact | Mitigation | Reference |
|------|--------|------------|-----------|
| macOS-specific SwiftUI issues | UI bugs | Early testing on multiple macOS versions | - |
| Performance differences | Poor UX | Profile on older Macs | - |
| Keyboard focus management | Accessibility issues | Test with keyboard-only navigation | - |
| Priority queue precision loss | Incorrect ordering | Implement renormalization | [Appendix O](#appendix-o-priority-queue-renormalization) |
| Debounce coordination errors | Stale UI state | Follow flush checklist | [Appendix M](#appendix-m-debounce-coordination) |
| UUID case mismatch | Session not found errors | Use lowercasedString extension | [Appendix Q](#appendix-q-uuid-case-sensitivity) |
| First-run confusion | User abandonment | Implement onboarding flow | [Appendix U](#appendix-u-first-run-onboarding) |

### Low Risk

| Risk | Impact | Mitigation | Reference |
|------|--------|------------|-----------|
| Voice API differences | Platform-specific implementations | Test on multiple macOS versions | - |
| Notification differences | Minor UX gap | Platform-specific implementations | - |
| App sandbox restrictions | Feature limitations | Request appropriate entitlements | - |
| Voice hash instability | Voice assignment changes | Document as acceptable | [Appendix X](#appendix-x-voice-hash-stability-note) |
| Render loop false positives | Spurious warnings | Use higher threshold for macOS | [Appendix T](#appendix-t-render-loop-detection) |

---

## 11. Feature Deep Dives

### 11.1 Voice Features (iOS Implementation Details)

#### Text-to-Speech Architecture
The iOS app uses `AVSpeechSynthesizer` with the following features:

**VoiceOutputManager.swift (220 lines):**
```swift
class VoiceOutputManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()
    private let audioSessionManager = DeviceAudioSessionManager()
    private var silencePlayer: AVAudioPlayer?  // For keep-alive
    private var keepAliveTimer: Timer?
    var onSpeechComplete: (() -> Void)?
}
```

**Key Features:**
- **Delegate pattern** (`AVSpeechSynthesizerDelegate`) for state tracking (`didStart`, `didFinish`, `didCancel`)
- **Silence Keep-Alive Timer**: Plays 100ms silent audio every 25 seconds to prevent iOS from stopping the audio session during long TTS playback
- **Background Playback**: Uses `.playback` audio category (via `DeviceAudioSessionManager`) to continue when screen is locked
- **Silent Mode Respect**: Optionally uses `.ambient` category to honor the hardware ringer switch (configurable in settings)
- **Speech Parameters**: Rate 0.5 (default, slow for code clarity), pitch 1.0, volume 1.0

**Audio Session Configuration:**
```swift
// DeviceAudioSessionManager handles two modes:
func configureAudioSessionForForcedPlayback()  // .playback category - ignores silent switch
func configureAudioSessionForSilentMode()      // .ambient category - respects silent switch
```

**Voice Selection (via AppSettings):**
- Filters to Premium and Enhanced quality English voices only
- "All Premium Voices" mode: Rotates voices per working directory using stable hash
- Same project always gets same voice (consistency)
- Different projects get different voices (variety)
- Voices cached after first load to avoid blocking main thread

**API:**
```swift
// Primary method - uses configured voice
func speak(_ text: String, rate: Float = 0.5, respectSilentMode: Bool = false, workingDirectory: String? = nil)

// For previews - specific voice
func speakWithVoice(_ text: String, rate: Float = 0.5, voiceIdentifier: String? = nil, respectSilentMode: Bool = false)

func stop()
func pause()
func resume()
```

**Text Processing (TextProcessor.swift):**
Before TTS, text is processed:
1. Fenced code blocks (` ``` `) replaced with "[code block]"
2. Inline code backticks removed, content kept
3. Multiple newlines collapsed
4. Whitespace trimmed

**macOS Considerations:**
- `AVSpeechSynthesizer` is available on macOS 10.14+
- No equivalent to iOS hardware silent switch - remove `respectSilentMode` option
- No `AVAudioSession` on macOS - remove `DeviceAudioSessionManager` dependency
- Background audio works differently (apps don't suspend) - keep-alive timer not needed
- Silence player workaround not required on macOS

#### Speech Recognition Architecture
**VoiceInputManager.swift (138 lines):**
```swift
class VoiceInputManager: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var transcribedText = ""
    @Published var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined

    /// macOS only: real-time audio levels for waveform visualization (see Appendix Y.4)
    @Published var audioLevels: [Float] = []

    /// macOS only: partial transcription for live preview (see Appendix Y.4)
    @Published var partialTranscription = ""

    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    var onTranscriptionComplete: ((String) -> Void)?
}
```

**Key Features:**
- Uses Apple's `Speech` framework (`SFSpeechRecognizer`)
- `AVAudioEngine` for real-time audio capture
- Hardcoded to en-US locale: `SFSpeechRecognizer(locale: Locale(identifier: "en-US"))`
- Partial results enabled (`shouldReportPartialResults = true`) for live transcription display
- Audio session: `.record` category, `.measurement` mode, `.duckOthers` option

**API:**
```swift
func requestAuthorization(completion: @escaping (Bool) -> Void)
func startRecording()
func stopRecording()
```

**Audio Tap Configuration:**
```swift
let inputNode = audioEngine.inputNode
let recordingFormat = inputNode.outputFormat(forBus: 0)
inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
    recognitionRequest.append(buffer)
}
```

**macOS Implementation:**
- `SFSpeechRecognizer` available on macOS 10.15+
- Requires microphone permission (entitlement + runtime authorization)
- Same `AVAudioEngine` + `SFSpeechRecognizer` pattern as iOS
- Audio session configuration differs: no `AVAudioSession.sharedInstance()` - use `AVAudioEngine` directly
- Voice input toggle in toolbar or global hotkey activation
- Consider push-to-talk option for desktop ergonomics (hold Space to record)

### 11.2 Priority Queue System

The priority queue is a sophisticated session management feature:

**Data Model (CDBackendSession+PriorityQueue.swift):**
```swift
// Properties on CDBackendSession
isInPriorityQueue: Bool
priority: Int32        // Lower = higher importance (1 = urgent, 10 = default)
priorityOrder: Double  // For FIFO ordering within same priority level
priorityQueuedAt: Date?
```

**Priority Values:**
| Value | Meaning | Use Case |
|-------|---------|----------|
| 1 | Urgent | Critical bugs, blocking issues |
| 5 | Normal | Standard work items |
| 10 | Low (default) | Background tasks, nice-to-have |

**Operations:**
- `addToPriorityQueue(_:context:)` - Add session to end of its priority level, or move to end if already in queue
- `removeFromPriorityQueue(_:context:)` - Remove and reset priority to 10 (default)
- `changePriority(_:newPriority:context:)` - Move to new priority level, positioned at end
- `reorderSession(_:between:and:context:)` - Drag-and-drop reordering with midpoint calculation for priorityOrder

**Sorting Logic:**
Sessions sorted by: `(priority ASC, priorityOrder ASC)` - lower priority number first, then by order within level.

**Auto-Add Behavior:**
- When assistant responds, session auto-added to priority queue (if enabled in settings)
- New sessions auto-added when created (if enabled in settings)
- Adding moves session to END of its priority level (FIFO within priority)

**Cross-View Sync:**
- Uses `NotificationCenter.post(name: .priorityQueueChanged)` for UI updates
- userInfo contains `["sessionId": session.id.uuidString.lowercased()]`
- Multiple views observe and react to queue changes

**macOS Adaptation:**
- Drag-and-drop reordering maps naturally to macOS
- Could show priority queue in sidebar section
- Priority picker in context menu or inspector panel

### 11.3 Command Execution System

**Available Commands Discovery:**
- Backend parses `make -qp` output for Makefile targets
- Targets grouped by hyphen convention: `docker-up` → Docker > Up
- General commands always available: `git.status`
- Commands sent via `available_commands` message after `set_directory`

**Execution Flow:**
1. iOS sends `execute_command` with command_id and working_directory
2. Backend spawns process, returns `command_started` with session ID
3. Output streamed line-by-line via `command_output` (stdout/stderr marked)
4. Process exits: `command_complete` with exit code and duration

**Concurrent Execution:**
- Multiple commands can run simultaneously (no locking)
- Each gets unique `cmd-<UUID>` session ID
- Independent output streams

**History Storage:**
- Index: `~/.voice-code/command-history/index.edn`
- Logs: `~/.voice-code/command-history/<session-id>.log`
- 7-day retention with automatic cleanup
- Preview (first 200 chars) stored in index

**macOS Adaptation:**
- Terminal-style output window with ANSI color support
- Detachable/floating command output windows
- Right-click to re-run command from history
- Could integrate with Terminal.app for complex commands

### 11.4 Resources/File Upload System

**iOS Share Extension:**
- Processes files shared from other apps
- Reads server config from App Group UserDefaults
- Direct HTTP POST to `http://<server>:<port>/upload`
- Base64 encodes file content
- Shows debug UI with real-time logging

**Main App Resources (ResourcesManager.swift):**
- Monitors App Group container for pending uploads
- Processes when connection established
- WebSocket message: `upload_file` with filename, content (base64), storage_location
- Acknowledgment-based with 30-second timeout
- Cleans up files after successful upload

**Backend Storage:**
- Location: `<working_directory>/.untethered/resources/`
- Filename conflicts: append timestamp (file-20251211143052.txt)
- 100MB size limit enforced

**macOS Adaptation:**
- Drag-and-drop onto conversation view or resources panel
- Standard file dialogs for manual selection
- No App Group needed - direct file system access
- Could show upload progress inline
- Consider Finder integration via Services menu

### 11.5 Session Management

**Session Lifecycle:**
1. **Creation**: User clicks +, enters name, optionally selects directory
2. **CoreData**: `CDBackendSession` created with UUID, marked `isLocallyCreated`
3. **Backend Sync**: Backend discovers session via filesystem watcher
4. **Message Flow**: User sends prompt → optimistic message → Claude response

**Session Locking:**
- Prevents concurrent prompts to same Claude session
- Optimistic lock: UI locks when sending, before backend confirms
- Backend maintains `session-locks` atom
- `session_locked` message if already processing
- `turn_complete` unlocks after successful response

**Session Deletion (Soft Delete):**
- `CDUserSession.isUserDeleted` flag set to true
- Session hidden from UI but not deleted from backend
- `session_deleted` message sent to backend for tracking

**Session Naming:**
- Backend infers name from first user message or summary
- User can set custom name via `CDUserSession.customName`
- Display priority: customName > backendName

**macOS Adaptation:**
- Sidebar shows session list with unread badges
- Context menu for rename, delete, compact, copy ID
- Session info in inspector panel (⌘I)
- Quick session switching with ⌘1-9

### 11.6 Conversation View Details

**Message Display:**
- Messages fetched via CoreData `@FetchRequest`
- Sorted by timestamp ascending (oldest first)
- Limited to 50 messages displayed (pruning threshold 100)
- Truncation at 500 chars with "... omitted ..." placeholder

**Optimistic UI:**
- User message shown immediately with `.sending` status
- Updated to `.confirmed` when backend acknowledges
- Error state if send fails

**Auto-Scroll:**
- ScrollViewReader with anchor to last message
- Toggle to disable (useful when reading history)
- Re-enables on new user message

**Input Area:**
- TextEditor for multi-line input
- Voice mode toggle (iOS)
- Send button disabled when locked or empty
- Draft auto-saved to UserDefaults

**macOS Adaptation:**
- Larger text input with markdown preview option
- ⌘⏎ to send (not just Enter)
- Message actions in right-click context menu
- "Read Aloud" available but secondary to copy
- Search within conversation (⌘F)

### 11.7 AppSettings Configuration

**App Group (iOS-only):**
- ID: `group.com.910labs.untethered.resources`
- Used for Share Extension communication
- macOS: Not needed (no App Groups for desktop apps)

**Settings with Defaults:**
| Setting | Default | Description |
|---------|---------|-------------|
| `serverURL` | `""` | WebSocket server address |
| `serverPort` | `"8080"` | WebSocket server port |
| `selectedVoiceIdentifier` | First premium voice | TTS voice selection |
| `continuePlaybackWhenLocked` | `true` | iOS: continue TTS when screen locked |
| `recentSessionsLimit` | `5` | Number of sessions in Recent section |
| `notifyOnResponse` | `true` | Send notification on assistant response |
| `resourceStorageLocation` | `"~/Downloads"` | Where to store uploaded files |
| `queueEnabled` | `false` | Enable legacy queue system |
| `priorityQueueEnabled` | `false` | Enable priority queue system |
| `respectSilentMode` | `true` | iOS: honor ringer switch for TTS |
| `systemPrompt` | `""` | Custom system prompt for Claude |
| `defaultWorkingDirectory` | `""` | Default directory for new sessions (macOS) |

**Access Pattern:**
AppSettings can be used as either a `@StateObject` for SwiftUI views or via shared singleton:
```swift
class AppSettings: ObservableObject {
    static let shared = AppSettings()
    // ... @Published properties ...
}
```

**Debounced Settings Saves:**
Text field settings (`serverURL`, `serverPort`, `systemPrompt`) use 0.5s debounce to avoid excessive UserDefaults writes during typing.

```swift
$serverURL
    .dropFirst()  // Skip initial value
    .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
    .sink { value in
        UserDefaults.standard.set(value, forKey: "serverURL")
    }
```

**Voice Rotation Algorithm:**
When "All Premium Voices" is selected, voices rotate deterministically per project:
```swift
func resolveVoiceIdentifier(forWorkingDirectory workingDirectory: String?) -> String? {
    // Stable hash ensures same project always gets same voice
    let hashValue = stableHash(workingDirectory)
    let index = hashValue % premiumVoices.count
    return premiumVoices[index].identifier
}

private func stableHash(_ string: String) -> Int {
    var hash = 0
    for char in string.unicodeScalars {
        hash = hash &* 31 &+ Int(char.value)
    }
    return abs(hash)
}
```

**macOS Adaptation:**
- Remove `continuePlaybackWhenLocked` (macOS doesn't lock audio)
- Remove `respectSilentMode` (macOS has no silent switch)
- Remove App Group syncing
- Keep all other settings identical

### 11.8 Auto-Scroll Behavior

**iOS Implementation:**
- Auto-scroll enabled by default when view appears
- 300ms debounce before scrolling to new messages (prevents layout thrashing)
- Toggle button in toolbar (filled circle = enabled)
- Re-enabling scrolls immediately to bottom

```swift
@State private var autoScrollEnabled = true

.onChange(of: messages.count) { oldCount, newCount in
    guard newCount > oldCount, autoScrollEnabled else { return }

    // CRITICAL: Capture target ID NOW, before delay (see Appendix R)
    guard let targetId = messages.last?.id else { return }

    // Debounce scroll to avoid triggering during layout calculations
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        guard self.autoScrollEnabled else { return }
        // Verify message still exists (may have been pruned)
        guard messages.contains(where: { $0.id == targetId }) else { return }
        proxy.scrollTo(targetId, anchor: .bottom)
    }
}
```

**macOS Adaptation:**
- Same behavior with keyboard shortcut (⌘↓ to toggle)
- Consider scroll-to-bottom button at bottom-right of message list

### 11.9 Legacy Queue System

**Separate from Priority Queue:**
The legacy queue is a simpler FIFO system predating the priority queue.

**CoreData Properties (CDBackendSession):**
| Property | Type | Description |
|----------|------|-------------|
| `isInQueue` | Bool | Session is in legacy queue |
| `queuePosition` | Int32 | Position (1 = first) |
| `queuedAt` | Date? | When added to queue |

**Behavior:**
- When `queueEnabled` setting is true, sessions auto-add to queue on prompt send
- Sessions already in queue move to end (LIFO for active work)
- Displayed in DirectoryListView under "Queue" section
- Independent of priority queue (can be in both)

**macOS Adaptation:**
- Consider deprecating in favor of priority queue
- If kept, show as collapsible sidebar section

### 11.10 Smart Speaking (Active Session Tracking)

**Purpose:**
Only auto-speak responses for the session the user is actively viewing.

**Implementation (ActiveSessionManager.swift):**
```swift
class ActiveSessionManager {
    static let shared = ActiveSessionManager()
    private var activeSessionId: UUID?

    func setActiveSession(_ sessionId: UUID) {
        activeSessionId = sessionId
    }

    func clearActiveSession() {
        activeSessionId = nil
    }

    func isActiveSession(_ sessionId: UUID) -> Bool {
        activeSessionId == sessionId
    }
}
```

**Usage:**
- `setActiveSession()` called when ConversationView appears
- `clearActiveSession()` called when ConversationView disappears
- SessionSyncManager checks before auto-speaking new messages

**macOS Adaptation:**
- Same pattern, but track per-window (multiple conversations can be visible)
- Consider speaking for focused window only

### 11.11 Session Name Inference

**Purpose:**
Auto-generate session names from first user message using Claude.

**WebSocket Messages:**
```json
// Request
{
  "type": "infer_session_name",
  "session_id": "<uuid>",
  "message_text": "<first-user-message>"
}

// Success Response
{
  "type": "session_name_inferred",
  "session_id": "<uuid>",
  "name": "<inferred-name>"
}

// Error Response
{
  "type": "infer_name_error",
  "session_id": "<uuid>",
  "error": "<error-message>"
}
```

**iOS Integration:**
- Available via message context menu → "Infer Name"
- Updates `CDUserSession.customName` on success
- Backend uses Claude to generate concise name from message content

**macOS Adaptation:**
- Add to message right-click context menu
- Could auto-infer for new sessions after first response

---

## 12. Testing Strategy for macOS

### 12.1 Shared Package Tests

The existing iOS test infrastructure is comprehensive (49 files, ~17K LOC). Key patterns to reuse:

**CoreData Testing:**
```swift
// In-memory store for test isolation
persistenceController = PersistenceController(inMemory: true)
context = persistenceController.container.viewContext
```

**WebSocket Mocking:**
```swift
// Behavioral subclassing, not protocol mocking
class MockVoiceCodeClient: VoiceCodeClientCore {
    var sentMessages: [[String: Any]] = []
    override func sendMessage(_ message: [String: Any]) {
        sentMessages.append(message)
    }
}
```

**Async Testing:**
```swift
let expectation = XCTestExpectation(description: "...")
client.$availableCommands
    .dropFirst()
    .sink { _ in expectation.fulfill() }
    .store(in: &cancellables)
await fulfillment(of: [expectation], timeout: 1.0)
```

### 12.2 macOS-Specific Tests

**Window Management:**
- Test NavigationSplitView column visibility
- Test window restoration on relaunch
- Test multi-window state independence

**Keyboard Navigation:**
- Test all keyboard shortcuts function correctly
- Test focus management between panels
- Test accessibility with VoiceOver

**Drag and Drop:**
- Test file drop onto conversation view
- Test session reordering in sidebar
- Test priority queue drag reordering

**Menu Bar:**
- Test all menu items enabled/disabled correctly
- Test keyboard shortcuts match menu items
- Test context menus in session list

### 12.3 Test Categories

| Category | Shared | macOS-Only |
|----------|--------|------------|
| CoreData operations | ✓ | |
| WebSocket protocol | ✓ | |
| Session sync | ✓ | |
| Command execution | ✓ | |
| Priority queue logic | ✓ | |
| Window management | | ✓ |
| Keyboard shortcuts | | ✓ |
| Drag and drop | | ✓ |
| Menu bar commands | | ✓ |
| File dialogs | | ✓ |

---

## 13. Detailed WebSocket Protocol

### 13.1 Connection Sequence

```
Client                                  Backend
   |                                       |
   |-------- WebSocket Connect ----------->|
   |                                       |
   |<--------- hello message --------------|
   |         {type: "hello",               |
   |          version: "0.1.0"}            |
   |                                       |
   |-------- connect message ------------->|
   |         {type: "connect"}             |
   |                                       |
   |<-------- connected message -----------|
   |         {type: "connected"}           |
   |                                       |
   |<------- session_list message ---------|
   |         {type: "session_list",        |
   |          sessions: [...]}             |
   |                                       |
   |<----- recent_sessions message --------|
   |         {type: "recent_sessions",     |
   |          sessions: [...], limit: N}   |
```

### 13.2 Message Types Reference

**Client → Backend:**
| Type | Required Fields | Optional Fields |
|------|-----------------|-----------------|
| `connect` | | |
| `ping` | | |
| `prompt` | `text` | `session_id`, `working_directory`, `system_prompt` |
| `subscribe` | `session_id` | |
| `unsubscribe` | `session_id` | |
| `set_directory` | `path` | |
| `compact_session` | `session_id` | |
| `kill_session` | `session_id` | |
| `infer_session_name` | `session_id`, `message_text` | |
| `execute_command` | `command_id`, `working_directory` | |
| `get_command_history` | | `working_directory`, `limit` |
| `get_command_output` | `command_session_id` | |
| `upload_file` | `filename`, `content` | `storage_location` |
| `list_resources` | | `working_directory` |
| `delete_resource` | `filename`, `working_directory` | |

**Backend → Client:**
| Type | Key Fields |
|------|------------|
| `hello` | `version`, `message` |
| `connected` | `message` |
| `session_list` | `sessions[]` |
| `recent_sessions` | `sessions[]`, `limit` |
| `available_commands` | `working_directory`, `project_commands[]`, `general_commands[]` |
| `ack` | `message` |
| `response` | `success`, `text`, `session_id`, `usage`, `cost` |
| `error` | `message` |
| `session_locked` | `session_id`, `message` |
| `turn_complete` | `session_id` |
| `session_created` | session metadata |
| `session_updated` | `session_id`, `messages[]` |
| `command_started` | `command_session_id`, `command_id`, `shell_command` |
| `command_output` | `command_session_id`, `stream`, `text` |
| `command_complete` | `command_session_id`, `exit_code`, `duration_ms` |
| `command_history` | `sessions[]`, `limit` |
| `command_output_full` | full output + metadata |
| `compaction_complete` | `session_id` |
| `compaction_error` | `session_id`, `error` |
| `session_name_inferred` | `session_id`, `name` |
| `infer_name_error` | `session_id`, `error` |
| `session_ready` | `session_id` |
| `session_killed` | `session_id` |
| `worktree_session_created` | `session_id`, `worktree_path`, `branch_name` |
| `worktree_session_error` | `error` |
| `upload_complete` | `filename`, `path` |
| `resources_list` | `resources[]` |

### 13.3 JSON Naming Convention

**CRITICAL:** All JSON keys use `snake_case`:
- `session_id` (not `sessionId`)
- `working_directory` (not `workingDirectory`)
- `command_session_id` (not `commandSessionId`)

Swift ↔ JSON conversion happens at boundaries using `CodingKeys`.

---

## 14. macOS-Specific Considerations

### 14.1 Sandbox and Entitlements

```xml
<!-- VoiceCodeDesktop.entitlements -->
<key>com.apple.security.app-sandbox</key>
<true/>

<key>com.apple.security.network.client</key>
<true/>

<key>com.apple.security.files.user-selected.read-write</key>
<true/>

<!-- Optional: for drag-and-drop from Finder -->
<key>com.apple.security.files.downloads.read-write</key>
<true/>

<!-- Required: for voice input (speech recognition) -->
<key>com.apple.security.device.microphone</key>
<true/>
```

### 14.2 App Distribution

**Options:**
1. **Mac App Store** - Requires sandbox, review process
2. **Direct Distribution** - Notarization required, more flexibility
3. **Developer ID** - For enterprise/internal distribution

**Recommendation:** Start with Direct Distribution (notarized DMG), consider App Store later.

### 14.3 Performance Considerations

- macOS apps stay open indefinitely - memory management is critical
- CoreData fetch limits more important for long-running sessions
- WebSocket reconnection should be less aggressive (no app suspension)
- Consider lazy loading for large session lists

### 14.4 Accessibility

- Full VoiceOver support required
- Keyboard navigation must work without mouse
- Respect "Reduce Motion" system setting
- Support Dynamic Type where applicable

---

## Appendix A: File Migration Checklist

### Files to Move to Shared Package

- [ ] `Models/CDBackendSession.swift`
- [ ] `Models/CDBackendSession+PriorityQueue.swift`
- [ ] `Models/CDMessage.swift`
- [ ] `Models/CDUserSession.swift`
- [ ] `Models/Command.swift`
- [ ] `Models/Message.swift`
- [ ] `Models/RecentSession.swift`
- [ ] `Models/Resource.swift`
- [ ] `Managers/SessionSyncManager.swift` (remove UIKit)
- [ ] `Managers/DraftManager.swift`
- [ ] `Managers/LogManager.swift`
- [ ] `Managers/ActiveSessionManager.swift`
- [ ] `Managers/PersistenceController.swift`
- [ ] `Utilities/TextProcessor.swift`
- [ ] `Utils/CommandSorter.swift`
- [ ] `VoiceCode.xcdatamodeld`

### Files to Refactor (Extract Shared + Platform-Specific)

- [ ] `Managers/VoiceCodeClient.swift`
- [ ] `Managers/AppSettings.swift`
- [ ] `Managers/ResourcesManager.swift`
- [ ] `Managers/NotificationManager.swift`

### Files to Keep iOS-Only

- [ ] `Managers/VoiceOutputManager.swift`
- [ ] `Managers/VoiceInputManager.swift`
- [ ] `Managers/DeviceAudioSessionManager.swift`
- [ ] `VoiceCodeShareExtension/`
- [ ] All iOS Views

---

## Appendix B: macOS Minimum Requirements

- **macOS Version:** 14.0 (Sonoma) or later
- **Xcode:** 15.0 or later
- **Swift:** 5.9 or later
- **Architecture:** Apple Silicon (arm64) + Intel (x86_64)

---

## Appendix C: References

- [Apple Human Interface Guidelines - macOS](https://developer.apple.com/design/human-interface-guidelines/macos)
- [SwiftUI for macOS](https://developer.apple.com/documentation/swiftui/building-macos-apps)
- [NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview)
- [Commands and Menus](https://developer.apple.com/documentation/swiftui/commands)

---

## Appendix D: iOS View Hierarchy Reference

```
VoiceCodeApp (@main)
├── NavigationStack
│   └── DirectoryListView (root)
│       ├── Sections:
│       │   ├── Recent Sessions (collapsible, N most recent)
│       │   ├── Queue (if enabled, sessions pending attention)
│       │   ├── Priority Queue (if enabled, priority-sorted sessions)
│       │   └── All Projects (grouped by working directory)
│       │
│       └── navigationDestination(for: String.self) → SessionsForDirectoryView
│           ├── Session list for specific directory
│           ├── Empty state if no sessions
│           ├── Context menu: Copy Session ID
│           ├── Swipe action: Delete
│           └── navigationDestination(for: UUID.self) → SessionLookupView
│               └── ConversationView
│                   ├── Message list (ScrollView + LazyVStack)
│                   ├── Input area (TextEditor + buttons)
│                   ├── Voice toggle (iOS)
│                   └── Sheets:
│                       ├── SessionInfoView (⌘I equivalent)
│                       ├── CommandMenuView
│                       └── MessageDetailView (full message + actions)
│
├── SettingsView (sheet from gear button)
│   ├── Server Configuration
│   ├── Voice Selection
│   ├── Audio Playback options
│   ├── Recent sessions limit
│   ├── Queue toggles
│   ├── Resources storage location
│   └── System prompt
│
└── CommandHistoryView (sheet from clock button)
    ├── Running commands with streaming output
    ├── Completed commands with exit codes
    └── CommandOutputDetailView (full output)
```

---

## Appendix E: CoreData Schema Details

### CDBackendSession Entity

| Attribute | Type | Notes |
|-----------|------|-------|
| `id` | UUID | Primary key, always lowercase string format |
| `backendName` | String | Auto-generated name from backend |
| `workingDirectory` | String | Absolute path |
| `lastModified` | Date | For sorting, updated on new messages |
| `messageCount` | Int32 | Filtered message count |
| `preview` | String | Last message snippet (100 chars) |
| `unreadCount` | Int32 | Badge count for notifications |
| `isLocallyCreated` | Bool | True until synced from backend |
| `isInQueue` | Bool | Legacy queue system |
| `queuePosition` | Int32 | Legacy queue position |
| `queuedAt` | Date? | Legacy queue timestamp |
| `isInPriorityQueue` | Bool | Priority queue membership |
| `priority` | Int32 | Lower = higher importance (1=urgent, 10=default) |
| `priorityOrder` | Double | FIFO ordering within same priority level |
| `priorityQueuedAt` | Date? | When first added to priority queue |

**Relationships:**
- `messages` → `CDMessage` (to-many, cascade delete)

### CDMessage Entity

| Attribute | Type | Notes |
|-----------|------|-------|
| `id` | UUID | Primary key |
| `sessionId` | UUID | Foreign key to session |
| `role` | String | "user" or "assistant" |
| `text` | String | Full message text |
| `timestamp` | Date | Client timestamp |
| `serverTimestamp` | Date? | Backend timestamp (for reconciliation) |
| `messageStatus` | Int16 | 0=sending, 1=confirmed, 2=error |

**Relationships:**
- `session` → `CDBackendSession` (to-one)

### CDUserSession Entity

| Attribute | Type | Notes |
|-----------|------|-------|
| `id` | UUID | Matches CDBackendSession.id |
| `customName` | String? | User-provided session name |
| `isUserDeleted` | Bool | Soft delete flag |
| `createdAt` | Date | When user customization was created |

---

## Appendix F: Backend Namespace Summary

| Namespace | Lines | Responsibility |
|-----------|-------|----------------|
| `voice_code.server` | 1,087 | WebSocket server, message routing, JSON conversion |
| `voice_code.replication` | 1,124 | Filesystem watching, session index, incremental parsing |
| `voice_code.claude` | 384 | Claude CLI invocation, process management |
| `voice_code.commands` | 303 | Makefile parsing, command resolution |
| `voice_code.commands_history` | 355 | Command history storage, cleanup |
| `voice_code.resources` | 181 | File upload/storage |
| `voice_code.worktree` | 197 | Git worktree creation |

**Key Backend State:**
- `session-index` - Atom: session-id → metadata
- `session-locks` - Atom: Set of locked session IDs
- `active-claude-processes` - Atom: session-id → Process
- `command-history-index` - EDN file on disk

---

## Appendix G: Keyboard Shortcuts Implementation

```swift
// AppCommands.swift - SwiftUI Commands structure

struct AppCommands: Commands {
    @FocusedValue(\.selectedSession) var selectedSession
    @FocusedValue(\.messageInput) var messageInput

    var body: some Commands {
        // File menu
        CommandGroup(replacing: .newItem) {
            Button("New Session") { ... }
                .keyboardShortcut("n")
            Button("New Window") { ... }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        // Edit menu additions
        CommandGroup(after: .pasteboard) {
            Button("Find...") { ... }
                .keyboardShortcut("f")
        }

        // Session menu (custom)
        CommandMenu("Session") {
            Button("Send Message") { ... }
                .keyboardShortcut(.return)
                .disabled(messageInput?.isEmpty ?? true)

            Divider()

            Button("Refresh") { ... }
                .keyboardShortcut("r")
            Button("Compact") { ... }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Kill Process") { ... }
                .disabled(selectedSession?.isLocked != true)

            Divider()

            Button("Session Info") { ... }
                .keyboardShortcut("i")
            Button("Copy Session ID") { ... }
                .keyboardShortcut("c", modifiers: [.command, .option])
        }

        // View menu additions
        CommandGroup(after: .sidebar) {
            Toggle("Show Queue", isOn: $showQueue)
                .keyboardShortcut("q", modifiers: [.command, .shift])
            Toggle("Show Priority Queue", isOn: $showPriorityQueue)
                .keyboardShortcut("p", modifiers: [.command, .shift])

            Divider()

            Button("Previous Session") { ... }
                .keyboardShortcut("[")
            Button("Next Session") { ... }
                .keyboardShortcut("]")
        }

        // Window menu - session switching
        CommandGroup(before: .windowList) {
            ForEach(0..<9, id: \.self) { index in
                Button("Session \(index + 1)") { ... }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
        }
    }
}
```

---

## Appendix H: Estimated Code Distribution

After refactoring for code sharing:

| Component | Shared LOC | iOS-Only LOC | macOS-Only LOC |
|-----------|------------|--------------|----------------|
| Models | 1,100 | 0 | 0 |
| Managers (shared) | 1,800 | 0 | 0 |
| Managers (platform) | 0 | 800 | 600 |
| Networking | 600 | 0 | 0 |
| Utilities | 300 | 0 | 0 |
| Views | 0 | 4,500 | 3,000 |
| Tests (shared) | 8,000 | 0 | 0 |
| Tests (platform) | 0 | 9,000 | 4,000 |
| **Total** | **11,800** | **14,300** | **7,600** |

**Sharing ratio:** ~35% shared code (excluding tests), ~45% including tests

---

## Appendix I: Implementation Patterns (iOS Reference)

This appendix documents specific implementation patterns from the iOS app that must be preserved or adapted for macOS.

### I.1 Error Handling Patterns

#### Connection Error Handling

**Pattern:** Exponential backoff reconnection with max attempts and user feedback.

```swift
// VoiceCodeClient.swift - Connection error recovery
private let maxReconnectionAttempts = 20  // ~17 minutes max
private let maxReconnectionDelay: Double = 60.0

// Exponential backoff calculation
let delay = min(pow(2.0, Double(reconnectionAttempts)), maxReconnectionDelay)

// Max attempt handling with user feedback
if reconnectionAttempts >= maxReconnectionAttempts {
    currentError = "Unable to connect to server after \(maxReconnectionAttempts) attempts. Check server status and network connection."
}
```

**macOS Adaptation:**
- Display connection status in window title bar or status bar
- Provide manual "Reconnect" button after max attempts
- Show notification when connection lost/restored

#### Session Lock Recovery

**Pattern:** Automatically unlock all sessions on connection failure to prevent stuck UI.

```swift
// On connection failure, clear all locks immediately
self.lockedSessions = Set<String>()
self.flushPendingUpdates()  // Immediate flush - don't debounce critical ops
print("🔓 [VoiceCodeClient] Cleared all locked sessions on connection failure")
```

**macOS Adaptation:**
- Same pattern applies
- Add menu item "Force Unlock All Sessions" for manual recovery
- Show lock status in session list (lock icon)

#### Error Message Types

| Error Source | Display Method | Auto-dismiss |
|--------------|----------------|--------------|
| Connection failure | Status bar + banner | No |
| WebSocket error | Alert dialog | No |
| Session locked | Inline message | Yes (on unlock) |
| Upload failure | Toast notification | Yes (5s) |
| Command failure | Inline in output | No |

### I.2 Network Recovery Patterns

#### Subscription Restoration

**Pattern:** Track active subscriptions and auto-restore after reconnection.

```swift
// Track what we're subscribed to
private var activeSubscriptions = Set<String>()

// After reconnection, restore all subscriptions
func handleConnected() {
    if !activeSubscriptions.isEmpty {
        print("🔄 Restoring \(activeSubscriptions.count) subscription(s)")
        for sessionId in activeSubscriptions {
            sendMessage(["type": "subscribe", "session_id": sessionId])
        }
    }
}
```

**macOS Adaptation:**
- Same pattern - subscriptions persist across reconnects
- Consider subscribing to visible sessions only (performance)

#### Message Replay and Acknowledgment

**Pattern:** Backend buffers undelivered messages; client ACKs each replay.

```swift
case "replay":
    // Process replayed message
    if let messageId = json["message_id"] as? String {
        sendMessageAck(messageId)  // Must ACK to clear from buffer
    }
```

**macOS Adaptation:**
- Identical implementation required
- Consider visual indicator for "catching up" state

#### Request Timeouts

| Operation | Timeout | Behavior on Timeout |
|-----------|---------|---------------------|
| Session list | 5 seconds | Resume with empty list |
| Session compaction | 60 seconds | Show error, re-enable controls |
| File upload | 30 seconds | Show error, keep file for retry |
| Command execution | No timeout | User can cancel |

### I.3 Debouncing and Performance Patterns

#### Property Update Debouncing

**Pattern:** Centralized debounce system for all @Published properties to prevent SwiftUI render thrashing.

```swift
// Configuration
private var pendingUpdates: [String: Any] = [:]
private var debounceWorkItem: DispatchWorkItem?
private let debounceDelay: TimeInterval = 0.1  // 100ms

// Schedule debounced update
private func scheduleUpdate(key: String, value: Any) {
    pendingUpdates[key] = value
    debounceWorkItem?.cancel()

    let workItem = DispatchWorkItem { [weak self] in
        self?.applyPendingUpdates()
    }
    debounceWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + debounceDelay, execute: workItem)
}

// Immediate flush for critical operations
private func flushPendingUpdates() {
    debounceWorkItem?.cancel()
    debounceWorkItem = nil
    applyPendingUpdates()
}
```

**When to flush immediately:**
- Session lock/unlock state changes
- Error state changes
- Connection state changes

**macOS Adaptation:**
- Same pattern required
- May need longer debounce for denser UI (150ms)

#### Render Loop Detection

**Pattern:** Track renders per second to detect infinite loops.

```swift
private class RenderLoopDetector {
    private var renderCount = 0
    private var windowStart = Date()
    private let threshold = 50  // renders per second

    func recordRender() {
        let now = Date()
        if now.timeIntervalSince(windowStart) > 1.0 {
            if renderCount > threshold {
                logger.error("🚨 RENDER LOOP DETECTED: \(renderCount) renders/sec")
            }
            renderCount = 1
            windowStart = now
        } else {
            renderCount += 1
        }
    }
}
```

**macOS Adaptation:**
- Include in debug builds
- Add to main window and conversation detail views

#### FetchRequest Animation Disabled

**Critical:** Always disable animations on FetchRequest to prevent render storms.

```swift
_messages = FetchRequest(
    fetchRequest: CDMessage.fetchMessages(sessionId: session.id),
    animation: nil  // CRITICAL - prevents animated transitions
)
```

### I.4 State Restoration Patterns

#### Draft Persistence

**Pattern:** Auto-save drafts with debounce to UserDefaults.

```swift
func saveDraft(sessionID: String, text: String) {
    if text.isEmpty {
        drafts.removeValue(forKey: sessionID)
    } else {
        drafts[sessionID] = text
    }

    // Debounce saves (300ms)
    saveWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
        UserDefaults.standard.set(self?.drafts, forKey: "sessionDrafts")
    }
    saveWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
}
```

**macOS Adaptation:**
- Same UserDefaults pattern
- Additionally: macOS state restoration for window positions

#### App Lifecycle Callbacks

**iOS:**
```swift
.onReceive(NotificationCenter.default.publisher(
    for: UIApplication.willEnterForegroundNotification
)) { _ in
    resourcesManager.processPendingUploads()
}
```

**macOS Equivalent:**
```swift
.onReceive(NotificationCenter.default.publisher(
    for: NSApplication.didBecomeActiveNotification
)) { _ in
    resourcesManager.processPendingUploads()
}
```

#### Session Sync from Backend

**Pattern:** Background context for CoreData operations with notification on completion.

```swift
func handleSessionList(_ sessions: [[String: Any]]) async {
    await withCheckedContinuation { continuation in
        persistenceController.performBackgroundTask { context in
            // Process sessions in background context
            // ...

            if context.hasChanges {
                try? context.save()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .sessionListDidUpdate,
                        object: nil
                    )
                }
            }
            continuation.resume()
        }
    }
}
```

**macOS Adaptation:**
- Identical pattern required
- macOS apps run longer - consider incremental sync for large session lists

### I.5 UI Component Specifications

#### Connection Status Indicator

**iOS Implementation:**
```swift
HStack(spacing: 4) {
    Circle()
        .fill(client.isConnected ? Color.green : Color.red)
        .frame(width: 8, height: 8)
    Text(client.isConnected ? "Connected" : "Disconnected")
        .font(.caption)
        .foregroundColor(.secondary)
}
```

**macOS Specification:**
- Location: Window title bar subtitle or status bar
- Size: 10pt indicator + 12pt text
- States: Connected (green), Disconnected (red), Reconnecting (yellow, pulsing)
- Click action: Show connection details popover

#### Session Lock UI

**States:**
| State | Visual | Input | Actions |
|-------|--------|-------|---------|
| Unlocked | Normal | Enabled | Send, Voice |
| Locked (own) | Spinner + "Processing..." | Disabled | Cancel (if supported) |
| Locked (other) | Lock icon + "Session busy" | Disabled | Manual Unlock |

**Manual Unlock:**
- iOS: Tap "Tap to Unlock" text
- macOS: Menu item "Session > Force Unlock" (⌘U) or toolbar button

#### Voice Mode Toggle

**iOS:** Pill button toggling between mic and keyboard icons

**macOS Specification:**
- Segmented control in toolbar: [🎤 Voice] [⌨️ Text]
- Keyboard shortcut: ⌘⇧V to toggle
- Menu item: "Session > Voice Input" (checkmark when active)
- Push-to-talk option: Hold Space to record (configurable)

#### Message Input Area

**iOS:** TextEditor with placeholder, voice button, send button

**macOS Specification:**
- Multi-line NSTextView with placeholder
- Minimum height: 60pt, maximum: 200pt (resizable)
- Send: ⌘⏎ (not just ⏎ - Enter adds newline)
- Voice toggle: Toolbar segmented control
- Character count: Optional, shown when > 1000 chars
- Markdown preview: Toggle button (⌘P)

#### Command Menu

**iOS:** List with DisclosureGroup for nested commands

**macOS Specification:**
- Outline view with expandable groups
- Search field at top (⌘F to focus)
- Recent commands section (last 5)
- Context menu on items: Run, Copy Command, Add to Favorites
- Keyboard navigation: Arrow keys, Enter to run
- Double-click to execute

### I.6 Logging and Diagnostics

**iOS Pattern:**
- In-memory ring buffer (1000 lines)
- OSLogStore access for system logs
- Size-limited export (15KB)

**macOS Specification:**
- Same in-memory buffer for UI display
- Additionally: File-based logging to `~/Library/Logs/VoiceCode/`
- Log rotation: Daily, keep 7 days
- Export: Full logs or filtered by category
- Integration: "Help > Show Logs in Finder"

### I.7 Notification Handling

**iOS Pattern:**
- UNUserNotificationCenter with action buttons
- Categories: "message" with "Read Aloud" and "Dismiss" actions

**macOS Specification:**
- UNUserNotificationCenter (same API on macOS 10.14+)
- Categories: "message" with "Open", "Mark Read", "Dismiss"
- Badge: Unread count on dock icon
- Sound: System default, configurable in preferences
- Grouping: By session (thread identifier = session ID)

---

## Appendix J: Specific macOS View Specifications

### J.1 Main Window Layout

```
┌─────────────────────────────────────────────────────────────────────┐
│ ◉ ◉ ◉  Voice Code                        🟢 Connected    ⚙️  │
├─────────┬───────────────┬───────────────────────────────────────────┤
│ SIDEBAR │   CONTENT     │              DETAIL                       │
│ (220pt) │   (280pt)     │              (flex)                       │
│         │               │                                           │
│ ▼ Recent│ Sessions for  │  ┌─────────────────────────────────────┐ │
│   Sess1 │ /path/to/proj │  │ Message List (ScrollView)           │ │
│   Sess2 │               │  │                                     │ │
│         │ ┌───────────┐ │  │ User: How do I...                   │ │
│ ▼ Queue │ │ • Session1│ │  │                                     │ │
│   Sess3 │ │ • Session2│ │  │ Assistant: Here's how...            │ │
│         │ │ • Session3│ │  │                                     │ │
│ ▼ Proj  │ └───────────┘ │  └─────────────────────────────────────┘ │
│  /path1 │               │  ┌─────────────────────────────────────┐ │
│  /path2 │               │  │ [Voice] [Text]  │  [📎] [Send ⌘⏎]  │ │
│         │               │  │ ┌─────────────────────────────────┐ │ │
│         │               │  │ │ Type a message...               │ │ │
│         │               │  │ └─────────────────────────────────┘ │ │
│         │               │  └─────────────────────────────────────┘ │
├─────────┴───────────────┴───────────────────────────────────────────┤
│ 📊 3 sessions • Last sync: 12:34 PM          [Commands] [Resources] │
└─────────────────────────────────────────────────────────────────────┘
```

**Column Widths:**
- Sidebar: 220pt min, 300pt max, collapsible
- Content: 280pt min, 400pt max
- Detail: Flexible, 400pt min

**Window Constraints:**
- Minimum size: 900 × 600 pt
- Recommended size: 1200 × 800 pt

### J.2 Preferences Window Layout

```
┌────────────────────────────────────────────────────────┐
│ Preferences                                            │
├─────────────┬──────────────────────────────────────────┤
│             │                                          │
│  [General]  │  Server Configuration                    │
│  [Voice]    │  ─────────────────────────               │
│  [Sessions] │  Server URL: [________________]          │
│  [Advanced] │  Port:       [______]                    │
│             │                                          │
│             │  System Prompt                           │
│             │  ─────────────────────────               │
│             │  ┌────────────────────────┐              │
│             │  │                        │              │
│             │  │                        │              │
│             │  └────────────────────────┘              │
│             │                                          │
│             │  ☑️ Connect automatically on launch      │
│             │  ☑️ Show in menu bar                     │
│             │                                          │
└─────────────┴──────────────────────────────────────────┘
```

**Preference Panes:**

1. **General:**
   - Server URL and port
   - System prompt
   - Auto-connect on launch
   - Menu bar icon toggle

2. **Voice:**
   - Voice selection (same as iOS)
   - Speech rate slider
   - "All Premium Voices" toggle
   - Push-to-talk hotkey configuration
   - Test voice button

3. **Sessions:**
   - Recent sessions limit
   - Auto-add to priority queue toggles
   - Default working directory
   - Session cleanup options

4. **Advanced:**
   - Debug logging toggle
   - Log file location
   - Clear cache button
   - Reset to defaults button

### J.3 Command Output Window

```
┌─────────────────────────────────────────────────────────┐
│ Command Output: make build                    ◉ ◉ ◉    │
├─────────────────────────────────────────────────────────┤
│ $ make build                                            │
│ Building project...                                     │
│ Compiling main.swift                                    │
│ Compiling utils.swift                                   │
│ Linking...                                              │
│ ✅ Build succeeded (2.3s)                               │
│                                                         │
│ █                                                       │
│                                                         │
│                                                         │
├─────────────────────────────────────────────────────────┤
│ Exit: 0 • Duration: 2.3s              [Copy] [Re-run]   │
└─────────────────────────────────────────────────────────┘
```

**Features:**
- Monospace font (SF Mono or system monospace)
- ANSI color support
- Auto-scroll (toggleable)
- Search within output (⌘F)
- Copy all / Copy selection
- Re-run same command
- Clear output
- Window stays on top option

### J.4 Menu Bar Status Item

**Icon States:**
| State | Icon | Color |
|-------|------|-------|
| Connected | `waveform` | System default |
| Disconnected | `waveform.slash` | Red tint |
| Reconnecting | `arrow.trianglehead.2.clockwise` | Yellow tint, animated |
| Processing | `waveform` | Pulsing animation |

**Menu Structure:**
```
┌──────────────────────────────┐
│ Voice Code                   │
├──────────────────────────────┤
│ 🟢 Connected to localhost    │
│    Last sync: 12:34 PM       │
├──────────────────────────────┤
│ ▶ Recent Sessions            │
│   └─ Fix auth bug            │
│   └─ Add dark mode           │
│   └─ Refactor tests          │
├──────────────────────────────┤
│ New Session...          ⌘N   │
│ Open Voice Code         ⌘O   │
├──────────────────────────────┤
│ Start Voice Input      ⌃⌥V   │
├──────────────────────────────┤
│ Preferences...          ⌘,   │
│ Quit Voice Code         ⌘Q   │
└──────────────────────────────┘
```

**Behavior:**
- Left-click: Show menu
- Right-click: Same as left-click (macOS convention)
- Option-click: Show debug info (connection details, version)
- Menu bar icon hidden when "Show in menu bar" is off in preferences
- When hidden, app is still accessible via Dock

**Implementation:**
```swift
/// Connection state for UI display
enum ConnectionState {
    case connected
    case disconnected
    case reconnecting
}

class StatusBarController: ObservableObject {
    private var statusItem: NSStatusItem?
    @Published var isVisible: Bool = true {
        didSet { updateVisibility() }
    }

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(for: .disconnected)
    }

    func updateIcon(for state: ConnectionState) {
        let imageName: String
        switch state {
        case .connected: imageName = "waveform"
        case .disconnected: imageName = "waveform.slash"
        case .reconnecting: imageName = "arrow.trianglehead.2.clockwise"
        }
        statusItem?.button?.image = NSImage(systemSymbolName: imageName, accessibilityDescription: "Voice Code")
    }

    private func updateVisibility() {
        if isVisible {
            if statusItem == nil { setup() }
        } else {
            statusItem = nil  // Removes from menu bar
        }
    }
}
```

---

## Appendix K: Edge Cases and Limits

This appendix documents edge cases, limits, and recovery patterns found in the iOS implementation that must be preserved in the macOS port.

### K.1 Message Limits

**Per-Session Message Count (CoreData):**
- iOS limits CoreData storage to **50 messages per session**
- Older messages are pruned when limit exceeded
- Full history remains in backend JSONL files
- macOS should implement same limit for UI performance

**Message Display Truncation:**
- Messages > 500 characters show first 250 + last 250 chars
- Middle section replaced with "[... N characters omitted ...]"
- Full content available via long-press or detail view
- Implemented via cached `displayText` property on CDMessage

**Note:** iOS does not currently implement a line limit - truncation is character-based only.

```swift
// iOS truncation pattern (from CDMessage.swift)
// Shows first 250 + last 250 chars for messages over 500 chars
private static let truncationHalfLength = 250

var displayText: String {
    let truncationLength = Self.truncationHalfLength * 2  // 500

    if text.count <= truncationLength {
        return text
    } else {
        let head = String(text.prefix(Self.truncationHalfLength))
        let tail = String(text.suffix(Self.truncationHalfLength))
        let omittedCount = text.count - truncationLength
        return "\(head)\n\n[... \(omittedCount) characters omitted ...]\n\n\(tail)"
    }
}

var isTruncated: Bool {
    text.count > (Self.truncationHalfLength * 2)
}
```

### K.2 Log and Export Limits

**In-Memory Log Buffer:**
- Ring buffer: **1000 lines** maximum
- Oldest lines dropped when buffer full
- Used for in-app log viewer

**Log Export Size:**
- Maximum export: **15KB**
- Truncates oldest entries if exceeded
- Header preserved: app version, device info, timestamp

**Command Output:**
- Maximum output per command: **10MB**
- Streaming prevents memory issues for large outputs
- History files cleaned up after 7 days

### K.3 File Upload Handling

**Timeout:**
- Resource uploads timeout after **30 seconds**
- User notified on timeout with retry option

**Encoding:**
- Files encoded as **base64** for WebSocket transmission
- Content-type inferred from file extension

**Filename Conflicts:**
- Backend handles conflicts by appending timestamp
- Pattern: `filename-YYYYMMDDHHMMSS.ext` (e.g., `file-20251211143052.txt`)
- iOS tracks original vs uploaded name for display

```swift
// Conflict resolution pattern
func resolveFilenameConflict(_ original: String) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMddHHmmss"
    let timestamp = formatter.string(from: Date())
    let ext = (original as NSString).pathExtension
    let base = (original as NSString).deletingPathExtension
    return "\(base)-\(timestamp).\(ext)"
}
```

### K.4 CoreData Recovery

**Corrupt Store Handling:**
- iOS automatically detects corrupt `.sqlite` files
- Recovery: Delete store and recreate empty
- User loses local session list (can re-fetch from backend)
- Pattern implemented in `PersistenceController`

```swift
// Recovery pattern in PersistenceController.swift
private func loadPersistentStores() {
    container.loadPersistentStores { description, error in
        if let error = error as NSError? {
            // Check for corruption indicators
            if error.domain == NSSQLiteErrorDomain ||
               error.code == NSPersistentStoreIncompatibleVersionHashError {
                self.handleCorruptStore()
            }
        }
    }
}

private func handleCorruptStore() {
    let storeURL = container.persistentStoreDescriptions.first?.url
    if let url = storeURL {
        try? FileManager.default.removeItem(at: url)
        // Also remove -shm and -wal files
        try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
    }
    // Reload with fresh store
    loadPersistentStores()
}
```

### K.5 Session Locking Edge Cases

**Lock Acquisition:**
- Per-session locking (not global)
- Optimistic lock on send (before backend confirms)
- Lock released on: `turn_complete`, `error`, or manual unlock

**Stuck Lock Recovery:**
- UI shows "Tap to Unlock" after extended lock period
- Manual unlock available via context menu
- Backend lock auto-releases if WebSocket disconnects

**Multi-Session Parallel Work:**
- Users can work with multiple sessions simultaneously
- Each session has independent lock state
- Lock on session A doesn't block session B

```swift
// Lock state management
class SessionLockManager: ObservableObject {
    @Published private(set) var lockedSessions: Set<String> = []

    func lock(_ sessionId: String) {
        lockedSessions.insert(sessionId)
    }

    func unlock(_ sessionId: String) {
        lockedSessions.remove(sessionId)
    }

    func isLocked(_ sessionId: String) -> Bool {
        lockedSessions.contains(sessionId)
    }
}
```

### K.6 Network Recovery

**Reconnection Strategy:**
- Exponential backoff with jitter
- Maximum **20 attempts** (~17 minutes total)
- User notification after 3 failed attempts
- Manual reconnect always available

**Backoff Schedule:**
```
Attempt 1: 1s
Attempt 2: 2s
Attempt 3: 4s
Attempt 4: 8s
Attempt 5: 16s
Attempt 6: 32s
Attempt 7-20: 60s (capped)
```

**Post-Reconnection:**
- Auto-restore all session subscriptions
- Replay undelivered messages with acknowledgment
- Re-fetch recent sessions list

### K.7 Content Block Summarization

**Tool Use Blocks:**
- Display: "🔧 Using tool: [tool_name]"
- Full input/output hidden by default
- Expandable for debugging

**Tool Result Blocks:**
- Display: "✅ Tool result" or "❌ Tool error"
- Truncated preview of result content
- Full content in expandable detail

**Thinking Blocks:**
- Display: "💭 Thinking..." with duration
- Content hidden by default (can be verbose)
- Toggle to show full thinking process

```swift
/// Represents a content block from Claude's response (tool_use, tool_result, thinking, text)
struct ContentBlock {
    let type: String        // "tool_use", "tool_result", "thinking", "text"
    var name: String?       // Tool name for tool_use blocks
    var text: String?       // Text content for text blocks
    var isError: Bool?      // Error indicator for tool_result blocks
}

/// Truncate content for preview display
/// Returns (truncated text, was truncated)
private func truncatedContent(_ text: String, maxLength: Int = 100) -> (String, Bool) {
    if text.count <= maxLength {
        return (text, false)
    }
    return (String(text.prefix(maxLength)) + "...", true)
}

// Content block summarization
func summarizeContentBlock(_ block: ContentBlock) -> String {
    switch block.type {
    case "tool_use":
        return "🔧 Using tool: \(block.name ?? "unknown")"
    case "tool_result":
        let status = block.isError == true ? "❌" : "✅"
        return "\(status) Tool result"
    case "thinking":
        return "💭 Thinking..."
    case "text":
        return truncatedContent(block.text ?? "").0
    default:
        return "[\(block.type)]"
    }
}
```

### K.8 Server Change Handling

**Server URL Change:**
- Clears all local sessions (different server = different data)
- User warned before clearing
- Backend connection re-established to new server

**Implementation:**
```swift
func updateServerURL(_ newURL: String) {
    guard newURL != currentServerURL else { return }

    // Warn user
    let alert = NSAlert()
    alert.messageText = "Change Server?"
    alert.informativeText = "Changing servers will clear all local session data."
    alert.addButton(withTitle: "Change")
    alert.addButton(withTitle: "Cancel")

    if alert.runModal() == .alertFirstButtonReturn {
        clearAllSessions()
        currentServerURL = newURL
        reconnect()
    }
}
```

### K.9 Session Name Inference

**Name Source Priority:**
1. User-provided custom name
2. First message content (truncated)
3. Working directory basename
4. Session ID (fallback)

**First Message Inference:**
- Takes first 50 characters of first user message
- Strips newlines, collapses whitespace
- Falls back to next priority if message is system/tool content

```swift
func inferSessionName(from session: CDBackendSession) -> String {
    // 1. Custom name
    if let name = session.displayName, !name.isEmpty {
        return name
    }

    // 2. First message
    if let firstMessage = session.messages?.first as? CDMessage,
       firstMessage.role == "user",
       let text = firstMessage.text, !text.isEmpty {
        let cleaned = text
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(50))
    }

    // 3. Working directory
    if let dir = session.workingDirectory, !dir.isEmpty {
        return (dir as NSString).lastPathComponent
    }

    // 4. Session ID
    return session.id.uuidString.lowercased().prefix(8).description
}
```

### K.10 Render Loop Detection

**iOS Protection:**
- Threshold: **50 renders per second**
- Triggers warning log and circuit breaker
- Prevents CPU/battery drain from SwiftUI re-evaluation loops

**Common Causes:**
- Publishing state changes during view body evaluation
- Binding updates triggering parent re-renders
- Timer-based updates without proper debouncing

**macOS Implementation:**
```swift
class RenderLoopDetector {
    private var renderCount = 0
    private var lastResetTime = Date()
    private let threshold = 50
    private let windowSeconds: TimeInterval = 1.0

    func recordRender() -> Bool {
        let now = Date()
        if now.timeIntervalSince(lastResetTime) > windowSeconds {
            renderCount = 0
            lastResetTime = now
        }

        renderCount += 1

        if renderCount > threshold {
            logger.warning("⚠️ Render loop detected: \(renderCount) renders/sec")
            return true // Loop detected
        }
        return false
    }
}

// Logger setup (using os.Logger)
private let logger = Logger(subsystem: "dev.910labs.voice-code", category: "ui")
```

### K.11 Optimistic Operations

**Optimistic Message Creation:**
- Message added to UI immediately on send
- Placeholder ID until backend confirms
- Reconciliation on backend response (update ID, handle failure)

**Optimistic Lock:**
- Session locked in UI immediately on send
- Before backend `ack` arrives
- Prevents double-send on rapid taps

**Rollback Pattern:**
```swift
func sendMessage(_ text: String, to session: CDBackendSession) {
    // Optimistic: Add to UI
    let optimisticMessage = createOptimisticMessage(text: text, session: session)

    // Optimistic: Lock session
    lockManager.lock(session.claudeSessionId ?? "")

    // Send to backend
    client.send(prompt: text, sessionId: session.claudeSessionId) { result in
        switch result {
        case .success(let response):
            // Reconcile: Update message with real ID/content
            reconcileMessage(optimisticMessage, with: response)
        case .failure(let error):
            // Rollback: Remove optimistic message, unlock
            rollbackMessage(optimisticMessage)
            lockManager.unlock(session.claudeSessionId ?? "")
            showError(error)
        }
    }
}
```

### K.12 Audio Session Edge Cases (iOS-Specific)

**Note:** These are iOS-specific and don't apply to macOS, but documented for completeness.

- Silent mode handling via `.ambient` vs `.playback` category
- Screen lock continuation via keep-alive timer
- Interruption handling (calls, other apps)
- Route change handling (headphones, Bluetooth)

macOS audio does not have these constraints - system audio plays regardless of any "silent mode" and apps continue audio when display sleeps.

---

## Appendix L: Threading and Concurrency Patterns

This appendix documents critical threading patterns that must be followed to avoid crashes and data corruption.

### L.1 CoreData Background Context Threading

**CRITICAL:** CoreData objects are not thread-safe. Objects fetched in one context cannot be used in another.

#### Correct Pattern: Background Task with Notification

```swift
// ✅ CORRECT: All work in background context, notify main thread after save
func handleSessionList(_ sessions: [[String: Any]]) async {
    await withCheckedContinuation { continuation in
        persistenceController.performBackgroundTask { backgroundContext in
            // ALL CoreData work happens here on background thread
            for sessionData in sessions {
                self.upsertSession(sessionData, in: backgroundContext)
            }

            do {
                if backgroundContext.hasChanges {
                    try backgroundContext.save()

                    // Notify AFTER save completes
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .sessionListDidUpdate,
                            object: nil
                        )
                    }
                }
            } catch {
                logger.error("Failed to save: \(error)")
            }

            continuation.resume()
        }
    }
}
```

#### Incorrect Patterns (DO NOT USE)

```swift
// ❌ WRONG: Passing CoreData objects across threads
persistenceController.performBackgroundTask { backgroundContext in
    let session = fetchSession(in: backgroundContext)

    DispatchQueue.main.async {
        // CRASH: session belongs to backgroundContext, not viewContext
        self.displaySession(session)
    }
}

// ❌ WRONG: Modifying view context from background
persistenceController.performBackgroundTask { backgroundContext in
    // CRASH: viewContext can only be modified on main thread
    let session = CDBackendSession(context: viewContext)
}

// ❌ WRONG: Publishing before save completes
persistenceController.performBackgroundTask { backgroundContext in
    // Notify before save - observers see inconsistent state
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .dataChanged, object: nil)
    }

    try backgroundContext.save()  // Save happens AFTER notification
}
```

#### Cross-Context Object Lookup

When you need to use an object from a different context, fetch by ID:

```swift
// ✅ CORRECT: Look up by ID in the correct context
persistenceController.performBackgroundTask { backgroundContext in
    // Get ID from main context object (IDs are thread-safe)
    let sessionId = mainContextSession.objectID

    // Fetch fresh object in background context
    if let backgroundSession = try? backgroundContext.existingObject(with: sessionId) as? CDBackendSession {
        // Safe to modify backgroundSession here
    }
}
```

### L.2 Merge Notification Setup

**CRITICAL:** SwiftUI `@FetchRequest` updates must happen on main thread to prevent AttributeGraph crashes.

```swift
// In PersistenceController.init()
NotificationCenter.default.addObserver(
    forName: .NSManagedObjectContextDidSave,
    object: nil,
    queue: .main  // CRITICAL: .main ensures merges happen on main thread
) { [weak container] notification in
    guard let container = container,
          let context = notification.object as? NSManagedObjectContext,
          context != container.viewContext,
          context.persistentStoreCoordinator == container.viewContext.persistentStoreCoordinator
    else { return }

    container.viewContext.perform {
        container.viewContext.mergeChanges(fromContextDidSave: notification)
    }
}
```

### L.3 Swift Package CoreData Bundle

When CoreData model is in a Swift Package, the bundle lookup differs:

```swift
// ❌ WRONG: Bundle.main doesn't contain Swift Package resources
let container = NSPersistentContainer(name: "VoiceCode")

// ✅ CORRECT: Use Bundle.module for Swift Package resources
guard let modelURL = Bundle.module.url(forResource: "VoiceCode", withExtension: "momd"),
      let model = NSManagedObjectModel(contentsOf: modelURL) else {
    fatalError("Failed to load CoreData model from package")
}

let container = NSPersistentContainer(name: "VoiceCode", managedObjectModel: model)
```

**Package.swift resource declaration:**
```swift
targets: [
    .target(
        name: "VoiceCodeShared",
        resources: [
            .process("CoreData/VoiceCode.xcdatamodeld")
        ]
    ),
]
```

### L.4 Notification Names

Define custom notification names for app-wide communication:

```swift
extension Notification.Name {
    // Session updates
    static let sessionListDidUpdate = Notification.Name("sessionListDidUpdate")
    static let priorityQueueChanged = Notification.Name("priorityQueueChanged")

    // Connection state
    static let connectionRestored = Notification.Name("connectionRestored")
    static let connectionLost = Notification.Name("connectionLost")

    // Data sync
    static let requestFullSync = Notification.Name("requestFullSync")
    static let dataChanged = Notification.Name("dataChanged")
}
```

---

## Appendix M: Debounce Coordination

This appendix documents the debouncing system and when to flush immediately.

### M.1 Debounce Timings

| Component | Delay | Purpose |
|-----------|-------|---------|
| VoiceCodeClient property updates | 100ms | Batch @Published updates to prevent render storms |
| DraftManager saves | 300ms | Avoid excessive UserDefaults writes during typing |
| AppSettings saves | 500ms | Avoid excessive saves during text field editing |
| Auto-scroll | 300ms | Allow layout to settle before scrolling |

### M.2 VoiceCodeClient Debounce Implementation

```swift
private var pendingUpdates: [String: Any] = [:]
private var debounceWorkItem: DispatchWorkItem?
private let debounceDelay: TimeInterval = 0.1  // 100ms

private func scheduleUpdate(key: String, value: Any) {
    pendingUpdates[key] = value
    debounceWorkItem?.cancel()

    let workItem = DispatchWorkItem { [weak self] in
        self?.applyPendingUpdates()
    }
    debounceWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + debounceDelay, execute: workItem)
}

private func flushPendingUpdates() {
    debounceWorkItem?.cancel()
    debounceWorkItem = nil
    applyPendingUpdates()
}
```

### M.3 Flush Checklist

**ALWAYS call `flushPendingUpdates()` for these critical operations:**

| Operation | Why Flush |
|-----------|-----------|
| Session lock state change | UI must reflect lock immediately |
| Session unlock state change | User needs to know they can type |
| Connection state change | User needs immediate feedback |
| Error state change | Errors must not be delayed |
| WebSocket disconnect | All locks must clear immediately |

```swift
// ✅ CORRECT: Flush after critical state changes
case "turn_complete":
    var updatedSessions = getCurrentValue(for: "lockedSessions", current: lockedSessions)
    updatedSessions.remove(sessionId)
    scheduleUpdate(key: "lockedSessions", value: updatedSessions)
    flushPendingUpdates()  // User can now type - don't delay

// ❌ WRONG: No flush - user sees stale locked state for 100ms
case "turn_complete":
    var updatedSessions = getCurrentValue(for: "lockedSessions", current: lockedSessions)
    updatedSessions.remove(sessionId)
    scheduleUpdate(key: "lockedSessions", value: updatedSessions)
    // Missing flush - lock indicator stays 100ms too long
```

### M.4 Getting Current Value During Debounce

Always check pending updates before current state:

```swift
private func getCurrentValue<T>(for key: String, current: T) -> T {
    if let pending = pendingUpdates[key] as? T {
        return pending
    }
    return current
}

// Usage - prevent losing concurrent updates
var updatedSessions = getCurrentValue(for: "lockedSessions", current: lockedSessions)
updatedSessions.remove(sessionId)
scheduleUpdate(key: "lockedSessions", value: updatedSessions)
```

---

## Appendix N: Session Lock State Machine

This appendix documents all session lock states and transitions.

### N.1 State Diagram

```
                                    ┌─────────────────┐
                                    │    UNLOCKED     │
                                    │  (can send)     │
                                    └────────┬────────┘
                                             │
                     ┌───────────────────────┼───────────────────────┐
                     │                       │                       │
              User sends prompt       Backend receives          WebSocket
              (optimistic lock)       concurrent prompt         disconnects
                     │                       │                       │
                     ▼                       ▼                       │
            ┌─────────────────┐     ┌─────────────────┐              │
            │ LOCKED (local)  │     │ LOCKED (remote) │              │
            │ (processing)    │     │ (session_locked)│              │
            └────────┬────────┘     └────────┬────────┘              │
                     │                       │                       │
     ┌───────────────┼───────────────┐       │                       │
     │               │               │       │                       │
turn_complete     error          timeout   Backend                   │
  received       received       (manual)  unlocks                    │
     │               │               │       │                       │
     ▼               ▼               ▼       ▼                       │
     └───────────────┴───────────────┴───────┴───────────────────────┘
                                    │
                                    ▼
                            ┌─────────────────┐
                            │    UNLOCKED     │
                            └─────────────────┘
```

### N.2 Unlock Triggers (Complete List)

| Trigger | Source | Notes |
|---------|--------|-------|
| `turn_complete` message | Backend | Normal completion |
| `error` message with `session_id` | Backend | Error during processing |
| `response` message (success) | Backend | Response includes implicit unlock |
| WebSocket disconnect | Client | Clear ALL locks immediately |
| WebSocket connection failure | Client | Clear ALL locks immediately |
| Manual unlock tap | User | "Tap to Unlock" UI action |
| App termination | System | Locks not persisted |

### N.3 Implementation Requirements

```swift
// All unlock points in VoiceCodeClient
case "turn_complete":
    if let sessionId = json["session_id"] as? String {
        unlockSession(sessionId)
        flushPendingUpdates()
    }

case "response":
    if let sessionId = json["session_id"] as? String {
        unlockSession(sessionId)
    }

case "error":
    if let sessionId = json["session_id"] as? String {
        unlockSession(sessionId)
    }

// On disconnect - clear ALL
func disconnect() {
    scheduleUpdate(key: "lockedSessions", value: Set<String>())
    flushPendingUpdates()
}

// On connection failure - clear ALL
case .failure(let error):
    scheduleUpdate(key: "lockedSessions", value: Set<String>())
    flushPendingUpdates()
```

### N.4 Empty String Edge Case

Sessions may not have a Claude session ID until the first prompt completes:

```swift
// ❌ WRONG: Lock with empty string
let sessionId = session.claudeSessionId ?? ""
lockedSessions.insert(sessionId)  // Inserts empty string

// ✅ CORRECT: Guard against empty/nil
if let sessionId = session.claudeSessionId, !sessionId.isEmpty {
    lockedSessions.insert(sessionId)
}
```

---

## Appendix O: Priority Queue Renormalization

### O.1 The Precision Problem

After many drag-drop reorder operations, `priorityOrder` values converge:

```
Initial:      1.0, 2.0, 3.0, 4.0
After drags:  1.5, 1.75, 1.875, 1.9375
More drags:   1.5, 1.625, 1.6875, 1.71875
Eventually:   1.5, 1.5625, 1.5625, 1.5625  // Precision lost!
```

### O.2 Renormalization Trigger (Design Change)

**Add automatic renormalization when minimum gap falls below threshold:**

```swift
extension CDBackendSession {
    /// Minimum gap between priorityOrder values before triggering renormalization
    static let minPriorityOrderGap: Double = 0.001

    /// Check if priority queue needs renormalization
    static func needsRenormalization(context: NSManagedObjectContext) -> Bool {
        let request: NSFetchRequest<CDBackendSession> = CDBackendSession.fetchRequest()
        request.predicate = NSPredicate(format: "isInPriorityQueue == YES")
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \CDBackendSession.priority, ascending: true),
            NSSortDescriptor(keyPath: \CDBackendSession.priorityOrder, ascending: true)
        ]

        guard let sessions = try? context.fetch(request), sessions.count > 1 else {
            return false
        }

        // Check gaps within each priority level
        var currentPriority: Int32 = -1
        var lastOrder: Double = 0.0

        for session in sessions {
            if session.priority != currentPriority {
                currentPriority = session.priority
                lastOrder = session.priorityOrder
            } else {
                let gap = session.priorityOrder - lastOrder
                if gap < minPriorityOrderGap && gap > 0 {
                    return true
                }
                lastOrder = session.priorityOrder
            }
        }

        return false
    }

    /// Renormalize priority order values to integers within each priority level
    static func renormalizePriorityQueue(context: NSManagedObjectContext) {
        let request: NSFetchRequest<CDBackendSession> = CDBackendSession.fetchRequest()
        request.predicate = NSPredicate(format: "isInPriorityQueue == YES")
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \CDBackendSession.priority, ascending: true),
            NSSortDescriptor(keyPath: \CDBackendSession.priorityOrder, ascending: true)
        ]

        guard let sessions = try? context.fetch(request) else { return }

        var currentPriority: Int32 = -1
        var orderCounter: Double = 1.0

        for session in sessions {
            if session.priority != currentPriority {
                currentPriority = session.priority
                orderCounter = 1.0
            }

            session.priorityOrder = orderCounter
            orderCounter += 1.0
        }

        try? context.save()
        // Logger setup: private let logger = Logger(subsystem: "dev.910labs.voice-code", category: "priorityQueue")
        logger.info("✅ Renormalized priority queue - all orders reset to integers")
    }
}
```

### O.3 Trigger Points

Call `needsRenormalization()` and `renormalizePriorityQueue()` at:
1. After every `reorderSession()` call
2. On app launch (background task)
3. Before priority queue view appears

### O.4 Testing Requirements

```swift
func testRenormalizationDetection() {
    // Create sessions with decreasing gaps
    let session1 = createSession(priority: 1, order: 1.0)
    let session2 = createSession(priority: 1, order: 1.0005)  // Below threshold
    let session3 = createSession(priority: 1, order: 1.001)

    XCTAssertTrue(CDBackendSession.needsRenormalization(context: context))
}

func testRenormalizationFixes() {
    // Create sessions with tiny gaps
    createSession(priority: 1, order: 1.5)
    createSession(priority: 1, order: 1.5001)
    createSession(priority: 1, order: 1.50015)

    CDBackendSession.renormalizePriorityQueue(context: context)

    // Verify orders are now integers
    let sessions = fetchAllPriorityQueueSessions()
    XCTAssertEqual(sessions[0].priorityOrder, 1.0)
    XCTAssertEqual(sessions[1].priorityOrder, 2.0)
    XCTAssertEqual(sessions[2].priorityOrder, 3.0)
}

func testRepeatedReorderingTriggersRenormalization() {
    // Simulate 50 drag operations
    for _ in 0..<50 {
        simulateDragReorder()
    }

    // Should have triggered renormalization at some point
    XCTAssertFalse(CDBackendSession.needsRenormalization(context: context))
}
```

---

## Appendix P: FetchRequest Safety Checklist

### P.1 Animation Parameter

**ALWAYS set `animation: nil` on FetchRequest to prevent render storms:**

```swift
// ✅ CORRECT
@FetchRequest(
    fetchRequest: CDMessage.fetchMessages(sessionId: session.id),
    animation: nil  // CRITICAL
) private var messages: FetchedResults<CDMessage>

// ❌ WRONG - will cause render storms on every CoreData change
@FetchRequest(
    fetchRequest: CDMessage.fetchMessages(sessionId: session.id)
    // animation defaults to .default - BAD!
) private var messages: FetchedResults<CDMessage>
```

### P.2 Code Review Checklist

When reviewing PRs, check every `@FetchRequest` for:

- [ ] `animation: nil` is explicitly set
- [ ] Fetch request includes `returnsObjectsAsFaults = false` for frequently accessed properties
- [ ] Fetch request includes `includesPropertyValues = true`
- [ ] Sort descriptors are defined (unsorted results cause unpredictable behavior)
- [ ] Predicate is efficient (indexed fields)

### P.3 Predicate Stability

Avoid predicates that depend on frequently-changing state:

```swift
// ❌ WRONG - predicate changes on every selection, triggers full reload
@FetchRequest(
    fetchRequest: makeFetchRequest(selectedId: selectedSession?.id)
)

// ✅ CORRECT - stable predicate, filter in view
@FetchRequest(
    fetchRequest: CDMessage.fetchAllMessages()
)
// Then filter: messages.filter { $0.sessionId == selectedSession?.id }
```

---

## Appendix Q: UUID Case Sensitivity

### Q.1 The Problem

Swift `UUID.uuidString` returns uppercase, but the backend expects lowercase:

```swift
let uuid = UUID()
print(uuid.uuidString)  // "A1B2C3D4-E5F6-7890-ABCD-EF1234567890" (uppercase!)
```

### Q.2 Compile-Time Safety Pattern

Create a type-safe wrapper or extension:

```swift
extension UUID {
    /// Lowercase string representation for backend communication
    var lowercasedString: String {
        uuidString.lowercased()
    }
}

extension CDBackendSession {
    /// Session ID in backend-compatible format (lowercase)
    var backendSessionId: String {
        id.lowercasedString
    }
}
```

### Q.3 Usage Checklist

Always use `.lowercased()` or `.lowercasedString` when:
- [ ] Sending session IDs to WebSocket
- [ ] Logging session IDs
- [ ] Comparing session IDs
- [ ] Storing in `lockedSessions` set
- [ ] Posting NotificationCenter userInfo

```swift
// ✅ CORRECT
client.subscribe(sessionId: session.id.lowercasedString)
lockedSessions.insert(session.backendSessionId)
userInfo["sessionId"] = session.id.uuidString.lowercased()

// ❌ WRONG
client.subscribe(sessionId: session.id.uuidString)  // Uppercase!
```

---

## Appendix R: Auto-Scroll Fix

### R.1 The Problem

Current implementation captures message reference at scroll time, not trigger time:

```swift
// ❌ WRONG - message may have changed during 300ms delay
.onChange(of: messages.count) { oldCount, newCount in
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        // 300ms later - messages array may have new items
        guard let lastMessage = self.messages.last else { return }
        proxy.scrollTo(lastMessage.id, anchor: .bottom)
    }
}
```

### R.2 Fixed Implementation (Design Change)

Capture the message ID at trigger time:

```swift
// ✅ CORRECT - capture target at trigger time
.onChange(of: messages.count) { oldCount, newCount in
    guard newCount > oldCount, autoScrollEnabled else { return }

    // Capture the target ID NOW, before delay
    guard let targetId = messages.last?.id else { return }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        guard self.autoScrollEnabled else { return }
        // Use captured ID, not current messages.last
        proxy.scrollTo(targetId, anchor: .bottom)
    }
}
```

### R.3 Additional Safeguard

Validate the target still exists:

```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
    guard self.autoScrollEnabled else { return }
    // Verify message still exists (may have been pruned)
    guard messages.contains(where: { $0.id == targetId }) else { return }
    proxy.scrollTo(targetId, anchor: .bottom)
}
```

### R.4 Testing Requirements

```swift
func testAutoScrollCapturesMessageIdAtTriggerTime() async {
    // Setup: conversation with 5 messages
    let initialMessages = createMessages(count: 5)
    let view = ConversationView(messages: initialMessages)

    // Act: Add new message, then add another during 300ms delay
    let firstNewMessage = addMessage()
    let capturedId = firstNewMessage.id

    // Add second message during the delay
    try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
    let secondNewMessage = addMessage()

    // Wait for scroll to complete
    try await Task.sleep(nanoseconds: 300_000_000)  // 300ms

    // Assert: Should have scrolled to first new message, not second
    XCTAssertEqual(view.lastScrollTarget, capturedId)
}

func testAutoScrollHandlesPrunedMessage() async {
    // Setup: conversation at max capacity
    let messages = createMessages(count: 50)
    let view = ConversationView(messages: messages)

    // Act: Add message (triggers pruning of oldest)
    let newMessage = addMessage()

    // Prune before scroll executes
    pruneOldestMessage()

    // Wait for scroll
    try await Task.sleep(nanoseconds: 400_000_000)

    // Assert: No crash, scroll skipped gracefully
    XCTAssertTrue(view.scrollCompleted || view.scrollSkipped)
}
```

---

## Appendix S: Smart Speaking for macOS

### S.1 The Problem

iOS uses single active session tracking, but macOS can have multiple visible conversations.

### S.2 macOS Model (Design Change)

Track active session per-window using window focus:

```swift
class WindowFocusManager: ObservableObject {
    static let shared = WindowFocusManager()

    /// Currently focused window's session ID (only one can be focused)
    @Published private(set) var focusedSessionId: UUID?

    /// Set when a conversation window becomes key window
    func windowDidBecomeKey(sessionId: UUID) {
        focusedSessionId = sessionId
    }

    /// Clear when conversation window resigns key
    func windowDidResignKey(sessionId: UUID) {
        if focusedSessionId == sessionId {
            focusedSessionId = nil
        }
    }

    /// Check if this session should auto-speak
    func shouldSpeak(sessionId: UUID) -> Bool {
        focusedSessionId == sessionId
    }
}
```

### S.3 Integration with SessionSyncManager

```swift
func handleSessionUpdated(sessionId: String, messages: [[String: Any]]) {
    // ... process messages ...

    // Auto-speak only for focused window
    if let sessionUUID = UUID(uuidString: sessionId),
       WindowFocusManager.shared.shouldSpeak(sessionId: sessionUUID),
       let newAssistantMessage = extractNewAssistantMessage(from: messages) {
        voiceOutputManager?.speak(newAssistantMessage)
    }
}
```

### S.4 Window Lifecycle Integration

```swift
struct ConversationDetailView: View {
    let sessionId: UUID
    @State private var hostingWindow: NSWindow?

    var body: some View {
        // ... content ...
        .background(WindowAccessor(window: $hostingWindow))
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if let window = notification.object as? NSWindow,
               window == hostingWindow {
                WindowFocusManager.shared.windowDidBecomeKey(sessionId: sessionId)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            if let window = notification.object as? NSWindow,
               window == hostingWindow {
                WindowFocusManager.shared.windowDidResignKey(sessionId: sessionId)
            }
        }
    }
}

/// Helper to access the hosting NSWindow from SwiftUI
struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            self.window = view.window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            self.window = nsView.window
        }
    }
}
```

### S.5 Testing Requirements

```swift
func testOnlyFocusedWindowSpeaks() {
    // Setup: Two windows with different sessions
    let session1 = UUID()
    let session2 = UUID()

    // Window 1 becomes key
    WindowFocusManager.shared.windowDidBecomeKey(sessionId: session1)

    // Assert: Only session1 should speak
    XCTAssertTrue(WindowFocusManager.shared.shouldSpeak(sessionId: session1))
    XCTAssertFalse(WindowFocusManager.shared.shouldSpeak(sessionId: session2))
}

func testFocusTransferBetweenWindows() {
    let session1 = UUID()
    let session2 = UUID()

    // Window 1 focused
    WindowFocusManager.shared.windowDidBecomeKey(sessionId: session1)
    XCTAssertTrue(WindowFocusManager.shared.shouldSpeak(sessionId: session1))

    // Window 2 becomes focused
    WindowFocusManager.shared.windowDidResignKey(sessionId: session1)
    WindowFocusManager.shared.windowDidBecomeKey(sessionId: session2)

    // Now session2 should speak
    XCTAssertFalse(WindowFocusManager.shared.shouldSpeak(sessionId: session1))
    XCTAssertTrue(WindowFocusManager.shared.shouldSpeak(sessionId: session2))
}

func testNoWindowFocusedMeansNoSpeaking() {
    let session1 = UUID()

    // Focus then unfocus
    WindowFocusManager.shared.windowDidBecomeKey(sessionId: session1)
    WindowFocusManager.shared.windowDidResignKey(sessionId: session1)

    // No session should speak
    XCTAssertFalse(WindowFocusManager.shared.shouldSpeak(sessionId: session1))
    XCTAssertNil(WindowFocusManager.shared.focusedSessionId)
}
```

---

## Appendix T: Render Loop Detection

### T.1 Configurable Threshold (Design Change)

Make threshold configurable and higher for macOS:

```swift
class RenderLoopDetector {
    static let shared = RenderLoopDetector()

    private var renderCount = 0
    private var windowStart = Date()
    private let windowSize: TimeInterval = 1.0

    /// Callback invoked when render loop is detected
    var onLoopDetected: (() -> Void)?

    #if os(macOS)
    let threshold = 100  // macOS: higher threshold for 120Hz displays
    #else
    let threshold = 50   // iOS: original threshold
    #endif

    func recordRender() {
        let now = Date()
        if now.timeIntervalSince(windowStart) > windowSize {
            if renderCount > threshold {
                logger.error("🚨 RENDER LOOP DETECTED: \(self.renderCount) renders in 1 second!")
                onLoopDetected?()
            }
            renderCount = 1
            windowStart = now
        } else {
            renderCount += 1
        }
    }
}
```

### T.2 Debug-Only in Production

Consider making this debug-only to avoid performance overhead:

```swift
#if DEBUG
private let renderDetector = RenderLoopDetector.shared
#endif

var body: some View {
    #if DEBUG
    renderDetector.recordRender()
    #endif
    // ... view content ...
}
```

### T.3 Testing Requirements

```swift
func testThresholdIsHigherOnMacOS() {
    #if os(macOS)
    XCTAssertEqual(RenderLoopDetector.shared.threshold, 100)
    #else
    XCTAssertEqual(RenderLoopDetector.shared.threshold, 50)
    #endif
}

func testDetectsRenderLoop() {
    let detector = RenderLoopDetector()
    var loopDetected = false
    detector.onLoopDetected = { loopDetected = true }

    // Simulate 150 renders in 1 second
    for _ in 0..<150 {
        detector.recordRender()
    }

    XCTAssertTrue(loopDetected)
}

func testDoesNotFalsePositiveOnNormalScrolling() {
    let detector = RenderLoopDetector()
    var loopDetected = false
    detector.onLoopDetected = { loopDetected = true }

    // Simulate 60 renders (normal 60fps scrolling)
    for _ in 0..<60 {
        detector.recordRender()
    }

    XCTAssertFalse(loopDetected)
}
```

---

## Appendix U: First-Run Onboarding

### U.1 Detection

```swift
class OnboardingManager: ObservableObject {
    @Published var needsOnboarding: Bool
    @Published var isServerConfigured: Bool

    init() {
        needsOnboarding = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        isServerConfigured = !AppSettings.shared.serverURL.isEmpty
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        needsOnboarding = false
    }
}
```

### U.2 Onboarding Flow (Design Change)

```swift
struct VoiceCodeDesktopApp: App {
    @StateObject private var onboarding = OnboardingManager()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            if onboarding.needsOnboarding {
                OnboardingView(onboarding: onboarding, settings: settings)
            } else {
                MainWindowView()
            }
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var onboarding: OnboardingManager
    @ObservedObject var settings: AppSettings
    @State private var step: OnboardingStep = .welcome
    @State private var isTestingConnection = false
    @State private var connectionError: String?

    enum OnboardingStep {
        case welcome
        case serverConfig
        case testConnection
        case voicePermissions  // NEW: Request microphone/speech permissions
        case success
    }

    var body: some View {
        VStack(spacing: 20) {
            switch step {
            case .welcome:
                WelcomeStep(onContinue: { step = .serverConfig })

            case .serverConfig:
                ServerConfigStep(
                    serverURL: $settings.serverURL,
                    serverPort: $settings.serverPort,
                    onTest: testConnection,
                    onSkip: skipOnboarding
                )

            case .testConnection:
                TestConnectionStep(
                    isLoading: isTestingConnection,
                    error: connectionError,
                    onRetry: testConnection,
                    onSkip: skipOnboarding
                )

            case .voicePermissions:
                VoicePermissionsStep(
                    onContinue: { step = .success },
                    onSkip: { step = .success }
                )

            case .success:
                SuccessStep(onFinish: {
                    onboarding.completeOnboarding()
                })
            }
        }
        .frame(width: 500, height: 400)
        .interactiveDismissDisabled()  // Cannot dismiss until complete
    }

    private func testConnection() {
        isTestingConnection = true
        connectionError = nil
        step = .testConnection

        // Test WebSocket connection
        let testClient = VoiceCodeClient(serverURL: settings.fullServerURL)
        testClient.connect()

        // Wait for connection with timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            isTestingConnection = false
            if testClient.isConnected {
                step = .voicePermissions  // Proceed to voice permissions
            } else {
                connectionError = "Could not connect to server. Please check URL and port."
                step = .serverConfig
            }
            testClient.disconnect()
        }
    }

    private func skipOnboarding() {
        onboarding.completeOnboarding()
        // Show persistent banner that server is not configured
    }
}

struct VoicePermissionsStep: View {
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var microphoneGranted = false
    @State private var speechGranted = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            Text("Voice Input")
                .font(.title)

            Text("Voice Code uses your microphone for speech-to-text input. Grant permissions to enable voice features.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                PermissionRow(
                    title: "Microphone",
                    description: "Required for voice input",
                    isGranted: microphoneGranted,
                    onRequest: requestMicrophone
                )

                PermissionRow(
                    title: "Speech Recognition",
                    description: "Required for transcription",
                    isGranted: speechGranted,
                    onRequest: requestSpeechRecognition
                )
            }
            .padding()

            HStack {
                Button("Skip for Now") { onSkip() }
                    .buttonStyle(.plain)

                Spacer()

                Button("Continue") { onContinue() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                microphoneGranted = granted
            }
        }
    }

    private func requestSpeechRecognition() {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                speechGranted = (status == .authorized)
            }
        }
    }
}

struct PermissionRow: View {
    let title: String
    let description: String
    let isGranted: Bool
    let onRequest: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Button("Grant") { onRequest() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}
```

**Required Imports for VoicePermissionsStep:**
```swift
import AVFoundation  // For AVCaptureDevice
import Speech        // For SFSpeechRecognizer
```

**Onboarding Step Views (Stubs):**
```swift
struct WelcomeStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.accentColor)

            Text("Welcome to Voice Code")
                .font(.largeTitle)

            Text("Voice-powered AI coding assistant for your projects.")
                .foregroundColor(.secondary)

            Button("Get Started") { onContinue() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}

struct ServerConfigStep: View {
    @Binding var serverURL: String
    @Binding var serverPort: String
    let onTest: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Connect to Backend")
                .font(.title)

            Form {
                TextField("Server URL", text: $serverURL)
                    .textFieldStyle(.roundedBorder)
                TextField("Port", text: $serverPort)
                    .textFieldStyle(.roundedBorder)
            }
            .formStyle(.grouped)

            HStack {
                Button("Skip") { onSkip() }
                    .buttonStyle(.plain)
                Spacer()
                Button("Test Connection") { onTest() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct TestConnectionStep: View {
    let isLoading: Bool
    let error: String?
    let onRetry: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            if isLoading {
                ProgressView()
                    .scaleEffect(1.5)
                Text("Testing connection...")
            } else if let error = error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.orange)
                Text(error)
                    .foregroundColor(.secondary)
                HStack {
                    Button("Skip") { onSkip() }
                    Button("Retry") { onRetry() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

struct SuccessStep: View {
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.green)

            Text("You're All Set!")
                .font(.largeTitle)

            Text("Voice Code is ready to use.")
                .foregroundColor(.secondary)

            Button("Start Using Voice Code") { onFinish() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}
```

### U.3 Persistent Banner for Unconfigured Server

```swift
struct MainWindowView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            if !settings.isServerConfigured {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Server not configured")
                    Spacer()
                    Button("Configure") {
                        // Open preferences
                        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                    }
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
            }

            // Main content
            NavigationSplitView { /* ... */ }
        }
    }
}
```

### U.4 Testing Requirements

```swift
func testFirstLaunchShowsOnboarding() {
    UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")

    let manager = OnboardingManager()

    XCTAssertTrue(manager.needsOnboarding)
}

func testSecondLaunchSkipsOnboarding() {
    UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")

    let manager = OnboardingManager()

    XCTAssertFalse(manager.needsOnboarding)
}

func testCompleteOnboardingSetsFlag() {
    UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
    let manager = OnboardingManager()

    manager.completeOnboarding()

    XCTAssertFalse(manager.needsOnboarding)
    XCTAssertTrue(UserDefaults.standard.bool(forKey: "hasCompletedOnboarding"))
}

func testSkipOnboardingShowsBanner() {
    let settings = AppSettings()
    settings.serverURL = ""  // Not configured

    // Skip without configuring
    let manager = OnboardingManager()
    manager.completeOnboarding()

    XCTAssertFalse(settings.isServerConfigured)
    // Banner should be visible
}

func testConnectionTestTimeout() async throws {
    let settings = AppSettings()
    settings.serverURL = "ws://invalid-host-that-will-timeout.local"

    let testClient = VoiceCodeClient(serverURL: settings.fullServerURL)
    testClient.connect()

    // Wait for connection timeout (5 seconds + buffer)
    try await Task.sleep(nanoseconds: 6_000_000_000)

    // Connection should have failed
    XCTAssertFalse(testClient.isConnected)
    testClient.disconnect()
}
```

---

## Appendix V: Backend Connection State Machine

### V.1 State Diagram

```
                         ┌───────────────────────────────────────────────────────┐
                         │                                                       │
                         ▼                                                       │
    ┌─────────────────────────────────────┐                                      │
    │           DISCONNECTED              │                                      │
    │  • No WebSocket connection          │                                      │
    │  • reconnectionAttempts = 0         │                                      │
    └──────────────────┬──────────────────┘                                      │
                       │                                                          │
                 connect() called                                                 │
                       │                                                          │
                       ▼                                                          │
    ┌─────────────────────────────────────┐                                      │
    │           CONNECTING                │◄──────────────────┐                  │
    │  • WebSocket.resume() called        │                   │                  │
    │  • Waiting for hello                │                   │                  │
    └──────────────────┬──────────────────┘                   │                  │
                       │                                       │                  │
            ┌──────────┴──────────┐                           │                  │
            │                     │                           │                  │
      hello received         connection failed           backoff timer           │
            │                     │                      (if attempts < 20)      │
            ▼                     ▼                           │                  │
    ┌─────────────────┐   ┌─────────────────┐                 │                  │
    │  AUTHENTICATING │   │   RECONNECTING  │─────────────────┘                  │
    │  • Sending      │   │  • Backoff wait │                                    │
    │    connect msg  │   │  • 1s→60s delay │                                    │
    └────────┬────────┘   └────────┬────────┘                                    │
             │                     │                                              │
       connected received    max attempts (20)                                   │
             │                     │                                              │
             ▼                     ▼                                              │
    ┌─────────────────┐   ┌─────────────────┐                                    │
    │    CONNECTED    │   │     FAILED      │                                    │
    │  • isConnected  │   │  • Show error   │                                    │
    │    = true       │   │  • Manual retry │                                    │
    │  • Restore subs │   │    available    │                                    │
    └────────┬────────┘   └────────┬────────┘                                    │
             │                     │                                              │
    WebSocket error/close     user clicks                                        │
             │                 "Reconnect"                                        │
             │                     │                                              │
             └─────────────────────┴──────────────────────────────────────────────┘
```

### V.2 Connection Sequence Detail

```
Client                                          Backend
   │                                               │
   │─── WebSocket Connect ────────────────────────>│
   │                                               │
   │<── hello {version, message} ─────────────────│
   │                                               │
   │─── connect {session_id} ──────────────────────>│
   │                                               │
   │<── connected {message, session_id} ──────────│
   │                                               │
   │<── recent_sessions {sessions[], limit} ──────│
   │                                               │
   │─── set_directory {path} ──────────────────────>│
   │                                               │
   │<── available_commands {commands[]} ──────────│
   │                                               │
   │─── subscribe {session_id} ────────────────────>│
   │                                               │
   │<── session_history {messages[]} ─────────────│
   │                                               │
```

### V.3 Test Scenarios

| Scenario | Expected Behavior | Test Method |
|----------|-------------------|-------------|
| Fresh connect | hello → connect → connected → ready | Unit test with mock |
| Reconnect | Restore subscriptions automatically | Integration test |
| Server restart | Detect disconnect, reconnect with backoff | Manual test |
| Invalid URL | Error message, no reconnect attempts | Unit test |
| Network loss | Exponential backoff, max 20 attempts | Unit test with mock |
| Server busy | Queue message, retry on connected | Integration test |
| Concurrent prompts | session_locked response, UI disabled | Unit test |

### V.4 Mock Backend for Testing

```swift
class MockWebSocketServer {
    var onConnect: (() -> Void)?
    var onMessage: ((String) -> Void)?
    var messageQueue: [String] = []

    func simulateHello() {
        send(["type": "hello", "version": "0.1.0", "message": "Welcome"])
    }

    func simulateConnected(sessionId: String) {
        send(["type": "connected", "message": "Session registered", "session_id": sessionId])
    }

    func simulateSessionLocked(sessionId: String) {
        send(["type": "session_locked", "session_id": sessionId, "message": "Session busy"])
    }

    func simulateTurnComplete(sessionId: String) {
        send(["type": "turn_complete", "session_id": sessionId])
    }

    func simulateDisconnect() {
        // Close connection
    }

    private func send(_ json: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: json),
           let text = String(data: data, encoding: .utf8) {
            messageQueue.append(text)
        }
    }
}
```

### V.5 Error → User Message Mapping

| Backend Error | User-Facing Message |
|---------------|---------------------|
| Connection refused | "Cannot connect to server. Is the backend running?" |
| Timeout | "Server not responding. Check network connection." |
| Invalid URL | "Invalid server URL. Please check settings." |
| Session not found | "Session no longer exists. It may have been deleted." |
| Session locked | "Session is processing another request. Please wait." |
| Upload failed | "File upload failed. Please try again." |
| Max attempts | "Unable to connect after 20 attempts. Check server settings." |

---

## Appendix W: WebSocket Message Handling

### W.1 Exhaustive Switch Requirement

All message types MUST be handled explicitly:

```swift
func handleMessage(_ text: String) {
    guard let json = parseJSON(text),
          let type = json["type"] as? String else { return }

    switch type {
    // Connection lifecycle
    case "hello": handleHello(json)
    case "connected": handleConnected(json)
    case "pong": break  // No-op

    // Session management
    case "session_list": handleSessionList(json)
    case "recent_sessions": handleRecentSessions(json)
    case "session_created": handleSessionCreated(json)
    case "session_history": handleSessionHistory(json)
    case "session_updated": handleSessionUpdated(json)
    case "session_ready": handleSessionReady(json)
    case "session_locked": handleSessionLocked(json)
    case "session_killed": handleSessionKilled(json)
    case "session_deleted": handleSessionDeleted(json)

    // Prompt/response
    case "ack": handleAck(json)
    case "response": handleResponse(json)
    case "error": handleError(json)
    case "turn_complete": handleTurnComplete(json)
    case "replay": handleReplay(json)

    // Commands
    case "available_commands": handleAvailableCommands(json)
    case "command_started": handleCommandStarted(json)
    case "command_output": handleCommandOutput(json)
    case "command_complete": handleCommandComplete(json)
    case "command_history": handleCommandHistory(json)
    case "command_output_full": handleCommandOutputFull(json)

    // Compaction
    case "compaction_complete": handleCompactionComplete(json)
    case "compaction_error": handleCompactionError(json)

    // Session naming
    case "session_name_inferred": handleSessionNameInferred(json)
    case "infer_name_error": handleInferNameError(json)

    // Resources
    case "upload_complete": handleUploadComplete(json)
    case "resources_list": handleResourcesList(json)

    // Worktree
    case "worktree_session_created": handleWorktreeSessionCreated(json)
    case "worktree_session_error": handleWorktreeSessionError(json)

    // Unknown type - log for debugging
    default:
        logger.warning("⚠️ Unknown message type: \(type)")
        logger.debug("Full message: \(text)")
    }
}
```

### W.2 New Message Type Checklist

When backend adds a new message type:

- [ ] Add case to switch statement
- [ ] Create handler function
- [ ] Add to message types table in STANDARDS.md
- [ ] Add test for new message type
- [ ] Update mock backend if applicable

---

## Appendix X: Voice Hash Stability Note

### X.1 Implementation

```swift
private func stableHash(_ string: String?) -> Int {
    guard let string = string else { return 0 }
    var hash = 0
    for char in string.unicodeScalars {
        hash = hash &* 31 &+ Int(char.value)
    }
    return abs(hash)
}
```

### X.2 Stability Guarantee

This hash is stable within:
- Same Swift version
- Same platform (Int size: 64-bit on modern devices)
- Same Unicode version

**NOT guaranteed stable across:**
- Different Swift versions (rare, but possible)
- 32-bit vs 64-bit platforms (not applicable for iOS 18+/macOS 14+)
- Major Unicode updates (very rare)

### X.3 Acceptable Tradeoff

Voice assignment changes are cosmetic, not functional. If a user's project gets a different voice after an update, this is acceptable. No action needed unless users report confusion.

---

## Appendix Y: Global Hotkey for Voice Input

### Y.1 Use Case

Users want to trigger voice input from anywhere in the system without switching to the app first. This is a key macOS-specific enhancement.

### Y.2 Implementation

```swift
import Carbon.HIToolbox

class GlobalHotkeyManager: ObservableObject {
    private var hotkeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// Default: ⌃⌥V (Control + Option + V)
    @Published var hotkey: (keyCode: UInt32, modifiers: UInt32) = (
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(controlKey | optionKey)
    )

    var onHotkeyPressed: (() -> Void)?

    func register() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // Install event handler
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData!).takeUnretainedValue()
                manager.onHotkeyPressed?()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        // Register the hotkey
        var hotkeyID = EventHotKeyID(signature: OSType(0x564F4943), id: 1)  // "VOIC"
        RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.modifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )
    }

    func unregister() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
    }

    /// Human-readable description of current hotkey
    var hotkeyDescription: String {
        var parts: [String] = []
        if hotkey.modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if hotkey.modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if hotkey.modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if hotkey.modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(keyCodeToString(hotkey.keyCode))
        return parts.joined()
    }

    /// Update hotkey and re-register
    func updateHotkey(keyCode: UInt32, modifiers: UInt32) {
        unregister()
        hotkey = (keyCode: keyCode, modifiers: modifiers)
        register()
    }

    /// Update hotkey from keyboard event
    func updateHotkey(from event: NSEvent) {
        let keyCode = UInt32(event.keyCode)
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        updateHotkey(keyCode: keyCode, modifiers: modifiers)
    }

    private func keyCodeToString(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_M: return "M"
        case kVK_Space: return "Space"
        // Add more as needed
        default: return "?"
        }
    }

    deinit {
        unregister()
    }
}
```

### Y.3 Behavior on Hotkey Press

```swift
// In VoiceCodeDesktopApp
// Assumes access to:
//   - sessionManager: SessionSelectionManager (see AB.1)
//   - voiceInputManager: VoiceInputManager
hotkeyManager.onHotkeyPressed = {
    // 1. Bring app to front (or show floating panel)
    NSApp.activate(ignoringOtherApps: true)

    // 2. Focus the active session's input
    if let activeSession = sessionManager.selectedSessionId {
        // Trigger voice input mode
        voiceInputManager.startRecording()
    } else {
        // No session - show session picker or create new
        showSessionPicker()
    }
}
```

### Y.4 Floating Voice Panel Alternative

For less intrusive voice input. Note: `WaveformView` is a conceptual placeholder - implement using SwiftUI shapes or a charting library:

```swift
/// Placeholder - implement audio level visualization using SwiftUI shapes
struct WaveformView: View {
    let levels: [Float]  // Audio levels from AVAudioEngine tap

    var body: some View {
        // Implementation: Use HStack of RoundedRectangles with heights based on levels
        HStack(spacing: 2) {
            ForEach(levels.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 4, height: CGFloat(levels[index]) * 40)
            }
        }
    }
}

struct FloatingVoicePanel: View {
    @ObservedObject var voiceInput: VoiceInputManager
    @State private var isListening = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            // Waveform visualization (requires adding audioLevels to VoiceInputManager)
            WaveformView(levels: voiceInput.audioLevels)
                .frame(height: 40)

            // Transcription preview
            Text(voiceInput.partialTranscription)
                .font(.system(.body, design: .monospaced))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Status and controls
            HStack {
                Circle()
                    .fill(isListening ? .red : .gray)
                    .frame(width: 8, height: 8)
                Text(isListening ? "Listening..." : "Press ⌃⌥V")
                    .foregroundColor(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .padding()
        .frame(width: 400)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
```

### Y.5 Preferences UI

```swift
struct HotkeyPreferenceView: View {
    @ObservedObject var hotkeyManager: GlobalHotkeyManager
    @State private var isRecording = false

    var body: some View {
        HStack {
            Text("Global Voice Hotkey:")
            Spacer()

            if isRecording {
                Text("Press key combination...")
                    .foregroundColor(.secondary)
            } else {
                Text(hotkeyManager.hotkeyDescription)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(4)
            }

            Button(isRecording ? "Cancel" : "Record") {
                isRecording.toggle()
            }
        }
        .background(KeyEventHandler(isActive: isRecording) { event in
            hotkeyManager.updateHotkey(from: event)
            isRecording = false
        })
    }
}

/// NSViewRepresentable for capturing key events
struct KeyEventHandler: NSViewRepresentable {
    let isActive: Bool
    let onKeyDown: (NSEvent) -> Void

    func makeNSView(context: Context) -> KeyEventView {
        let view = KeyEventView()
        view.onKeyDown = onKeyDown
        return view
    }

    func updateNSView(_ nsView: KeyEventView, context: Context) {
        nsView.isActive = isActive
        if isActive {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    class KeyEventView: NSView {
        var isActive = false
        var onKeyDown: ((NSEvent) -> Void)?

        override var acceptsFirstResponder: Bool { isActive }

        override func keyDown(with event: NSEvent) {
            if isActive {
                onKeyDown?(event)
            } else {
                super.keyDown(with: event)
            }
        }
    }
}
```

### Y.6 Accessibility Permissions

Global hotkeys require accessibility permissions on macOS:

```swift
func checkAccessibilityPermissions() -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
    return AXIsProcessTrustedWithOptions(options as CFDictionary)
}

// In app launch
if !checkAccessibilityPermissions() {
    // Show explanation and link to System Preferences
    showAccessibilityPrompt()
}
```

---

## Appendix Z: Error Recovery Patterns

### Z.1 Categories of Errors

| Category | Examples | Recovery Strategy |
|----------|----------|-------------------|
| Transient | Network timeout, server busy | Auto-retry with backoff |
| User-Recoverable | Invalid URL, missing permission | Show error + action button |
| Fatal | Corrupted database, missing entitlement | Show error + support info |

### Z.1.1 Custom Error Types

```swift
/// Error thrown when a session is locked and cannot accept new prompts
struct SessionLockError: Error {
    let sessionId: String
    let message: String

    init(sessionId: String, message: String = "Session is locked") {
        self.sessionId = sessionId
        self.message = message
    }
}
```

### Z.2 Transient Error Recovery

```swift
class RetryableOperation<T> {
    let maxAttempts: Int
    let baseDelay: TimeInterval
    let operation: () async throws -> T

    func execute() async throws -> T {
        var lastError: Error?
        var delay = baseDelay

        for attempt in 1...maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error

                // Check if error is retryable
                guard isRetryable(error) else { throw error }

                // Log attempt
                logger.warning("Attempt \(attempt)/\(maxAttempts) failed: \(error)")

                // Wait before retry (except on last attempt)
                if attempt < maxAttempts {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    delay = min(delay * 2, 60.0)  // Cap at 60 seconds
                }
            }
        }

        throw lastError!
    }

    private func isRetryable(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet:
                return true
            default:
                return false
            }
        }
        return false
    }
}
```

### Z.3 User-Recoverable Error Display

```swift
struct RecoverableErrorView: View {
    let error: RecoverableError
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(error.title)
                    .font(.headline)
            }

            Text(error.message)
                .foregroundColor(.secondary)

            if let recoveryAction = error.recoveryAction {
                HStack {
                    Spacer()
                    Button("Dismiss") { onDismiss() }
                    Button(recoveryAction.label) {
                        recoveryAction.perform()
                        onRetry()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
    }
}

struct RecoverableError {
    let title: String
    let message: String
    let recoveryAction: RecoveryAction?
}

struct RecoveryAction {
    let label: String
    let perform: () -> Void
}
```

### Z.4 Error → Recovery Mapping

```swift
extension VoiceCodeClient {
    func recoverableError(from error: Error) -> RecoverableError? {
        switch error {
        case let urlError as URLError where urlError.code == .notConnectedToInternet:
            return RecoverableError(
                title: "No Internet Connection",
                message: "Check your network connection and try again.",
                recoveryAction: RecoveryAction(label: "Retry") { [weak self] in
                    self?.reconnect()
                }
            )

        case let urlError as URLError where urlError.code == .cannotFindHost:
            return RecoverableError(
                title: "Server Not Found",
                message: "Cannot reach \(serverURL). Is the backend running?",
                recoveryAction: RecoveryAction(label: "Open Settings") {
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                }
            )

        case is SessionLockError:
            return RecoverableError(
                title: "Session Busy",
                message: "This session is processing another request. Please wait.",
                recoveryAction: nil  // Auto-clears when session unlocks
            )

        default:
            return nil  // Non-recoverable or unknown
        }
    }
}
```

### Z.5 CoreData Recovery

```swift
class PersistenceController {
    func recoverFromCorruption() {
        guard let storeURL = container.persistentStoreDescriptions.first?.url else {
            return
        }

        // 1. Log the issue
        logger.error("CoreData store corruption detected")

        // 2. Backup corrupted store
        let backupURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent("VoiceCode_backup_\(Date().timeIntervalSince1970).sqlite")

        try? FileManager.default.copyItem(at: storeURL, to: backupURL)
        logger.info("Backed up corrupted store to \(backupURL.path)")

        // 3. Delete corrupted store
        try? FileManager.default.removeItem(at: storeURL)

        // 4. Reload with fresh store
        container.loadPersistentStores { description, error in
            if let error = error {
                logger.error("Recovery failed: \(error)")
                // At this point, show fatal error to user
            } else {
                logger.info("Recovery successful - store recreated")
                // Trigger sync from backend to repopulate
                NotificationCenter.default.post(name: .requestFullSync, object: nil)
            }
        }
    }
}
```

### Z.6 WebSocket Reconnection Recovery

```swift
extension VoiceCodeClient {
    /// Track for incremental sync (future feature)
    private var lastKnownTimestamp: Date?

    /// Backend capability flag - set based on hello message version
    private var supportsIncrementalSync: Bool { false }  // Not yet implemented

    /// Tracks running command sessions (cmd-<UUID> strings)
    private var runningCommands = Set<String>()

    func handleConnectionRecovery() {
        // 1. Clear stale state
        lockedSessions.removeAll()
        runningCommands.removeAll()

        // 2. Restore subscriptions
        for sessionId in activeSubscriptions {
            subscribe(sessionId: sessionId)
        }

        // 3. Request missed updates (optional - backend may not support yet)
        // NOTE: request_sync is a proposed message type for incremental sync
        // If backend doesn't support it, fall back to full session_list refresh
        if supportsIncrementalSync, let timestamp = lastKnownTimestamp {
            let formatter = ISO8601DateFormatter()
            sendMessage([
                "type": "request_sync",
                "since": formatter.string(from: timestamp)
            ])
        }
        // else: Backend will send session_list automatically after connected

        // 4. Notify UI
        NotificationCenter.default.post(
            name: .connectionRestored,
            object: nil,
            userInfo: ["restoredSubscriptions": activeSubscriptions.count]
        )
    }
}
```

### Z.7 User Notification of Recovery

This pattern wraps content to show a reconnection banner overlay:

```swift
/// Wrapper view that shows reconnection banners
/// In practice, this would wrap your main content view
struct ConnectionStatusView<Content: View>: View {
    @ObservedObject var client: VoiceCodeClient
    let content: Content
    @State private var showingReconnectedBanner = false

    init(client: VoiceCodeClient, @ViewBuilder content: () -> Content) {
        self.client = client
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Main content
            content

            // Reconnection banner
            if showingReconnectedBanner {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Connection restored")
                }
                .padding(8)
                .background(.green.opacity(0.1))
                .cornerRadius(8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .connectionRestored)) { _ in
            withAnimation {
                showingReconnectedBanner = true
            }

            // Auto-hide after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation {
                    showingReconnectedBanner = false
                }
            }
        }
    }
}

// Usage in App:
// ConnectionStatusView(client: client) {
//     MainWindowView()
//         .environmentObject(client)
//         .environmentObject(settings)
// }
```

---

## Appendix AA: CoreData Schema Migration

### AA.1 Migration Strategy

When the CoreData schema changes between app versions:

**Lightweight Migration (Preferred):**
- Used for additive changes: new entities, new optional attributes, new relationships
- CoreData handles automatically with `NSPersistentStoreDescription` options

```swift
let description = NSPersistentStoreDescription(url: storeURL)
description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
container.persistentStoreDescriptions = [description]
```

**Heavyweight Migration (When Required):**
- Used for: renaming attributes, changing types, complex data transformations
- Requires custom mapping model (`.xcmappingmodel`)

### AA.2 Version History

| Version | Schema Changes | Migration Type |
|---------|----------------|----------------|
| 1.0 | Initial schema | N/A |
| 1.1 (future) | Add priority queue fields | Lightweight |
| 1.2 (future) | TBD | TBD |

### AA.3 Testing Migrations

```swift
func testMigrationFromV1ToV1_1() {
    // 1. Create store with old model
    let oldModelURL = Bundle.module.url(forResource: "VoiceCode_v1", withExtension: "mom")!
    let oldModel = NSManagedObjectModel(contentsOf: oldModelURL)!
    let oldContainer = NSPersistentContainer(name: "Test", managedObjectModel: oldModel)

    // 2. Populate with test data
    // ...

    // 3. Migrate to new model
    let newContainer = NSPersistentContainer(name: "VoiceCode")
    newContainer.loadPersistentStores { _, error in
        XCTAssertNil(error)
    }

    // 4. Verify data integrity
    let sessions = try! newContainer.viewContext.fetch(CDBackendSession.fetchRequest())
    XCTAssertEqual(sessions.count, expectedCount)
}
```

### AA.4 Fallback on Migration Failure

If migration fails, treat as corruption and recover:

```swift
container.loadPersistentStores { description, error in
    if let error = error as NSError?,
       error.code == NSMigrationError || error.code == NSMigrationMissingMappingModelError {
        logger.error("Migration failed: \(error). Recovering...")
        self.recoverFromCorruption()
    }
}
```

---

## Appendix AB: State Persistence

### AB.1 Session Selection Persistence

Remember the last selected session across app launches:

```swift
class SessionSelectionManager: ObservableObject {
    private let key = "lastSelectedSessionId"

    @Published var selectedSessionId: UUID? {
        didSet {
            if let id = selectedSessionId {
                UserDefaults.standard.set(id.uuidString.lowercased(), forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    init() {
        if let idString = UserDefaults.standard.string(forKey: key),
           let id = UUID(uuidString: idString) {
            selectedSessionId = id
        }
    }

    func validateSelection(against sessions: [CDBackendSession]) {
        // Clear selection if session no longer exists
        if let id = selectedSessionId,
           !sessions.contains(where: { $0.id == id }) {
            selectedSessionId = nil
        }
    }
}
```

### AB.2 Window State Restoration

macOS automatically restores window positions. Additional state to persist:

| State | Storage | Restored When |
|-------|---------|---------------|
| Selected session | UserDefaults | App launch |
| Sidebar collapsed | NSWindow state | Window reopen |
| Column widths | NSWindow state | Window reopen |
| Scroll position | Not persisted | N/A |
| Draft text | DraftManager | View appears |

### AB.3 Integration with SwiftUI

```swift
struct MainWindowView: View {
    @StateObject private var selectionManager = SessionSelectionManager()
    @FetchRequest(fetchRequest: CDBackendSession.fetchRequest())
    private var sessions: FetchedResults<CDBackendSession>

    var body: some View {
        NavigationSplitView {
            SessionListView(selection: $selectionManager.selectedSessionId)
        } detail: {
            if let id = selectionManager.selectedSessionId,
               let session = sessions.first(where: { $0.id == id }) {
                ConversationDetailView(session: session)
            } else {
                EmptyStateView()
            }
        }
        .onAppear {
            selectionManager.validateSelection(against: Array(sessions))
        }
    }
}
```

---

## Appendix AC: Dark Mode Support

### AC.1 System Appearance Integration

SwiftUI automatically adapts to system appearance. Key considerations:

**Colors:**
- Use semantic colors: `.primary`, `.secondary`, `.background`
- Avoid hardcoded colors unless brand-specific

**Assets:**
- Provide both light and dark variants in Asset Catalog
- Use `Color("BrandColor")` for custom colors with appearance variants

### AC.2 Custom Color Definitions

```swift
extension Color {
    static let messageBubbleUser = Color("MessageBubbleUser")
    static let messageBubbleAssistant = Color("MessageBubbleAssistant")
    static let connectionStatusGreen = Color("ConnectionGreen")
    static let connectionStatusRed = Color("ConnectionRed")
}
```

**Asset Catalog Structure:**
```
Assets.xcassets/
├── Colors/
│   ├── MessageBubbleUser.colorset/
│   │   └── Contents.json  (light: #E3F2FD, dark: #1E3A5F)
│   ├── MessageBubbleAssistant.colorset/
│   │   └── Contents.json  (light: #F5F5F5, dark: #2D2D2D)
│   └── ...
```

### AC.3 Code Syntax Highlighting

For code blocks in messages, use appearance-aware highlighting. This example uses a hypothetical `HighlightTheme` type - in practice, integrate a syntax highlighting library like [Highlightr](https://github.com/raspu/Highlightr) or use SwiftUI's `AttributedString`:

```swift
// Example using a syntax highlighting library
struct CodeBlockView: View {
    let code: String
    let language: String?
    @Environment(\.colorScheme) var colorScheme

    /// Theme selection based on system appearance
    /// Replace with your chosen library's theme type
    var themeName: String {
        colorScheme == .dark ? "xcode-dark" : "xcode"
    }

    var body: some View {
        // Use syntax highlighting library with themeName
        // Example: Highlightr().highlight(code, as: language, theme: themeName)
        Text(code)
            .font(.system(.body, design: .monospaced))
    }
}
```

### AC.4 Testing Appearance

```swift
func testLightModeColors() {
    let view = MessageBubbleView(role: .user)
        .environment(\.colorScheme, .light)
    // Assert colors match light theme
}

func testDarkModeColors() {
    let view = MessageBubbleView(role: .user)
        .environment(\.colorScheme, .dark)
    // Assert colors match dark theme
}
```

---

## Appendix AD: Edge Case Clarifications

### AD.1 Command Execution Without Working Directory

**Scenario:** User tries to execute a command but no working directory is set for the session.

**Behavior:**
1. If session has no `workingDirectory`, use app's default working directory from settings
2. If no default is set, prompt user to select a directory
3. Commands are disabled in UI until a directory is configured

```swift
func executeCommand(_ commandId: String, session: CDBackendSession) {
    let workingDirectory: String

    if let sessionDir = session.workingDirectory, !sessionDir.isEmpty {
        workingDirectory = sessionDir
    } else if let defaultDir = AppSettings.shared.defaultWorkingDirectory, !defaultDir.isEmpty {
        workingDirectory = defaultDir
    } else {
        // Show directory picker
        showDirectoryPicker { selectedPath in
            if let path = selectedPath {
                session.workingDirectory = path
                self.executeCommand(commandId, session: session)
            }
        }
        return
    }

    client.sendMessage([
        "type": "execute_command",
        "command_id": commandId,
        "working_directory": workingDirectory
    ])
}

/// Show macOS directory picker panel
func showDirectoryPicker(completion: @escaping (String?) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Select a working directory for commands"
    panel.prompt = "Select"

    panel.begin { response in
        if response == .OK, let url = panel.url {
            completion(url.path)
        } else {
            completion(nil)
        }
    }
}
```

**UI Indication:**
- Command button shows "Set Directory..." if no directory configured
- Tooltip explains why commands are disabled

### AD.2 Multi-Window Session Sharing

**Scenario:** Same session opened in multiple windows.

**Design Decision:** Sessions can only be open in ONE window at a time.

**Behavior:**
1. When opening a session that's already in another window, focus that window instead
2. Detached windows track their session ID
3. Main window's sidebar shows which sessions are in detached windows (icon indicator)

```swift
class WindowSessionRegistry {
    static let shared = WindowSessionRegistry()
    private var sessionToWindow: [UUID: NSWindow] = [:]

    func registerWindow(_ window: NSWindow, for sessionId: UUID) {
        sessionToWindow[sessionId] = window
    }

    func unregisterWindow(for sessionId: UUID) {
        sessionToWindow.removeValue(forKey: sessionId)
    }

    func windowForSession(_ sessionId: UUID) -> NSWindow? {
        return sessionToWindow[sessionId]
    }

    func isSessionInWindow(_ sessionId: UUID) -> Bool {
        return sessionToWindow[sessionId] != nil
    }
}

// When selecting a session
func selectSession(_ sessionId: UUID) {
    if let existingWindow = WindowSessionRegistry.shared.windowForSession(sessionId) {
        existingWindow.makeKeyAndOrderFront(nil)
    } else {
        // Open in current window or create new
    }
}
```

**Alternative (Not Implemented):** If multi-window same-session is needed later:
- Use CoreData's automatic merge propagation
- Optimistic messages would need deduplication by temporary ID
- Lock state already shared via `VoiceCodeClient` singleton

### AD.3 Session Not Found Recovery

**Scenario:** User has a session selected that no longer exists (deleted on backend, corrupted data).

**UI Behavior:**
```swift
struct ConversationDetailView: View {
    let sessionId: UUID
    @Binding var selectedSessionId: UUID?
    @EnvironmentObject var client: VoiceCodeClient
    @FetchRequest private var sessions: FetchedResults<CDBackendSession>

    private var session: CDBackendSession? {
        sessions.first { $0.id == sessionId }
    }

    var body: some View {
        if let session = session {
            ConversationContent(session: session)
        } else {
            SessionNotFoundView(
                sessionId: sessionId,
                onDismiss: { clearSelection() },
                onRefresh: { refreshFromBackend() }
            )
        }
    }

    private func clearSelection() {
        selectedSessionId = nil
    }

    private func refreshFromBackend() {
        // Request fresh session list from backend
        client.sendMessage(["type": "get_session_list"])
    }
}

struct SessionNotFoundView: View {
    let sessionId: UUID
    let onDismiss: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Session Not Found")
                .font(.title2)

            Text("This session may have been deleted or is no longer available.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            HStack {
                Button("Refresh") { onRefresh() }
                Button("Close") { onDismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
    }
}
```

**Recovery Actions:**
- **Refresh:** Re-fetch session list from backend
- **Close:** Clear selection, return to sidebar view
- **Auto-cleanup:** On next backend sync, remove orphaned CoreData entries

### AD.4 Priority Queue Persistence

**Design Decision:** Priority queue state is **client-only** and persists in CoreData.

**Implications:**
- Priority queue is NOT synced across devices
- Each client (iOS, macOS) has its own priority queue
- Reinstalling app loses priority queue state
- Backend has no knowledge of priority queue membership

**Rationale:**
- Priority queue is a personal workflow tool, not shared state
- Different devices may have different prioritization needs
- Backend simplicity - no additional protocol messages needed

**Alternative (Not Implemented):** If cross-device sync is needed later:
- Add `priority_queue_sync` message type
- Store in backend per-user preferences
- Merge conflicts resolved by timestamp (last write wins)

### AD.5 Global Hotkey Conflict Handling

**Scenario:** User's chosen hotkey is already registered by another app or system.

**Behavior (add these properties/methods to GlobalHotkeyManager from Appendix Y):**
```swift
// Add to GlobalHotkeyManager class definition
class GlobalHotkeyManager: ObservableObject {
    // ... existing properties from Appendix Y ...

    @Published var registrationError: String?

    func registerWithFeedback() -> Bool {
        var hotkeyRef: EventHotKeyRef?
        var hotkeyID = EventHotKeyID(signature: OSType(0x564F4943), id: 1)

        let status = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.modifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        if status == noErr {
            self.hotkeyRef = hotkeyRef
            registrationError = nil
            return true
        } else {
            registrationError = "Hotkey ⌃⌥V is in use by another application. Please choose a different combination."
            return false
        }
    }

    func suggestAlternatives() -> [(keyCode: UInt32, modifiers: UInt32, description: String)] {
        return [
            (UInt32(kVK_ANSI_V), UInt32(controlKey | shiftKey), "⌃⇧V"),
            (UInt32(kVK_ANSI_V), UInt32(optionKey | shiftKey), "⌥⇧V"),
            (UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey), "⌃⌥M"),
            (UInt32(kVK_Space), UInt32(controlKey | optionKey), "⌃⌥Space"),
        ]
    }
}
```

**UI Handling:**
```swift
struct HotkeyPreferenceView: View {
    @ObservedObject var hotkeyManager: GlobalHotkeyManager

    var body: some View {
        VStack(alignment: .leading) {
            // ... hotkey selection UI ...

            if let error = hotkeyManager.registrationError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .foregroundColor(.secondary)
                }

                Text("Suggested alternatives:")
                    .font(.caption)
                ForEach(hotkeyManager.suggestAlternatives(), id: \.description) { alt in
                    Button(alt.description) {
                        hotkeyManager.updateHotkey(keyCode: alt.keyCode, modifiers: alt.modifiers)
                    }
                }
            }
        }
    }
}
```

**Fallback:**
- If no hotkey can be registered, voice input is still accessible via:
  - Menu bar item
  - Toolbar button
  - Menu > Session > Start Voice Input
