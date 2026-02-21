# Manual Test: Session Locking UI

**Beads Task:** VCMOB-7gzp
**Date:** 2026-02-21
**Platform:** iOS Simulator - iPhone 16 Pro (iOS 18.6)
**App:** Untethered (React Native / ClojureScript)
**Backend:** voice-code backend on localhost:8080
**Tester:** Agent (REPL-driven state manipulation + screenshots)

## Test Summary

| Area | Tests | Passed | Failed | Notes |
|------|-------|--------|--------|-------|
| Unlock State (Voice Mode) | 3 | 3 | 0 | Blue mic, "Tap to Speak" |
| Lock State (Voice Mode) | 4 | 4 | 0 | Gray mic, "Tap to Unlock", kill button |
| Lock State (Text Mode) | 3 | 3 | 0 | Input disabled, lock icon on send |
| Unlock State (Text Mode) | 2 | 2 | 0 | Input enabled, send icon |
| Session List Lock Indicator | 2 | 2 | 0 | Red badge on locked session |
| State Transitions (REPL) | 3 | 3 | 0 | Lock/unlock cycle verified |
| **Total** | **17** | **17** | **0** | |

## 1. Unlocked State (Voice Mode)

**Evidence:** `01-conversation-unlocked.png`, `07-voice-mode-unlocked.png`

- [PASS] Microphone icon is blue (active color)
- [PASS] "Tap to Speak" text displayed
- [PASS] No kill button (red X) in toolbar

**REPL Verification:**
```clojure
@(rf/subscribe [:session/locked? session-id])
;; => false
(:locked-sessions @re-frame.db/app-db)
;; => #{}
```

## 2. Locked State (Voice Mode)

**Evidence:** `02-conversation-locked.png`

- [PASS] Microphone icon is gray (disabled color)
- [PASS] "Tap to Unlock" text replaces "Tap to Speak"
- [PASS] Kill button (red X) appears in toolbar
- [PASS] Tapping mic dispatches `[:sessions/unlock session-id]`

**REPL Verification:**
```clojure
(rf/dispatch-sync [:sessions/lock session-id])
@(rf/subscribe [:session/locked? session-id])
;; => true
(:locked-sessions @re-frame.db/app-db)
;; => #{"20140abc-ac0b-4a93-adb1-7d91e49dd82f"}
```

## 3. Locked State (Text Mode)

**Evidence:** `03-text-mode-locked.png`, `05-text-mode-locked-detail.png`

- [PASS] Text input field disabled/replaced with touchable overlay
- [PASS] Send button shows lock icon in warning color
- [PASS] Tapping text input area triggers unlock

**Code Reference (conversation.cljs):**
- TextInput wrapped in `[touchable]` when locked (line 842)
- Send button shows `:lock` icon instead of `:send` (line 911)
- iOS parity: matches `ConversationView.swift` `.onTapGesture { if isDisabled { onManualUnlock() } }` (line 1399)

## 4. Unlocked State (Text Mode)

**Evidence:** `04-text-mode-unlocked.png`

- [PASS] "Type your message..." placeholder visible in text input
- [PASS] Send button shows blue send icon (not lock)

## 5. Session List Lock Indicator

**Evidence:** `06-session-list-locked-indicator.png`

- [PASS] Locked session shows red badge/indicator in session list
- [PASS] Other sessions show normal state (no red indicator)

## 6. State Transitions (REPL Verification)

**Result: PASS**

Full lock/unlock cycle verified programmatically:

```clojure
[{:step "initial",     :locked? false}
 {:step "after-lock",  :locked? true,
  :locked-sessions #{"20140abc-ac0b-4a93-adb1-7d91e49dd82f"}}
 {:step "after-unlock", :locked? false, :locked-sessions #{}}]
```

## Implementation Details Verified

| Feature | iOS Reference | RN Implementation | Status |
|---------|--------------|-------------------|--------|
| Voice mode disabled when locked | ConversationView.swift | conversation.cljs:770-804 | Parity |
| "Tap to Unlock" text | ConversationView.swift | conversation.cljs:804 | Parity |
| Text input overlay when locked | ConversationView.swift:1399 | conversation.cljs:842 | Parity |
| Lock icon on send button | ConversationView.swift | conversation.cljs:911 | Parity |
| Kill button when locked | ConversationView.swift | conversation.cljs:1358 | Parity |
| Compact button disabled when locked | ConversationView.swift | conversation.cljs:1298 | Parity |
| Typing indicator when locked | ConversationView.swift | conversation.cljs:1019 | Parity |

## Screenshots Index

| File | Screen | Description |
|------|--------|-------------|
| `01-conversation-unlocked.png` | Conversation | Voice mode, unlocked, normal state |
| `02-conversation-locked.png` | Conversation | Voice mode, locked, "Tap to Unlock" |
| `03-text-mode-locked.png` | Conversation | Text mode, locked, input disabled |
| `04-text-mode-unlocked.png` | Conversation | Text mode, unlocked, input enabled |
| `05-text-mode-locked-detail.png` | Conversation | Text mode locked with detail |
| `06-session-list-locked-indicator.png` | SessionList | Red indicator on locked session |
| `07-voice-mode-unlocked.png` | Conversation | Voice mode, unlocked, blue mic |
