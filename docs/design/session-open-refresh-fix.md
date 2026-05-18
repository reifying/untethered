# Session-Open "Stale Messages" Fix

## 1. Overview

### Problem Statement

After opening a session and returning to it following a background→foreground transition,
the user sees stale cached messages and must tap the ⟳ toolbar button to fetch updates.
The behaviour is deterministic after the *second* foreground return to the same session
without navigating away in between.

A secondary, less frequent symptom occurs when opening a session whose JSONL file was
recently replaced by a new Claude Code process: the view briefly displays "No messages
yet" even though the session has a full history — because the `file_replaced` recovery
path purges the local cache in the gap before the auto-resubscribe delivers fresh messages.

### Goals

1. Ensure every background→foreground transition while a session is visible issues a
   fresh subscribe, regardless of how many such transitions have already occurred.
2. Eliminate the "No messages yet" flash when `file_replaced` purges a non-empty
   cached session during recovery.
3. Preserve all existing subscription-lifecycle contracts (navigate away → navigate
   back, cold launch, macOS NavigationSplitView session switch).

### Non-goals

- Changing the prune threshold constants or the `needsPruning()` gating logic.
- Server-side changes. Both bugs are purely client-side iOS.
- Extending the message retention limit beyond `maxMessagesPerSession = 50`.

---

## 2. Background & Context

### Current State

#### `hasSubscribedThisAppear` lifecycle

`hasSubscribedThisAppear` is a `@State var Bool` that guards against duplicate
subscribes within a single view-appear cycle.

| Event | `hasSubscribedThisAppear` after | Wire effect |
|---|---|---|
| `onAppear` → `loadSessionIfNeeded()` | `true` | subscribe sent |
| `onDisappear` | `false` | unsubscribe sent |
| `onChange(of: session.id)` (macOS) | reset to `false`, then `loadSessionIfNeeded()` sets `true` | unsubscribe old, subscribe new |
| `onChange(of: scenePhase)` → foreground | `false` ← **bug** | `refreshSubscription()` called |

The scenePhase handler sets `hasSubscribedThisAppear = false` *before* calling
`refreshSubscription`. It is never set back to `true`. After the first foreground
return, subsequent foreground transitions hit the guard and produce no subscribe.

#### `file_replaced` recovery — cache purge race

When the server detects the underlying JSONL file has been replaced it returns a
`session_history` payload with `fileReplaced: true` and zero messages.
`SessionSyncManager.handleSessionHistoryPayload` (v0.5.0, lines 723–746) responds:

1. `session.lastOffsetMerged = 0`; `session.liveFromOffset = 0`
2. `purgeMessagesAtOrAbove(offset: 0, …)` — deletes all CDMessage rows for the session
3. `ctx.save()`
4. Fires `sessionSyncRequestsResubscribeFromZero` delegate → `VoiceCodeClient.subscribe`

Between step 3 and the delivery of the re-subscribe's `session_history` response:
- Core Data has 0 messages for the session
- `hasSubscribedThisAppear = true` (was never reset by this path)
- `isLoading = false` (was cleared at `onAppear` time because Core Data had messages)

The view's branching condition is:

```swift
if isLoading {
    // spinner ← not shown
} else if messages.isEmpty && hasSubscribedThisAppear {
    // "No messages yet" ← shown briefly  ← bug
} else if scenePhase == .active {
    // message list
}
```

During the ~300 ms recovery window the user sees "No messages yet" instead of a
spinner, then the re-subscribe delivers the full history and the list appears.

### Why Now

Commit `e6f673b9` ("gate scenePhase handler on `hasSubscribedThisAppear`") introduced
Fix 1 of `docs/design/conversation-refresh-and-prune-fix.md`, correctly stopping
background-stack sessions from re-subscribing on foreground return. That fix sets
`hasSubscribedThisAppear = false` without restoring it, which is the root cause of
Bug 1 here.

Bug 2 (the "No messages yet" flash) pre-dates that commit but is unmasked by the
`file_replaced` recovery path added in the v0.5.0 protocol work.

### Related Work

- `docs/design/conversation-refresh-and-prune-fix.md` — prune-on-open and scenePhase
  guard fixes (the guard introduced here is the proximate cause of Bug 1)
