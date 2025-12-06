# macOS Desktop Port - Design Document

## Executive Summary

This document outlines the architecture and implementation strategy for porting the Untethered iOS app to macOS. The port will maximize code reuse while embracing macOS-native patterns and conventions.

## Goals

1. **Code Reuse**: Share 70-80% of code between iOS and macOS through Swift Package
2. **Native Experience**: Embrace macOS UI patterns (NavigationSplitView, menu bar, keyboard shortcuts)
3. **Feature Parity**: Match core iOS functionality (voice I/O, sessions, commands, resources)
4. **Platform Enhancement**: Add macOS-specific improvements where they make sense

## Non-Goals

1. Cross-platform support (Windows, Linux) - macOS only for now
2. Catalyst/Mac Idiom - native macOS target instead
3. Rewriting working code - reuse extensively from iOS

---

## Architecture Overview

### Technology Stack

| Component | Technology | Rationale |
|-----------|-----------|-----------|
| UI Framework | SwiftUI | Maximum code reuse from iOS, modern Apple platform UI |
| Persistence | CoreData | Share models with iOS, proven solution |
| Voice Input | Speech Framework | Same as iOS, native macOS support |
| Voice Output | AVSpeechSynthesizer | Same as iOS, native macOS support |
| Networking | URLSession WebSocket | Same as iOS |
| Build System | XcodeGen | Extend existing project.yml with macOS target |

### Project Structure

```
voice-code-desktop/
├── backend/                    # Unchanged - platform agnostic
├── ios/                        # Existing iOS app
│   ├── Sources/               # iOS-specific UI and app lifecycle
│   └── Tests/
├── macos/                      # New macOS app
│   ├── Sources/               # macOS-specific UI and app lifecycle
│   │   ├── UntetheredMac.swift           # App entry point
│   │   ├── RootView.swift                # NavigationSplitView root
│   │   ├── DirectoryListView.swift       # Sidebar (column 1)
│   │   ├── SessionListView.swift         # Session list (column 2)
│   │   ├── ConversationView.swift        # Chat view (column 3)
│   │   ├── SettingsWindow.swift          # Settings window
│   │   └── MenuBarCommands.swift         # Menu bar integration
│   ├── Resources/
│   │   ├── Assets.xcassets
│   │   └── Info.plist
│   └── Tests/
├── Shared/                     # Swift Package - shared code
│   ├── Package.swift
│   └── Sources/
│       └── UntetheredCore/
│           ├── Models/                   # Shared data models
│           │   ├── Message.swift
│           │   ├── Session.swift
│           │   ├── Command.swift
│           │   └── Resource.swift
│           ├── Networking/               # WebSocket client
│           │   ├── VoiceCodeClient.swift
│           │   ├── WebSocketMessage.swift
│           │   └── ConnectionState.swift
│           ├── Managers/                 # Business logic
│           │   ├── SessionSyncManager.swift
│           │   ├── VoiceInputManager.swift
│           │   ├── VoiceOutputManager.swift
│           │   ├── ResourcesManager.swift
│           │   └── ActiveSessionManager.swift
│           ├── Persistence/              # CoreData stack
│           │   ├── PersistenceController.swift
│           │   ├── UntetheredModel.xcdatamodeld
│           │   └── CoreDataModels/
│           │       ├── CDBackendSession+CoreDataClass.swift
│           │       ├── CDMessage+CoreDataClass.swift
│           │       └── CDUserSession+CoreDataClass.swift
│           └── Settings/
│               └── AppSettings.swift
└── docs/
    └── macos-port-design.md    # This document
```

---

## Shared Code Package (UntetheredCore)

### Purpose
Extract platform-agnostic code into Swift Package that both iOS and macOS targets depend on.

### Included Components

#### 1. Models
- `Message`, `Session`, `Command`, `Resource`
- WebSocket message types
- Codable conformance for JSON serialization
- **Platform-agnostic**: No UIKit/AppKit dependencies

#### 2. Networking
- `VoiceCodeClient`: WebSocket client managing connection lifecycle
- Message serialization/deserialization (snake_case ↔ camelCase)
- Reconnection logic with exponential backoff
- Session lock state tracking
- **Platform-agnostic**: Uses Foundation URLSession only

