# Append-Only Message Stream with Monotonic Sequence Numbers

## Overview

### Problem Statement

The iOS reconnect and in-session message update paths are flaky. Investigation (see `Related work` below) identified five classes of race / drift bugs that all share a root cause: the backend serves messages through **two separate paths with two incompatible cursors**.

1. **`session_history`** (pull) keyed on a client-supplied `last_message_id` UUID.
2. **`session_updated`** (push) fired from the JSONL watcher with no cursor at all — just "here is a batch of new messages."

Symptoms that fall out:

- iOS picks `last_message_id` by CoreData `timestamp`, not insertion order. Timestamp ties or out-of-order writes produce a stale cursor. Backend does a linear UUID search and silently falls back to full history when not found. Messages can appear twice or in the wrong order.
- The JSONL watcher advances its byte offset after reading, even when a watch event fires mid-write (partial JSON line). The malformed line is filtered out and never re-read — data loss.
- A subscribe that races a watcher tick produces overlapping `session_history` and `session_updated` payloads; iOS merges them without a UUID-based guard if any message lacks `.id`.
- A socket flap drops any `session_updated` pushes that were in-flight; on reconnect the client re-subscribes with the stale-but-cached `last_message_id` and never learns what it missed.
- An `is_complete: false` reply (size budget exhausted) is silently tolerated on iOS — no signal to the user that the conversation is truncated.

### Goals

1. Collapse the two message-delivery paths into one append-only stream ordered by a monotonic per-session sequence number.
2. Make the client's only cursor state a single integer (`last_seq`), eliminating UUID lookup and timestamp-based sort for sync decisions.
3. Make partial-JSONL-line writes safe: never advance the parse cursor past a line that did not parse successfully.
4. Guarantee that reconnect resumes at the exact message boundary the client last acknowledged, with no loss and no duplicate merge conflict.
5. Emit a gap signal the client can detect when the server cannot satisfy a requested range (pruned, compacted, or beyond budget).

### Non-goals

- Changing how provider CLIs (Claude, Copilot, Cursor) write their JSONL files. Sequence numbers are a backend-side concept assigned at parse time.
- Redesigning CoreData. Existing `CDMessage` remains; we add one scalar field (`seq`) and deprecate one (`timestamp` as a sync key; it stays for display).
- Reworking the tmux-untethered provider invocation path. This is orthogonal.
- Solving compaction/prune semantics beyond the gap signal. When the server detects a requested `last_seq` is no longer available it tells the client; policy for what iOS does (full reload vs. user prompt) is a follow-up.

## Background & Context

### Current State

Backend serves messages through two paths. Both live in `backend/src/voice_code/server.clj` and `backend/src/voice_code/replication.clj`:

```
iOS                           Backend
 │                              │
 │── subscribe(last_msg_id) ──▶ │  server.clj:1245  (handle-subscribe)
 │                              │── linear UUID search ─▶ build-session-history-response
 │◀── session_history ─────────│  server.clj:268
 │                              │
 │                              │  (async, unrelated)
 │                              │   JSONL file modified
 │                              │   replication.clj:1496 (handle-file-modified)
 │                              │   parse-jsonl-incremental (advances byte cursor)
 │◀── session_updated ─────────│   server.clj:1099 (on-session-updated)
 │                              │
```

Key code locations:

- **Subscribe / history build**: `backend/src/voice_code/server.clj:268–337` (`build-session-history-response`), `1245–1310` (handler).
- **Push on file change**: `backend/src/voice_code/server.clj:1099–1129` (`on-session-updated`), `backend/src/voice_code/replication.clj:1496–1610` (file-modified handler).
- **Incremental parse**: `backend/src/voice_code/replication.clj:1039–1070` (`parse-jsonl-incremental`) — advances `file-positions` after read, regardless of whether every line parsed.
- **iOS subscribe + cursor pick**: `ios/VoiceCode/Managers/VoiceCodeClient.swift:1118–1166` — sorts by `timestamp`.
- **iOS history merge / update merge**: `ios/VoiceCode/Managers/SessionSyncManager.swift:145–250` (history), `337–536` (updated).
- **iOS reconnect**: `ios/VoiceCode/Managers/VoiceCodeClient.swift:573–593` — restores `activeSubscriptions`, re-subscribes with stale `last_message_id`.