- `docs/design/websocket-reconnection-fix.md` — subscription lifecycle background
- `ios/VoiceCode/Views/ConversationView.swift` — both fixes land here
- `ios/VoiceCode/Managers/SessionSyncManager.swift` — `file_replaced` handler

---

## 3. Detailed Design

### Data Model

No CoreData schema changes. Both fixes are purely behavioral.

### API Design

N/A — both fixes are client-side iOS behavioral changes with no protocol or endpoint changes.

---

### Fix 1 — Restore `hasSubscribedThisAppear` after foreground refresh

**File:** `ios/VoiceCode/Views/ConversationView.swift`

**Current code (`onChange(of: scenePhase)` handler):**

```swift
.onChange(of: scenePhase) { oldPhase, newPhase in
    guard newPhase == .active, oldPhase != .active else { return }
    guard !(session.isLocallyCreated && session.messageCount == 0) else { return }
    guard hasSubscribedThisAppear else { return }
    hasSubscribedThisAppear = false
    client.refreshSubscription(sessionId: session.id.uuidString.lowercased())
}
```

**Problem:** `hasSubscribedThisAppear` is set to `false` before `refreshSubscription`
and is never restored. The next background→foreground transition fails the guard and
produces no subscribe. The user sees messages frozen at the state of the previous
subscribe.

**Proposed change:**

```swift
.onChange(of: scenePhase) { oldPhase, newPhase in
    guard newPhase == .active, oldPhase != .active else { return }
    guard !(session.isLocallyCreated && session.messageCount == 0) else { return }
    guard hasSubscribedThisAppear else { return }
    hasSubscribedThisAppear = false
    client.refreshSubscription(sessionId: session.id.uuidString.lowercased())
    // Restore so the next foreground return also triggers a refresh.
    hasSubscribedThisAppear = true
}
```

**Why this is safe:** All assignments happen synchronously on the main thread in a
single SwiftUI state-update transaction. SwiftUI cannot observe the intermediate
`false` value from outside this closure. The `guard !hasSubscribedThisAppear` check
inside `loadSessionIfNeeded()` is only evaluated after this closure completes and
SwiftUI re-renders, by which time the flag is `true` again. Any intermediate `onAppear`
that fires while `hasSubscribedThisAppear = false` would call `loadSessionIfNeeded()`,
but `client.subscribe()` is a no-op when `subscriptions[sessionId] == .confirmed`.

---

### Fix 2 — Show spinner instead of "No messages yet" during `file_replaced` recovery

**File:** `ios/VoiceCode/Views/ConversationView.swift`

**Current code (`onChange(of: messages.count)`):**

```swift
.onChange(of: messages.count) { oldCount, newCount in
    // Hide loading indicator when messages arrive
    if isLoading && newCount > 0 {
        logger.info("⏱️ Messages arrived (\(newCount)), hiding loading indicator")
        isLoading = false
    }
    // ... auto-scroll logic
}
```

**Problem:** This handler only transitions `isLoading: true → false`. When `file_replaced`
purges a non-empty session (`oldCount > 0 → newCount == 0`), `isLoading` stays `false`.
The view renders the "No messages yet" branch until the re-subscribe delivers fresh messages.

**Proposed change:**

```swift
.onChange(of: messages.count) { oldCount, newCount in
    // Hide loading indicator when messages arrive
    if isLoading && newCount > 0 {
        logger.info("⏱️ Messages arrived (\(newCount)), hiding loading indicator")
        isLoading = false
    }
    // Show spinner during file_replaced recovery: N→0 purge while subscribed.
    if !isLoading && newCount == 0 && oldCount > 0 && hasSubscribedThisAppear {
        logger.info("⏱️ Messages purged (\(oldCount) → 0) while subscribed, showing loading indicator")
        isLoading = true
        // Fallback: loadSessionIfNeeded's timeout won't clear this later isLoading=true.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            if self.isLoading {
                logger.info("⏱️ Purge-recovery loading indicator hidden (5s timeout fallback)")
                self.isLoading = false
            }
        }
    }
    // ... auto-scroll logic (unchanged)
}
```

