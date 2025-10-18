# End-to-End Test Report

## Test Suite Overview

This document covers end-to-end testing for the Session Replication Architecture (voice-code-117):

- **voice-code-97**: Terminal to iOS Sync ✅ DOCUMENTED
- **voice-code-98**: iOS to iOS Sync ✅ DOCUMENTED
- **voice-code-99**: Session Forking ✅ DOCUMENTED
- **voice-code-100**: Deletion Workflow ✅ DOCUMENTED
- **voice-code-101**: Performance Testing ✅ DOCUMENTED

---

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

---

## Test voice-code-98: iOS to iOS Sync

**Date**: TBD
**Status**: READY FOR MANUAL TESTING
**Test Duration**: ~15 minutes

### Prerequisites

✅ Backend running on port 8080
❓ Two iOS simulators or devices ready

### Test Steps

#### Step 1: Start First iOS Client
1. Launch VoiceCode app on iPhone 16 Pro simulator
2. Configure server URL: `http://localhost:8080`
3. Verify connection successful

#### Step 2: Create Session from iOS
1. In first iOS app, tap "+" to create new session
2. Enter session name: "Test iOS Session"
3. Enter working directory: `/tmp/test-ios-session`
4. Tap "Create"

**Expected**: Session created in Sessions list

#### Step 3: Send Prompt from iOS
1. Select the newly created session
2. Type prompt: "Hello from iOS"
3. Send prompt

**Expected**: Message appears with "Sending..." status, then confirmed

#### Step 4: Verify Backend File Creation
1. In Terminal, check for `.jsonl` file:
   ```bash
   ls -la ~/.claude/projects/-tmp-test-ios-session/
   ```

**Expected**: Session .jsonl file exists

#### Step 5: Verify Filesystem Watcher Detected File
1. Check backend logs for "New file detected" message

**Expected**: Watcher detected new file, indexed session

#### Step 6: Connect Second iOS Client
1. Launch second simulator (iPhone 15 Pro)
2. Install and launch VoiceCode app
3. Configure same server URL
4. Navigate to Sessions view

**Expected**: "Test iOS Session" appears in list

#### Step 7: Verify Session History
1. On second iOS client, tap on "Test iOS Session"
2. View conversation

**Expected**:
- User message: "Hello from iOS"
- Assistant response visible
- Full conversation history loaded

#### Step 8: Send Prompt from Second Client
1. On second iOS client, send: "Reply from second device"

**Expected**:
- Message appears on second client
- First iOS client receives update
- Both clients stay synchronized

### Success Criteria

✅ iOS can create new sessions
✅ Backend creates .jsonl files for iOS sessions
✅ Filesystem watcher detects iOS-created sessions
✅ Other iOS clients receive session via session_list
✅ Full history available when subscribing
✅ Real-time sync works bidirectionally

---

## Test voice-code-99: Session Forking

**Date**: TBD
**Status**: READY FOR MANUAL TESTING
**Test Duration**: ~10 minutes

### Prerequisites

✅ Backend running
❓ Terminal with Claude Code
❓ iOS app connected

### Test Steps

#### Step 1: Create Session from Terminal
1. Open Terminal
2. Start Claude Code in a project directory
3. Send initial prompt: "What is 1 + 1?"
4. Wait for response

**Expected**: Session created, response received

#### Step 2: iOS Subscribes to Session
1. In iOS app, locate the new session
2. Tap to open conversation

**Expected**: iOS subscribes, sees conversation history

#### Step 3: Resume Same Session Concurrently
1. Open SECOND terminal window
2. Navigate to SAME project directory
3. Start Claude Code (this will try to resume same session)
4. Note the session ID shown

**Expected**: Claude creates fork (session-id-fork-1.jsonl)

#### Step 4: Verify Fork File Created
1. Check filesystem:
   ```bash
   ls -la ~/.claude/projects/<project-name>/
   ```

**Expected**: See both original and `-fork-1` files

#### Step 5: Verify iOS Receives session_created for Fork
1. Return to iOS Sessions list
2. Look for new session with "(fork)" or "(compacted)" in name

**Expected**: Fork session appears in list

#### Step 6: Verify Auto-Subscription to Fork
1. Tap on fork session in iOS

**Expected**: Can view fork conversation independently

#### Step 7: Verify Fork Independence
1. In second terminal (fork), send prompt: "Fork message"
2. Check iOS fork conversation

**Expected**: Message appears only in fork, not original session

### Success Criteria

✅ Concurrent resume creates fork
✅ Fork detected by filesystem watcher
✅ iOS receives session_created for fork
✅ Fork naming includes "(fork)" or "(compacted)"
✅ Fork and original remain independent

