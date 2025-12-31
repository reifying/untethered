# Delta Sync Session History

## Overview

### Problem Statement

When iOS subscribes to a session, the backend sends ALL messages (up to 200) in a single `session-history` response. This causes two problems:

1. **Redundant data transfer**: iOS often already has most messages cached in CoreData, but receives them again
2. **Aggressive truncation**: To fit within WebSocket message limits (256KB iOS limit), the current implementation divides the budget equally among all messages, resulting in very small per-message limits that truncate even modest responses

Current truncation behavior with 100KB limit and 50 messages:
- Per-message budget: `100KB / 50 / 2 = 1KB per message`
- A 10KB Claude response gets truncated to ~1KB

### Goals

1. Eliminate redundant message transfer by supporting delta sync
2. Prioritize recent messages (most relevant to user)
3. Preserve small messages intact while allowing truncation of large ones
4. Respect per-client WebSocket message size limits
5. Maintain backward compatibility with clients that don't send `last_message_id`

### Non-goals

- Changing how individual `response` messages are truncated (separate concern)
- Adding pagination for session history (complexity not justified yet)
- Modifying JSONL file format

## Background & Context

### Current State

#### Subscribe Flow

```
iOS                                    Backend
 |                                        |
 |-- subscribe {session_id} ------------->|
 |                                        | Read ALL messages from JSONL
 |                                        | Filter internal messages
 |                                        | Take last 200
 |                                        | Truncate to fit budget
 |<-- session-history {messages[]} -------|
 |                                        |
```

#### Current Message Structure (JSONL)

Each message in Claude's `.jsonl` files has:
```json
{
  "uuid": "73f9332c-a85f-4bee-a264-789942e3aa91",
  "parentUuid": "previous-message-uuid",
  "timestamp": "2025-12-28T14:29:11.054Z",
  "type": "user|assistant",
  "message": {
    "role": "user|assistant",
    "content": [{"type": "text", "text": "..."}]
  }
}
```

#### Current Truncation Algorithm

```clojure
;; truncate-messages-array divides budget equally
(loop [max-text-per-msg (int (/ max-total-bytes msg-count 2))
       iteration 0]
  ;; Truncate ALL messages to this small budget
  (let [truncated (mapv #(truncate-message-text % max-text-per-msg) messages)]
    ...))
```

Problem: A 100-byte message and a 50KB message both get the same 1KB budget.

### Why Now

- Users report truncated content in message detail view
- The "View Full" action shows truncated content because that's all iOS received
- Setting the max message size to 200KB doesn't help because the per-message budget is still divided among all messages

### Related Work

- @STANDARDS.md - WebSocket protocol documentation (must be updated with new fields)
- @docs/design/workstream-provider-session-refactor.md - Session identity concepts

### Required Documentation Updates

After implementation, @STANDARDS.md must be updated to document:

1. **Subscribe message** - Add `last_message_id` optional field
2. **Session History response** - Add `oldest_message_id`, `newest_message_id`, `is_complete` fields
3. **Delta sync behavior** - Document the new sync algorithm

## Detailed Design

### Data Model

No schema changes required. Uses existing `uuid` and `timestamp` fields in JSONL messages.

#### iOS CoreData (existing)

```swift
// CDMessage already stores backend UUID (see SessionSyncManager.createMessage)
// message.id = extractMessageId(from: messageData) ?? UUID()
// extractMessageId extracts the "uuid" field from backend message data
@NSManaged public var id: UUID          // Backend's UUID from JSONL
@NSManaged public var sessionId: UUID
@NSManaged public var timestamp: Date
```

**Note:** iOS already extracts and stores the backend's `uuid` field in `CDMessage.id` via `SessionSyncManager.extractMessageId()`. This enables delta sync without schema changes.

### API Design

#### Subscribe Message (Client → Backend)

**Before:**
```json
{
  "type": "subscribe",
  "session_id": "abc123-..."
}
```

**After:**
```json
{
  "type": "subscribe",
  "session_id": "abc123-...",
  "last_message_id": "73f9332c-..."  // Optional: UUID of newest message iOS has
}
```

**Fields:**
- `session_id` (required): Session to subscribe to
- `last_message_id` (optional): UUID of the most recent message iOS has cached. If provided, backend only sends messages newer than this. If omitted, backend sends recent messages up to budget limit (backward compatible).

#### Session History Response (Backend → Client)

**Before:**
```json
{
  "type": "session_history",
  "session_id": "abc123-...",
  "messages": [...],
  "total_count": 150
}
```