**Why this is safe:** This branch only fires when all four conditions hold: `isLoading`
is already `false` (no in-progress spinner from a prior path), the list went to zero
(`newCount == 0`) from a non-zero state (`oldCount > 0`), and a subscribe is in flight
(`hasSubscribedThisAppear = true`). The only production call site that produces this
transition is `purgeMessagesAtOrAbove(offset: 0)` in the `file_replaced` handler.

The loading indicator is cleared either when the re-subscribe delivers messages
(existing `isLoading && newCount > 0` branch) or by the explicit 5-second timeout
scheduled inline. The timeout is necessary because `loadSessionIfNeeded()` schedules
its own 5-second fallback only when `isLoading = true` at the time that function
executes — this `onChange` fires later, so that earlier timeout block was never
enqueued for this particular `isLoading = true` transition.

---

### Component Interactions

#### Bug 1 — Repeated foreground return, before fix

```
User opens Session A
  │  onAppear → loadSessionIfNeeded → hasSubscribedThisAppear = true → subscribe
  │
  ├── Background app
  │
  ├── Foreground app (1st time)
  │     scenePhase: inactive → active
  │     hasSubscribedThisAppear = true → guard passes
  │     hasSubscribedThisAppear = false     ← not restored
  │     refreshSubscription("session-a")
  │
  ├── Background app again (hasSubscribedThisAppear = false)
  │
  └── Foreground app (2nd time)
        scenePhase: inactive → active
        hasSubscribedThisAppear = false → guard BLOCKS   ← user sees stale messages
```

#### Bug 1 — After fix

```
User opens Session A
  │  onAppear → loadSessionIfNeeded → hasSubscribedThisAppear = true → subscribe
  │
  ├── Background / Foreground (1st time)
  │     guard passes → refreshSubscription → hasSubscribedThisAppear = true (restored)
  │
  ├── Background / Foreground (2nd time)
  │     guard passes → refreshSubscription → hasSubscribedThisAppear = true (restored)
  │
  └── ... every foreground return triggers a fresh subscribe
```

#### Bug 2 — `file_replaced` recovery, before fix

```
Session cached: 50 messages, isLoading = false

subscribe → session_history(msgs=0, fileReplaced=true)
  │
  ├── SessionSync purges Core Data: 50 → 0 messages
  │     messages.count: 50 → 0
  │     onChange fires: isLoading=false, newCount=0, oldCount=50 → no action
  │     view renders: !isLoading && isEmpty && hasSubscribed → "No messages yet" ← shown
  │
  └── auto-resubscribe → session_history(msgs=145)
        messages.count: 0 → 145
        onChange: isLoading=false, newCount=145 → isLoading = false (no-op)
        view renders: message list ← shown
```

#### Bug 2 — After fix

```
Session cached: 50 messages, isLoading = false

subscribe → session_history(msgs=0, fileReplaced=true)
  │
  ├── SessionSync purges Core Data: 50 → 0 messages
  │     onChange fires: !isLoading && newCount=0 && oldCount=50 && hasSubscribed
  │       → isLoading = true                   ← new branch
  │     view renders: isLoading → spinner       ← shown instead of "No messages yet"
  │
  └── auto-resubscribe → session_history(msgs=145)
        onChange: isLoading=true && newCount=145 → isLoading = false
        view renders: message list ← shown
```

---

## 4. Verification Strategy

### Testing Approach

#### Unit Tests — Fix 1

The `onChange(of: scenePhase)` handler logic is not directly unit-testable (it is a
private SwiftUI modifier closure). Acceptance criteria are verified by:

1. **New behavioral test**: add `testScenePhaseRefreshRestoresFlagForNextCycle` to
   `ScenePhaseSubscriptionGuardTests.swift`. It must also update the `simulate` helper
   to include the `hasSubscribedThisAppear = true` restoration so the helper matches
   the fixed handler.
2. **Updated regression test**: `testScenePhaseRefreshesActiveSession` currently
   asserts `XCTAssertFalse(flagAfter)`. With Fix 1 the flag is restored to `true`,
   so this assertion **must be updated** to `XCTAssertTrue(flagAfter)` (and the
   assertion message updated accordingly). Failing to update it is not an option —
   the test will fail with the fix applied.

#### Unit Tests — Fix 2

`isLoading` is `@State` on a SwiftUI view and cannot be set directly from a test.
Acceptance is verified by:

