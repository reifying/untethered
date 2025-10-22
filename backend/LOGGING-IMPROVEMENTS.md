# Diagnostic Logging Improvements for Race Condition Investigation

## Date
2025-10-21

## Purpose
Added comprehensive logging to help diagnose and understand the suspected race condition where terminal sessions with only initial sidechain messages may not appear in the iOS app.

## Changes Made

### Backend (Clojure)

#### 1. `replication.clj` - `filter-internal-messages` (lines 159-184)
**Added logging:**
- Total message count (before filtering)
- Filtered message count (kept)
- Removed message count
- Breakdown of removed message types (sidechain, summary, system)

**Log level:** `DEBUG`

**Purpose:** Track how many sidechain/internal messages are being filtered out at each stage.

#### 2. `replication.clj` - `handle-file-created` (lines 572-619)
**Added logging:**
- File creation event detection with full details (session ID, file path, file size, message count)
- Whether session has preview/first/last messages
- Explicit logging when iOS notification is **sent** (message-count > 0)
- **Warning** when iOS notification is **skipped** (message-count = 0) with reason
- Final summary of session added to index

**Log levels:**
- `INFO`: File created event, iOS notification sent/skipped, session added
- `WARN`: Zero-message sessions (potential race condition)
- `DEBUG`: Session details

**Purpose:** Track the critical decision point where sessions with 0 messages are not notified to iOS.

#### 3. `replication.clj` - `handle-file-modified` (lines 622-695)
**Added logging:**
- File modification event detection with subscription status
- **Warning** when modifications are skipped because session not subscribed
- Detailed message parsing results (total vs filtered)
- Index update operations (old count → new count)
- iOS notification events

**Log levels:**
- `INFO`: Index updates, session update callbacks
- `WARN`: Skipped modifications due to missing subscription
- `DEBUG`: File modification events, parsed messages, notifications

**Purpose:** Track when file modifications are ignored because iOS was never notified and therefore never subscribed.

#### 4. `server.clj` - `on-session-created` (lines 141-191)
**Added logging:**
- Session created callback invocation details
- Total connected clients vs eligible clients (excluding deleted sessions)
- Per-client notification attempts
- Initial message sending for already-subscribed sessions

**Log levels:**
- `INFO`: Callback invocation, client counts, initial messages
- `DEBUG`: Per-client notifications

**Purpose:** Verify that callbacks are being triggered and messages are reaching clients.

#### 5. `server.clj` - `on-session-updated` (lines 193-217)
**Added logging:**
- Session updated callback invocation
- Total vs eligible client counts
- Per-client notification attempts

**Log levels:**
- `INFO`: Callback invocation, client counts
- `DEBUG`: Per-client notifications

**Purpose:** Track when session updates are sent to iOS clients.

### iOS (Swift)

#### 6. `SessionSyncManager.swift` - `handleSessionCreated` (lines 72-99)
**Enhanced logging:**
- Full session details when session_created message arrives
- Explicit warning when filtering out 0-message sessions
- Clear indication that this might be a backend race condition
- Final acceptance confirmation for valid sessions

**Log levels:**
- `info`: Session received, session details, acceptance
- `warning`: Filtering out 0-message sessions (potential race condition)

**Purpose:** Track what sessions iOS receives and which ones it rejects.

## What to Look For in Logs

### Scenario 1: Race Condition Confirmed
If the diagnosis is correct, you'll see:

**Backend logs:**
```
INFO: File created event detected
  {:session-id "abc-123", :message-count 0, :file-size 1234}
WARN: Skipping iOS notification for zero-message session
  {:reason "Session has no non-sidechain messages yet - potential race condition"}

[30 seconds later]

DEBUG: File modified event detected
  {:session-id "abc-123", :is-subscribed false}
WARN: Skipping file modification - session not subscribed
  {:reason "iOS never notified or subscription expired - potential race condition"}
```

**iOS logs:**
```
(No messages at all for session abc-123)
```

### Scenario 2: Backend Never Sending
If backend isn't creating the session at all:

**Backend logs:**
```
(No "File created event detected" for the missing session)
```

### Scenario 3: iOS Filtering Out
If iOS is receiving but rejecting:

**iOS logs:**
```
📨 session_created received: abc-123
  Message count: 0
⚠️ Filtering out session_created with 0 messages: abc-123
  This indicates a potential race condition in backend
```

### Scenario 4: Format Incompatibility
If the session has messages but iOS can't display them:

**Backend logs:**
```
INFO: File created event detected
  {:session-id "abc-123", :message-count 21,
   :has-preview false, :has-first-message false, :has-last-message false}
```

This would indicate messages exist but don't have the `:text` field iOS expects.

## Testing

All existing tests pass:
```bash
cd backend && clj -M:test
# All tests PASSED
```

## Next Steps

1. **Reproduce the issue:** Create a new Claude Code terminal session
2. **Collect logs:**
   - Backend: Check `backend/server.log` or console output
   - iOS: Use Xcode console filtering for "SessionSync" category
3. **Analyze the timeline:**
   - When was file created?
   - What was the initial message count?
   - Was iOS notified?
   - When did new messages arrive?
   - Were modifications processed?
4. **Form better theory** based on actual log data rather than speculation

## Log Locations

**Backend:**
- Console output when running `make run`
- Log file: `backend/server.log` (if configured)

**iOS:**
- Xcode console when app is running
- Filter: "SessionSync" or "VoiceCode"
- Device Console app for on-device logs

## Cleanup

If these logs become too verbose for production, we can:
1. Change `INFO` → `DEBUG` for less critical messages
2. Add a feature flag to disable diagnostic logging
3. Remove the race condition warnings once the issue is fixed