### Why Now

Voice users are hitting message-order and "missing reply" bugs on every long-ish session. The tmux-untethered refactor made provider windows persistent, which exposes reconnect edge cases more often because sessions now span many more connect/disconnect cycles.

### Related Work

- @canonical-message-wire-format.md — established the canonical shape of a message over the wire; this proposal reuses that shape and adds a `seq` field.
- @websocket-reconnection-fix.md — earlier fix to connection bringup. Does not address in-session sync races.
- @refresh-session-list-fix.md — prior art for managing active subscriptions across reconnect.
- `STANDARDS.md` §WebSocket Protocol — current `subscribe` / `session_history` / `session_updated` message shapes (v0.3.0).

## Detailed Design

### Data Model

#### Backend: per-session sequence counter

`seq` is a 1-indexed monotonic integer assigned when the backend parses a new message from a provider's JSONL file. It is unique within a session and strictly increasing. It is **not** derived from file byte offset (which shifts under compaction) or from line number (which resets on file rewrite).

Storage lives in the session index alongside existing metadata:

**Before** (conceptual — see `replication.clj` session index):

```clojure
{:session-id "36895c49-..."
 :working-directory "/Users/travisbrown/assist"
 :last-modified 1776726769761
 :provider :claude
 :message-count 549}
```

**After**:

```clojure
{:session-id "36895c49-..."
 :working-directory "/Users/travisbrown/assist"
 :last-modified 1776726769761
 :provider :claude
 :message-count 549
 :next-seq 550           ;; new — the seq to assign to the next message
 :min-available-seq 1}   ;; new — smallest seq still retained after compaction
```

On startup, `next-seq` is computed from the existing transcript length (one-time scan) and then maintained incrementally.

`:min-available-seq` is seeded to `1` at migration and **does not advance under the scope of this design** — normal operation is strictly append-only, so every previously-assigned seq remains available. The field exists now so that a future compaction/prune feature (explicit Non-goal of this doc) can advance it without another protocol bump. The `gap.reason = "pruned"` branch is correspondingly dormant in this design; its only live trigger is *catastrophic state loss* (e.g. corrupted session file recovered with fewer messages than before), in which case the server re-seeds `min-available-seq` to the lowest surviving `seq`.

Each parsed message gets `:seq` stamped on it in memory before being broadcast and before being stored for later `session_history` requests. The wire format carries `seq` as a top-level field:

```json
{
  "role": "assistant",
  "text": "...",
  "session_id": "36895c49-...",
  "uuid": "8b4472f6-...",
  "timestamp": "2026-04-20T18:12:59Z",
  "seq": 549
}
```

#### iOS: `CDMessage.seq`

Add one attribute to `CDMessage`:

```swift
@NSManaged public var seq: Int64  // 0 if unknown (legacy / offline-created)
```

A fetched-properties index `(sessionId, seq desc)` makes "newest seq for this session" a constant-time lookup. `timestamp` stays for display ordering but is no longer consulted for sync.

##### New iOS types introduced by this design

- `WireMessage` (struct) — decoded shape of a message in a `session_history.messages` array. Fields: `sessionId: String, seq: Int64, role: String, text: String, uuid: String, timestamp: Date`. Replaces the ad-hoc dictionary access currently used by `SessionSyncManager`.
- `SessionHistoryPayload` (struct) — decoded shape of the `session_history` envelope. Fields: `sessionId: String, messages: [WireMessage], firstSeq: Int64?, lastSeq: Int64?, nextSeq: Int64, isComplete: Bool, gap: Gap?`.
- `Gap` (struct, nested) — `requestedLastSeq: Int64, minAvailableSeq: Int64, reason: String` where `reason ∈ {"pruned", "client_ahead"}`.
- `SessionSyncDelegate.didDetectPrunedGap(_ sessionId: String, gap: Gap)` (new method on the existing delegate protocol) — fired when the backend reports a pruned gap so the UI layer can prompt the user.

#### Migration