#### 3. Managers
- `SessionSyncManager`: Syncs backend sessions to CoreData
- `VoiceInputManager`: Speech-to-text abstraction
- `VoiceOutputManager`: Text-to-speech abstraction
- `ResourcesManager`: File upload handling
- `ActiveSessionManager`: Current session tracking
- **Mostly platform-agnostic**: Voice managers need minor platform checks

#### 4. Persistence
- `PersistenceController`: CoreData stack setup
- CoreData models: `CDBackendSession`, `CDMessage`, `CDUserSession`
- Fetch request helpers
- **Platform-agnostic**: CoreData works identically on iOS/macOS

#### 5. Settings
- `AppSettings`: User preferences (server URL, voice settings, system prompt)
- UserDefaults integration
- **Platform-agnostic**: Pure Foundation

### Migration Strategy

**Extract from iOS app:**
1. Move files to `Shared/Sources/UntetheredCore/`
2. Remove UIKit imports
3. Add `#if os(iOS)` / `#if os(macOS)` where needed (minimal)
4. Update iOS app to import `UntetheredCore`
5. Verify iOS app still builds and works

**Platform-specific considerations:**
- Voice managers: Check for `SpeechRecognizer` availability differences
- File pickers: Keep in platform-specific UI code
- Notifications: Keep in platform-specific code

---

## macOS Application Architecture

### UI Structure

```
UntetheredMac (App)
└── RootView (NavigationSplitView)
    ├── Sidebar (Column 1)
    │   └── DirectoryListView
    │       └── List of working directories
    ├── Content (Column 2)
    │   └── SessionListView
    │       └── Sessions for selected directory
    └── Detail (Column 3)
        └── ConversationView
            ├── Message list (ScrollView)
            ├── Voice input controls
            └── Text input field
```

### Key Differences from iOS

| Feature | iOS | macOS |
|---------|-----|-------|
| Navigation | NavigationStack (drill-down) | NavigationSplitView (3-column) |
| Input | Phone-optimized (portrait) | Keyboard-first with voice option |
| Voice | Push-to-talk primary | Push-to-talk secondary (keyboard shortcuts) |
| Settings | In-app NavigationStack | Separate Settings window (Cmd+,) |
| Resources | Share Extension | Drag-and-drop + file picker |
| Window Management | Single window | Multiple windows possible |

### macOS-Specific Views

#### 1. **RootView** (NavigationSplitView)
- 3-column layout: directories | sessions | conversation
- Column visibility toggles (toolbar buttons)
- Sidebar width persistence
- Keyboard navigation (arrow keys, Cmd+1/2/3 to switch columns)

#### 2. **DirectoryListView** (Sidebar)
- List of working directories with project icons
- "Add Directory" button (opens file picker)
- Right-click context menu (remove, reveal in Finder)
- Badge showing unread message count per directory

#### 3. **SessionListView** (Content)
- Filtered list of sessions for selected directory
- Search/filter field at top
- Session preview with timestamp, message count
- Right-click context menu (rename, delete, compact, copy session ID)
- Keyboard shortcuts (Cmd+N new session, Delete key)

#### 4. **ConversationView** (Detail)
- Message thread with proper text selection
- Inline code block syntax highlighting (SwiftUI Text markdown)
- Multi-line text input at bottom (TextEditor, not TextField)
- Voice input button with recording indicator
- Toolbar: Stop button, session info, commands menu
- Keyboard shortcuts:
  - Cmd+Enter: Send message
  - Cmd+K: Focus commands menu
  - Cmd+.: Stop current turn
  - Space (hold): Push-to-talk

#### 5. **SettingsWindow**
- Separate window (not in-app view)
- Standard macOS Settings pattern (TabView with icons)
- Tabs: General, Voice, Advanced
- Preferences persisted via AppSettings (shared with iOS)

#### 6. **MenuBarCommands**
- File menu: New Session, New Window, Close Window
- Edit menu: Standard (copy, paste, select all)
- View menu: Toggle Sidebar, Toggle Toolbar, Zoom
- Session menu: Send Prompt, Stop Turn, Compact Session
- Commands menu: Recent Commands, Command History
- Window menu: Standard (minimize, zoom, bring all to front)
- Help menu: Online Documentation, Report Issue

### Menu Bar Integration

**Standard macOS menu bar:**
- App menu (UntetheredMac): About, Preferences, Quit
- File, Edit, View, Session, Commands, Window, Help
- Command palette (Cmd+K): Quick access to sessions, commands, directories

