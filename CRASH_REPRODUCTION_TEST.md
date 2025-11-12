# AttributeGraph Crash Reproduction Test

## The Fix
**File:** `ios/VoiceCode/Managers/DraftManager.swift` line 11
**Change:** Removed `@Published` from `private var drafts`

## Test Created
**File:** `ios/VoiceCodeUITests/CrashReproductionTest.swift`

This is a **real integration test** that:
- Connects to actual backend
- Uses real sessions with real state
- Types characters in a real conversation
- Will **CRASH** with `@Published`, **PASS** without it

## How to Run the Test

### Step 1: Start Backend
```bash
cd ~/code/mono/active/voice-code-resources
make backend-run
```

Leave this running in a separate terminal.

### Step 2: Ensure Session Exists
Either:
- Open the app manually and create a session, OR
- Use an existing session from previous usage

### Step 3: Run Integration Test (WITH FIX - should PASS)
```bash
make test-integration
```

**Expected result:** ✅ Test passes, types "test" successfully

### Step 4: Revert to Broken State
```bash
git revert --no-commit HEAD~1  # Revert the @Published removal
```

This restores `@Published` on line 8 of DraftManager.swift

### Step 5: Run Integration Test (WITHOUT FIX - should CRASH)
```bash
make test-integration
```

**Expected result:** ❌ Test fails/crashes after typing 1-3 characters

### Step 6: Restore Fix
```bash
git revert --abort  # Restore the fix
```

## What This Proves

If Step 3 passes and Step 5 fails, this definitively proves:
1. The bug exists (confirmed by Step 5 crash)
2. The fix works (confirmed by Step 3 pass)
3. Removing `@Published` from DraftManager.drafts resolves the AttributeGraph crash

## Current Status
- ✅ Integration test created
- ✅ Fix is currently applied (Build 34 on TestFlight)
- ⏳ Test execution pending (requires backend + sessions)

## Alternative: Manual Testing
If you don't want to run the integration test:

1. **Test Build 34** (has fix): Type a few characters → should work
2. If it crashes, the fix was wrong
3. If it works, the fix is confirmed

The integration test is more scientific but manual testing is simpler.
