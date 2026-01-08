# Desktop UX Improvements

## Overview

### Problem Statement

The macOS desktop app shares code with iOS but lacks desktop-native interactions. Users experience friction with keyboard shortcuts, trackpad gestures, and discoverable controls. Several iOS-specific settings appear on macOS where they don't apply.

### Goals

1. Add standard macOS keyboard and trackpad interactions
2. Improve discoverability via hover tooltips with keyboard shortcuts
3. Fix layout issues (command history sizing)
4. Hide iOS-only settings on macOS
5. Add stop speech control for TTS
6. Make connection status icon actionable for retry
7. Enable system prompt editing in settings
8. Maintain full iOS feature parity (no iOS regressions)

### Non-goals

- iOS UX changes (except connection retry, which benefits both)
- New features beyond UX improvements
- Backend changes (pure frontend work)

## Background & Context

### Current State

The macOS app was built with maximum code sharing from iOS. Platform conditionals (`#if os(macOS)`) handle API differences, but desktop-specific interactions weren't prioritized for MVP.

Current friction points:
- Return key highlights text instead of sending prompts
- No trackpad swipe navigation
- No hover tooltips on toolbar buttons
- Command history sheet sizing broken
- iOS-only settings visible on macOS
- No way to stop TTS playback
- Connection status not actionable when stuck

### Why Now

Desktop users need native-feeling interactions to be productive. These are polish items that significantly improve daily usage.

### Related Work

- @docs/design/macos-desktop-app.md - Initial macOS MVP design
- @STANDARDS.md - Platform-specific patterns (existing `#if os()` usage)

## Detailed Design

### 1. Text Input Return Key Behavior

**Problem:** Pressing Return in the text input field highlights text instead of sending the prompt.

**Solution:**
- Return (Enter) sends the prompt
- Shift+Return inserts a newline

**Implementation:**

```swift
// ConversationView.swift - TextEditor/TextField handling
// Use onSubmit for simple case, or custom key handling

#if os(macOS)
TextField("Type a message...", text: $inputText, axis: .vertical)
    .onSubmit {
        sendPrompt()
    }
    .onKeyPress(.return) { press in
        if press.modifiers.contains(.shift) {
            // Allow default behavior (newline)
            return .ignored
        } else {
            sendPrompt()
            return .handled
        }
    }
#else
// iOS: Keep existing behavior (keyboard has dedicated send button)
TextField("Type a message...", text: $inputText, axis: .vertical)
#endif
```

**Note:** The `onKeyPress` modifier requires macOS 14.0+. The codebase targets macOS 15.0+, so this is available.

**Target file:** The text input is in `ConversationTextInputView` (defined in ConversationView.swift around line 1422), not the main view body.

**Alternative approach using NSViewRepresentable if onKeyPress insufficient:**

```swift
#if os(macOS)
struct MacTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        return textView
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        if nsView.string != text {
            nsView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacTextEditor

        init(parent: MacTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if NSEvent.modifierFlags.contains(.shift) {
                    return false // Allow newline
                } else {
                    parent.onSubmit()
                    return true // Handled, don't insert newline
                }
            }
            return false
        }
    }
}
#endif
```

### 2. Trackpad Swipe Navigation (macOS)

**Problem:** Two-finger swipe left doesn't navigate back like in native macOS apps.

**Solution:** Add swipe gesture recognizer to views with back navigation.

**Views requiring swipe support:**

| View | Swipe Left Action |
|------|-------------------|
| ConversationView (Session view) | Pop to session list |
| SessionsForDirectoryView (Project view) | Pop to directory list |
| CommandOutputDetailView | Pop to command history |
| CommandExecutionView | Pop to command menu |
| SessionInfoView | Dismiss sheet |
| RecipeMenuView | Dismiss sheet |
| APIKeyManagementView | Dismiss sheet |
| DebugLogsView | Pop to directory list |

**Implementation pattern:**

