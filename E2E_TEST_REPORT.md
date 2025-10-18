# End-to-End Test Report

## Test voice-code-97: Terminal to iOS Sync

**Date**: 2025-10-17
**Status**: READY FOR MANUAL TESTING
**Backend**: Running on port 8080
**Test Duration**: ~10 minutes

### Prerequisites

✅ **Backend Server**: Running on `localhost:8080`
- Process ID: 35935
- Session index loaded: 677 sessions
- Filesystem watcher: Active (71 project directories)

❓ **iOS App**: Needs to be started in simulator
- Configure server URL: `ws://localhost:8080`
- Ensure WebSocket connection establishes

### Test Steps

#### Step 1: Start iOS App
1. Open Xcode
2. Select iPhone 16 Pro simulator
3. Run VoiceCode app (Cmd+R)
4. Verify app launches successfully
5. Navigate to Settings
6. Set Server URL to `http://localhost:8080` (or `ws://localhost:8080`)
7. Verify connection indicator shows "Connected"

**Expected Result**: iOS app connects to backend, displays connection status

---

#### Step 2: Verify Initial Session List
1. Navigate to Sessions view in iOS app
2. Observe session list

**Expected Result**:
- Session list loads
- May show existing sessions from `~/.claude/` directory
- Sessions sorted by last modified date (newest first)

---

#### Step 3: Create New Claude Session from Terminal
1. Open Terminal
2. Navigate to a test project directory:
   ```bash
   cd ~/code/mono/active/voice-code
   ```
3. Start a new Claude Code session:
   ```bash
   claude
   ```
4. Wait for Claude Code prompt to appear

**Expected Result**:
- Claude Code session starts successfully
- Creates `.jsonl` file in `~/.claude/projects/<project-name>/`

---

#### Step 4: Verify iOS Receives session_created
1. Switch to iOS app
2. Observe Sessions list

**Expected Result**:
- New session appears in list within 1-2 seconds
- Session displays correct:
  - Project name/working directory
  - Timestamp
  - Message count (0)

---

#### Step 5: Verify Auto-Subscription
1. In iOS app, tap on the newly created session
2. Observe conversation view

**Expected Result**:
- Conversation view opens
- Shows "No messages yet" empty state
- Title shows session name
- iOS automatically subscribes to session updates

---

#### Step 6: Send Prompt from Terminal
1. Switch back to Terminal with Claude Code session
2. Send a simple prompt:
   ```
   > What is 2 + 2?
   ```
3. Wait for Claude's response

**Expected Result**:
- Claude responds with answer
- Terminal displays full conversation

---

#### Step 7: Verify iOS Receives session_updated
1. Switch to iOS app (still viewing the conversation)
2. Observe message list

**Expected Result**:
- User prompt appears: "What is 2 + 2?"
- Assistant response appears: "4" (or similar explanation)
- Messages display correct:
  - Role indicators (user/assistant icons)
  - Message text
  - Timestamps
  - Proper formatting

---

#### Step 8: Verify Message Display
1. In iOS app, review the conversation
2. Long-press on assistant message
3. Select "Read Aloud" from context menu

**Expected Result**:
- Context menu appears
- "Read Aloud" option present
- Tapping it reads message via TTS

---

#### Step 9: Send Additional Prompts
1. In Terminal, send another prompt:
   ```
   > What is the capital of France?
   ```
2. Verify iOS updates

**Expected Result**:
- New messages appear on iOS in real-time
- Conversation stays synchronized
- Auto-scroll to latest message

---

#### Step 10: Test Smart Speaking
1. Keep iOS app in foreground on conversation view
2. Send prompt from terminal
3. Listen for TTS output from iOS

**Expected Result**:
- iOS speaks the assistant's response automatically (if session is active)
- Only speaks for currently viewed session

---

### Success Criteria

✅ All test steps complete without errors
✅ Sessions sync from terminal to iOS
✅ Auto-subscription works correctly
✅ Messages display properly with correct metadata
✅ Real-time updates work (< 2 second latency)
✅ Smart speaking activates for active session

### Issues Found

_To be filled during manual testing_

### Notes

- Backend has 677 existing sessions loaded
- Filesystem watcher monitoring 71 project directories
- WebSocket protocol uses JSON messages with snake_case keys
- iOS displays sessions using CoreData with lazy loading

### Next Tests

- voice-code-98: Test iOS to iOS sync (multiple devices)
- voice-code-99: Test session forking
- voice-code-100: Test deletion workflow
- voice-code-101: Performance testing

---

## Additional Verification Tests

### Test: Unread Count (Background Sessions)
1. While viewing Session A on iOS, send prompts to Session B from terminal
2. Return to Sessions list

**Expected**: Session B shows unread badge with count

### Test: Session Renaming
1. In iOS conversation view, tap pencil icon
2. Enter custom name "My Test Session"
3. Save

**Expected**: Session displays custom name in list and conversation view

### Test: Session Deletion
1. In Sessions list, swipe left on a session
2. Tap "Delete"

**Expected**:
- Session disappears from list
- Backend receives `session_deleted` message
- Session marked as deleted in CoreData

### Test: Read Aloud
1. Long-press any message
2. Select "Read Aloud"

**Expected**: Message is read via text-to-speech

---

## Backend Status

**Server**: ✅ Running
**Port**: 8080
**PID**: 35935
**Session Index**: 677 sessions loaded
**Filesystem Watcher**: Active (71 directories)

## iOS App Requirements

- **Xcode**: Latest version
- **Simulator**: iPhone 16 Pro (or similar)
- **Server Configuration**: `http://localhost:8080`
- **Test Duration**: 10-15 minutes for full test suite

## Test Report Template

```
Test Date: _______
Tester: _______
iOS Version: _______
Simulator: _______

Step 1: [ ] PASS [ ] FAIL
Step 2: [ ] PASS [ ] FAIL
Step 3: [ ] PASS [ ] FAIL
Step 4: [ ] PASS [ ] FAIL
Step 5: [ ] PASS [ ] FAIL
Step 6: [ ] PASS [ ] FAIL
Step 7: [ ] PASS [ ] FAIL
Step 8: [ ] PASS [ ] FAIL
Step 9: [ ] PASS [ ] FAIL
Step 10: [ ] PASS [ ] FAIL

Overall: [ ] PASS [ ] FAIL

Issues:
__________________________________________
__________________________________________
```
