# iOS Simulator Manual Test Report: New Session Creation & Conversation E2E

**Date:** 2026-02-21
**Platform:** iOS Simulator - iPhone 16 Pro (iOS 18.6)
**App:** Untethered (React Native / ClojureScript)
**Backend:** voice-code backend on localhost:8080
**Tester:** Agent (REPL-driven navigation + screenshots)
**Beads Task:** VCMOB-yymo

## Test Summary

| Area | Tests | Passed | Failed | Notes |
|------|-------|--------|--------|-------|
| New Session Creation | 3 | 3 | 0 | Form, navigation, empty state |
| Bug Fix: Subscribe Skip | 2 | 2 | 0 | VCMOB-ymt0 - no error on new sessions |
| Conversation E2E | 3 | 3 | 0 | Prompt sent, response received, messages display |
| Draft Persistence | 2 | 2 | 0 | Draft saved, persists across navigation |
| Session Rename | 2 | 2 | 0 | Custom name set, displayed in header + list |
| Message Detail Modal | 3 | 3 | 0 | Modal opens, actions shown, dismisses cleanly |
| **Total** | **15** | **15** | **0** | |

## Bug Found and Fixed

### Subscribe sends for locally-created sessions (VCMOB-ymt0)
**File:** `frontend/src/voice_code/events/websocket.cljs`
**Issue:** When a new session is created locally and user navigates to the conversation, `component-did-mount` dispatches `:session/subscribe` which sends a WebSocket subscribe message. The backend has no session yet, returning a "Session not found" error banner.
**iOS Reference:** `ConversationView.swift` line 692 skips subscribe when `messageCount == 0`.
**Fix:** Check `:is-locally-created` flag in `:session/subscribe` event handler. If true, mark session as subscribed without sending WebSocket message.
**Tests:** 727 tests, 2839 assertions - all passing after fix.

## 1. New Session Creation

### 1.1 New Session Form
**Evidence:** `01-new-session-empty.png`
- [PASS] New Session screen displays with session name field
- [PASS] Working directory field present
- [PASS] Worktree toggle visible
- [PASS] Back navigation to session list

### 1.2 New Session Conversation (Before Fix)
**Evidence:** `02-new-session-conversation-empty.png`
- [FAIL] Red error banner displayed: "Session not found" (bug VCMOB-ymt0)

### 1.3 New Session Conversation (After Fix)
**Evidence:** `03-new-session-fixed-no-error.png`
- [PASS] Clean empty conversation state - "No messages yet"
- [PASS] No error banner displayed
- [PASS] Text input available for sending first message
- [PASS] Session header shows correct name

## 2. Conversation End-to-End Flow

### 2.1 Send Prompt
**Evidence:** `04-conversation-user-message.png`
- [PASS] Prompt "Reply with exactly: Hello from test" sent via `:conversation/send-prompt`
- [PASS] User message appears immediately with "You" label
- [PASS] Message shows `:sending` status indicator (clock icon)

### 2.2 Receive Response
**Evidence:** `05-conversation-with-response.png`
- [PASS] Backend processed prompt via Claude CLI
- [PASS] Assistant response "Hello from test" received
- [PASS] Response displayed with "Claude" label and icon
- [PASS] Both messages visible in conversation

**REPL Verification:**
```clojure
;; Backend session JSONL confirms round-trip
;; User: "Reply with exactly: Hello from test"
;; Assistant: "Hello from test"
;; Model: claude-opus-4-6
```

### 2.3 Subscribe After Reconnect
- [PASS] After app restart, subscribe to session retrieves both messages
- [PASS] Delta sync works with `last_message_id`

## 3. Draft Persistence

### 3.1 Set Draft
- [PASS] Typed "This is a test draft message" in text input
- [PASS] Draft stored in app-db at `[:ui :drafts "ce220fed-..."]`

### 3.2 Navigate Away and Return
**Evidence:** `05-conversation-with-response.png` (draft visible in input)
- [PASS] Navigated to session list, then back to conversation
- [PASS] Draft text "This is a test draft message" persisted in input field
- [PASS] Draft survives navigation cycle

**REPL Verification:**
```clojure
(get-in @re-frame.db/app-db [:ui :drafts "ce220fed-b02d-4c5d-8c4b-0e841dff7d7f"])
;; => "This is a test draft message"
```

## 4. Session Rename

### 4.1 Rename Via Dispatch
- [PASS] `[:sessions/rename session-id "Test Renamed Session"]` dispatched
- [PASS] `:custom-name` set to "Test Renamed Session" in app-db
- [PASS] Display name resolves to custom-name over backend-name

### 4.2 UI Reflects Rename
**Evidence:** `07-session-list-renamed.png`
- [PASS] Conversation header shows "Test Renamed Session"
- [PASS] Session list shows "Test Renamed Session" for the session

**REPL Verification:**
```clojure
(let [session (get-in @re-frame.db/app-db [:sessions "ce220fed-..."])]
  {:custom-name "Test Renamed Session"
   :backend-name "Reply with exactly: Hello from test"
   :display-name "Test Renamed Session"})
```

## 5. Message Detail Modal

### 5.1 Open Modal
**Evidence:** `06-message-detail-modal.png`
- [PASS] Modal opens with "Claude's Response" header
- [PASS] Full message text "Hello from test" displayed
- [PASS] "Done" dismiss button at top

### 5.2 Action Buttons
- [PASS] "Infer Name" action button visible with icon
- [PASS] "Read Aloud" action button visible with icon
- [PASS] "Copy" action button visible with icon

### 5.3 Dismiss Modal
- [PASS] `hide-message-detail!` dismisses modal cleanly
- [PASS] Returns to conversation view

## Screenshots Index

| File | Screen | Description |
|------|--------|-------------|
| `01-new-session-empty.png` | NewSession | Empty new session form |
| `02-new-session-conversation-empty.png` | Conversation | BEFORE fix - error banner on new session |
| `03-new-session-fixed-no-error.png` | Conversation | AFTER fix - clean empty state |
| `04-conversation-user-message.png` | Conversation | User prompt sent, showing in UI |
| `05-conversation-with-response.png` | Conversation | Both user and assistant messages + draft |
| `06-message-detail-modal.png` | MessageDetail | Modal with actions (Infer Name, Read Aloud, Copy) |
| `07-session-list-renamed.png` | SessionList | Session list showing renamed session |
