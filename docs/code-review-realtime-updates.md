# Code Review: Real-Time Update Issues

**Branch:** github-copilot
**Date:** 2026-01-31
**Issue:** Users must manually refresh to see new messages in a session

---

## Executive Summary

Investigation reveals **multiple gaps** in the real-time update pipeline between backend and iOS. The primary issue is that `session_updated` messages (real-time incremental updates) don't trigger UI refresh notifications, while `session_history` messages (full/delta sync) do. Additionally, server logs show messages being lost when the iOS client disconnects, with no buffering or replay mechanism implemented.

---

## Critical Finding #1: Missing UI Notification for session_updated

### Location
`ios/VoiceCode/Managers/SessionSyncManager.swift`

### Problem
When the backend sends `session_updated` with new messages, `handleSessionUpdated()` saves to CoreData but **does not post a notification** to trigger UI refresh.

Compare the two handlers:

**handleSessionHistory (lines 230-242) - POSTS NOTIFICATION:**
```swift
// Post notification on main thread to trigger UI refresh
// This is needed because @FetchRequest may not auto-update when messages are
// added via background context merge (especially after backend reconnection)
if addedCount > 0 {
    DispatchQueue.main.async {
        NotificationCenter.default.post(
            name: .sessionHistoryDidUpdate,
            object: nil,
            userInfo: ["sessionId": sessionId]
        )
    }
}
```

**handleSessionUpdated (lines 486-490) - NO NOTIFICATION:**
```swift
do {
    if backgroundContext.hasChanges {
        try backgroundContext.save()
        logger.info("Updated session: \(sessionId)")
    }
    // NO NOTIFICATION POSTED HERE
}
```

### Impact
- New messages saved to CoreData but UI doesn't update
- User must navigate away and back, or pull-to-refresh
- Real-time experience is broken

### Root Cause
The code comment in `handleSessionHistory` explains the issue: "@FetchRequest may not auto-update when messages are added via background context merge." This same problem affects `handleSessionUpdated` but the fix (posting notification) was not applied.

### Severity
**HIGH** - Core functionality broken

---

## Critical Finding #2: Messages Lost During Disconnect

### Location
- `backend/src/voice_code/server.clj` (on-session-updated, send-to-client!)
- `backend/server.out` (log analysis)

### Evidence from Logs
```
WARNING: Channel not in connected-clients, skipping send {:type :recipe-exited}
WARNING: Channel not in connected-clients, skipping send {:type :turn-complete}
INFO: Session updated callback invoked {:session-id ..., :total-clients 0, :eligible-clients 0}
```

50 occurrences of messages being skipped because no client was connected.

### Problem
The backend's `send-to-client!` function:
1. Checks if channel is in `@connected-clients`
2. If not: logs warning and **silently drops the message**
3. No buffering, no retry, no replay on reconnection

### STANDARDS.md Protocol Specification (NOT IMPLEMENTED)
```markdown
**Undelivered Messages Replay (Reconnection Only)**

After `connected` response, backend sends any undelivered messages buffered during disconnection:
{
  "type": "replay",
  "message_id": "<unique-message-id>",
  "message": {...}
}
```

### Current Implementation
- `message_ack` handler exists but only logs
- No undelivered message queue
- No replay mechanism on reconnection

### Impact
- Messages sent while client is disconnected are permanently lost
- Particularly affects `turn_complete`, `recipe-exited`, `recipe-step-transition`
- Client doesn't know conversation is finished until manual refresh

### Severity
**HIGH** - Data loss on network interruption

---

## Finding #3: Race Condition in File Position Tracking

### Location
`backend/src/voice_code/replication.clj` - handle-file-modified, parse-jsonl-incremental

### Problem
```clojure
;; In handle-subscribe:
(repl/reset-file-position! file-path)
(swap! repl/file-positions assoc file-path current-size)

;; In handle-file-modified (concurrent):
(parse-jsonl-incremental file-path) ;; reads from stored position
```

Multiple actors can race:
1. Watcher detects file change, reads from stored position
2. Subscribe handler resets position to current size
3. Watcher updates position after reading, potentially overwriting subscribe's position

### Impact
- Messages can be skipped if timing is unlucky
- Affects reconnection scenarios

### Severity
**MEDIUM** - Intermittent message loss

---

## Finding #4: Duplicate Messages in session_updated

### Location
`ios/VoiceCode/Managers/SessionSyncManager.swift` lines 415-419

### Problem
```swift
} else {
    // Create new message (backend-originated or not found)
    self.createMessage(messageData, sessionId: sessionId, ...)
    newMessageCount += 1
```

Unlike `handleSessionHistory` which checks `existingIds.contains(messageId)`, `handleSessionUpdated`:
1. Only checks for optimistic message by (role, text) tuple
2. Creates new message without checking if UUID already exists
3. If same message arrives twice (retry, buffering), creates duplicates

### Impact
- Potential duplicate messages in conversation
- Minor but noticeable

### Severity
**LOW** - Edge case, cosmetic issue

---

## Finding #5: Subscription State is Global, Not Per-Client