**Optional future enhancement:**
- Menu bar extra (status item) for quick access
- Global hotkey to bring app to front

---

## Voice Input/Output

### Voice Input (Speech Framework)

**macOS considerations:**
- Same `Speech` framework as iOS
- Permission request: Info.plist `NSSpeechRecognitionUsageDescription`
- Microphone access: Info.plist `NSMicrophoneUsageDescription`
- Input source: System default microphone (configurable in future)

**UI patterns:**
- Hold Space bar for push-to-talk (like Discord)
- Click microphone button for tap-to-start, tap-to-stop
- Visual feedback: Waveform animation during recording
- Status: "Listening...", "Processing...", "Done"

**Keyboard shortcuts:**
- Space (hold): Record while held
- Escape: Cancel recording
- Cmd+Shift+V: Toggle auto-voice-input mode

### Voice Output (AVSpeechSynthesizer)

**macOS considerations:**
- Same `AVFoundation` API as iOS
- System voices available via `AVSpeechSynthesisVoice.speechVoices()`
- Quality: Use enhanced voices when available

**UI controls:**
- Auto-play toggle in Settings
- Per-message play button (click to replay)
- Stop speaking button in toolbar
- Voice selection in Settings (preview before selecting)

**Keyboard shortcuts:**
- Cmd+Shift+S: Stop speaking
- Cmd+Shift+R: Replay last message

---

## Data Persistence

### CoreData Stack

**Shared between iOS and macOS:**
- Same `.xcdatamodeld` file in UntetheredCore package
- Same entities: `CDBackendSession`, `CDMessage`, `CDUserSession`
- Same relationships and constraints

**Platform-specific storage:**
- iOS: App container (sandboxed)
- macOS: `~/Library/Application Support/com.910labs.untethered.mac/`
- SQLite files: `Untethered.sqlite`, `Untethered.sqlite-shm`, `Untethered.sqlite-wal`

**Migration strategy:**
- No automatic migration between iOS and macOS
- If needed in future: Export/import via JSON or iCloud sync

### App Groups (Future Enhancement)

**Not needed for v1:**
- iOS uses App Group for Share Extension
- macOS doesn't need Share Extension (drag-and-drop works)
- Possible future use: Background sync agent

---

## Resource Management

### File Uploads

**macOS approach:**
- **Drag-and-drop**: Drop files directly into ConversationView
- **File picker**: Click "Attach" button → standard macOS open panel
- **Paste**: Cmd+V to paste files from clipboard (if supported)

**Implementation:**
- `.onDrop(of: [.fileURL])` modifier on ConversationView
- `NSOpenPanel` for file picker
- Reuse `ResourcesManager` from UntetheredCore (same upload logic)

**Storage:**
- Backend stores in `.untethered/resources/` (same as iOS)
- No local caching (rely on backend persistence)

### Resources View

**macOS-specific UI:**
- List or grid of uploaded files
- File icons with Quick Look preview (spacebar)
- Right-click: Reveal in Finder, Copy URL, Delete
- Drag out of app to save to filesystem

---

## Keyboard Shortcuts

### Global Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+N | New session |
| Cmd+W | Close window |
| Cmd+, | Preferences |
| Cmd+Q | Quit app |
| Cmd+M | Minimize window |

### Conversation Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+Enter | Send message |
| Space (hold) | Push-to-talk |
| Escape | Cancel recording/input |
| Cmd+. | Stop current turn |
| Cmd+K | Open commands menu |
| Cmd+Shift+C | Copy session ID |
| Cmd+Shift+V | Toggle auto-voice-input |
| Cmd+Shift+S | Stop speaking |
| Cmd+Shift+R | Replay last message |

### Navigation Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+1 | Focus sidebar |
| Cmd+2 | Focus session list |
| Cmd+3 | Focus conversation |
| Cmd+[ | Previous session |
| Cmd+] | Next session |
| Cmd+F | Focus search field |

---

## Settings and Configuration

### Settings Window Structure

**General Tab:**
- Server URL (text field with validation)
- Default working directory (file picker)
- Auto-start on login (checkbox)
- Theme: System, Light, Dark (future enhancement)

**Voice Tab:**
- Auto-play responses (toggle)
- Voice selection (dropdown with preview)
- Speech rate slider (0.5x - 2.0x)
- Test voice button ("This is a test of the selected voice")

