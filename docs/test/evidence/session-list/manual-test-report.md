# Manual Test: Session List Screen (VCMOB-qv1v)

**Date:** 2026-02-21
**Platform:** iOS Simulator (iPhone 16 Pro, iOS 18.6)
**App:** React Native frontend (shadow-cljs)
**Method:** REPL-driven state injection + visual screenshots
**Reference:** `ios/VoiceCode/Views/SessionsForDirectoryView.swift`

## Test Summary

| # | Test Case | Status | Evidence |
|---|-----------|--------|----------|
| 1 | Populated session list rendering (dark mode) | PASS | 01-session-list-dark-mode.png |
| 2 | Empty state with directory name (dark mode) | PASS | 02-empty-state-dark.png |
| 3 | Empty state (light mode) | PASS | 03-empty-state-light.png |
| 4 | Populated session list (light mode) | PASS | 04-populated-list-light.png |
| 5 | Unread badge rendering (3, 42, 99+) | PASS | 05-unread-badges-light.png |
| 6 | Locked session indicator (light mode) | PASS | 06-locked-session-light.png |
| 7 | Locked session indicator (dark mode) | PASS | 07-locked-session-dark.png |
| 8 | Navigation to Conversation screen | PASS | 08-conversation-navigation.png |
| 9 | Running command green dot indicator | PASS | 09-running-command-green-dot.png |
| 10 | Session sort order (newest first) | PASS | REPL verification |
| 11 | Message count display accuracy | PASS | REPL verification |
| 12 | Relative timestamp display | PASS | REPL verification |
| 13 | Disclosure indicator (chevron) | PASS | REPL verification |
| 14 | Session deletion | PASS | REPL verification |
| 15 | Session unlock clears indicator | PASS | REPL verification |
| 16 | Toolbar button state (commands badge) | PASS | REPL verification |
| 17 | Toolbar button state (speaking indicator hidden when not speaking) | PASS | REPL verification |
| 18 | Platform-conditional swipe (iOS: swipeable, Android: context menu) | PASS | Unit test verification |

**Result: 18/18 PASS**

## Detailed Test Results

### 1. Populated Session List Rendering (Dark Mode)
- 18 sessions displayed for voice-code-react-native directory
- Session names truncated correctly with ellipsis
- Message counts shown ("69 messages", "411 messages", etc.)
- Relative timestamps ("10m ago", "29m ago", "2h ago")
- Card-style rows with separator lines
- Header toolbar with gear, +, refresh, history, command badge icons

### 2-3. Empty State (Dark + Light)
- Tray icon rendered at 64pt (iOS parity: `Image(systemName: "tray")`)
- Title: "No sessions in empty-project" (includes directory name)
- Subtitle: "Create a new session with the + button to get started."
- Proper contrast in both light and dark modes

### 4. Populated Session List (Light Mode)
- White card backgrounds with dark text
- Blue accent color for + button and back nav
- Gray secondary text for timestamps and message counts
- Separator lines between rows

### 5. Unread Badge Rendering
- Badge count 3: Small red circle with white "3"
- Badge count 42: Red circle with white "42"
- Badge count 150: Red circle with "99+" (caps correctly)
- Badge uses `:destructive` (red) color, not `:accent` (blue) - iOS parity
- Session name font-weight increases to "700" for unread sessions

### 6-7. Locked Session Indicator (Light + Dark)
- Orange dot (8x8, `border-radius: 4`) on left side of row
- "• Processing" text in `:warning` color appended after message count
- Matches iOS `SessionsForDirectoryView.swift` lock indicator
- Indicator correctly removed after unlock dispatch

### 8. Navigation to Conversation
- Tapping session navigates to Conversation screen
- Session name passed as navigation parameter
- Back button returns to session list

### 9. Running Command Green Dot
- Green dot (8x8) on Active Commands (history) toolbar button
- Appears when `:commands/running-any?` is truthy
- Disappears when all commands complete
- iOS parity: `clock.arrow.circlepath` with green dot

### 10-17. REPL-Verified Behaviors
- **Sort order:** Sessions sorted by `:last-modified` descending (verified with `apply >=` on timestamps)
- **Message count:** Data matches display (69, 411, 506, 906, 379...)
- **Timestamps:** `relative-time-text` component auto-updates
- **Disclosure indicator:** Renders valid hiccup (chevron icon)
- **Deletion:** Count drops from 18 to 17, deleted session filtered from subscription
- **Unlock:** Locked set empties, indicator disappears
- **Command badge:** Shows 78 (total project + general commands for directory)
- **Speaking indicator:** Hidden when `:voice/speaking?` is false

### 18. Platform-Conditional Swipe
- iOS: `swipeable-session-item` wraps each row (swipe-to-delete)
- Android: `session-item` only (context menu, no swipe)
- Verified via unit test `platform-ios-flag-for-swipe-test`

## Automated Test Coverage

The session list has comprehensive unit test coverage (652 lines, 35+ tests):
- Session name display (custom > backend > ID fallback)
- Directory filtering
- Sort order
- Lock state tracking
- Unread count tracking
- Deletion flow
- Toolbar state (commands, speaking, refresh)
- Platform-conditional swipe
- Icon mapping
- Empty state rendering
- Badge color (destructive red, not accent blue)

## Bugs Found

None.

## Notes

- All sessions currently have the same name pattern ("If clojure-mcp tool is not working...") - this is real production data, not a bug
- The GO_BACK error toast visible in some screenshots is from testing navigation edge cases (calling goBack at root), not a Session List bug
- Preview text with bullet separator is functional but hard to verify visually in rotated screenshots - confirmed via code inspection that the layout matches iOS CDSessionRowContent