### Location
`backend/src/voice_code/replication.clj` - watcher-state atom

### Design
```clojure
(defonce watcher-state
  (atom {:subscribed-sessions #{}  ;; GLOBAL set, not per-client
         ...}))
```

### Behavior
- Any client subscribing adds session to global set
- File watcher triggers for ALL subscribed sessions
- `on-session-updated` broadcasts to ALL connected clients (filtered by deleted-sessions)
- Unsubscribe removes from global set, affects all clients

### Impact
- Client A subscribes, Client B connects, Client B receives updates for A's subscriptions
- Generally benign (extra messages filtered client-side)
- But wastes bandwidth and processing

### Severity
**LOW** - Inefficiency, not a bug

---

## Finding #6: iOS Disconnect Patterns

### Location
`backend/server.out` log analysis

### Observations
- 31 WebSocket disconnections with status `:going-away`
- Pattern suggests iOS going to background state
- Connections from localhost (`0:0:0:0:0:0:0:1`) never authenticate (health checks?)

### Typical Sequence
```
1. iOS sends prompt
2. Backend invokes Claude CLI
3. iOS goes to background (WebSocket closes with :going-away)
4. Claude responds, backend tries to send
5. WARNING: Channel not in connected-clients, skipping send
6. iOS returns to foreground, reconnects
7. User sees stale state, must refresh
```

### Impact
- Common use case: user asks question, puts phone down, comes back to stale UI

### Severity
**HIGH** - Frequent occurrence, poor UX

---

## Finding #7: No Idempotency for session_updated

### Location
Protocol design in STANDARDS.md vs implementation

### Problem
Unlike `session_history` which uses `last_message_id` for idempotent delta sync:
- `session_updated` has no sequence numbers
- No delivery guarantees documented
- No deduplication window tracking
- Vulnerable to double-delivery after reconnection

### Impact
- Combined with Finding #4, can cause duplicates

### Severity
**LOW** - Theoretical risk

---

## Finding #8: Debounce Window May Miss Rapid Updates

### Location
`backend/src/voice_code/replication.clj` - debounce-event

### Design
```clojure
(defn debounce-event [session-id]
  ;; 200ms default debounce per session
  ...)
```

### Problem
- Rapid consecutive writes within 200ms are coalesced
- Only the last state is sent
- If first write has message A, second write has A+B, client only sees A+B
- Generally fine, but if parsing fails on second event, A is lost

### Impact
- Unlikely edge case

### Severity
**VERY LOW**

---

## Recommendations

### Immediate Fix (Finding #1)
Add notification posting to `handleSessionUpdated`:

```swift
// After context.save() succeeds:
if newMessageCount > 0 {
    DispatchQueue.main.async {
        NotificationCenter.default.post(
            name: .sessionHistoryDidUpdate,  // or create sessionUpdatedDidUpdate
            object: nil,
            userInfo: ["sessionId": sessionId]
        )
    }
}
```

### Short-Term Fix (Finding #2)
Implement message buffering for critical control messages:
- Buffer `turn_complete`, `recipe-exited`, `recipe-step-transition`
- Replay on client reconnection (before session_history)
- Expire buffer after reasonable timeout (5 min)

### Medium-Term Improvements
1. **Per-client subscription tracking** - Map channel → subscribed sessions
2. **UUID deduplication in handleSessionUpdated** - Check existing IDs before creating
3. **Sequence numbers for session_updated** - Enable gap detection

### Long-Term Considerations
1. **Push notifications for critical state changes** - When WebSocket is unavailable
2. **Session state query endpoint** - Allow client to poll current state
3. **Persistent message queue** - Survive backend restarts

---

## Files Reviewed

### iOS
- `ios/VoiceCode/Managers/VoiceCodeClient.swift` - WebSocket handling
- `ios/VoiceCode/Managers/SessionSyncManager.swift` - Message persistence
- `ios/VoiceCode/Views/ConversationView.swift` - UI binding

### Backend
- `backend/src/voice_code/server.clj` - WebSocket server
- `backend/src/voice_code/replication.clj` - Filesystem watching
- `backend/server.out` - Runtime logs

### Reference
- `STANDARDS.md` - Protocol specification

---

## Summary

| Finding | Severity | Effort to Fix |
|---------|----------|---------------|
| #1 Missing notification for session_updated | HIGH | Low (1 line) |
| #2 Messages lost during disconnect | HIGH | Medium |
| #3 Race condition in file positions | MEDIUM | Medium |
| #4 Duplicate messages possible | LOW | Low |
| #5 Global subscription state | LOW | High (refactor) |
| #6 iOS background disconnect pattern | HIGH | Medium (needs #2) |
| #7 No idempotency for session_updated | LOW | Medium |
| #8 Debounce window edge case | VERY LOW | N/A |

**Primary Root Cause:** Finding #1 explains why users must refresh - `session_updated` doesn't trigger UI updates even when messages are successfully saved.

**Secondary Root Cause:** Finding #2 explains why messages are missing entirely after reconnection - no buffering or replay mechanism.
