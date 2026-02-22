# Manual Test: Conversation View States (un-85j)

**Date:** 2026-02-22
**Platform:** iOS Simulator (iPhone 16 Pro, iOS 18.6)
**Build:** React Native (shadow-cljs)
**Method:** REPL-driven state injection + visual screenshots
**Reference:** `ios/VoiceCode/Views/ConversationView.swift`

## Test Summary

| # | Test Case | Status | Evidence |
|---|-----------|--------|----------|
| 1 | Conversation with messages renders correctly | PASS | 01-conversation-with-messages.png |
| 2 | Session not found state | PASS | 02-session-not-found.png |
| 3 | Empty conversation state (dark mode) | PASS | 04-empty-state-after-error-cleared.png |
| 4 | Empty conversation state (light mode) | PASS | 05-empty-state-light-mode.png |
| 5 | Loading indicator | PASS | 06-loading-indicator.png |
| 6 | Text input mode (empty) | PASS | 07-text-input-mode.png |
| 7 | Text input mode (with draft) | PASS | 08-text-input-with-draft.png |
| 8 | Text input locked state | PASS | 09-text-input-locked.png |
| 9 | Stale error cleared on conversation mount | PASS | 10-clean-conversation-no-stale-error.png |

**Result: 9/9 PASS**

## Bug Found and Fixed

### Stale Error Banner Overlapping Conversation States

**Problem:** When navigating to a conversation, stale errors from previous screens (or earlier operations) persisted in the global error state. The error banner rendered on top of the conversation's own conditional states (empty-conversation, session-not-found, loading-conversation), creating confusing dual-error displays.

**Root cause:** The conversation view's `component-did-mount` dispatched `[:session/subscribe]` without first clearing `[:ui/current-error]`. If a previous screen set an error, it would remain visible even though the conversation view has its own state handling.

**Fix:** Added `(rf/dispatch [:ui/clear-error])` to `conversation-view`'s `component-did-mount` lifecycle, before the subscribe dispatch. This clears stale errors while still allowing new errors (e.g., from a subscribe failure) to display.

**File changed:** `frontend/src/voice_code/views/conversation.cljs` (line 1440)

**Tests added:** 2 new tests in `conversation_test.cljs`:
- `conversation-mount-clears-stale-error-test`: Verifies stale errors are cleared
- Verifies new errors can still be set after clearing

## Detailed Test Results

### 1. Conversation with Messages
- Messages display with role icons (blue=user, green=assistant)
- Message bubbles have correct tinted backgrounds (0.1 opacity)
- Role labels, timestamps, and "Actions" buttons render correctly
- Toolbar shows correct icons

### 2. Session Not Found
- Warning icon and "Error" header with red border
- Shows full session UUID for debugging
- "Tap to copy" hint for copying session ID
- Note: When navigating to a nonexistent session, both the error banner AND session-not-found view render. The error banner is from the backend subscribe failure, while session-not-found is from the local state check. This is redundant but not blocking.

### 3-4. Empty Conversation (Dark + Light Mode)
- Chat bubble icon (64px) centered vertically
- "No messages yet" title (22px, semibold, secondary color)
- "Start a conversation to see messages here." subtitle (17px, centered)
- Matches iOS ConversationView.swift empty state specification
- Proper contrast in both dark and light modes

### 5. Loading Indicator
- Blue spinner (ActivityIndicator, large size)
- "Loading conversation..." text (14px, secondary color)
- Centered with padding-top 100
- Matches iOS ProgressView + caption specification

### 6-7. Text Input Mode
- Pill-shaped input (border-radius 20, 16px font)
- "Type your message..." placeholder in muted color
- Draft text displays correctly when set via `:ui/set-draft`
- Send button changes color: blue (has text), gray (empty), orange (locked)
- Mode toggle button ("Text Mode" / "Voice Mode") with icon

### 8. Locked State
- Input field at 50% opacity (matches iOS .opacity(0.5))
- Placeholder: "Session locked — tap to unlock"
- Lock icon (orange) replaces send icon
- Typing indicator ("Claude is thinking...") in message list footer
- Matches iOS ConversationTextInputView locked behavior

### 9. Stale Error Fix Verification
- Set a fake error, navigated to conversation, error was cleared
- No error banner visible on clean conversation mount
- Verified via REPL: `@(rf/subscribe [:ui/current-error])` returned `nil`

## Swift Reference Comparison

| Element | Swift | React Native | Match? |
|---------|-------|-------------|--------|
| Empty state icon | message (64pt) | chatbubble (64px) | Yes |
| Empty state title | title2, secondary | 22px, 600, secondary | Yes |
| Loading spinner | ProgressView | ActivityIndicator | Yes |
| Loading text | caption, secondary | 14px, secondary | Yes |
| Input border-radius | roundedBorder | 20px (pill) | Intentional diff |
| Send button size | 32pt | 32px | Yes |
| Locked opacity | 0.5 | 0.5 | Yes |
| Mode toggle bg | blue.opacity(0.1) | accent-background | Yes |
| Message bubble padding | 12pt | 12px | Yes |
| Message bubble radius | 12pt | 12px | Yes |

## Automated Test Coverage

**789 tests, 3075 assertions, 0 failures, 0 errors**

New tests added:
- `conversation-mount-clears-stale-error-test` (2 assertions)