- **Backend**: on first startup after upgrade, a one-shot pass assigns `seq` to existing messages by scanning each session's JSONL in *file order*, which is chronological for every provider we support today (Claude, Copilot, Cursor all write append-only, and `claude --compact` summarizes in-place without reordering prior entries). If a future provider rewrites history out of order, the migration needs a stable tie-breaker (e.g. the message's original `timestamp` captured at write time) before running — call this out as a precondition for onboarding any such provider. The scan is O(total messages) and runs once. New sessions start at `seq = 1`.
- **iOS**: a lightweight CoreData migration adds the `seq` column defaulting to `0`. On first subscribe per session, the client sends `last_seq = 0` (meaning "I have nothing with a known seq; give me everything"). The backend treats `0` as "full history" the same way it treats a missing `last_seq`.
- **Wire protocol**: bumps to `v0.4.0`. Breaking change — `last_message_id` is removed from `subscribe`, replaced by `last_seq`. `session_history` and `session_updated` grow `first_seq` / `last_seq` / `next_seq` fields. Existing clients fail the version check in `hello` and prompt for update.

### API Design

#### Subscribe (client → backend)

```json
{
  "type": "subscribe",
  "session_id": "36895c49-...",
  "last_seq": 548
}
```

Fields:

- `last_seq` (optional, default 0): the highest `seq` the client already has for this session. The server replies with messages whose `seq > last_seq`.

#### Session History (backend → client)

Unified reply for both the initial load and reconnect resume. `session_updated` is no longer a structurally different message — it is a `session_history` with a small range.

```json
{
  "type": "session_history",
  "session_id": "36895c49-...",
  "messages": [ /* ... */ ],
  "first_seq": 549,
  "last_seq": 560,
  "next_seq": 561,
  "is_complete": true,
  "gap": null
}
```

Fields:

- `first_seq` / `last_seq`: range of `seq` values included in this payload. Always contiguous.
- `next_seq`: the `seq` the server will assign to the next new message. Client can detect "I am caught up" when `next_seq == last_seq + 1` and the server has no newer writes.
- `is_complete` (bool): `true` when all messages in the requested range fit in the size budget. `false` means `last_seq < next_seq - 1` — client should immediately subscribe again with `last_seq = last_seq` to fetch the next window.
- `gap` (nullable object): present when the server cannot satisfy the requested range. `reason` is one of:

  - `"pruned"` — the requested `last_seq` is below `min_available_seq` (compaction or catastrophic state loss; dormant under the current design — see the `:min-available-seq` note in Data Model).
  - `"client_ahead"` — the requested `last_seq` is greater than `next_seq - 1`. Happens after a backend rollback/downgrade that discarded messages the client had already seen. Server returns a full resync (`messages` populated from the start).

  ```json
  {
    "requested_last_seq": 42,
    "min_available_seq": 200,
    "reason": "pruned"
  }
  ```

  ```json
  {
    "requested_last_seq": 612,
    "min_available_seq": 1,
    "reason": "client_ahead"
  }
  ```

  Client decides whether to drop local state and reload, or surface a warning.

#### Push (backend → client)

Every new message emits the same `session_history` shape with a one-message window. No separate `session_updated` type. The push is a **flat broadcast** — every subscriber for that session receives the same payload regardless of their individual `last_seq`. Tailoring per-subscriber is deliberately not done on the server.

```json
{
  "type": "session_history",
  "session_id": "36895c49-...",
  "messages": [ { "role": "assistant", "seq": 550, /* ... */ } ],
  "first_seq": 550,
  "last_seq": 550,
  "next_seq": 551,
  "is_complete": true,
  "gap": null
}
```

**Client gap-detection contract.** The client compares `first_seq` in every received payload against its own `local_last_seq`:

- `first_seq == local_last_seq + 1` → contiguous; upsert the window and advance.
- `first_seq > local_last_seq + 1` → a push was missed (socket flap, backpressure, etc.); the client must upsert the received window *and* immediately re-`subscribe(last_seq: local_last_seq)` to backfill the missing range. The client must not advance `local_last_seq` past the gap until the backfill arrives.
- `first_seq <= local_last_seq` → duplicate or reorder; upsert is a no-op (idempotent on `(session_id, seq)`) and `local_last_seq` does not regress.