**Advanced Tab:**
- System prompt (multi-line text editor)
- Enable debug logging (toggle)
- Clear message cache (button)
- About section: Version, build number, licenses

### Persistence

**AppSettings (UserDefaults):**
- Shared with UntetheredCore package
- Keys: `serverURL`, `autoPlayVoice`, `selectedVoice`, `speechRate`, `systemPrompt`
- macOS-specific: `autoStartOnLogin`, `defaultWorkingDirectory`

**Window state:**
- Sidebar width, column widths (SceneStorage)
- Last selected directory, session (AppStorage)
- Window size/position (automatic via SwiftUI)

---

## Testing Strategy

### Unit Tests

**UntetheredCore package:**
- Model encoding/decoding (JSON ↔ Swift)
- VoiceCodeClient message handling
- SessionSyncManager logic
- AppSettings persistence

**macOS app:**
- View model logic (if using MVVM pattern)
- Keyboard shortcut handling
- File drop validation

### Integration Tests

**Backend communication:**
- WebSocket connection lifecycle
- Message send/receive flow
- Session lock state management
- Command execution

**CoreData:**
- Session CRUD operations
- Message insertion/deletion
- Fetch request performance
- Concurrent access safety

### Manual Testing Checklist

**Core flows:**
- [ ] Connect to backend
- [ ] Create new session
- [ ] Send voice prompt
- [ ] Send text prompt
- [ ] Receive response with auto-play
- [ ] Execute command (Makefile target)
- [ ] Upload resource file
- [ ] Compact session
- [ ] Switch directories
- [ ] Switch sessions

**macOS-specific:**
- [ ] Keyboard shortcuts work
- [ ] Menu bar commands work
- [ ] Drag-and-drop file upload
- [ ] Multi-window support
- [ ] Settings window persistence
- [ ] Quit and relaunch (state restoration)

**Voice:**
- [ ] Push-to-talk (Space bar hold)
- [ ] Microphone permission
- [ ] Voice output plays
- [ ] Voice selection changes
- [ ] Stop speaking works

---

## Build and Deployment

### XcodeGen Configuration

**project.yml additions:**

```yaml
targets:
  UntetheredMac:
    type: application
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - macos/Sources
    dependencies:
      - package: UntetheredCore
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: com.910labs.untethered.mac
      MARKETING_VERSION: 1.0.0
      INFOPLIST_FILE: macos/Resources/Info.plist
    scheme:
      testTargets:
        - UntetheredMacTests

packages:
  UntetheredCore:
    path: Shared
```

### Versioning

**Independent versioning:**
- iOS app: Current version (continues independently)
- macOS app: Start at 1.0.0
- Backend: Version agnostic (supports both clients)

**Build numbers:**
- iOS: Existing TestFlight build numbers
- macOS: Separate build number sequence

### Distribution

**Phase 1: TestFlight (internal)**
- Same process as iOS (`scripts/publish-testflight.sh`)
- Separate bundle ID: `com.910labs.untethered.mac`
- Platform: macOS in App Store Connect

**Phase 2: Direct download (future)**
- Notarized DMG for distribution outside Mac App Store
- Automatic updates via Sparkle framework (future enhancement)

---

## Migration Path from iOS

### Phase 1: Extract Shared Code
**Goal:** Create UntetheredCore package without breaking iOS app

**Steps:**
1. Create `Shared/` directory with Swift Package structure
2. Move platform-agnostic files to package (models, managers, persistence)
3. Add UntetheredCore dependency to iOS target
4. Update iOS imports from local to `import UntetheredCore`
5. Run iOS tests - ensure 100% pass rate
6. Commit: "Extract UntetheredCore shared package"

**Validation:**
- iOS app builds without errors
- iOS app runs on device/simulator
- All iOS tests pass
- No behavior changes (UI, functionality, performance)

### Phase 2: Create macOS Target
**Goal:** Minimal macOS app that connects to backend

**Steps:**
1. Add `macos/` directory structure
2. Create macOS target in project.yml
3. Generate Xcode project: `make generate-project`
4. Add UntetheredCore dependency to macOS target
5. Implement minimal UI (single window with text input)
6. Implement WebSocket connection using VoiceCodeClient
7. Send basic prompt and display response
8. Commit: "Add minimal macOS target"

