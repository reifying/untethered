# Investigation: Session Not Appearing in iOS App

## Problem Statement

A Claude Code terminal session created in `/Users/travisbrown/code/mono/910labs/website` (session ID `2c3f54fc-654d-4320-a34c-b7f29d0ebe31`) is not appearing in the iOS voice-code app, despite being present on disk with valid messages.

## Investigation Summary

**Date**: 2025-10-21
**Session ID**: `2c3f54fc-654d-4320-a34c-b7f29d0ebe31`
**Working Directory**: `/Users/travisbrown/code/mono/910labs/website`
**File Path**: `~/.claude/projects/-Users-travisbrown-code-mono-910labs-website/2c3f54fc-654d-4320-a34c-b7f29d0ebe31.jsonl`

## Key Findings

### 1. Session IS in the Index
The session exists in `~/.claude/.session-index.edn`:

```clojure
"2c3f54fc-654d-4320-a34c-b7f29d0ebe31" {
  :session-id "2c3f54fc-654d-4320-a34c-b7f29d0ebe31"
  :name "Terminal: website - 2025-10-21 17:48"
  :file "/Users/travisbrown/.claude/projects/-Users-travisbrown-code-mono-910labs-website/2c3f54fc-654d-4320-a34c-b7f29d0ebe31.jsonl"
  :working-directory "/Users/travisbrown/code/mono/910labs/website"
  :message-count 0          ← INCORRECT (should be 21)
  :preview nil
  :first-message nil
  :last-message nil
  :last-modified 1761086900510
  :created-at 1761086900510
}
```

### 2. Actual File Contents
- **Total messages on disk**: 23
- **Sidechain messages**: 2
- **Non-sidechain messages**: 21 (actual conversational messages)
- **All messages added**: Between 17:48:18 - 17:48:50 (32-second window)

### 3. Message Format Incompatibility
Claude Code terminal sessions use a different message structure than voice-code iOS sessions:
- **Expected format**: Messages with top-level `:text` field
- **Actual format**: Messages with `:message` → `:content` structure
- Messages have keys like: `:sessionId`, `:parentUuid`, `:thinkingMetadata`, `:cwd`, `:isSidechain`
- **No `:text` field exists**, causing preview extraction to return empty strings (but doesn't cause exceptions)

### 4. Root Cause: Race Condition + Notification Deadlock

**Timeline Reconstruction:**
```
17:48:18 - First message written (isSidechain=true, warmup message)
17:48:20 - File CREATED, 2nd message written (isSidechain=true)
17:48:20 - File watcher detects creation
         - Calls handle-file-created (replication.clj:560)
         - Extracts metadata: 2 total messages, 0 after filtering sidechain
         - Adds to index with message-count: 0
         - iOS callback SKIPPED (line 583: only notifies if message-count > 0)
         - File position set to current file size
17:48:25-50 - 21 more messages added to file
         - File modifications trigger handle-file-modified (line 595)
         - BUT: is-subscribed? returns false (line 602)
         - iOS never got notified, so never subscribed
         - Index update SKIPPED
```

**The Deadlock:**
1. `handle-file-created` (line 583) only notifies iOS if `message-count > 0`
2. Initial file had only sidechain messages → `message-count: 0`
3. iOS never notified → iOS never subscribes to session
4. `handle-file-modified` (line 602) only updates subscribed sessions
5. Session stuck with stale `message-count: 0` forever

**Critical Code Locations:**

`backend/src/voice_code/replication.clj:583-585`:
```clojure
;; Notify callback only if session has non-internal messages
;; This prevents zero-message sessions from being broadcast to clients
(when (pos? (:message-count metadata))
  (when-let [callback (:on-session-created @watcher-state)]
    (callback metadata)))
```

`backend/src/voice_code/replication.clj:602`:
```clojure
;; Only process if subscribed (is-subscribed? handles normalization)
(when (is-subscribed? session-id)
  ;; Debounce and update...
```

## Test Results

Manual testing of `extract-metadata-from-file` with the current file:
```
Total lines: 23
All messages: 23
Filtered messages: 21
First msg has :text? false
Last msg has :text? false
Result: {:message-count 21, :preview "", :first-message nil, :last-message nil}
```

**The extraction works correctly NOW**, but the index shows 0 because it captured the file's state when it only had sidechain messages.

## Technical Details

### Backend Environment
- **Process**: Java process (PID 42259)
- **Started**: Oct 18, 2025 10:57:28 AM
- **Working directory**: `/Users/travisbrown/code/mono/active/voice-code/backend`
- **Log file**: `server.log` (32 lines, minimal logging since restart)

### File System State
- **File created**: 2025-10-21 17:48:20
- **File modified**: 2025-10-21 17:48:50
- **Index updated**: 2025-10-21 17:56:05 (8 minutes after file creation)
- **Project directory found**: `-Users-travisbrown-code-mono-910labs-website` (verified in logs)

### Message Filtering Logic
`filter-internal-messages` removes:
- `isSidechain: true` messages
- `type: "summary"` messages
- `type: "system"` messages

First 2 messages in this file are both `isSidechain: true`, explaining the initial 0-message count.

## Related Issues

This same race condition could affect ANY Claude Code terminal session that:
1. Starts with only sidechain/warmup messages
2. Gets detected by file watcher before real messages are added
3. Has subsequent messages added while not subscribed

## Potential Solutions (Not Implemented - For Next Agent)

### Option 1: Retry Initial Sessions
Add logic to retry sessions with `message-count: 0` after a delay to catch late-arriving messages.

### Option 2: Always Notify
Remove the `(pos? message-count)` check at line 583, notify iOS about all sessions regardless of initial message count.

### Option 3: Update Unsubscribed Sessions
Allow `handle-file-modified` to update index for unsubscribed sessions, but only notify iOS if message count changes from 0 to >0.

### Option 4: Full Rescan on iOS Connect
When iOS connects/reconnects, trigger a full index rebuild or at minimum re-check sessions with 0 messages.

### Option 5: File Watcher Delay
Add a small delay before processing file creation events to allow initial sidechain messages to be followed by real messages.

## Files to Review

1. `backend/src/voice_code/replication.clj:560-593` - handle-file-created
2. `backend/src/voice_code/replication.clj:595-627` - handle-file-modified
3. `backend/src/voice_code/replication.clj:154-165` - filter-internal-messages
4. `backend/src/voice_code/replication.clj:168-199` - extract-metadata-from-file
5. `backend/src/voice_code/replication.clj:516-521` - is-subscribed?

## Next Steps

1. Decide on solution approach
2. Implement fix in `replication.clj`
3. Write tests to reproduce the race condition
4. Test with both iOS and terminal session creation patterns
5. Consider adding metrics/logging for 0-message sessions to detect this pattern
6. Update index to correct the message count for this specific session (temporary fix)

## Immediate Workaround

To fix this specific session without code changes:

1. Manually update the index entry to set `message-count: 21`
2. Restart the backend to reload the index
3. The session should appear in iOS app if iOS re-fetches the session list

OR:

1. Delete `~/.claude/.session-index.edn`
2. Restart the backend
3. Index will be rebuilt with correct counts for all sessions

## Additional Context

- User is in CDT timezone (UTC-5)
- Backend tracks 729 sessions total across 72 project directories
- This is a Claude Code 2.0.25 terminal session
- Session contains conversation about initializing Beads issue tracker
