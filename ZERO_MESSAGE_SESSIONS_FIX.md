# Zero-Message Sessions Fix

## Problem
Sessions with 0 messages (after filtering internal messages like sidechain warmup) were appearing in the iOS app session list, cluttering the UI.

## Root Cause
Race condition during session creation:
1. Backend `handle-file-created` correctly calculates `message-count = 0` after filtering internal messages
2. **BUT** broadcasts `session-created` event immediately without checking if count > 0
3. iOS receives and saves the session to CoreData without filtering
4. iOS database query doesn't filter by `messageCount > 0`
5. User sees empty sessions in the list

## Solution: Three-Layer Defense

### Layer 1: Backend - Don't Broadcast Empty Sessions (PRIMARY FIX)
**File:** `backend/src/voice_code/replication.clj`
**Function:** `handle-file-created` (Line 527-531)

**Change:**
```clojure
;; Notify callback only if session has non-internal messages
;; This prevents zero-message sessions from being broadcast to clients
(when (pos? (:message-count metadata))
  (when-let [callback (:on-session-created @watcher-state)]
    (callback metadata)))
```

**Impact:**
- Prevents zero-message sessions from ever being sent to iOS clients
- Backend still tracks them in the index (for when they get messages later)
- When first real message arrives, `handle-file-modified` updates count and broadcasts

---

### Layer 2: iOS Database - Filter Query (SAFETY NET)
**File:** `ios/VoiceCode/Models/CDSession.swift`
**Function:** `fetchActiveSessions()` (Line 35)

**Change:**
```swift
request.predicate = NSPredicate(format: "markedDeleted == NO AND messageCount > 0")
```

**Impact:**
- Ensures UI never displays sessions with 0 messages, even if they somehow get into CoreData
- Protects against any edge cases where Layer 1 might fail
- Cleans up any existing zero-message sessions already in the database

---

### Layer 3: iOS Handler - Input Validation (DEFENSE IN DEPTH)
**File:** `ios/VoiceCode/Managers/SessionSyncManager.swift`
**Function:** `handleSessionCreated` (Line 57-62)

**Change:**
```swift
// Filter out sessions with 0 messages (defense in depth)
let messageCount = sessionData["message_count"] as? Int ?? 0
guard messageCount > 0 else {
    logger.debug("Ignoring session_created with 0 messages: \(sessionId)")
    return
}
```

**Impact:**
- Additional safety check in case backend sends zero-message sessions
- Logs when filtering happens for debugging
- Redundant with Layer 1, but provides defense in depth

---

## How Message Counting Works

### Backend Message Filtering
All message counting in the backend correctly filters internal messages:

1. **`extract-metadata-from-file`** (replication.clj:147-166)
   - Calls `filter-internal-messages` before counting
   - Removes: sidechain warmup, type='summary', type='system'

2. **`handle-file-modified`** (replication.clj:539-565)
   - Filters internal messages before checking if empty
   - Only broadcasts updates if filtered messages exist

3. **Session List Endpoint** (server.clj:213-229)
   - Already filtered sessions with `message-count > 0`
   - This remains unchanged, still works correctly

### Session Lifecycle

**New Session Created:**
1. Claude CLI creates `.jsonl` file with sidechain warmup messages
2. Backend `handle-file-created` detects file
3. Calculates `message-count = 0` (warmup filtered out)
4. **NEW:** Doesn't broadcast to iOS (Layer 1 blocks it)
5. Waits for first real user/assistant message

**First Real Message:**
1. User sends first prompt
2. Backend `handle-file-modified` detects change
3. Filters internal messages, finds 1+ real messages
4. Updates index: `message-count = 1+`
5. Broadcasts `session-updated` to subscribed clients
6. **NEW:** First time iOS hears about this session

**Session List Refresh:**
1. iOS sends `connect` message
2. Backend returns sessions where `message-count > 0`
3. Session appears in iOS list with accurate count

---

## Testing

### Test Results
All 73 backend tests pass:
```
Ran 73 tests containing 407 assertions.
0 failures, 0 errors.
```

### Manual Testing Scenarios

**Scenario 1: New Session with Only Warmup**
1. Create session in terminal
2. Claude sends warmup messages only
3. **Expected:** Session does NOT appear in iOS list
4. **Expected:** Backend logs "New session detected" with `message-count: 0`

**Scenario 2: New Session with Real Message**
1. Create session in terminal with user prompt
2. Claude responds to prompt
3. **Expected:** Session appears in iOS list immediately
4. **Expected:** `message-count: 2` (user + assistant)

**Scenario 3: Existing Zero-Message Sessions**
1. iOS has sessions with `messageCount = 0` in CoreData (from before this fix)
2. User views session list
3. **Expected:** Zero-message sessions filtered out by database query (Layer 2)

**Scenario 4: Backend Sends Zero-Message Session**
1. Backend somehow bypasses Layer 1 and sends `session-created` with `message-count: 0`
2. iOS receives the message
3. **Expected:** Layer 3 blocks it with debug log
4. **Expected:** Session not added to CoreData

---

## Files Modified

### Backend
1. `backend/src/voice_code/replication.clj` - Added message count check before broadcasting

### iOS
1. `ios/VoiceCode/Models/CDSession.swift` - Added `messageCount > 0` to database predicate
2. `ios/VoiceCode/Managers/SessionSyncManager.swift` - Added input validation in `handleSessionCreated`

---

## Backward Compatibility

### For Existing Users
- **iOS Database:** Layer 2 automatically filters out any existing zero-message sessions
- **No Migration Needed:** Old sessions with 0 messages simply stop appearing in the UI
- **Backend Index:** Zero-message sessions remain in index, will be broadcast when they get messages

### For Backend
- **No Protocol Changes:** Uses existing message types
- **No Breaking Changes:** Clients that don't have Layer 2/3 filters will work fine (Layer 1 prevents the issue)

---

## Future Enhancements

Possible improvements (not implemented):
1. Periodic cleanup job to remove zero-message sessions from iOS CoreData
2. Analytics to track how often sessions are created with only warmup messages
3. Option to show/hide empty sessions for debugging purposes
4. Toast notification when a previously-empty session gets its first message

---

## Related Issues

This fix addresses the issue where:
- Session list shows 50 sessions but half have 0 messages
- Users see clutter from empty sessions
- Sessions appear before they have any real conversation content

This works in conjunction with:
- Commit 964f305: "Filter sessions with only internal messages from backend and iOS"
- Auto-discovery fix: Sessions in new directories appear automatically
- Refresh buttons: Manual refresh to update session list