```swift
// Create reusable modifier for swipe-to-back (macOS only)
// File: Utils/SwipeNavigationModifier.swift

import SwiftUI

#if os(macOS)
struct SwipeToBackModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    var customAction: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .gesture(
                DragGesture(minimumDistance: 50)
                    .onEnded { value in
                        // Two-finger swipe left detection
                        // Horizontal movement, leftward direction
                        if value.translation.width < -50 &&
                           abs(value.translation.height) < abs(value.translation.width) {
                            if let action = customAction {
                                action()
                            } else {
                                dismiss()
                            }
                        }
                    }
            )
    }
}
#endif

// Extension available on both platforms (no-op on iOS)
extension View {
    func swipeToBack(action: (() -> Void)? = nil) -> some View {
        #if os(macOS)
        modifier(SwipeToBackModifier(customAction: action))
        #else
        self // No-op on iOS
        #endif
    }
}
```

**Usage in views:**

```swift
// ConversationView.swift
var body: some View {
    VStack {
        // ... existing content
    }
    #if os(macOS)
    .swipeToBack {
        // Pop navigation - depends on how navigation is structured
        navigationPath.removeLast()
    }
    #endif
}

// SessionInfoView.swift (sheet)
var body: some View {
    NavigationStack {
        // ... content
    }
    #if os(macOS)
    .swipeToBack() // Uses default dismiss
    #endif
}
```

**Note:** SwiftUI's `NavigationStack` on macOS may already support swipe gestures in some contexts. Test before implementing custom gesture to avoid conflicts.

### 3. Button Hover Tooltips (macOS)

**Problem:** Toolbar buttons have no discoverability. Users don't know what buttons do or their keyboard shortcuts.

**Solution:** Add `.help()` modifiers to all toolbar buttons on macOS.

**Buttons requiring tooltips:**

| Button | Tooltip Text |
|--------|-------------|
| Refresh | "Refresh session (Cmd+R)" |
| Kill Session | "Stop current prompt (Cmd+K)" |
| Session Info | "Session info (Cmd+I)" |
| Auto-scroll | "Toggle auto-scroll" |
| Compact | "Compact session history" |
| Recipe | "Run recipe (Cmd+Shift+R)" |
| Queue Remove | "Remove from queue" |
| Stop Speech | "Stop speaking (Cmd+.)" |
| Voice Input | "Start voice input (Space)" |

**Note:** Kill Session uses Cmd+K (not Cmd+.) to avoid conflict with Stop Speech. Cmd+. is reserved for the more common "stop current operation" action (speech).

**Implementation:**

```swift
// ConversationView.swift toolbar section
#if os(macOS)
ToolbarItem(placement: .automatic) {
    HStack(spacing: 16) {
        Button(action: { refreshSession() }) {
            Image(systemName: "arrow.clockwise")
        }
        .help("Refresh session (Cmd+R)")
        .keyboardShortcut("r", modifiers: [.command])

        Button(action: { toggleAutoScroll() }) {
            Image(systemName: autoScrollEnabled ? "arrow.down.circle.fill" : "arrow.down.circle")
                .foregroundColor(autoScrollEnabled ? .blue : .gray)
        }
        .help("Toggle auto-scroll")

        // ... other buttons with .help() modifiers
    }
}
#endif
```

**Keyboard shortcuts to add (macOS only):**

| Action | Shortcut |
|--------|----------|
| Refresh | Cmd+R |
| Session Info | Cmd+I |
| Stop Speech | Cmd+. |
| Recipe Menu | Cmd+Shift+R |
| Send Prompt | Return |

### 4. Command History Sizing

**Problem:** Command history sheet only shows Done button, content not visible.

**Location:** The command history is presented as a sheet in `SessionsForDirectoryView.swift` (line 293). It actually shows `ActiveCommandsListView` (defined in CommandExecutionView.swift), not `CommandHistoryView`.

**Fix:** Add frame constraints to the sheet presentation in `SessionsForDirectoryView.swift`:

```swift
// SessionsForDirectoryView.swift (around line 293)
.sheet(isPresented: $showingCommandHistory) {
    NavigationView {
        ActiveCommandsListView(client: client)
            .toolbar {
                // ... existing toolbar
            }
    }
    #if os(macOS)
    .frame(minWidth: 600, minHeight: 400)
    #endif
}
```

