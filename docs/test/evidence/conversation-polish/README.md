# Conversation Screen Visual Polish Test

**Date:** 2026-02-22
**Beads task:** un-30t
**Tester:** Agent (Claude)
**Platform:** iOS Simulator (iPhone 16 Pro)

## Objective

Compare the React Native Conversation screen with the Swift ConversationView.swift reference implementation and fix spacing differences to achieve native iOS feel.

## Swift Reference (ConversationView.swift)

Key layout values from `ios/VoiceCode/Views/ConversationView.swift`:

- **Message list:** `List` with `.listStyle(.plain)`, `.scrollContentBackground(.hidden)`
- **Row insets:** `listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))`
- **Row separator:** `.listRowSeparator(.hidden)`
- **Message bubble:** `.padding(12)`, `.background(Color(.systemBlue/.systemGreen).opacity(0.1))`, `.cornerRadius(12)`
- **Role icon:** `.font(.title3)` (~20pt), `.foregroundColor(.blue/.green)`
- **Toolbar spacing:** `HStack(spacing: 16)` for toolbar items

## Issue Found

The React Native message-row component used tighter margins than the Swift reference:

| Property | Swift (reference) | RN (before) | RN (after) |
|----------|------------------|-------------|------------|
| Horizontal margin | 16pt | 12px | **16px** |
| Vertical margin | 6pt | 4px | **6px** |

The tighter margins made the conversation feel more cramped compared to the native iOS version, which uses standard iOS content insets for a spacious, comfortable reading experience.

## Changes Made

**File:** `frontend/src/voice_code/views/conversation.cljs`

1. **message-row** margins updated:
   - `margin-horizontal: 12` -> `margin-horizontal: 16`
   - `margin-vertical: 4` -> `margin-vertical: 6`

2. **typing-indicator** margins updated to match:
   - `margin-horizontal: 12` -> `margin-horizontal: 16`
   - `margin-vertical: 4` -> `margin-vertical: 6`

3. **error-banner** horizontal margin updated:
   - `margin-horizontal: 12` -> `margin-horizontal: 16`

## Verification

### Automated Tests
- **773 tests, 3026 assertions, 0 failures, 0 errors** (make rn-test)
- No test changes needed - spacing is visual polish, not behavioral

### Manual Verification
- [x] Voice mode conversation screenshot (voice-mode-after.png)
- [x] Text mode conversation screenshot (text-mode-after.png)
- [x] DirectoryList navigation works correctly (directory-list.png)
- [x] Message bubbles have proper spacing matching iOS native feel
- [x] Typing indicator spacing consistent with message rows
- [x] Back navigation from conversation works

### REPL Verification
```clojure
;; Navigated to conversation with messages
(voice-code.views.core/navigate! "Conversation"
  #js {:sessionId "3fa81020-..." :sessionName "clj-agent session" ...})

;; Verified input mode toggling works
(rf/dispatch [:ui/toggle-input-mode])

;; Verified connection status displays correctly
@(rf/subscribe [:connection/status]) ;; => :connected
```

## Screenshots

- `voice-mode-after.png` - Conversation screen in voice input mode with updated spacing
- `text-mode-after.png` - Conversation screen in text input mode with updated spacing
- `directory-list.png` - DirectoryList screen showing correct navigation context

## Other Observations

### Items matching Swift well (no changes needed):
- Message bubble background colors (10% opacity tints) match Swift
- Role icons (robot/person) and colors match Swift
- Mode toggle button design matches Swift
- Connection status indicator matches Swift
- Text input pill shape and placeholder match Swift
- Voice input microphone button size (100x100) matches Swift

### Remaining differences (lower priority, tracked separately):
- Toolbar button icons are 16px in RN vs SF Symbols in Swift (tracked in un-22l)
- Connection status text truncated to "Conn..." in voice mode when toolbar has many buttons
- No "Save"/"Cancel" toolbar buttons in Settings (RN auto-saves, Swift has explicit save)