**Validation:**
- macOS app builds and launches
- Connects to backend WebSocket
- Can send prompt and receive response
- Response displays in UI

### Phase 3: Implement Core UI
**Goal:** Feature parity with iOS for basic conversation flow

**Steps:**
1. Implement NavigationSplitView layout (3 columns)
2. Implement DirectoryListView (sidebar)
3. Implement SessionListView (content)
4. Implement ConversationView (detail)
5. Integrate CoreData (shared models)
6. Implement SessionSyncManager integration
7. Test multi-session workflow
8. Commit: "Implement core macOS UI"

**Validation:**
- Directory/session/conversation navigation works
- Sessions persist across app restarts
- Multiple sessions can coexist
- UI updates in real-time from backend

### Phase 4: Add Voice I/O
**Goal:** Voice input and output working on macOS

**Steps:**
1. Add microphone/speech permissions to Info.plist
2. Integrate VoiceInputManager (from UntetheredCore)
3. Add push-to-talk UI (Space bar, button)
4. Integrate VoiceOutputManager (from UntetheredCore)
5. Add auto-play toggle and manual replay
6. Test voice flow end-to-end
7. Commit: "Add voice input/output to macOS"

**Validation:**
- Microphone permission requested on first use
- Push-to-talk records and transcribes
- Voice output plays automatically (if enabled)
- Manual replay works
- Stop speaking works

### Phase 5: Add macOS-Specific Features
**Goal:** Platform-native enhancements

**Steps:**
1. Implement keyboard shortcuts (Cmd+Enter, Cmd+K, etc.)
2. Implement menu bar (File, Edit, View, Session, etc.)
3. Implement Settings window (Cmd+,)
4. Add drag-and-drop file upload
5. Add file picker for resources
6. Add ResourcesView for uploaded files
7. Implement command execution UI
8. Commit: "Add macOS-specific features"

**Validation:**
- All keyboard shortcuts work
- Menu bar commands work
- Settings persist across launches
- File upload via drag-and-drop works
- Commands execute and stream output

### Phase 6: Polish and Testing
**Goal:** Production-ready macOS app

**Steps:**
1. Add app icon and assets
2. Implement error handling and user-facing errors
3. Add loading states and empty states
4. Write unit tests for macOS-specific code
5. Write integration tests
6. Manual testing pass (full checklist)
7. Fix bugs discovered during testing
8. Update documentation
9. Commit: "Polish macOS app for v1.0 release"

**Validation:**
- All manual test checklist items pass
- All unit/integration tests pass
- No crashes or hangs during normal use
- Performance is acceptable (no UI lag)

---

## Future Enhancements (Post-v1.0)

### Near-term
- **Menu bar extra**: Quick access from status bar
- **Global hotkey**: Bring app to front from anywhere
- **Multiple windows**: Open sessions in separate windows
- **Quick Look preview**: Preview code files inline
- **Syntax highlighting**: Better code block rendering
- **Export conversation**: Save as Markdown, PDF

### Medium-term
- **Themes**: Light, dark, custom color schemes
- **Custom keyboard shortcuts**: User-configurable
- **Session search**: Full-text search across all messages
- **Session tags**: Organize sessions with tags
- **Workspace presets**: Save/restore directory + session sets

### Long-term
- **iCloud sync**: Sync sessions between iOS and macOS
- **Screen sharing**: Send screenshots to Claude
- **Diff view**: Visual diff for code changes
- **Git integration**: Commit, branch, PR from app
- **Plugin system**: Extend app with custom commands

---

## Risk Assessment

### Technical Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Swift Package dependency issues | Medium | Medium | Test thoroughly during extraction phase |
| CoreData migration issues | Low | High | Use same models, separate storage paths |
| Voice framework API differences | Low | Medium | Test on macOS early, add platform checks |
| Performance (large sessions) | Medium | Medium | Implement pagination, lazy loading |
| WebSocket connection instability | Low | High | Reuse proven iOS reconnection logic |

### Process Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Breaking iOS app during extraction | Medium | Critical | Incremental changes, continuous testing |
| Scope creep (too many features) | High | Medium | Stick to Phase 1-6 plan, defer enhancements |
| Testing insufficient | Medium | High | Comprehensive test plan, manual checklist |

---

## Success Criteria

### v1.0 Release Criteria

