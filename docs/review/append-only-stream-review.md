# Append-Only Message Stream — Code Review

**Branch:** `tmux-untethered`  
**Reviewed commits:** e655424a through 66da2a6d (append-only stream implementation)  
**Date:** 2026-04-27  
**Scope:** Backend (Clojure) and iOS (Swift) implementation of the v0.4.0 `session_history` / `last_seq` protocol

---

## Executive Summary

The design is sound and the happy-path implementation is solid. However, six **critical** issues were found that can cause silent data loss or crashes in production, plus a cluster of high-severity races and design gaps. The test suite is strong on happy paths but weak on concurrency, error recovery, and protocol edge cases.

Issues are grouped by severity, then by subsystem. Each finding includes file + line, reproduction scenario, and a suggested fix.

---

## Critical

### C1 — Backend: `build-session-history-response` packed branch crashes when no messages fit budget

**File:** `backend/src/voice_code/server.clj` (lines that compute `:first-seq` / `:last-seq`)  
**Category:** Nil dereference / crash

When `pack-within-budget` returns an empty `:included` vector (e.g., a single message is larger than the budget and the client is not yet caught up), the packed branch does:

```clojure
:first-seq (:seq (first included))   ; → nil if included=[]
:last-seq  (:seq (last  included))   ; → nil if included=[]
```

`(first [])` and `(last [])` both return `nil`. The resulting response has `nil` for both fields and `is-complete: false`, which is ambiguous — the client cannot distinguish "no new messages" from "budget exhausted on the first message."

