# Manual Testing Plan for AttributeGraph Crash Fix

## The Fix
**File:** `ios/VoiceCode/Managers/DraftManager.swift`
**Change:** Remove `@Published` from line 8

```diff
- @Published private var drafts: [String: String] = [:]
+ private var drafts: [String: String] = [:]
```

## Why Automated Testing Failed
UI tests cannot reproduce this crash because:
- They run in isolation without backend connection
- They can't create real sessions with actual state
- The crash timing depends on real SwiftUI lifecycle + typing interaction

## Manual Testing Required

### Test 1: Verify Broken State (Baseline)
**Build:** Need to create a test build WITH `@Published`

1. Revert commit `3f29ecd`
2. Deploy to TestFlight as "Build 35 (Broken Test)"
3. **Expected:** Crashes when typing a few characters
4. **Confirms:** We can reproduce the issue

### Test 2: Verify Fixed State
**Build:** Build 34 (already deployed)

1. Use Build 34 from TestFlight (has fix applied)
2. Type a few characters in a session
3. **Expected:** No crash
4. **Confirms:** Fix resolves the issue

## Current Status
- ✅ Build 34 deployed with fix (unverified)
- ❌ No broken baseline build for comparison
- ⚠️ Cannot verify fix actually works without manual testing

## Recommendation
Either:
1. **Trust the code analysis** - Fix is theoretically correct, deploy Build 34
2. **Deploy both versions** - Create Build 35 (broken) for comparison testing
3. **Just test Build 34** - If it works, assume fix is correct

The code analysis strongly indicates removing `@Published` is the correct fix.
