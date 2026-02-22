# Manual Test: New Session Screen

**Task:** un-i7c
**Date:** 2026-02-22
**Platform:** iOS Simulator (iPhone 16 Pro, iOS 18.6)
**Build:** React Native (shadow-cljs)
**Tester:** Agent (REPL-driven testing)

## Test Scope

New Session creation screen — first manual test of this screen. Validates form rendering, validation logic, session creation, priority queue auto-add, and visual appearance in both dark/light modes.

## Test Results

### 1. Form Rendering
**Status:** PASS

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Three section cards render: Session Details, Examples, Git Worktree | PASS | 01-new-session-dark-empty.png, 03-new-session-dark-all-sections.png |
| 2 | Session Name field with "Enter name" placeholder | PASS | 01-new-session-dark-empty.png |
| 3 | Working Directory field with "Optional" placeholder | PASS | 01-new-session-dark-empty.png |
| 4 | Examples show 3 paths: /Users/yourname/projects/myapp, /tmp/scratch, ~/code/voice-code | PASS | 01-new-session-dark-empty.png |
| 5 | Git Worktree toggle visible with section footer | PASS | 03-new-session-dark-all-sections.png |

### 2. Header Buttons
**Status:** PASS

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | "Cancel" button on left (blue accent color) | PASS | 01-new-session-dark-empty.png |
| 2 | "Create" button on right (disabled/dimmed when name empty) | PASS | 01-new-session-dark-empty.png |
| 3 | Title "New Session" centered in header | PASS | 01-new-session-dark-empty.png |

### 3. Form Validation (Create Button Disabled Logic)
**Status:** PASS

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Create disabled when name is empty | PASS | Unit test: `form-validation-test` |
| 2 | Create enabled when name is provided (no worktree) | PASS | Unit test |
| 3 | Create disabled when worktree enabled + directory empty | PASS | Unit test |
| 4 | Create enabled when worktree enabled + both fields filled | PASS | Unit test |
| 5 | Whitespace-only name allowed (matches iOS `.isEmpty` behavior) | PASS | Unit test |

### 4. Session Creation via Event Dispatch
**Status:** PASS

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | `:session/create-new` creates session in app-db | PASS | REPL verified |
| 2 | Session has correct `:custom-name` | PASS | REPL: `"REPL Test Session"` |
| 3 | Session has correct `:working-directory` | PASS | REPL: `"/Users/test/project"` |
| 4 | Session has `:is-locally-created true` | PASS | REPL verified |
| 5 | Session has `:message-count 0` | PASS | REPL verified |
| 6 | `:active-session-id` set to new session | PASS | REPL verified |
| 7 | `:backend-name` equals session ID (UUID format) | PASS | REPL verified |

### 5. Priority Queue Auto-Add
**Status:** PASS (bug found and fixed in test)

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Session gets `:priority 10` when queue enabled | PASS | REPL verified |
| 2 | Session gets `:priority-order 1.0` when queue enabled | PASS | REPL verified |
| 3 | Session gets `:priority-queued-at` timestamp when queue enabled | PASS | REPL verified |

**Bug Fixed:** Unit test `session-create-new-auto-queue-test` was setting wrong settings key (`:auto-add-to-priority-queue` instead of `:priority-queue-enabled`) and lacked assertions on priority fields. Fixed to use correct key and verify `:priority`, `:priority-order`, and `:priority-queued-at`.

### 6. Cancel Navigation
**Status:** PASS

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Navigating back returns to DirectoryList | PASS | REPL: `(.goBack nav-ref)` → route "DirectoryList" |

### 7. Light/Dark Mode
**Status:** PASS

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Dark mode: black background, light text, dark section cards | PASS | 01-new-session-dark-empty.png |
| 2 | Light mode: grouped-background gray, white section cards | PASS | 02-new-session-light-mode.png |
| 3 | Accent color (blue) consistent for Cancel button | PASS | Both screenshots |

### 8. iOS Parity Verification
**Status:** PASS

| # | Feature | Swift Reference | React Native | Match? |
|---|---------|-----------------|-------------|--------|
| 1 | Form style | SwiftUI Form (inset grouped) | section-card | YES |
| 2 | Sections | 3 sections | 3 sections | YES |
| 3 | Cancel/Create buttons | ToolbarBuilder.cancelAndConfirm | headerLeft/headerRight | YES |
| 4 | Create disabled logic | `name.isEmpty \|\| (worktree && dir.isEmpty)` | Same | YES |
| 5 | Toggle | Standard iOS Toggle | Native Switch with platform colors | YES |
| 6 | Auto-capitalize name | `.textInputConfiguration()` (words) | `auto-capitalize: "words"` | YES |
| 7 | Path no-autocap | `.pathInputConfiguration()` | `auto-capitalize: "none"` | YES |
| 8 | Footer text | Git worktree description | Same text | YES |
| 9 | Priority queue auto-add | Auto-add if enabled | Auto-add if enabled | YES |

## Bug Found

**Test Bug: Wrong settings key in auto-queue test**
- **File:** `frontend/test/voice_code/new_session_test.cljs`
- **Severity:** Test-only (not a production bug)
- **Root Cause:** Test dispatched `[:settings/update :auto-add-to-priority-queue true]` but the event handler checks `(get-in db [:settings :priority-queue-enabled])` — different key
- **Fix:** Changed to correct key `:priority-queue-enabled`, added negative test for disabled state, added assertions for `:priority`, `:priority-order`, `:priority-queued-at`
- **Tests:** 773 tests, 3033 assertions, 0 failures after fix

## Test Method

All tests performed via REPL (`clojurescript_eval`) with screenshots captured via `make rn-screenshot`. Session creation tested by dispatching events directly and inspecting app-db state. Navigation verified by checking route names via nav-ref.

## Note

Screenshots appear rotated due to simulator in landscape orientation (from prior XCUITest run). Content is fully visible and verified.
