# Manual Test: Conversation Message Types and Edge Cases

**Task:** un-c1z
**Date:** 2026-02-22
**Platform:** iOS Simulator (iPhone 16 Pro, iOS 18.6)
**Build:** React Native (shadow-cljs)
**Tester:** Agent (REPL-driven testing)

## Test Scope

Comprehensive testing of conversation screen message rendering for all role types (user, assistant, tool-call, tool-result), including truncation behavior, usage/cost display, and the message detail modal. This area was identified as untested in the test coverage analysis.

## Bug Found and Fixed

### Message Detail Modal Title (un-c1z)

**Bug:** The message detail modal showed "Claude's Response" for ALL non-user messages, including tool-call and tool-result messages. The title logic used a simple binary check: `(if (= role :user) "Your Message" "Claude's Response")`.

**Fix:** Replaced with a `case` expression that maps each role to its correct title:
- `:user` → "Your Message"
- `:assistant` → "Claude's Response"
- `:tool-call` → "Tool Call"
- `:tool-result` → "Tool Result"
- default → "Message"

Extracted the logic into a public `modal-title` function for testability.

**Files changed:**
- `frontend/src/voice_code/views/conversation.cljs` — Added `modal-title` fn, used in modal header
- `frontend/test/voice_code/conversation_test.cljs` — Added `modal-title-test` with 5 test cases

## Test Results

### 1. Message Role Rendering
**Status:** PASS

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | User message: blue tint, person icon, "You" label | PASS | 01-all-role-types-top.png |
| 2 | Assistant message: green tint, robot icon, "Claude" label | PASS | 01-all-role-types-top.png |
| 3 | Tool Call message: orange tint, wrench icon, "Tool Call" label | PASS | 01-all-role-types-top.png |
| 4 | Tool Result message: purple tint, document icon, "Tool Result" label | PASS | 01-all-role-types-top.png |

### 2. Message Truncation
**Status:** PASS

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Long assistant message shows middle truncation marker | PASS | 02-assistant-code-block-truncated.png |
| 2 | Truncation marker shows character count: "...[141 chars truncated]..." | PASS | 02-assistant-code-block-truncated.png |
| 3 | "View Full" link appears on truncated messages | PASS | 02-assistant-code-block-truncated.png |
| 4 | "Actions" link appears on non-truncated messages | PASS | 01-all-role-types-top.png |

### 3. Usage/Cost Display
**Status:** PASS

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Assistant message shows token usage: "1.5K in / 89 out" | PASS | 01-all-role-types-top.png |
| 2 | Assistant message shows cost: "$0.0048" | PASS | 01-all-role-types-top.png |
| 3 | Combined format: "2.8K in / 312 out · $0.01" | PASS | 02-assistant-code-block-truncated.png |
| 4 | Non-assistant messages show no usage/cost | PASS | 01-all-role-types-top.png |

### 4. Message Detail Modal - Title Bug (BEFORE fix)
**Status:** BUG FOUND → FIXED

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Tool Call modal showed "Claude's Response" (WRONG) | BUG | 03-tool-call-detail-modal-bug.png |
| 2 | Tool Result modal showed "Claude's Response" (WRONG) | BUG | 04-tool-result-detail-modal-bug.png |

### 5. Message Detail Modal - Title Bug (AFTER fix)
**Status:** PASS

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Tool Call modal now shows "Tool Call" | PASS | 06-tool-call-detail-fixed.png |
| 2 | Tool Result modal now shows "Tool Result" | PASS | 07-tool-result-detail-fixed.png |

### 6. Message Detail Modal - Actions
**Status:** PASS

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Tool Call modal shows Copy and Read Aloud (no Infer Name) | PASS | 06-tool-call-detail-fixed.png |
| 2 | Tool Result modal shows Copy and Read Aloud (no Infer Name) | PASS | 07-tool-result-detail-fixed.png |
| 3 | Infer Name only appears for assistant messages | PASS | Code verified |

### 7. Light Mode
**Status:** PASS

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Message role colors visible in light mode | PASS | 05-light-mode-bottom.png |
| 2 | Code block text readable in light mode | PASS | 05-light-mode-bottom.png |
| 3 | Usage/cost text readable in light mode | PASS | 05-light-mode-bottom.png |

## Code Block Rendering

Code blocks in messages display as plain text with visible markdown backticks (` ```clojure `). This matches the Swift iOS reference implementation, which also renders plain text in both the message list and detail modal. No markdown rendering is performed in either implementation.

## Automated Tests

- **787 tests, 3066 assertions, 0 failures, 0 errors** (`make rn-test`)
- Added `modal-title-test` with 5 assertions covering all role types and unknown/nil fallback

## Test Method

All tests performed via REPL (`clojurescript_eval` on shadow-cljs). Test messages injected via `rf/dispatch-sync [:messages/add ...]` with controlled role types, timestamps, usage, and cost data. Modal state triggered via `selected-message-state` atom. Screenshots captured via `make rn-screenshot`.

## Screenshots

- `01-all-role-types-top.png` — All 4 role types visible: user (blue), assistant (green), tool-call (orange), tool-result (partially visible)
- `02-assistant-code-block-truncated.png` — Truncated assistant message with code block, usage/cost, "View Full" link
- `03-tool-call-detail-modal-bug.png` — BEFORE fix: Tool Call modal showing wrong "Claude's Response" title
- `04-tool-result-detail-modal-bug.png` — BEFORE fix: Tool Result modal showing wrong "Claude's Response" title
- `05-light-mode-bottom.png` — Light mode rendering of messages
- `06-tool-call-detail-fixed.png` — AFTER fix: Tool Call modal showing correct "Tool Call" title
- `07-tool-result-detail-fixed.png` — AFTER fix: Tool Result modal showing correct "Tool Result" title
