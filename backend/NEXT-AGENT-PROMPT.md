# Continuation Prompt: Fix Session Index Race Condition

## Context

We've identified why the session `2c3f54fc-654d-4320-a34c-b7f29d0ebe31` (910labs/website) isn't appearing in the iOS app. Full investigation details are in `INVESTIGATION-910labs-session.md` in this directory.

## The Problem

**Race condition causes sessions to be stuck with `message-count: 0`:**

1. Claude Code terminal sessions start with sidechain messages (warmup, etc.)
2. File watcher detects file creation before real messages arrive
3. `extract-metadata-from-file` counts 0 non-sidechain messages
4. Session added to index with `message-count: 0`
5. **iOS callback skipped** because count is 0 (replication.clj:583)
6. Real messages arrive 1-30 seconds later
7. File modifications detected BUT session not subscribed (iOS was never notified)
8. **Updates skipped** because only subscribed sessions are processed (replication.clj:602)
9. Session permanently stuck with stale `message-count: 0`

**Classic deadlock**: iOS can't subscribe without being notified → Backend won't notify sessions with 0 messages → Backend won't update unsubscribed sessions → Session stays at 0 messages forever.

## Your Task

Fix this race condition without breaking existing functionality.

## Requirements

1. **Preserve existing behavior** for iOS sessions (don't break voice-code app)
2. **Handle terminal sessions** that start with only sidechain messages
3. **Add tests** to reproduce and verify the fix
4. **Don't break** the subscription model (still needed for real-time updates)
5. **Consider backwards compatibility** with existing index format

## Suggested Approaches

### Option A: Update Unsubscribed Sessions (Recommended)
Modify `handle-file-modified` to update index for unsubscribed sessions when message count changes from 0 to >0, then trigger notification.

**Changes needed:**
- `replication.clj:595-627` - Relax the `is-subscribed?` check
- Add special case: if old message-count is 0 and new count > 0, trigger notification
- Keep subscription requirement for already-notified sessions

### Option B: Delayed Notification
Add retry logic to re-check 0-message sessions after a delay.

**Changes needed:**
- Track sessions created with 0 messages
- Schedule re-check after 5-10 seconds
- Extract fresh metadata and notify if count increased

### Option C: Remove Count Restriction
Always notify iOS about new sessions regardless of message count.

**Changes needed:**
- Remove `(pos? message-count)` check at line 583
- iOS will need to handle 0-message sessions gracefully

## Files to Modify

Primary:
- `backend/src/voice_code/replication.clj` (lines 560-627)

Testing:
- Create test for race condition scenario
- Verify both iOS sessions and terminal sessions work

## Testing Strategy

1. **Reproduce the issue:**
   - Create a session file with only sidechain messages
   - Trigger file creation event
   - Verify message-count is 0 and iOS not notified
   - Add real messages
   - Verify index stays at 0 (current broken behavior)

2. **Verify the fix:**
   - Repeat above scenario
   - Verify index updates to correct count
   - Verify iOS gets notified when count changes from 0 to >0
   - Verify normal sessions still work correctly

3. **Edge cases:**
   - Session that never gets real messages (stays at 0)
   - Session created with messages already present
   - Rapid succession of messages
   - Backend restart scenarios

## Quick Start Commands

```bash
# Read the full investigation
cat backend/INVESTIGATION-910labs-session.md

# View the problematic code
less backend/src/voice_code/replication.clj +560

# Test current metadata extraction
clj -e "
(require '[clojure.java.io :as io])
(load-file \"src/voice_code/replication.clj\")
(let [file (io/file \"$HOME/.claude/projects/-Users-travisbrown-code-mono-910labs-website/2c3f54fc-654d-4320-a34c-b7f29d0ebe31.jsonl\")]
  (println (voice-code.replication/extract-metadata-from-file file)))
"

# Check current index entry
grep -A 10 "2c3f54fc-654d-4320-a34c-b7f29d0ebe31" ~/.claude/.session-index.edn

# Run backend tests (when you add them)
clj -M:test
```

## Success Criteria

- [ ] Session `2c3f54fc-654d-4320-a34c-b7f29d0ebe31` shows correct message-count (21) in index
- [ ] Session appears in iOS app
- [ ] New terminal sessions that start with sidechain messages appear in iOS
- [ ] Existing iOS sessions continue to work normally
- [ ] Tests added to prevent regression
- [ ] No performance degradation for high-frequency updates

## Additional Notes

- Backend is currently running (PID 42259), will need restart after code changes
- 729 sessions in index, need to ensure fix doesn't break them
- Message filtering is working correctly, issue is purely notification/subscription timing
- The session file format (Claude Code vs voice-code) is different but that's not the root cause
- Index format can be extended if needed (add retry timestamp, pending-notification flag, etc.)

## Reference

**Current broken flow:**
```
File created (only sidechain) → extract (count=0) → add to index (count=0)
→ skip iOS notify → messages arrive → modify event → not subscribed → skip update
→ STUCK at 0
```

**Desired fixed flow:**
```
File created (only sidechain) → extract (count=0) → add to index (count=0)
→ skip iOS notify → messages arrive → modify event → detect 0→N transition
→ update index → notify iOS → subscribe → future updates work normally
```

Good luck! Read the full investigation doc for complete technical details.