This pushes reconciliation to the client but keeps the broadcast trivial and race-free. The client's rule is a single integer comparison per push.

#### Error Cases

| Condition | Response |
|---|---|
| Unknown `session_id` | `{"type":"error","code":"unknown_session", ...}` |
| `last_seq > next_seq - 1` (client ahead of server, e.g. after server rewind) | `{"type":"session_history", ...}` with `gap.reason = "client_ahead"` and full resync |
| Budget exhausted | `is_complete: false`; client immediately re-subscribes with bumped cursor |
| Malformed subscribe | `{"type":"error","code":"invalid_subscribe", ...}` |

#### Breaking Changes / Deprecation

- `last_message_id` field on `subscribe`: removed.
- `session_updated` message type: removed.
- Protocol version in `hello`: `0.4.0`. Clients that announce `< 0.4.0` get a versioned error and connection close. iOS ships simultaneously per the project's coordinated-update pattern (see @canonical-message-wire-format.md §Non-goals).

### Code Examples

#### Backend: seq assignment in the JSONL watcher

```clojure
(ns voice-code.replication)

;; Session-level next-seq counter, persisted in the session index.
;; Assigns sequence numbers to messages at parse time.

(defn- assign-seq!
  "Mutate session-index entry to stamp :seq on each parsed message.
   Returns messages with :seq assigned, in parse order."
  [session-id parsed-messages]
  (let [entry   (session-index-get session-id)
        start   (or (:next-seq entry) 1)
        stamped (map-indexed (fn [i m] (assoc m :seq (+ start i)))
                             parsed-messages)
        end     (+ start (count parsed-messages))]
    (session-index-update! session-id assoc :next-seq end)
    stamped))

(defn parse-jsonl-incremental
  "Read new bytes since the last tracked offset. The partial-line signal is
   whether the read buffer ends with \\n, NOT whether the last line parsed
   successfully — the existing parser legitimately returns nil for non-
   message lines (sidechain / summary / system entries in Claude's JSONL;
   see `parse-jsonl-line` at backend/src/voice_code/replication.clj:254),
   and we must not confuse those with partial writes."
  [file-path]
  (let [file        (io/file file-path)
        last-pos    (get @file-positions file-path 0)
        current-size (.length file)]
    (if (<= current-size last-pos)
      {:messages [] :new-pos last-pos}
      (with-open [raf (RandomAccessFile. file "r")]
        (.seek raf last-pos)
        (let [buf        (byte-array (- current-size last-pos))
              _          (.readFully raf buf)
              ends-with-nl? (and (pos? (alength buf))
                                 (= (byte \newline) (aget buf (dec (alength buf)))))
              text       (String. buf "UTF-8")
              ;; split with -1 keeps trailing empty string if text ended in \n
              lines      (str/split text #"\n" -1)
              [complete trailing-bytes]
              (if ends-with-nl?
                ;; every newline-terminated line is complete; final "" slot is empty
                [(butlast lines) 0]
                ;; last element is the unterminated tail — hold it back
                [(butlast lines)
                 (count (.getBytes ^String (last lines) "UTF-8"))])
              parsed     (->> complete (map parse-jsonl-line) (filter some?) vec)
              new-pos    (- current-size trailing-bytes)]
          {:messages parsed :new-pos new-pos})))))
```

The cursor advances only past bytes that are newline-terminated. A line that
parses to nil (legitimately non-message) is *still* newline-terminated and
therefore fully consumed — only a truly unterminated tail holds the cursor
back. This decouples partial-line detection from parse-result semantics.

#### Backend: unified history build