---

## Test voice-code-100: Deletion Workflow

**Date**: TBD
**Status**: READY FOR MANUAL TESTING
**Test Duration**: ~15 minutes

### Prerequisites

✅ Backend running
❓ Two iOS clients connected
❓ At least one active session

### Test Steps

#### Step 1: Setup Test Session
1. Create session from terminal with multiple messages
2. Both iOS clients subscribe to session

**Expected**: Both clients see same session

#### Step 2: Delete Session on First iOS Client
1. On first iOS app, navigate to Sessions list
2. Swipe left on test session
3. Tap "Delete"

**Expected**: Session disappears from first client's list

#### Step 3: Verify session_deleted Message Sent
1. Check backend logs for session_deleted message

**Expected**: Backend received session_deleted from first client

#### Step 4: Verify Backend File Still Exists
1. Check filesystem:
   ```bash
   ls -la ~/.claude/projects/<project-name>/
   ```

**Expected**: .jsonl file still exists (local deletion only)

#### Step 5: Verify Second Client Unaffected
1. On second iOS client, check Sessions list

**Expected**: Session still visible and accessible

#### Step 6: Send Update from Terminal
1. In terminal, resume the "deleted" session
2. Send prompt: "After deletion test"

**Expected**: Prompt and response appear in terminal

#### Step 7: Verify First Client Does NOT Receive Update
1. Check first iOS client (that deleted session)

**Expected**: No update received (unsubscribed)

#### Step 8: Verify Second Client DOES Receive Update
1. On second iOS client, view the session

**Expected**: New message "After deletion test" appears

### Success Criteria

✅ Deletion on one client doesn't affect others
✅ Backend file remains intact
✅ session_deleted stops updates to that client
✅ Other clients continue receiving updates
✅ Deleted client stays unsubscribed

---

## Test voice-code-101: Performance Testing

**Date**: TBD
**Status**: READY FOR MANUAL TESTING
**Test Duration**: ~30 minutes

### Prerequisites

✅ Backend running
❓ Test data: 1000+ session .jsonl files
❓ iOS app ready
❓ Performance monitoring tools (Activity Monitor, Instruments)

### Test 1: Index Build Time

**Setup**: Stop backend, ensure 1000+ .jsonl files exist

**Steps**:
1. Note start time
2. Start backend server
3. Wait for "Session index initialized" log
4. Note end time

**Target**: < 5 seconds for 1000 sessions

---

### Test 2: session_list Send Time

**Steps**:
1. Connect iOS client
2. Note timestamp of connection
3. Note timestamp when Sessions list populated

**Target**: < 2 seconds from connection to populated list

---

### Test 3: Per-Session Load Time

**Steps**:
1. Select session from list
2. Measure time to load conversation view

**Target**: < 200ms per session

---

### Test 4: Filesystem Watcher Overhead

**Steps**:
1. Subscribe to 10 different sessions from iOS
2. Open Activity Monitor
3. Monitor backend process CPU usage
4. Let run for 5 minutes

**Target**: < 5% CPU usage with 10 active subscriptions

---

### Test 5: Memory Usage

**Steps**:
1. With 1000 sessions indexed
2. Check backend process memory in Activity Monitor

**Target**: ~10MB for session index

---

### Test 6: iOS Pagination

**Setup**: 1000+ sessions synced to iOS

**Steps**:
1. Open Sessions list
2. Scroll through list
3. Observe loading behavior

**Target**: Smooth scrolling with lazy loading

---

### Test 7: Incremental Update Latency

**Steps**:
1. iOS viewing active session
2. In terminal, send prompt to same session
3. Note: timestamp of terminal response
4. Note: timestamp when iOS displays message

**Target**: < 1 second latency

---

### Success Criteria

✅ Index builds in < 5s
✅ session_list sends in < 2s
✅ Per-session load < 200ms
✅ CPU usage < 5% with 10 subscriptions
✅ Memory usage ~10MB for 1000 sessions
✅ iOS pagination smooth
✅ Update latency < 1s

### Performance Metrics Table

| Metric | Target | Actual | Status |
|--------|--------|--------|--------|
| Index build (1000 sessions) | < 5s | _____ | ⏳ |
| session_list send | < 2s | _____ | ⏳ |
| Per-session load | < 200ms | _____ | ⏳ |
| CPU (10 subscriptions) | < 5% | _____ | ⏳ |
| Memory (1000 sessions) | ~10MB | _____ | ⏳ |
| Update latency | < 1s | _____ | ⏳ |