**Alternative:** Add frame constraints inside `ActiveCommandsListView` itself:

```swift
// CommandExecutionView.swift - ActiveCommandsListView
var body: some View {
    List {
        // ... existing content
    }
    .navigationTitle("Active Commands")
    #if os(macOS)
    .frame(minWidth: 500, minHeight: 300)
    #endif
}
```

### 5. Settings: System Prompt Editing

**Problem:** System prompt field in settings cannot be modified on macOS.

**Current implementation (SettingsView.swift lines 176-189):**
```swift
Section(header: Text("System Prompt")) {
    TextField("Custom System Prompt", text: $localSystemPrompt, axis: .vertical)
        .lineLimit(3...6)
        #if os(iOS)
        .autocapitalization(.sentences)
        #endif
        .onChange(of: localSystemPrompt) { newValue in
            settings.systemPrompt = newValue
        }
}
```

The view uses a local `@State` variable `localSystemPrompt` that's initialized from `settings.systemPrompt` in `.onAppear` (line 297).

**Investigation needed:** The issue may be macOS-specific TextField behavior with `.lineLimit()` or the binding pattern. Test on macOS to identify root cause:
1. Is the TextField receiving focus?
2. Is text input being captured?
3. Is the binding updating?

**Potential fixes:**

Option A - Use TextEditor instead of TextField for multi-line on macOS:
```swift
Section(header: Text("System Prompt")) {
    #if os(macOS)
    TextEditor(text: $localSystemPrompt)
        .frame(minHeight: 100)
    #else
    TextField("Custom System Prompt", text: $localSystemPrompt, axis: .vertical)
        .lineLimit(3...6)
        .autocapitalization(.sentences)
    #endif
    .onChange(of: localSystemPrompt) { newValue in
        settings.systemPrompt = newValue
    }
}
```

Option B - Ensure proper focus handling on macOS:
```swift
TextField("Custom System Prompt", text: $localSystemPrompt, axis: .vertical)
    .lineLimit(3...6)
    #if os(macOS)
    .textFieldStyle(.plain)
    #endif
```

### 6. Settings: Hide iOS-Only Options

**Problem:** iOS-specific settings appear on macOS where they don't apply.

**Settings to hide on macOS:**
- "Silence speech when phone is on vibrate"
- "Continue playback even when locked"

**Implementation:**

```swift
// SettingsView.swift
#if os(iOS)
Section("Audio Behavior") {
    Toggle("Silence speech when phone is on vibrate", isOn: $settings.respectSilentMode)
    Toggle("Continue playback even when locked", isOn: $settings.continuePlaybackWhenLocked)
}
#endif
```

### 7. Stop Speech Control

**Problem:** No way to stop TTS when agent response is being read.

**Solution:** Two-part implementation:
1. Toolbar button (macOS only) with Cmd+. shortcut
2. Toggle existing "Read Aloud" button in Message Detail (shared)

**Toolbar button (macOS):**

Note: `voiceOutput` is a `@StateObject` in ConversationView (line 46), not `@EnvironmentObject`.

```swift
// ConversationView.swift - macOS toolbar (around line 396-484)
// voiceOutput is already available as @StateObject var voiceOutput: VoiceOutputManager

// In the macOS toolbar HStack (inside ToolbarItem placement: .automatic):
#if os(macOS)
if voiceOutput.isSpeaking {
    Button(action: { voiceOutput.stop() }) {
        Image(systemName: "stop.circle.fill")
            .foregroundColor(.red)
    }
    .help("Stop speaking (Cmd+.)")
    .keyboardShortcut(".", modifiers: [.command])
}
#endif
```

**Message Detail toggle (shared):**

```swift
// MessageDetailView action buttons
Button(action: {
    if voiceOutput.isSpeaking {
        voiceOutput.stop()
    } else {
        let processedText = TextProcessor.removeCodeBlocks(from: message.text)
        voiceOutput.speak(processedText, workingDirectory: message.session?.workingDirectory)
    }
}) {
    VStack(spacing: 4) {
        Image(systemName: voiceOutput.isSpeaking ? "stop.circle.fill" : "speaker.wave.2.fill")
            .font(.title2)
            .foregroundColor(voiceOutput.isSpeaking ? .red : .primary)
        Text(voiceOutput.isSpeaking ? "Stop" : "Read Aloud")
            .font(.caption)
    }
}
```