```clojure
(defn- pack-within-budget
  "Walk candidates oldest-first, including each if the running JSON byte
   estimate stays under max-bytes. Replaces the existing loop at
   server.clj:314–333 (which did the same walk keyed on UUID rather
   than seq). Returns {:included [..] :complete? bool}."
  [candidates max-bytes]
  (let [overhead 200] ;; response-envelope JSON overhead estimate
    (loop [remaining candidates
           included  []
           used      overhead]
      (if (empty? remaining)
        {:included included :complete? true}
        (let [m      (first remaining)
              m-json (generate-json m)
              m-sz   (inc (count (.getBytes ^String m-json "UTF-8")))] ;; +1 for comma
          (if (> (+ used m-sz) max-bytes)
            {:included included :complete? false}
            (recur (rest remaining) (conj included m) (+ used m-sz))))))))

(defn build-session-history-response
  "Unified reply for subscribe and live push.

   - last-seq: client's high-water seq (0 if client is fresh)
   - messages: vector of session messages (see 'Message source' below),
               each carrying :seq"
  [messages last-seq max-total-bytes min-available-seq next-seq]
  (cond
    (< last-seq (dec min-available-seq))
    {:messages []
     :first-seq nil :last-seq nil :next-seq next-seq
     :is-complete true
     :gap {:requested-last-seq last-seq
           :min-available-seq  min-available-seq
           :reason "pruned"}}

    (>= last-seq (dec next-seq))
    {:messages []
     :first-seq nil :last-seq nil :next-seq next-seq
     :is-complete true
     :gap nil}

    :else
    (let [candidates (filter #(> (:seq %) last-seq) messages)
          {:keys [included complete?]} (pack-within-budget
                                         candidates max-total-bytes)]
      {:messages    (vec included)
       :first-seq   (:seq (first included))
       :last-seq    (:seq (last included))
       :next-seq    next-seq
       :is-complete complete?
       :gap         nil})))
```

The backend no longer does a UUID scan. `last-seq` is a direct `>` comparison.

**Message source.** `messages` is produced by `repl/parse-session-messages` (existing helper in `backend/src/voice_code/replication.clj`), which re-reads the JSONL each call. Per-subscribe cost is O(total messages), the same as today; the OS page cache absorbs repeat reads. An in-memory per-session deque would eliminate even that cost and is a natural follow-up, but is not required by this design — the win from the single-path redesign is achieved without it.

#### iOS: subscribe and merge

```swift
// VoiceCodeClient.swift — pick cursor from seq, not timestamp.
func subscribe(sessionId: String) {
    activeSubscriptions.insert(sessionId)
    let lastSeq = newestCachedSeq(sessionId: sessionId)   // Int64, defaults 0
    sendMessage([
        "type": "subscribe",
        "session_id": sessionId,
        "last_seq": lastSeq
    ])
}

// `context` is injectable to mirror the existing `getNewestCachedMessageId`
// signature at VoiceCodeClient.swift:1146 and keep tests ergonomic.
private func newestCachedSeq(sessionId: String,
                              context: NSManagedObjectContext? = nil) -> Int64 {
    guard let sessionUUID = UUID(uuidString: sessionId) else { return 0 }
    let ctx = context ?? PersistenceController.shared.container.viewContext
    let req = CDMessage.fetchRequest()
    req.predicate = NSPredicate(format: "sessionId == %@", sessionUUID as CVarArg)
    req.sortDescriptors = [NSSortDescriptor(keyPath: \CDMessage.seq,
                                            ascending: false)]
    req.fetchLimit = 1
    return (try? ctx.fetch(req))?.first?.seq ?? 0
}

// SessionSyncManager.swift — one merge path for both initial load and pushes.
func handleSessionHistory(_ payload: SessionHistoryPayload) {
    if let gap = payload.gap, gap.reason == "pruned" {
        // Local messages below min-available-seq are orphans — surface to user.
        delegate?.didDetectPrunedGap(payload.sessionId, gap: gap)
        return
    }
    for msg in payload.messages {
        upsertMessage(msg)   // idempotent on (session_id, seq)
    }
    if !payload.isComplete {
        // More available; fetch the next window immediately.
        client.subscribe(sessionId: payload.sessionId)
    }
}
```

Upsert by `(sessionId, seq)` is idempotent, so subscribe+push overlap is safe.

#### iOS: reconnect

```swift
// VoiceCodeClient.swift — on connected message, resubscribe everything.
// newestCachedSeq already advances as pushes arrive, so the cursor is
// always the last thing we durably persisted, regardless of socket state.
func onConnected() {
    for sid in activeSubscriptions {
        subscribe(sessionId: sid)   // reads seq from CoreData
    }
}
```

No special "was I disconnected?" branch. The cursor is the truth.

### Component Interactions

