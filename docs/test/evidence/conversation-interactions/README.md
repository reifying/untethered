# Manual Test: Conversation Message Interactions

**Task:** VCMOB-db4
**Date:** 2026-02-21
**Platform:** iOS Simulator (iPhone 16 Pro, iOS 18.6)
**Build:** React Native (shadow-cljs)
**Tester:** Agent (REPL-driven testing)

## Test Scope

Conversation screen message interaction features not previously covered by manual testing.

## Test Results

### 1. Input Mode Toggle (Voice ↔ Text)
**Status:** PASS

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Voice mode shows mic icon + "Tap to Speak" | PASS | 01-conversation-voice-mode.png |
| 2 | Toggle to text mode shows text input + "Text Mode" label | PASS | 02-conversation-text-mode.png |
| 3 | Toggle back to voice mode restores mic UI | PASS | 03-voice-mode-toggle-back.png |
| 4 | Mode state tracked via `:ui/input-mode` subscription | PASS | REPL verified |

### 2. Text Input & Draft Persistence
**Status:** PASS

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Text input accepts typed text | PASS | 04-text-input-with-draft.png |
| 2 | Draft persists in app state when navigating away | PASS | REPL: `:ui/draft` subscription verified |
| 3 | Draft restored when returning to conversation | PASS | 05-draft-persisted-after-nav.png |

### 3. Message Detail Modal
**Status:** PASS

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Assistant message shows "Claude's Response" header | PASS | 06-message-detail-modal.png |
| 2 | User message shows "Your Message" header | PASS | 07-user-message-detail-modal.png |
| 3 | Full message text displayed (including code blocks) | PASS | 06-message-detail-modal.png |
| 4 | "Done" button visible to dismiss | PASS | 06-message-detail-modal.png |
| 5 | Modal scrollable for long messages | PASS | Verified via REPL |

### 4. Message Actions
**Status:** PASS

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Assistant messages show 3 actions: Infer Name, Read Aloud, Copy | PASS | 06-message-detail-modal.png |
| 2 | User messages show 2 actions: Read Aloud, Copy (no Infer Name) | PASS | 07-user-message-detail-modal.png |
| 3 | Copy action calls clipboard with haptic feedback | PASS | REPL verified (returned timer ID) |
| 4 | Read Aloud dispatches `:voice/speak-response` | PASS | REPL verified |
| 5 | Infer Name sends `:session/infer-name` (not triggered to avoid cost) | PASS | Code path verified |

### 5. Long-Press Behavior
**Status:** PASS (matches iOS design)

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Long-press on message copies text to clipboard | PASS | Code verified: line 452 |
| 2 | No native context menu on messages (matching iOS) | PASS | iOS ConversationView.swift:1113 confirms removal |
| 3 | Native context menu used on DirectoryList/SessionList | PASS | Code verified: context_menu.cljs |

### 6. Session Info Screen
**Status:** PASS

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Shows session name, directory, git branch, session ID | PASS | 08-session-info.png |
| 2 | "Tap to copy any field" hint visible | PASS | 08-session-info.png |
| 3 | Priority Queue section visible | PASS | 08-session-info.png |

### 7. Light/Dark Mode Appearance
**Status:** PASS

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Dark mode: good contrast, readable text | PASS | 01-conversation-voice-mode.png |
| 2 | Light mode: proper colors, readable | PASS | 09-conversation-light-mode.png |
| 3 | Message detail modal light mode | PASS | 10-message-detail-light-mode.png |
| 4 | Message bubbles have role-based coloring (blue=user, green=assistant) | PASS | 09-conversation-light-mode.png |

## Observations

### Code Block Rendering
The message detail modal shows raw markdown backticks for code blocks rather than formatted/highlighted code. This is consistent with the current design (plain text display in modal) but could be improved in the future.

### Render Loop Warning (Non-blocking)
A "RENDER LOOP DETECTED: 52 renders in 1 second" warning appeared on initial conversation load with 27+ messages. Investigation showed:
- The 50 renders/sec threshold is too sensitive for initial mount of message lists
- Each message row renders as a separate component (~27 messages × 2 render phases ≈ 54)
- Current render rate after load: 1 render/second (no active loop)
- This is a threshold calibration issue, not a real render loop

### Native Context Menu Limitations
Native context menus (via react-native-context-menu-view) cannot be triggered programmatically from the REPL. Testing was limited to code verification. The context menu on DirectoryList and SessionList rows was confirmed structurally correct.

## Test Method
All tests performed via REPL (clojurescript_eval on shadow-cljs port 55152) with screenshots captured via `make rn-screenshot`. Message detail modal triggered by directly setting `selected-message-state` atom. Actions tested by calling handler functions directly.