1. **Regression guard**: existing `PruneOnOpenRegressionTests` must pass unchanged.
2. **Observable condition**: verify that `CDMessage.pruneOldMessages` returning
   `deletedCount > 0` from a non-empty starting state is the only production path
   that triggers `messages.count` dropping to zero while `hasSubscribedThisAppear = true`.

#### Integration Tests

1. **Repeated foreground return — Fix 1.** Navigate to a session, background the app,
   foreground it (triggers first refresh), background again, foreground again. Verify
   the second foreground triggers a subscribe wire message for the visible session.
   Confirm via VoiceCodeClient wire-log: two additional `→ subscribe` entries (one per
   foreground return) with **no** intervening `→ unsubscribe`. `refreshSubscription`
   demotes the in-memory state from `.confirmed → .desired` and re-calls `subscribe`;
   it does not send an unsubscribe wire message (contrast with `requestSessionRefresh`,
   the toolbar button, which does send an unsubscribe+pong barrier before resubscribing).

2. **`file_replaced` recovery — Fix 2.** With a session that has 50+ cached rows, trigger
   the `file_replaced` path by deleting or replacing the session's JSONL file on disk while
   the backend is running (e.g. `rm ~/.voice-code/sessions/<session-id>.jsonl`), then sending
   a new message so the backend re-creates it. The backend detects the changed file signature
   on the next write and returns `session_history` with `fileReplaced: true` and zero
   messages. Confirm the trigger fired by checking the backend log for
   `"file-replaced"` or by inspecting the `fileReplaced` field in the `session_history`
   WebSocket frame via the VoiceCodeClient wire-log. Verify the view shows a spinner
   (not "No messages yet") between the purge and the delivery of fresh messages.

3. **navigate-away-and-back remains unaffected — Fix 1 regression.** Navigate Session
   A → Session B → back to Session A. Verify exactly one subscribe for Session A on
   the return (not two). The `onChange(of: session.id)` path, which calls
   `loadSessionIfNeeded()` after resetting the flag, should not be affected.

#### Test Examples

```swift
// MARK: - Fix 1: update simulate helper and add multi-cycle regression test
//
// Two changes to ScenePhaseSubscriptionGuardTests.swift:
//
// 1. Update the `simulate` helper to include the flag restoration from Fix 1:
//
//    private func simulate(...) -> Bool {
//        var flag = hasSubscribedThisAppear
//        guard newPhase == .active, oldPhase != .active else { return flag }
//        guard flag else { return flag }
//        flag = false
//        client.refreshSubscription(sessionId: sessionId)
//        flag = true    // ← Add this line (Fix 1)
//        return flag
//    }
//
// 2. Update `testScenePhaseRefreshesActiveSession` to expect flagAfter = true:
//
//    XCTAssertTrue(flagAfter,   // ← was XCTAssertFalse before Fix 1
//        "hasSubscribedThisAppear must be restored to true so subsequent foreground returns also refresh")
//
// 3. Add the following new test for the repeated-foreground scenario:

func testScenePhaseRefreshRestoresFlagForNextCycle() {
    // First foreground return — guard passes, refresh fires, flag is restored to true.
    let flagAfterFirst = simulate(
        newPhase: .active, oldPhase: .inactive,
        hasSubscribedThisAppear: true,
        sessionId: "session-a", client: client
    )
    XCTAssertTrue(client.refreshSubscriptionCalled,
        "refresh must fire on 1st foreground return")
    XCTAssertTrue(flagAfterFirst,
        "flag must be restored to true so the 2nd foreground return also refreshes")

    // Second foreground return — guard must pass again (regression: before Fix 1 it blocked).
    client.refreshSubscriptionCalled = false
    let flagAfterSecond = simulate(
        newPhase: .active, oldPhase: .inactive,
        hasSubscribedThisAppear: flagAfterFirst,
        sessionId: "session-a", client: client
    )
    XCTAssertTrue(client.refreshSubscriptionCalled,
        "refresh must also fire on 2nd foreground return (was blocked before Fix 1)")
    XCTAssertTrue(flagAfterSecond,
        "flag must remain true after 2nd foreground return")
}
```

