# Continuation Prompt: iOS AttributeGraph Crash Reproduction

## Current Status

We have an iOS app crash that occurs **reliably when typing just a few characters** in the ConversationView text field. The crash signature is `swift_deallocClassInstance.cold.1` - an AttributeGraph crash in SwiftUI.

## What We Know

### Root Cause Analysis (High Confidence)

The crash is caused by `DraftManager.swift` line 8:
```swift
@Published private var drafts: [String: String] = [:]
```

**Why this causes the crash:**

When user types in TextField:
1. TextField binding updates `promptText` (line 218 of ConversationView.swift)
2. `.onChange(of: promptText)` fires (line 378)
3. Calls `draftManager.saveDraft()` which mutates `drafts[sessionID] = text` (line 22 of DraftManager.swift)
4. **@Published fires `objectWillChange`**
5. SwiftUI schedules ConversationView re-evaluation **during the same update cycle**
6. AttributeGraph detects re-entrant update → **CRASH**

### The Fix (Tested with unit tests, NOT crash reproduction)

Remove `@Published` from line 8 of DraftManager.swift:
```swift
// CRITICAL: NOT @Published - drafts is internal state only
private var drafts: [String: String] = [:]
```

**Fix is stashed:** `git stash list` shows the fix

**Build 34** was deployed to TestFlight with this fix, but we haven't verified it actually prevents the crash the user experiences.

## The Problem

User can reproduce crash by typing just a few characters, but our UI tests can't reproduce it in an automated way.

### UI Test Attempts

File: `ios/VoiceCodeUITests/VoiceCodeUITests.swift`

**Current test (`testRapidTextInputNoCrash`):**
- Tries to navigate to a session
- Tries to find text field
- Types 3 characters one at a time
- **Problem:** Test environment doesn't have sessions/backend connection, so it can't reach the typing scenario

## What Needs to Happen

### Option 1: Create a Working Automated Test

Create a UI test that:
1. Actually reaches ConversationView with a TextField
2. Types characters and triggers the crash
3. Verifies the crash happens WITH `@Published`
4. Verifies crash is FIXED WITHOUT `@Published`

This may require:
- Creating mock sessions in the test setup
- Mocking backend connection
- Using XCUITest properly to navigate to text input

### Option 2: Manual Testing Protocol

If automated testing isn't feasible:
1. Deploy Build 33 (has `@Published` - should crash)
2. User manually types a few characters → verify crash
3. Deploy Build 34 (no `@Published` - should be fixed)
4. User manually types a few characters → verify no crash

## Files to Understand

### Key Files
1. **ios/VoiceCode/Managers/DraftManager.swift** - The problematic `@Published` on line 8
2. **ios/VoiceCode/Views/ConversationView.swift** - TextField binding (line 218), onChange (line 378)
3. **ios/VoiceCodeUITests/VoiceCodeUITests.swift** - Current UI tests

### Code Execution Trace

See commit `3f29ecd` for complete trace of what happens on each keystroke.

## Commands

```bash
# Current state
git log --oneline -5

# See the fix
git stash show -p

# Apply the fix
git stash pop

# Revert to broken state (for testing)
git revert --no-commit 3f29ecd

# Run UI tests
make test-ui-crash

# Run all tests
make test
```

## What Previous Agent Tried

1. ✅ CoreData threading fixes - Not the issue
2. ✅ Combine `.receive(on:)` - Good practice but not the issue
3. ✅ Debounced UserDefaults - Performance optimization but not the issue
4. ✅ `.task` instead of `.onAppear` - Minor improvement but not the issue
5. ✅ Identified actual root cause - `@Published drafts` in DraftManager
6. ❌ Failed to create automated test that reproduces crash
7. ✅ Deployed Build 34 with fix (unverified)

## Critical Question

**Can you create a UI test that reproduces the crash, or do we need manual testing?**

If you can't create an automated test within 30 minutes, recommend manual testing protocol instead.

## Background Context

- User reports crash is "not an exact timing bug" - happens reliably with just a few characters
- Crash has been happening since Nov 10, 2025 when ResourcesManager was added
- Main branch doesn't have this crash - only `resources` branch
- User has been patient but needs verification the fix actually works