### 8. Connection Retry on Status Icon Tap

**Problem:** Connection status icon is informational only. When connection fails, user cannot retry.

**Solution:** Make status icon tappable to force reconnection (both platforms).

**Location:** Connection status is displayed inline in `ConversationView.swift` (lines 239-246), not in a separate view:
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

**Implementation:**

```swift
// ConversationView.swift (around line 239)
// Wrap the existing status indicator in a Button
Button(action: {
    client.forceReconnect()
}) {
    HStack(spacing: 4) {
        Circle()
            .fill(client.isConnected ? Color.green : Color.red)
            .frame(width: 8, height: 8)
        Text(client.isConnected ? "Connected" : "Disconnected")
            .font(.caption)
            .foregroundColor(.secondary)
    }
}
.buttonStyle(.plain)
#if os(macOS)
.help("Click to reconnect")
#endif

// VoiceCodeClient.swift - add new method
func forceReconnect() {
    logger.info("Force reconnect requested by user")
    reconnectionAttempts = 0
    disconnect()
    if let sessionId = sessionId {
        connect(sessionId: sessionId)
    }
}
```

## Verification Strategy

### Testing Approach

#### Unit Tests

Most changes are UI-only and don't require unit tests. However:

1. Test `forceReconnect()` logic in VoiceCodeClient
2. Test keyboard shortcut bindings compile correctly

#### Manual Testing Checklist

| Feature | Test Case | Expected Result |
|---------|-----------|-----------------|
| Return key | Type text, press Return | Prompt sends |
| Shift+Return | Type text, press Shift+Return | Newline inserted |
| Swipe back (Session) | Two-finger swipe left | Navigate to session list |
| Swipe back (Project) | Two-finger swipe left | Navigate to directory list |
| Hover tooltip | Hover over refresh button | Shows "Refresh session (Cmd+R)" |
| Cmd+R | Press Cmd+R in conversation | Session refreshes |
| Cmd+. | Press Cmd+. while speaking | Speech stops |
| Command history | Open command history sheet | Content visible, scrollable |
| System prompt | Edit system prompt in settings | Text editable, saves |
| iOS settings hidden | Open settings on macOS | Silent mode/locked playback not shown |
| Stop speech button | Click stop while speaking | Speech stops immediately |
| Stop speech toggle | Click "Read Aloud" while speaking | Shows "Stop", speech stops |
| Connection retry | Click status when disconnected | Reconnection attempt starts |

#### Platform Matrix

| Feature | iOS | macOS |
|---------|-----|-------|
| Return sends prompt | N/A (keyboard button) | Yes |
| Swipe navigation | N/A | Yes |
| Hover tooltips | N/A | Yes |
| Keyboard shortcuts | N/A | Yes |
| Command history sizing | Unchanged | Fixed |
| System prompt editing | Test works | Test works |
| Hide iOS settings | N/A | Yes |
| Stop speech toolbar | N/A | Yes |
| Stop speech toggle | Yes | Yes |
| Connection retry | Yes | Yes |

### Acceptance Criteria

1. Return key sends prompt in text input (macOS)
2. Shift+Return inserts newline (macOS)
3. Two-finger swipe left navigates back in Session view (macOS)
4. Two-finger swipe left navigates back in Project view (macOS)
5. All toolbar buttons show hover tooltips (macOS)
6. Cmd+R refreshes session (macOS)
7. Cmd+. stops speech (macOS)
8. Command history sheet shows full content (macOS)
9. System prompt is editable in settings (both)
10. "Silence speech on vibrate" hidden on macOS
11. "Continue playback when locked" hidden on macOS
12. Stop speech button appears in toolbar when speaking (macOS)
13. "Read Aloud" toggles to "Stop" when speaking (both)
14. Clicking connection status retries connection (both)
15. All existing iOS functionality unchanged