```swift
// MARK: - Fix 2: no new test needed
//
// The existing `testPruneOldMessagesOnlyFiresAboveThreshold` in PruneOnOpenRegressionTests
// already verifies that CDMessage.pruneOldMessages on a 50-message session deletes 0 rows
// and leaves count == 50 — confirming that normal pruning cannot drop the count to 0 and
// spuriously trigger the new isLoading=true branch. No additional test is required.
```

### Acceptance Criteria

1. Opening a session, backgrounding the app, foregrounding it, backgrounding again,
   and foregrounding again while the same session is visible sends **two** subscribe
   wire messages (one per foreground return), not one.
2. `hasSubscribedThisAppear` is `true` immediately after the `scenePhase` handler fires
   the `refreshSubscription` call.
3. Opening a session that has 50+ cached rows and whose JSONL file is replaced shows a
   spinner (not "No messages yet") during the gap between the local cache purge and the
   re-subscribe's `session_history` delivery.
4. All existing `ScenePhaseSubscriptionGuardTests` that are not explicitly updated pass
   without modification: `testScenePhaseDoesNotRefreshUnsubscribedSession` (off-screen
   guard unchanged) and `testScenePhaseNonActiveTransitionsAreIgnored` (phase-pair guard
   unchanged).
5. `testScenePhaseRefreshesActiveSession` is updated to assert `XCTAssertTrue(flagAfter)`
   (not `XCTAssertFalse`) and passes: first foreground return still fires a refresh
   and the flag is now `true` afterwards.
6. All existing `PruneOnOpenRegressionTests` pass without modification.
7. Navigate-away-and-back to the same session still sends exactly one subscribe wire
   message (the `onDisappear` unsubscribe + `onAppear` subscribe cycle).

---

## 5. Alternatives Considered

### 5.1 Never reset `hasSubscribedThisAppear` in the scenePhase handler

**Approach:** Remove the `hasSubscribedThisAppear = false` line entirely:

```swift
.onChange(of: scenePhase) { oldPhase, newPhase in
    guard newPhase == .active, oldPhase != .active else { return }
    guard !(session.isLocallyCreated && session.messageCount == 0) else { return }
    guard hasSubscribedThisAppear else { return }
    // No flag reset — flag stays true
    client.refreshSubscription(sessionId: session.id.uuidString.lowercased())
}
```

**Pros:** Simpler; one fewer line.

**Cons:** The `false` assignment exists to handle a subtle edge case: on some iOS
versions `onAppear` can fire after `scenePhase` transitions to `.active` during a
warm foreground. With the flag staying `true`, that `onAppear` would hit the guard in
`loadSessionIfNeeded()` and skip the subscribe — which is correct, but relies on
`client.subscribe()` being a no-op for `.confirmed` sessions. That invariant holds
today but is not the most explicit contract. The proposed fix (reset to `false` then
immediately restore to `true`) explicitly honours the existing comment in
docs/design/conversation-refresh-and-prune-fix.md while also fixing Bug 1.

**Decision:** Rejected in favour of the explicit false→true cycle to preserve
documentation fidelity and make the intent unambiguous.

### 5.2 Post a `sessionPurgedMessages` notification from `SessionSyncManager`

**Approach:** When `purgeMessagesAtOrAbove(offset: 0)` runs for `file_replaced`,
post a `Notification.Name("sessionPurgedMessages")` carrying the session ID. Handle
it in `ConversationView` to set `isLoading = true`.

**Pros:** Does not couple the `isLoading` state transition to Core Data change
observation; the trigger is explicit.

**Cons:** Adds a notification type, a new observer in ConversationView, and coupling
between `SessionSyncManager` and the view layer that doesn't already exist.
The `onChange(of: messages.count)` approach achieves the same effect using the
Core Data state that the view already observes, without new cross-layer coupling.

**Decision:** Rejected. The `onChange` approach is more cohesive.

### 5.3 Set `isLoading = true` unconditionally on subscribe

**Approach:** In `loadSessionIfNeeded()`, always set `isLoading = true` before
sending the subscribe, even when `messages.isEmpty = false`.

**Pros:** Eliminates both the "No messages yet" flash (Bug 2) and any other cases
where the user might see stale messages while a subscribe is in flight.