**After:**
```json
{
  "type": "session_history",
  "session_id": "abc123-...",
  "messages": [...],
  "total_count": 150,
  "oldest_message_id": "first-uuid-...",  // New: UUID of oldest message in response
  "newest_message_id": "last-uuid-...",   // New: UUID of newest message in response
  "is_complete": true                      // New: false if budget exhausted before reaching last_message_id
}
```

**New fields:**
- `oldest_message_id`: UUID of the oldest message included (helps iOS understand sync state). `null` if no messages.
- `newest_message_id`: UUID of the newest message included. `null` if no messages.
- `is_complete`: Indicates whether all requested messages were included:
  - When `last_message_id` provided: `true` = all messages since that ID included, `false` = budget exhausted before reaching that ID
  - When `last_message_id` not provided: `true` = all recent messages fit in budget, `false` = budget exhausted (some older messages omitted)

#### Error Cases

| Scenario | Response |
|----------|----------|
| `last_message_id` not found in session | Send all recent messages (treat as if not provided) |
| Session not found | `{type: "error", message: "Session not found: ..."}` |
| Empty session | `{type: "session_history", messages: [], total_count: 0, is_complete: true}` |

### Code Examples

#### Backend: New Truncation Algorithm

```clojure
(def per-message-max-bytes
  "Maximum bytes for a single message's text content.
   Messages larger than this are truncated individually."
  (* 20 1024)) ;; 20KB per message max

(defn build-session-history-response
  "Build session-history response with delta sync and smart truncation.

   Algorithm:
   1. Find messages newer than last-message-id (or all if not provided)
   2. Start from newest, work backwards
   3. Add messages until budget exhausted or last-message-id reached
   4. Truncate only messages exceeding per-message-max
   5. Reverse to chronological order"
  [messages last-message-id max-total-bytes]
  (let [;; Find index of last known message
        last-idx (when last-message-id
                   (some (fn [[idx msg]]
                           (when (= (:uuid msg) last-message-id) idx))
                         (map-indexed vector messages)))

        ;; Get messages newer than last known (or all if not found)
        new-messages (if last-idx
                       (subvec messages (inc last-idx))
                       messages)

        ;; Work backwards from newest, building up result
        reversed-msgs (reverse new-messages)
        overhead-estimate 200 ;; JSON structure overhead

        result (loop [remaining reversed-msgs
                      accumulated []
                      used-bytes overhead-estimate]
                 (if (empty? remaining)
                   {:messages (vec (reverse accumulated))
                    :is-complete true}
                   (let [msg (first remaining)
                         ;; Truncate individual large messages
                         processed-msg (truncate-message-text msg per-message-max-bytes)
                         msg-json (generate-json processed-msg)
                         msg-bytes (count (.getBytes msg-json "UTF-8"))
                         new-total (+ used-bytes msg-bytes 1)] ;; +1 for comma
                     (if (> new-total max-total-bytes)
                       ;; Budget exhausted
                       {:messages (vec (reverse accumulated))
                        :is-complete false}
                       ;; Add message and continue
                       (recur (rest remaining)
                              (conj accumulated processed-msg)
                              new-total)))))]

    (assoc result
           :oldest-message-id (-> result :messages first :uuid)
           :newest-message-id (-> result :messages last :uuid))))
```

#### Backend: Updated Subscribe Handler

```clojure
"subscribe"
(let [session-id (:session-id data)
      last-message-id (:last-message-id data)] ;; New: optional field
  (if-not session-id
    (http/send! channel
                (generate-json
                 {:type :error
                  :message "session_id required in subscribe message"}))
    (do
      (log/info "Client subscribing to session"
                {:session-id session-id
                 :last-message-id last-message-id}) ;; Log delta sync

      (repl/subscribe-to-session! session-id)

      (if-let [metadata (repl/get-session-metadata session-id)]
        (let [file-path (:file metadata)
              file (io/file file-path)
              current-size (.length file)
              all-messages (repl/parse-jsonl-file file-path)
              filtered (repl/filter-internal-messages all-messages)
              max-bytes (get-client-max-message-size-bytes channel)

              ;; Use new delta sync algorithm
              {:keys [messages is-complete oldest-message-id newest-message-id]}
              (build-session-history-response filtered last-message-id max-bytes)]

          (repl/reset-file-position! file-path)
          (swap! repl/file-positions assoc file-path current-size)

          (log/info "Sending session history"
                    {:session-id session-id
                     :message-count (count messages)
                     :total (count all-messages)
                     :is-complete is-complete
                     :has-delta-sync (some? last-message-id)})

          (send-to-client! channel
                           {:type :session-history
                            :session-id session-id
                            :messages messages
                            :total-count (count all-messages)
                            :oldest-message-id oldest-message-id
                            :newest-message-id newest-message-id
                            :is-complete is-complete}))

        (do
          (log/warn "Session not found" {:session-id session-id})
          (http/send! channel
                      (generate-json
                       {:type :error
                        :message (str "Session not found: " session-id)})))))))
```