```
iOS                                       Backend
 │                                          │
 │─ subscribe(session, last_seq=548) ─────▶│  server/handle-subscribe
 │                                          │  replication/messages-since(548)
 │◀── session_history(549..560, complete) ─│
 │                                          │
 │                                          │  JSONL write → watcher fires
 │                                          │  parse-jsonl-incremental  ──▶ seq=561
 │                                          │  broadcast to all subscribers
 │◀── session_history(561..561, complete) ─│
 │                                          │
 │  (socket flap)                           │
 │                                          │
 │─ subscribe(session, last_seq=561) ─────▶│  (on reconnect)
 │◀── session_history([], complete) ──────│  last_seq == next_seq-1
 │                                          │
```

Integration points:

- **`replication/file-watcher`** → `replication/assign-seq!` → `server/broadcast-session-history!`. Single callback chain. `on-session-updated` is removed.
- **`server/subscribe` handler** → `replication/messages-since` → `build-session-history-response`. Same `build-` function is called from the broadcast path with a 1-message input.
- **Session index persistence**: `:next-seq` is mutated in an in-memory atom keyed per session; persistence to disk rides on the existing `:last-modified` flush path (already debounced — see the session-index writer in `replication.clj`) and is not an extra write per message. On crash recovery, `:next-seq` is re-derived from the JSONL line count during the startup scan, so an unflushed update is bounded to "at most one restart recomputes it."

No new dependencies. The change is internal to the backend and iOS client.

## Verification Strategy

### Testing Approach

**Unit (backend)**:
- `assign-seq!` — counter advances correctly under concurrent parses (serialized via existing session index lock).
- `parse-jsonl-incremental` — partial trailing line holds cursor back; complete lines advance it.
- `build-session-history-response` — seq filter, budget packing, `is-complete`, `gap` for pruned and client-ahead.

**Unit (iOS)**:
- `newestCachedSeq` — returns 0 on empty, max on populated, respects sessionId scoping.
- `upsertMessage` — idempotent on `(sessionId, seq)`; second call with same tuple updates in place.
- `handleSessionHistory` — walks `is_complete: false` into a follow-up subscribe.

**Integration**:
- Backend: watcher fires with a half-written trailing JSON line, completes on next tick — verify exactly-once delivery and no lost content.
- Backend: subscribe concurrent with a JSONL append; assert subscriber receives contiguous seqs with no gap and no dupe.
- Backend WebSocket loopback (Clojure-only, uses the existing server test harness): spin up a mock subscriber, drive subscribe → push → disconnect → reconnect → resume; assert every `seq` delivered exactly once across the union of socket messages. This covers AC3/AC4's server-side contract without requiring iOS.
- iOS XCTest (standalone, no backend): feed recorded `session_history` payloads into `SessionSyncManager` and assert CoreData reaches the expected state (including the gap-detected re-subscribe path). This covers AC4's client-side contract.
- Cross-stack end-to-end (optional): if and only if a Dockerized-backend + XCTest harness exists or is introduced alongside this work, add one reconnect-during-turn scenario. Not a prerequisite — the two halves above already pin both contracts.

**End-to-end**:
- Fresh session: open, send 3 prompts, tail the conversation — all messages appear in order with no manual refresh.
- Reconnect: kill Wi-Fi during an assistant turn, restore — turn completes and renders without duplicate bubbles.
- Prune: compact a session server-side, trigger `gap` on next subscribe, assert iOS shows the prune-warning UI.

### Test Examples