## Alternatives Considered

### 1. Global Keyboard Shortcut Handler

**Approach:** Single `Commands` menu with all shortcuts defined in one place.

**Pros:**
- Centralized shortcut management
- Follows macOS app conventions

**Cons:**
- Requires more architectural changes
- Shortcuts need context (which view is active)

**Decision:** Deferred. Per-view shortcuts are simpler for this scope.

### 2. NSGestureRecognizer for Swipe

**Approach:** Use AppKit's gesture recognizers directly.

**Pros:**
- More precise control
- Native macOS behavior

**Cons:**
- Requires NSViewRepresentable wrapper
- More code complexity

**Decision:** Try SwiftUI DragGesture first. Use NSGestureRecognizer if needed.

### 3. Floating TTS Control Panel

**Approach:** Separate floating panel for speech controls.

**Pros:**
- Always visible during speech
- Room for future controls (pause, speed)

**Cons:**
- More UI complexity
- Takes screen space

**Decision:** Rejected for now. Toolbar button sufficient for stop control.

## Risks & Mitigations

### 1. Swipe Gesture Conflicts

**Risk:** Custom swipe gesture may conflict with system gestures or NavigationStack's built-in behavior.

**Mitigation:**
- Test thoroughly on macOS
- Check if NavigationStack already supports swipe-back
- Use `.highPriorityGesture()` if needed to override

### 2. Keyboard Shortcut Collisions

**Risk:** Custom shortcuts may conflict with system or other app shortcuts.

**Mitigation:**
- Use standard macOS conventions (Cmd+R for refresh, Cmd+. for stop)
- Test with common apps open
- Document shortcuts in help

### 3. TextField Focus Issues

**Risk:** Return key handling may break when TextField loses focus or in specific states.

**Mitigation:**
- Test with various input states
- Ensure send-on-return only fires when TextField is focused

### Rollback Strategy

1. All changes are additive with `#if os(macOS)` guards
2. iOS code paths unchanged
3. Individual features can be disabled by removing specific modifiers
4. No backend changes required

## Implementation Order

1. **Text input Return key** - Core usability fix
2. **Button hover tooltips** - Low risk, high discoverability value
3. **Stop speech control** - Complete TTS UX
4. **Hide iOS settings** - Simple conditionals
5. **Connection retry** - Benefits both platforms
6. **System prompt editing** - Fix existing feature
7. **Command history sizing** - Fix existing feature
8. **Swipe navigation** - Higher complexity, test carefully
9. **Keyboard shortcuts** - After tooltips document them

## Files to Modify

| File | Changes |
|------|---------|
| `ConversationView.swift` | Return key (in `ConversationTextInputView`), swipe, toolbar tooltips, stop speech button, keyboard shortcuts, connection retry button |
| `SessionsForDirectoryView.swift` | Swipe navigation, command history sheet frame sizing |
| `SettingsView.swift` | Hide iOS settings, fix system prompt editing |
| `CommandExecutionView.swift` | Frame sizing for `ActiveCommandsListView`, swipe navigation |
| `MessageDetailView.swift` | Stop/Read Aloud toggle (note: this is `messageDetailContent` in ConversationView.swift) |
| `VoiceCodeClient.swift` | Add `forceReconnect()` method |
| `SessionInfoView.swift` | Swipe to dismiss |
| `RecipeMenuView.swift` | Swipe to dismiss |
| `APIKeyManagementView.swift` | Swipe to dismiss |
| `DebugLogsView.swift` | Swipe navigation |
| `CommandOutputDetailView.swift` | Swipe navigation |

## New Files

| File | Purpose |
|------|---------|
| `Utils/SwipeNavigationModifier.swift` | Reusable swipe-to-back modifier (optional, could inline) |

## Notes

- `CommandHistoryView.swift` exists but the "command history" button actually presents `ActiveCommandsListView` (defined in `CommandExecutionView.swift`)
- Connection status is inline in `ConversationView.swift`, not a separate view
- Message detail view is defined as `messageDetailContent` computed property within `ConversationView.swift`