#### iOS: Updated Subscribe Call

```swift
// VoiceCodeClient.swift

func subscribe(sessionId: String) {
    // Find the newest message we have cached for this session
    let lastMessageId = getNewestCachedMessageId(sessionId: sessionId)

    var message: [String: Any] = [
        "type": "subscribe",
        "session_id": sessionId
    ]

    if let lastId = lastMessageId {
        message["last_message_id"] = lastId
        print("📥 [VoiceCodeClient] Subscribing with delta sync, last: \(lastId)")
    } else {
        print("📥 [VoiceCodeClient] Subscribing without delta sync (no cached messages)")
    }

    sendMessage(message)
}

private func getNewestCachedMessageId(sessionId: String) -> String? {
    guard let sessionUUID = UUID(uuidString: sessionId) else { return nil }

    // Use PersistenceController's viewContext (consistent with existing code patterns)
    let context = PersistenceController.shared.container.viewContext
    let request = CDMessage.fetchRequest()
    request.predicate = NSPredicate(format: "sessionId == %@", sessionUUID as CVarArg)
    request.sortDescriptors = [NSSortDescriptor(keyPath: \CDMessage.timestamp, ascending: false)]
    request.fetchLimit = 1

    do {
        let messages = try context.fetch(request)
        // CDMessage.id contains the backend's UUID (extracted from "uuid" field)
        return messages.first?.id.uuidString.lowercased()
    } catch {
        print("⚠️ [VoiceCodeClient] Failed to fetch newest message: \(error)")
        return nil
    }
}
```

#### iOS: Handle Incomplete Response

```swift
case "session_history":
    if let messages = json["messages"] as? [[String: Any]],
       let sessionId = json["session_id"] as? String,
       let isComplete = json["is_complete"] as? Bool {

        // Process messages...
        processSessionHistory(sessionId: sessionId, messages: messages)

        if !isComplete {
            // Budget exhausted before reaching our last known message
            // This means there's a gap - iOS should show indicator
            print("⚠️ [VoiceCodeClient] Session history incomplete, some messages truncated")
            // Optionally notify user or mark session as having truncated history
        }
    }
```

### Component Interactions

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Subscribe Flow                               │
└─────────────────────────────────────────────────────────────────────┘

iOS (VoiceCodeClient)                    Backend (server.clj)
        │                                        │
        │ 1. Query CoreData for newest           │
        │    message ID in session               │
        │                                        │
        │ 2. subscribe                           │
        │    {session_id, last_message_id} ──────┼──▶ 3. Parse JSONL file
        │                                        │      Filter internal msgs
        │                                        │
        │                                        │    4. Find last_message_id
        │                                        │       index in message list
        │                                        │
        │                                        │    5. Starting from newest:
        │                                        │       - Work backwards
        │                                        │       - Truncate large msgs (>20KB)
        │                                        │       - Stop at budget or last_id
        │                                        │
        │    6. session_history                  │
        │ ◀──{messages, is_complete, ids}────────┤
        │                                        │
        │ 7. Merge into CoreData                 │
        │    (only genuinely new messages)       │
        │                                        │
```

## Verification Strategy

### Testing Approach

#### Unit Tests

1. `build-session-history-response` function:
   - Empty message list
   - All messages fit in budget
   - Budget exhausted mid-way
   - `last-message-id` found → only newer messages
   - `last-message-id` not found → all recent messages
   - Large individual messages truncated
   - Small messages preserved intact

2. Individual message truncation:
   - Messages under 20KB unchanged
   - Messages over 20KB truncated with marker

#### Integration Tests

1. Subscribe without `last_message_id` (backward compatibility)
2. Subscribe with valid `last_message_id` (delta sync)
3. Subscribe with stale `last_message_id` (not in current history)
4. Subscribe to session with large messages

#### End-to-End Tests

1. iOS reconnects → only new messages transferred
2. Large session history → budget respected, recent messages prioritized
3. Mixed message sizes → small preserved, large truncated

### Test Examples

```clojure
(ns voice-code.server-test
  (:require [clojure.test :refer [deftest testing is]]
            [clojure.string :as str]
            [voice-code.server :as server]))