**Functional:**
- [ ] All core features from iOS work on macOS (voice, sessions, commands, resources)
- [ ] macOS-specific features work (keyboard shortcuts, menu bar, drag-and-drop)
- [ ] Settings persist across launches
- [ ] No data loss during normal operation

**Quality:**
- [ ] All unit/integration tests pass
- [ ] Manual test checklist 100% complete
- [ ] No crashes during 1-hour continuous use session
- [ ] Performance acceptable (UI responsive, <100ms input lag)

**Polish:**
- [ ] App icon and launch screen
- [ ] Proper empty states and error messages
- [ ] Keyboard shortcuts documented in menus
- [ ] README and user documentation updated

**Release:**
- [ ] TestFlight build uploaded and installable
- [ ] Internal team testing complete (3+ users)
- [ ] Critical bugs fixed
- [ ] Release notes written

---

## Timeline Estimate

**Note:** Per project instructions, no time estimates. Phases are listed in dependency order.

**Phase 1: Extract Shared Code** (dependencies: none)
**Phase 2: Create macOS Target** (dependencies: Phase 1)
**Phase 3: Implement Core UI** (dependencies: Phase 2)
**Phase 4: Add Voice I/O** (dependencies: Phase 3)
**Phase 5: Add macOS-Specific Features** (dependencies: Phase 4)
**Phase 6: Polish and Testing** (dependencies: Phase 5)

---

## Appendices

### A. File Inventory (to be moved to Shared)

**Models:**
- `ios/Sources/Models/Message.swift`
- `ios/Sources/Models/Session.swift`
- `ios/Sources/Models/Command.swift`
- `ios/Sources/Models/Resource.swift`

**Managers:**
- `ios/Sources/Managers/VoiceCodeClient.swift`
- `ios/Sources/Managers/SessionSyncManager.swift`
- `ios/Sources/Managers/VoiceInputManager.swift`
- `ios/Sources/Managers/VoiceOutputManager.swift`
- `ios/Sources/Managers/ResourcesManager.swift`
- `ios/Sources/Managers/ActiveSessionManager.swift`
- `ios/Sources/Managers/AppSettings.swift`

**Persistence:**
- `ios/Sources/Persistence/PersistenceController.swift`
- `ios/Sources/Persistence/UntetheredModel.xcdatamodeld/`
- `ios/Sources/Persistence/CDBackendSession+*.swift`
- `ios/Sources/Persistence/CDMessage+*.swift`
- `ios/Sources/Persistence/CDUserSession+*.swift`

### B. Platform-Specific Code to Keep in iOS

**Views:**
- All `.swift` files in `ios/Sources/Views/`
- iOS-specific layout (NavigationStack, not NavigationSplitView)
- Share Extension integration

**App Lifecycle:**
- `VoiceCodeApp.swift` (iOS App entry point)
- `SceneDelegate` (if present)
- Background tasks

**iOS-Only Features:**
- Share Extension (upload files from other apps)
- Widget (future)
- Watch app (future)

### C. New Files for macOS

**App:**
- `macos/Sources/UntetheredMac.swift` - App entry point
- `macos/Resources/Info.plist` - macOS-specific plist
- `macos/Resources/Assets.xcassets` - macOS app icon

**Views:**
- `macos/Sources/Views/RootView.swift`
- `macos/Sources/Views/DirectoryListView.swift`
- `macos/Sources/Views/SessionListView.swift`
- `macos/Sources/Views/ConversationView.swift`
- `macos/Sources/Views/SettingsWindow.swift`
- `macos/Sources/Views/ResourcesView.swift`
- `macos/Sources/Views/CommandMenuView.swift`

**Commands:**
- `macos/Sources/MenuBarCommands.swift` - Menu bar setup

**Tests:**
- `macos/Tests/UntetheredMacTests.swift`

---

## Conclusion

This design provides a clear path to port Untethered to macOS while:
1. Maximizing code reuse through UntetheredCore shared package
2. Embracing macOS-native patterns (NavigationSplitView, keyboard shortcuts, menu bar)
3. Maintaining feature parity with iOS
4. Enabling platform-specific enhancements

The phased approach ensures iOS app stability while incrementally building macOS functionality. Each phase has clear validation criteria to prevent regressions and ensure quality.

The architecture is designed for future expansion (Windows/Linux) by keeping platform-specific code isolated and business logic in the shared package.