**Cons:** Every session re-open (including routine background→foreground returns)
would show a brief spinner over the cached message list. For sessions the user
navigates to frequently, this is a visible regression: the cached messages they
were reading would be replaced by a spinner for the duration of the subscribe
round-trip (~100–300 ms).

**Decision:** Rejected. Fix 2's targeted `messages.count: N → 0` condition restricts
the spinner to the `file_replaced` recovery case, which is far less frequent.

---

## 6. Risks & Mitigations

### 6.1 Risk: `isLoading = true` set spuriously during offline purge

**Scenario:** An unusually aggressive offline flush of Core Data (e.g. disk pressure
eviction, iOS storage reclaim) causes CDMessage rows to be deleted outside the
`file_replaced` path. The conditions `!isLoading && newCount == 0 && oldCount > 0 &&
hasSubscribedThisAppear` would be met, showing a spinner that never clears (because
no subscribe is in flight and no `session_history` will arrive).

**Likelihood:** Extremely low. CoreData does not delete rows due to disk pressure;
only explicit `backgroundContext.save()` calls modify the store.

**Mitigation:** Fix 2's inline `DispatchQueue.main.asyncAfter(deadline: .now() + 5.0)`
clears `isLoading` if no messages arrive. `loadSessionIfNeeded()`'s own 5-second timeout
is not a fallback here — it is only enqueued when `isLoading = true` at the time that
function executes, which does not happen for cached-message sessions (the function sets
`isLoading = false` and skips its `if isLoading` gate). The spinner resolves without user
action via Fix 2's timeout.

**Detection:** Log `"⏱️ Messages purged … while subscribed, showing loading indicator"`
(the new branch's log line). If this appears without a subsequent
`"⏱️ Messages arrived"` log, an unexpected purge occurred.

### 6.2 Risk: Extra subscribe after Fix 1 for a session that reconnects while backgrounded

**Scenario:** The WebSocket drops while the app is backgrounded.
`restoreSubscriptionsAfterReconnect()` re-subscribes on the `connected` event. Then
the app is foregrounded. The scenePhase handler fires, `hasSubscribedThisAppear = true`
passes the guard, and `refreshSubscription` sends an additional subscribe.

**Likelihood:** Low but possible on flaky networks. Occurs with and without Fix 1
(the reconnect path always re-subscribes; the foreground path on top adds one more).

**Mitigation:** `refreshSubscription` is idempotent: it demotes `.confirmed → .desired`
then re-calls `subscribe`, which the server handles by sending a fresh `session_history`
from `lastOffsetMerged`. The worst outcome is one extra subscribe/session_history
round-trip. This is the same behavior as today for the *first* foreground return;
Fix 1 extends it to subsequent foreground returns.

### 6.3 Risk: Double subscribe if `onAppear` fires concurrently with the scenePhase handler

**Scenario:** On an iOS version where `onAppear` fires during a warm foreground
transition, both the scenePhase handler and `loadSessionIfNeeded()` run before
SwiftUI's state-update pass has rendered the `hasSubscribedThisAppear = true`
assignment from Fix 1.

**Likelihood:** Extremely low. SwiftUI processes state mutations synchronously within
a single render pass. The `false → true` transition in the scenePhase handler and
any subsequent `onAppear` call cannot observe the intermediate `false` from outside
the closure.

**Mitigation:** Even if `loadSessionIfNeeded()` fires with `hasSubscribedThisAppear =
false` (intermediate state), it calls `client.subscribe()` which is a no-op when
`subscriptions[sessionId] == .confirmed` (set by the scenePhase handler's
`refreshSubscription`). No duplicate wire send occurs.

### Rollback Strategy

Both fixes are independently reversible:

- **Fix 1 rollback:** Remove the single `hasSubscribedThisAppear = true` line added
  after `client.refreshSubscription(...)`, and revert the `simulate` helper and
  `testScenePhaseRefreshesActiveSession` assertion back to their pre-fix state.
  Restores the Bug 1 behavior where only the first foreground return triggers a
  subscribe.
- **Fix 2 rollback:** Remove the `if !isLoading && newCount == 0 && ...` block
  (condition + log + `isLoading = true` + timeout dispatch, ~7 lines) from
  `onChange(of: messages.count)`. Restores the "No messages yet" flash on
  `file_replaced` recovery.

No CoreData migration is required for either rollback.