```clojure
(deftest parse-jsonl-incremental-partial-trailing-line
  (testing "unterminated tail holds cursor back for next tick"
    (let [f (temp-jsonl-file)
          _ (append-bytes! f "{\"role\":\"user\",\"uuid\":\"a\"}\n{\"role\":\"as")
          {:keys [messages new-pos]} (parse-jsonl-incremental (.getPath f))]
      (is (= 1 (count messages)) "only the complete line is returned")
      (is (< new-pos (.length f)) "cursor stops before the partial line")
      (swap! file-positions assoc (.getPath f) new-pos)
      (append-bytes! f "sistant\",\"uuid\":\"b\"}\n")
      (let [r2 (parse-jsonl-incremental (.getPath f))]
        (is (= 1 (count (:messages r2))) "second tick picks up the now-complete line")
        (is (= "b" (:uuid (first (:messages r2)))))
        (is (= (.length f) (:new-pos r2))))))

  (testing "newline-terminated line that parses to nil still advances the cursor"
    ;; Regression: Claude JSONL contains sidechain/summary/system lines that
    ;; parse-jsonl-line intentionally returns nil for. Those must not be
    ;; confused with partial writes.
    (let [f (temp-jsonl-file)
          _ (append-bytes! f "{\"type\":\"sidechain\"}\n{\"role\":\"assistant\",\"uuid\":\"a\"}\n")
          {:keys [messages new-pos]} (parse-jsonl-incremental (.getPath f))]
      (is (= 1 (count messages)) "sidechain line filtered; one assistant returned")
      (is (= (.length f) new-pos)
          "Cursor must advance fully when the buffer ends in \\n, regardless of nil parses"))))

(deftest build-session-history-response-gap
  (testing "returns pruned gap when client's last_seq is below min-available"
    (let [msgs [{:seq 200} {:seq 201} {:seq 202}]
          r    (build-session-history-response msgs 42 10000 200 203)]
      (is (empty? (:messages r)))
      (is (= "pruned" (get-in r [:gap :reason])))
      (is (= 200      (get-in r [:gap :min-available-seq]))))))

(deftest build-session-history-response-idempotent-on-caught-up
  (testing "empty reply when client is at next-seq - 1"
    (let [r (build-session-history-response [{:seq 549}] 549 10000 1 550)]
      (is (empty? (:messages r)))
      (is (nil?   (:gap r)))
      (is (true?  (:is-complete r))))))
```

```swift
func test_upsertMessage_isIdempotentOnSessionAndSeq() {
    let msg = WireMessage(sessionId: sid, seq: 5, role: "assistant", text: "hi")
    sync.upsertMessage(msg)
    sync.upsertMessage(msg)               // concurrent push then history
    XCTAssertEqual(fetchAllMessages(sid).count, 1)
}

func test_reconnect_resumesFromCachedSeq() {
    seedMessages(sid, seqs: 1...5)
    let last = client.newestCachedSeq(sessionId: sid)
    XCTAssertEqual(last, 5)
    let sent = captureLastSubscribe()
    XCTAssertEqual(sent["last_seq"] as? Int64, 5)
}
```

### Acceptance Criteria

1. **AC1** — `subscribe` with `last_seq = N` returns only messages with `seq > N`, in ascending order, contiguous. No UUID lookup happens server-side.
2. **AC2** — A JSONL watcher tick whose read buffer does not end in `\n` holds the cursor back at the start of the unterminated tail; a buffer that ends in `\n` advances fully, regardless of whether individual lines parsed to nil (legitimately non-message). The next tick, once the line is complete, returns the parsed message exactly once.
3. **AC3** — Concurrent `subscribe` and file-write never produce a gap in the client's materialized state. The wire may carry the same `seq` more than once (e.g. a push crossing a concurrent subscribe reply, or a gap-backfill overlapping a prior push); upsert on `(session_id, seq)` makes this idempotent, so CoreData ends with exactly one row per `seq` in the server's transcript.
4. **AC4** — A socket disconnect followed by reconnect restores the client to the exact message set the server has, with no duplicate bubbles and no missing messages. Reconnect sends `last_seq` derived from CoreData, not from in-memory state.
5. **AC5** — When `last_seq < min_available_seq` (server lost state, e.g. corrupted session recovery), the reply carries `gap.reason = "pruned"`; iOS surfaces this to the user via `didDetectPrunedGap` rather than silently merging a partial view. Verified by injecting a `min_available_seq` bump in a unit test; the `pruned` branch does not fire during normal append-only operation in this design.
6. **AC6** — `is_complete: false` triggers an immediate follow-up `subscribe` with the advanced cursor. User does not need to manually refresh to see the rest.
7. **AC7** — Wire protocol version is `0.4.0`. A client that announces `< 0.4.0` in `hello` receives exactly `{"type":"error","code":"unsupported_protocol_version","required":"0.4.0","received":"<version>","message":"Client is too old; upgrade required"}` and the backend closes the socket. A test asserts the error is serializable JSON with those exact keys.
8. **AC8** — On upgrade from a pre-seq backend, the one-shot migration assigns `seq` to every existing message in chronological order and persists `next-seq` / `min-available-seq` per session.