(deftest test-build-session-history-delta-sync
  (testing "Returns only messages newer than last-message-id"
    (let [messages [{:uuid "msg-1" :timestamp "2025-01-01T00:00:00Z" :text "old"}
                    {:uuid "msg-2" :timestamp "2025-01-02T00:00:00Z" :text "middle"}
                    {:uuid "msg-3" :timestamp "2025-01-03T00:00:00Z" :text "new"}]
          result (server/build-session-history-response messages "msg-1" 100000)]
      (is (= 2 (count (:messages result))))
      (is (= "msg-2" (-> result :messages first :uuid)))
      (is (= "msg-3" (-> result :messages last :uuid)))
      (is (true? (:is-complete result))))))

(deftest test-build-session-history-budget-exhausted
  (testing "Stops when budget exhausted, prioritizes newest"
    (let [;; Create messages with increasing size
          messages (for [i (range 10)]
                     {:uuid (str "msg-" i)
                      :text (apply str (repeat (* i 1000) "x"))})
          ;; Small budget that can't fit all
          result (server/build-session-history-response (vec messages) nil 5000)]
      ;; Should include newest messages, not oldest
      (is (= "msg-9" (-> result :messages last :uuid)))
      (is (false? (:is-complete result))))))

(deftest test-build-session-history-preserves-small-messages
  (testing "Small messages are not truncated"
    (let [messages [{:uuid "small" :text "Hello world"}
                    {:uuid "large" :text (apply str (repeat 50000 "x"))}]
          result (server/build-session-history-response messages nil 100000)]
      ;; Small message unchanged
      (is (= "Hello world" (-> result :messages first :text)))
      ;; Large message truncated
      (is (str/includes? (-> result :messages last :text) "[truncated")))))

(deftest test-build-session-history-empty-messages
  (testing "Empty messages returns empty result with nil IDs"
    (let [result (server/build-session-history-response [] nil 100000)]
      (is (= [] (:messages result)))
      (is (true? (:is-complete result)))
      (is (nil? (:oldest-message-id result)))
      (is (nil? (:newest-message-id result))))))
```

### Acceptance Criteria

1. Subscribe with `last_message_id` returns only newer messages
2. Subscribe without `last_message_id` returns recent messages (backward compatible)
3. Messages under 20KB are never truncated
4. Messages over 20KB are truncated with marker showing size
5. Response never exceeds client's max message size setting
6. Newest messages are prioritized when budget is exhausted
7. `is_complete: false` indicates budget exhaustion
8. iOS displays truncated content with appropriate indicator
9. All existing tests continue to pass

## Alternatives Considered

### 1. Pagination

**Approach:** Client requests pages of messages with offset/limit.

**Pros:**
- Fine-grained control
- No truncation needed

**Cons:**
- Multiple round trips
- Complex state management
- Overkill for current use case

**Decision:** Rejected. Delta sync is simpler and addresses the immediate problem.

### 2. Timestamp-based sync

**Approach:** Use `last_timestamp` instead of `last_message_id`.

**Pros:**
- Simpler (no need to track UUIDs)

**Cons:**
- Potential for missed messages if timestamps collide
- Less precise

**Decision:** Rejected. UUIDs are already available and provide exact matching.

### 3. Keep current truncation, increase limits

**Approach:** Just set higher defaults (250KB).

**Pros:**
- No protocol changes

**Cons:**
- Doesn't solve redundant data transfer
- Still divides budget among all messages
- Hits iOS 256KB limit

**Decision:** Rejected. Doesn't address root cause.

## Risks & Mitigations

### 1. UUID mismatch between iOS and backend

**Risk:** iOS sends a `last_message_id` that backend doesn't recognize (e.g., after session compaction).

**Mitigation:** Backend treats unrecognized UUID as if not provided, sends recent messages. Log for debugging.

### 2. Backward compatibility

**Risk:** Older iOS clients don't send `last_message_id`.

**Mitigation:** Field is optional. Missing = full history behavior (up to budget).

### 3. CoreData UUID storage format

**Risk:** iOS stores UUIDs differently than backend (uppercase vs lowercase).

**Mitigation:** Already standardized on lowercase per @STANDARDS.md. Verify in implementation.

### 4. Large gap between cached and current state

**Risk:** User hasn't connected in days, has stale cache, delta sync misses important context.

**Mitigation:** `is_complete: false` indicates gap. iOS can display indicator or request full refresh.

### Rollback Strategy

1. Backend change is additive (new optional field)
2. iOS can roll back without backend changes
3. If issues occur, iOS can stop sending `last_message_id` to get previous behavior