**Reproduction:**
1. Session has message at seq 5, ~10 KB text
2. Client subscribed at `last_seq=4`, `max_message_size` set to 1 KB
3. Server enters packed branch; `pack-within-budget` returns `{:included [] :complete? false}`
4. Response: `{:messages [] :first-seq nil :last-seq nil :is-complete false :gap nil}`
5. Client re-subscribes from `local_last_seq` (cursor doesn't advance) — infinite loop

**Fix:**
```clojure
(if (empty? included)
  {:messages [] :first-seq nil :last-seq nil
   :next-seq next-seq :is-complete false :gap nil}
  {:messages    (vec included)
   :first-seq   (:seq (first included))
   :last-seq    (:seq (last  included))
   :next-seq    next-seq
   :is-complete complete?
   :gap         nil})
```

---

### C2 — Backend: Subscribe/broadcast race allows client to miss a seq

**File:** `backend/src/voice_code/server.clj` (`handle-subscribe`)  
**Category:** Race condition / data loss

The subscribe handler: (1) registers the subscription globally, then (2) reads messages from disk. The watcher runs on a separate thread. If a new message is written to disk between steps (1) and (2):

- The watcher fires `broadcast-session-history!` and sends seq N to the newly-subscribed client
- The subscribe handler finishes reading the old snapshot (which does not include seq N)
- Response: `{:messages [1..N-1] :next-seq N :is-complete true}`
- Client's `localLastSeq` = N-1 after merging the subscribe reply
- Client receives broadcast seq N, sees `first_seq == localLastSeq + 1` — **contiguous, accepted**

This path actually works correctly due to gap-detection idempotency. **However**, the inverse race is dangerous:

- Watcher fires and reads messages at snapshot time; assigns `next-seq = N+1` in the broadcast
- Subscribe handler reads messages including seq N; builds response with `next-seq = N+1`
- Subscribe reply arrives *after* the broadcast
- Client merges broadcast (seq N, `next-seq = N+1`) first → `localLastSeq = N`
- Subscribe reply arrives: `messages=[1..N], next-seq=N+1, is-complete=true` — duplicate seq N, idempotent upsert handles it ✓

The real gap: `next-seq` in the broadcast payload is read from `get-session-metadata` *after* new messages have been assigned seqs. If another assign happens between the broadcast's `last-seq` capture and its `next-seq` capture:

```
broadcast computed last-seq=55 from messages vector
concurrent assign-seq! runs → next-seq advances to 61
broadcast reads next-seq=61 from metadata
payload: {:last_seq 55 :next_seq 61}   ← apparent 5-seq gap
```

Client sees `first_seq=55, next_seq=61`, which looks like 5 messages are available but not included, triggering an immediate re-subscribe.

**Fix:** Read `next-seq` atomically with the message snapshot, before broadcasting:

```clojure
(let [snapshot-next-seq (get-in @session-index [session-id :next-seq])
      msgs-vec (vec (filter #(<= (:seq %) (dec snapshot-next-seq)) new-messages))
      ...]
```

---

### C3 — Backend: File truncation/shrinkage silently corrupts the JSONL cursor

**File:** `backend/src/voice_code/replication.clj` (`parse-jsonl-incremental`)  
**Category:** Silent data loss

```clojure
(if (<= current-size last-pos)
  {:messages [] :new-pos last-pos}   ; ← returns stale cursor if file shrank
```

When a session's JSONL file shrinks (compaction rewrites it, or a partially-written file is truncated), `current-size < last-pos`. The function returns the **old cursor** unchanged. On the next watcher tick, the file has grown again (new appends) but the cursor is already past the new content's byte range. All messages written to the file after the truncation are silently skipped.

**Reproduction:**
1. Session grows to 10,000 bytes; cursor at 9,800
2. `claude --compact` rewrites the JSONL to 2,000 bytes
3. Watcher fires: `current-size=2000 < last-pos=9800` → returns `{:new-pos 9800}`
4. Next write appends to the file; it grows to 2,500 bytes
5. Watcher fires: `current-size=2500 > last-pos=9800`? No — `2500 < 9800` still returns stale cursor
6. Messages written to bytes 2,000–2,500 are never parsed

**Fix:**
```clojure
(if (<= current-size last-pos)
  (do
    (log/warn "JSONL file shrank; resetting cursor to 0"
              {:file file-path :was last-pos :now current-size})
    {:messages [] :new-pos 0})
  ; ... existing read path
```

---

### C4 — Backend: `:next-seq` can be lost on crash (seq collision after restart)

**File:** `backend/src/voice_code/replication.clj` (`assign-seq!`, `save-index!`)  
**Category:** Data corruption after restart

`assign-seq!` updates the in-memory `@session-index` atom. `save-index!` flushes it to disk (debounced). If the process crashes in the window between these two calls:

1. Pre-crash: 100 messages parsed, `:next-seq = 101`, flush pending
2. Crash: disk still has `:next-seq = 50` (last flushed value)
3. Restart: `migrate-session-seqs!` re-scans JSONL, counts lines → sets `:next-seq = 101` ✓

Migration rescues this case because it re-scans the file. **However**, if the file was also partially written at the crash point:

1. Pre-crash: JSONL has 100 complete lines + a 101st partial line (incomplete write)
2. Migration counts 100 lines → `:next-seq = 101`
3. Watcher fires; reads from `last-pos=0` (reset on startup); parses all 100 lines
4. `assign-seq!` assigns seqs 101–200 to these 100 "new" messages
5. These are duplicates — backend now sends seq 101–200 to clients for messages that already had seqs 1–100

**Root cause:** Migration and the watcher share the same `:next-seq` counter but do not coordinate on which messages have already been assigned seqs. Migration stamps seqs onto stored messages but the watcher does not know those are already stamped.

**Fix:** After migration, set `file-positions` for each session to the actual file length, so the watcher does not re-parse already-migrated content.

---

### C5 — iOS: `seq=0` optimistic messages collide under multiple offline prompts

**File:** `ios/VoiceCode/Managers/SessionSyncManager.swift` (`upsertMessage`)  
**Category:** Data loss / duplicate rows

Optimistic messages (user prompts sent while waiting for response) are inserted with `seq = 0` before the backend assigns a real seq. The upsert is keyed on `(sessionId, seq)`. When the user submits two prompts before either is echoed back:

1. Prompt A: `CDMessage(sessionId=S, seq=0, text="first")`
2. Prompt B: `CDMessage(sessionId=S, seq=0, text="second")` — **same key**
3. Backend echoes A back with `seq=1`
4. Upsert for seq=1 fetches `(S, seq=0).first` → updates one of the two rows
5. The other `seq=0` row is orphaned permanently

**Reproduction:** Dictate two commands rapidly before the first response arrives.

**Fix:** Assign a deterministic negative seq to optimistic messages (e.g., `-abs(UUID.hashValue)`) rather than 0, so multiple offline messages have distinct upsert keys.

---

### C6 — iOS: Pruned-gap banner dismissal does not prevent stale messages from rendering

**File:** `ios/VoiceCode/Views/ConversationView.swift` (`PrunedGapBanner` and surrounding view)  
**Category:** UX data integrity

When `didDetectPrunedGap` fires, the banner is shown. When dismissed, `client.dismissPrunedGap(...)` is called. However:

1. The `@FetchRequest` binding for `messages` still renders seqs 1..50 (the old local cache)
2. No reload or scroll position reset is triggered
3. If a new push arrives at seq 205, the list shows `[1..50, 205]` — a visible discontinuity with no visual separator
4. The delegate callback is dispatched async; between dispatch and execution another `session_history` payload can arrive and merge normally

**The design document (AC5) says** the client should surface the gap "rather than silently merging a partial view." The current implementation fires the notification but does not block or quarantine subsequent merges.

**Fix:**
- Add a `prunedSessions: Set<String>` flag to `SessionSyncManager`
- In `handleSessionHistoryPayload`, if the session is in `prunedSessions`, return early (do not merge) until the flag is cleared
- In `ConversationView`, on pruned-gap detection, freeze the message list or show a "session history unavailable" overlay until the user explicitly reloads

---

## High

### H1 — Backend: `min-available-seq` hardcoded to `1` in subscribe handler

**File:** `backend/src/voice_code/server.clj` (call to `build-session-history-response`)  
**Category:** Wrong gap detection

The subscribe handler passes `min-available-seq=1` literally to `build-session-history-response`, regardless of what the session index actually contains. If messages have been pruned (e.g., after compaction that left seq 151–200), the function's pruned-gap check `(< last-seq (dec min-available-seq))` is evaluated as `(< last-seq 0)`, which is always false. A client subscribing from `last_seq=0` receives messages 151–200 with `gap=nil`, silently skipping 1–150.

**Fix:** Read `:min-available-seq` from the session index entry:
```clojure
min-avail (get session-entry :min-available-seq 1)
```

---

### H2 — Backend: `pack-within-budget` 200-byte overhead underestimates gap responses

**File:** `backend/src/voice_code/server.clj` (`pack-within-budget`)  
**Category:** Budget overshoot

The overhead constant (200 bytes) does not account for:
- Long session IDs (>50 chars add 50+ bytes)
- Gap objects: `{"requested_last_seq":42,"min_available_seq":200,"reason":"pruned"}` ≈ 80 bytes

For a gap response with a long session ID the actual envelope is 250–280 bytes. `pack-within-budget` may include one extra message, sending a response that exceeds `max_message_size` on the client.

**Fix:** Compute envelope overhead dynamically, or use `300` as the constant.

---

### H3 — Backend: `assign-seq!` creates stub index entries with missing fields

**File:** `backend/src/voice_code/replication.clj` (`assign-seq!`)  
**Category:** Runtime errors in downstream code

When `assign-seq!` is called for a session not yet in the index (race between watcher and `ensure-session-in-index!`), it creates a stub entry containing only `:session-id`, `:min-available-seq`, and `:next-seq`. Downstream code that reads `:provider`, `:file`, or `:name` from the index will receive `nil`. The stub is also persisted via `save-index!`, creating an incomplete record on disk that survives restarts.

**Fix:** Make `assign-seq!` throw instead of creating a stub when the session is absent, requiring callers to ensure the session is indexed first.

---

### H4 — Backend: Dead channels accumulate indefinitely (subscriber leak)

**File:** `backend/src/voice_code/server.clj` (`send-to-client!`)  
**Category:** Memory leak

When `http/send!` throws (network failure, closed channel), the exception is logged and swallowed. The channel is not removed from `connected-clients` or unsubscribed from sessions. `broadcast-session-history!` iterates all subscribed clients on every message — with enough churn, this becomes O(dead-channels × messages).

**Fix:** On send failure, call the same cleanup logic used by the WebSocket close handler to remove the channel from all subscriptions.

---

### H5 — iOS: `newestCachedSeq` can return a stale cursor before viewContext merges background saves

**File:** `ios/VoiceCode/Managers/VoiceCodeClient.swift` (`newestCachedSeq`)  
**Category:** Race condition / stale cursor

`newestCachedSeq` fetches from `viewContext`. Background saves from `SessionSyncManager` post a `NSManagedObjectContextDidSave` notification, which is merged into `viewContext` on the main queue. But if `subscribe()` is called on the main queue in the same run-loop cycle that the notification was posted, the merge has not yet been applied:

```
T0: background save: seq=99 written to disk
T1: NSManagedObjectContextDidSave posted on main queue
T2: subscribe() called (same run loop, before notification processed)
    → newestCachedSeq fetches viewContext → sees seq=42 (stale)
T3: merge applied to viewContext
```

Result: client sends `last_seq=42`; backend never resends 43–99.

**Fix:** Use a `newBackgroundContext()` with `performAndWait` for the fetch, ensuring it reads the latest persistent store state regardless of view context merge state.

---

### H6 — iOS: `subscribe()` before `connect()` silently drops the subscribe message

**File:** `ios/VoiceCode/Managers/VoiceCodeClient.swift` (`subscribe`, `sendMessage`)  
**Category:** Silent failure

`sendMessage` uses optional chaining: `webSocket?.send(...)`. If the WebSocket has not been created yet, the send is a no-op with no error. Callers that subscribe before `connect()` completes (or before "hello" is received) silently lose the subscription.

**Fix:** In `subscribe()`, guard on `isConnected`. If not connected, `activeSubscriptions` still captures the session ID so `restoreSubscriptionsAfterReconnect()` picks it up when the connection is established.

---

### H7 — iOS: `activeSubscriptions` accumulates deleted/killed sessions

**File:** `ios/VoiceCode/Managers/VoiceCodeClient.swift` (reconnect path)  
**Category:** Design flaw / wasted bandwidth

When a session is deleted or killed, there is no corresponding removal from `activeSubscriptions`. On every reconnect, the client re-subscribes to sessions that no longer exist. The backend will respond with an error or empty reply, but the stale entry stays in the set.

**Fix:** Add `activeSubscriptions.remove(sessionId)` to the `kill_session` / session-deletion path.

---

### H8 — iOS: `is_complete:false` resubscribe loop has no termination guard

**File:** `ios/VoiceCode/Managers/SessionSyncManager.swift` (`handleSessionHistoryPayload`)  
**Category:** Infinite loop

When `isComplete == false`, the manager fires `sessionSyncNeedsResubscribe` with no rate limit, retry cap, or progress check. If the server keeps returning `is_complete: false` for the same cursor (e.g., a message larger than the budget), the client and server will loop at maximum speed.

**Fix:** Track the cursor from the last `is_complete: false` response. If the next response carries the same `nextSeq` or an empty window without advancing, abort the chain and surface an error.

---

### H9 — iOS: Pruned gap detection does not block subsequent merges (async race)

**File:** `ios/VoiceCode/Managers/SessionSyncManager.swift` (`handleSessionHistoryPayload`)  
**Category:** Race condition / data integrity

The `didDetectPrunedGap` delegate is dispatched asynchronously. Before the delegate runs, a push for the same session can arrive and be merged normally. Result: partial history is silently merged despite the pruned gap.

This is the backend-side expression of C6. See C6 for the fix.

---

### H10 — iOS: `session_history` decode failure resumes the refresh continuation as "success"

**File:** `ios/VoiceCode/Managers/VoiceCodeClient.swift` (session_history message handler)  
**Category:** Silent failure

If `SessionHistoryPayload` decoding fails, the error is logged, but `sessionRefreshContinuations[sessionId]?.resume()` is still called. The awaiting caller receives no indication that the refresh failed and proceeds with stale state.

**Fix:** Only resume the continuation inside the `do` block on successful decode. Let the timeout handle the failure case.

---

### H11 — iOS: CoreData v4 — `seq` attribute may lack its own index

**File:** `ios/VoiceCode/VoiceCode.xcdatamodeld/VoiceCode 4.xcdatamodel/contents`  
**Category:** Performance regression

The model defines a composite fetch index `bySessionAndSeq (sessionId ASC, seq DESC)`, which is good. However, the `seq` attribute itself appears to lack `indexed="YES"`. On large sessions (50k+ messages), `maxCachedSeq()` issues a sort-and-limit query that may not use the composite index if the query planner doesn't recognize the partial key optimization.

**Verification:** Check the xcdatamodel XML — the `seq` attribute declaration should contain `indexed="YES"`.

**Fix:** Add `indexed="YES"` to the seq attribute in VoiceCode 4.xcdatamodel/contents. This requires a new lightweight migration (v5).

---

## Medium

### M1 — Backend: TOCTOU between file-size check and `readFully` in `parse-jsonl-incremental`

**File:** `backend/src/voice_code/replication.clj`  
**Category:** Race condition

`(.length file)` is called before opening the `RandomAccessFile`. If new bytes are written between the length check and `readFully`, `readFully` reads fewer bytes than are available. The missed bytes are recovered on the next watcher tick, but it adds noise to message batching.

**Fix:** Re-read `raf.length()` after seeking:
```clojure
(with-open [raf (RandomAccessFile. file "r")]
  (.seek raf last-pos)
  (let [actual-size (.length raf)
        buf (byte-array (- actual-size last-pos))
```

---

### M2 — Backend: UTF-8 multi-byte characters at the holdback boundary can miscompute cursor

**File:** `backend/src/voice_code/replication.clj` (`parse-jsonl-incremental`)  
**Category:** Edge case / data corruption

The holdback size is computed as `(count (.getBytes (last lines) "UTF-8"))`. If the raw bytes end mid-character (e.g., the first byte of a 4-byte emoji), `String.(buf "UTF-8")` may produce a replacement character. Re-encoding the replacement character gives a different byte length than the original partial sequence, placing the cursor in the wrong position.

**Fix:** Detect the holdback in bytes directly (find the last `\n` byte in `buf`) rather than decoding to String first, then re-encoding.

---

### M3 — Backend: `truncate-text-middle` can overshoot the byte budget

**File:** `backend/src/voice_code/server.clj` (`truncate-text-middle`)  
**Category:** Budget violation

The truncation marker size is estimated once. If the actual marker (which includes the truncated-KB count) is larger than the estimate, `available-bytes` may be negative, causing the final assembled string to exceed `max-bytes`. On extremely large messages (>1 GB text), the KB count is 6+ digits and the marker string is notably longer than expected.

**Fix:** After assembling `first-part + marker + last-part`, verify the total byte count is ≤ `max-bytes`. If not, reduce `half-bytes` by the overage and retry.

---

### M4 — Backend: Protocol version enforcement silently disabled on config parse failure

**File:** `backend/src/voice_code/server.clj` (`enforce-protocol-version!`)  
**Category:** Security / correctness gap

If `config.edn` is missing or malformed, `message-stream-version` defaults to `:v0.3.0`, which disables protocol version enforcement. Old (v0.3.0) clients connect without rejection and no warning is emitted that enforcement is off.

**Fix:** Log a warning at startup when `:message-stream-version` is `:v0.3.0` or absent, so operators know enforcement is disabled.

---

### M5 — iOS: `requestSessionRefresh` unsubscribe/resubscribe race with 100ms gap

**File:** `ios/VoiceCode/Managers/VoiceCodeClient.swift` (`requestSessionRefresh`)  
**Category:** Race condition

The method unsubscribes, waits 100ms, then resubscribes. 100ms is not enough to guarantee the backend has processed the unsubscribe before the subscribe arrives. A `session_history` from the unsubscribe epoch can arrive after the continuation is resumed, causing the refresh caller to see stale data.

**Fix:** Replace the time-based delay with a response-based handshake, or use a generation counter to discard responses from old subscribe epochs.

---

### M6 — iOS: `nextSeq` from payload is never persisted for reconnect cursor

**File:** `ios/VoiceCode/Managers/SessionSyncManager.swift`  
**Category:** Design gap

`SessionHistoryPayload.nextSeq` (the backend's current next-seq) is never stored. On reconnect, `newestCachedSeq()` reads the max seq from CoreData. If the client's message cache was pruned locally (e.g., user cleared app data), the cursor resets to 0 and a full resync is triggered. Storing `nextSeq` in `CDBackendSession` would allow the client to resume from the correct cursor even with an empty local cache.

---

### M7 — iOS: `WireMessage.seq` has no fallback — a malformed batch drops all messages

**File:** `ios/VoiceCode/Managers/MessageStreamTypes.swift` (`WireMessage`)  
**Category:** Error handling

`seq` is decoded with `try container.decode(Int64.self, forKey: .seq)` — required, no default. If one message in a batch has a missing or wrong-type `seq`, decoding the entire `SessionHistoryPayload` fails, and none of the messages in that batch are merged. A log entry appears but no user-visible error surfaces.

**Fix:** Decode `seq` as optional with a default of `0`, or catch and skip individual malformed messages rather than failing the batch.

---

### M8 — Backend: `broadcast-session-history!` with empty `new-messages` sends nil seqs

**File:** `backend/src/voice_code/server.clj` (`broadcast-session-history!`)  
**Category:** Edge case

If the watcher parses a file tick and filters produce zero messages (all lines were sidechain/summary entries), but the caller still invokes `broadcast-session-history!`, `(first [])` and `(last [])` return nil, producing `{:first-seq nil :last-seq nil}`. All subscribers receive this payload.

**Fix:** Guard at the top of `broadcast-session-history!`: if `new-messages` is empty, return immediately without broadcasting.

---

## Test Gaps

The following scenarios have no test coverage. They are listed without full reproduction steps because the scenario itself is the coverage gap.

| # | Area | Missing scenario |
|---|------|-----------------|
| T1 | Backend replication | `parse-jsonl-incremental` with a multi-byte UTF-8 character (e.g., emoji) split across two watcher ticks |
| T2 | Backend replication | File shrinks between two ticks — cursor reset and recovery |
| T3 | Backend replication | Backend restart with unsaved `:next-seq` — verifies migration re-derives correct value |
| T4 | Backend replication | Concurrent watcher ticks reading the same byte range — verifies deduplication |
| T5 | Backend server | `build-session-history-response` when `:next-seq` is missing from session metadata |
| T6 | Backend server | Subscribe to a session with zero messages (distinct from "caught up") |
| T7 | Backend server | `pack-within-budget` re-subscribe cursor continuity — two consecutive calls cover the full range with no gaps or overlap |
| T8 | Backend server | Zombie channel send failure — verifies channel removed from subscriptions after failure |
| T9 | Backend server | `subscribe` with `last_seq = -1` (negative value) rejected |
| T10 | Backend server | `nil` vs missing `protocol_version` in connect message treated identically |
| T11 | iOS sync | `seq=0` key collision for multiple concurrent optimistic messages |
| T12 | iOS sync | `is_complete:false` chain of 4+ windows with out-of-order delivery of chain steps |
| T13 | iOS sync | Pruned gap followed by user-triggered refresh — verifies gap state cleared and new data accepted |
| T14 | iOS sync | Socket disconnect mid `is_complete:false` chain — verifies cursor survives reconnect |
| T15 | iOS sync | `handleSessionHistoryPayload` called concurrently for same session — verifies no duplicate rows |
| T16 | iOS client | `subscribe()` called before `connect()` — message buffered and sent after connect |
| T17 | iOS client | `activeSubscriptions` contains a deleted session — reconnect ignores the stale entry |
| T18 | iOS model | CoreData v4 — verify `seq` attribute has an index (either standalone or the composite index covers solo seq queries efficiently) |
| T19 | iOS model | Lightweight migration v3→v4 — verify existing rows with no seq survive with `seq=0` default |
| T20 | iOS UI | ConversationView — pruned gap banner dismissal does not cause message list to auto-advance to new seq |

---

## Priority Order

Fix the following before merging this branch:

**Must fix (data loss or crash):**
1. C1 — Packed branch nil first/last-seq crash
2. C3 — File truncation cursor reset
3. C5 — Optimistic seq=0 collision
4. C6 — Pruned gap doesn't block subsequent merges (+ H9 same root)

**Should fix (silent misbehavior in production):**
5. C2 — next-seq race in broadcast payload
6. C4 — next-seq not saved before crash (migration rescues most cases, but not all)
7. H1 — min-available-seq hardcoded to 1
8. H4 — Dead channel subscriber leak
9. H5 — Stale viewContext cursor on subscribe
10. H8 — is_complete:false infinite loop

**Should add tests for (correctness gaps that could hide bugs):**
11. T1, T2, T3 — Watcher and restart edge cases
12. T7 — Budget cursor continuity
13. T11 — Optimistic seq=0 collision (mirrors C5)
14. T13 — Pruned gap + refresh recovery

---

## Notes on Things That Are Correct

- The `parse-jsonl-incremental` newline-holdback logic is correct: a nil parse result from a complete newline-terminated line (sidechain entries) correctly advances the cursor, while an unterminated tail holds it back. This was the primary bug the design was solving and it's done right.
- The `assign-seq!` `swap-vals!` pattern is correctly atomic — no two threads can be assigned the same seq range.
- The `is_complete: false` client chain trigger is architecturally correct; it just needs the loop guard (H8).
- The CoreData composite index `bySessionAndSeq` is the right structure for the `newestCachedSeq` fetch.
- The `NSMergeByPropertyObjectTrumpMergePolicy` choice for the background context is correct for constraint-collision resolution.