## Alternatives Considered

### A. Keep two paths, fix the cursor

Make UUIDs mandatory, require iOS to sort by insertion order, and add `from_uuid`/`to_uuid` bracketing to every reply so the client can detect gaps by UUID chains.

- **Pros**: smallest wire change, no migration, no protocol bump.
- **Cons**: preserves the dual-path cognitive model. The watcher-vs-subscribe race still exists; gap detection relies on clients storing a UUID chain (easy to break). Timestamp-sort removal alone is a significant client refactor without eliminating the root issue.

Rejected — it reduces the symptom rate but not the class of bugs.

### B. File bytes as cursor

Use the JSONL file's byte offset as the sync cursor on the wire.

- **Pros**: absolute simplicity server-side.
- **Cons**: byte offsets shift under compaction (the file gets rewritten). Compaction events would invalidate every client's cursor. Also leaks the provider's on-disk schema into the protocol.

Rejected — compaction incompatibility is a dealbreaker.

### C. Push-only, replay on subscribe

Subscribe replays the entire session as individual push events; no "history" payload at all.

- **Pros**: exactly one code path.
- **Cons**: every subscribe costs O(messages) network. Large sessions (>1k messages, common) would saturate the WebSocket on reconnect. No budget/truncation support without reinventing pagination inside the push stream.

Rejected — performance regression.

### D. Chosen: monotonic seq + unified `session_history`

Combines B's simplicity with A's compatibility story: an integer cursor is stable across compaction if we retain it, and the single `session_history` shape removes the dual-path races entirely.

**Trade-off**: requires a one-shot migration to stamp existing messages and a protocol bump. Both are bounded, well-understood costs. The payoff is that five distinct flakiness classes collapse into "did the cursor math work?" — which is trivially unit-testable.

## Risks & Mitigations

| Risk | Detection | Mitigation |
|---|---|---|
| Migration miscounts `seq` for an existing large session, leaving `next-seq` wrong | Session-index audit at startup after migration; log count mismatch between JSONL lines and `message-count`. | Migration is idempotent: on failure, delete `next-seq` and re-run. Backup the session index before migrating. |
| Client and server disagree on `seq` after backend rollback | Client sends `last_seq` ahead of server's `next_seq`; server responds with `gap.reason = "client_ahead"`. | Client drops local CoreData for that session and reloads from `last_seq = 0`. Rare (only during downgrade). |
| Partial-line detection false-positives drop a real but unusually formatted line | Parse failure rate metric on the watcher; alert if > 0.1% of lines fail to parse. | Fall back to the old behavior (advance cursor) after N consecutive retries on the same byte range. Log the line for inspection. |
| Protocol bump strands older iOS users | `hello.version` mismatch visible in backend logs. | Ship iOS update to TestFlight ≥ 1 week before backend flip; gate backend enforcement behind a config flag so we can roll back to accepting v0.3.0 clients temporarily. |
| Per-session seq counter becomes a write hotspot | Session-index write latency metrics. | Counter lives in an atom keyed per-session; writes are serialized per session only. Monitor p99 of `session-index-update!` during rollout. |

**Rollback strategy**: the feature ships behind a backend config flag `:message-stream-version` (`:v0.3.0` or `:v0.4.0`). If an issue surfaces post-deploy, flip to `:v0.3.0`, which disables seq assignment and reverts to the `last_message_id` / `session_updated` paths. Leftover state is harmless on both sides and does not need cleanup:

- **Backend**: `:next-seq` and `:min-available-seq` keys in the session index are ignored by v0.3.0 code paths. They remain accurate if we later re-enable v0.4.0, so leaving them in place is strictly better than stripping them.
- **iOS**: the `seq` column on `CDMessage` is likewise ignored by v0.3.0-compatible code; existing cached rows keep their `seq` values, new offline-created rows default to `0`.

Client-side, the flag materializes as the `hello.version` value; iOS already has a compatibility branch for `0.3.0`.
