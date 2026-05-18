# Conversation Refresh & Message Prune Fix

## Overview

### Problem Statement

Two related bugs affect `ConversationView` reliability:

1. **Spurious background re-subscriptions on foreground return.** When the iOS app is
   backgrounded and brought to the foreground, every `ConversationView` still alive in the
   NavigationStack receives the `scenePhase` environment change. The `onChange(of: scenePhase)`
   handler (added in commit `907bbee0`) unconditionally calls `refreshSubscription()`, which
   re-subscribes sessions the user navigated *away* from — sessions whose `onDisappear` already
   fired and cleared the subscription.

2. **Visible message flicker on session open.** Opening a session (or returning to foreground)
   triggers `loadSessionIfNeeded()`, which calls `CDMessage.pruneOldMessages()` on every
   invocation. If the session has more than 50 cached messages, the oldest rows are deleted
   immediately. Shortly after, the backend's `session_history` reply can deliver new rows,
   temporarily inflating the count past the prune threshold again. The `@FetchRequest` renders
   each CoreData state change, producing a visible jump: the displayed list goes from N → N+delta
   → N−pruned, which reads to the user as "the most recent messages disappeared and then
   reloaded."

### Goals

1. Restrict the foreground-return re-subscribe to the session that is *currently visible*; do
   not re-subscribe sessions the user previously navigated away from.
2. Eliminate the prune-on-open flicker: do not delete cached rows when opening a session.
   Pruning belongs only in `handleSessionHistoryPayload`, where it is already gated behind
   `CDMessage.needsPruning()`.
3. Preserve the `hasSubscribedThisAppear` lifecycle contract for all existing paths (navigate
   away → navigate back, reconnect, cold launch).

### Non-goals

- Re-introducing a `fetchLimit` on the `@FetchRequest`. That limit was removed in commit
  `02f329c2` to fix AttributeGraph hangs caused by the reversed-sort + fetchLimit combination.
  Restoring it is a separate investigation.
- Server-side changes. Both bugs are entirely client-side.
- Changing the prune threshold constants (`maxMessagesPerSession = 50`,
  `pruneThreshold = 10`).

---

## Background & Context

### Current State

#### Subscription lifecycle

`hasSubscribedThisAppear` (`@State var Bool`) is the per-view guard:

| Event | Effect on `hasSubscribedThisAppear` | Effect on subscription |
|---|---|---|
| `onAppear` → `loadSessionIfNeeded()` | set `true` | subscribe sent |
| `onDisappear` | set `false` | unsubscribe sent, `subscriptions[id] = nil` |
| `onChange(of: session.id)` (macOS) | reset to `false`, then `loadSessionIfNeeded()` sets `true` | unsubscribe old, subscribe new |
| `onChange(of: scenePhase)` → foreground | reset to `false`, then `refreshSubscription()` | subscription demoted `.confirmed → .desired`, subscribe re-sent |

The gap: after `scenePhase` resets the flag and calls `refreshSubscription()`, `hasSubscribedThisAppear` remains `false`. Any view in the SwiftUI tree receives the environment change, including views "below" in the navigation stack whose `onDisappear` already fired.

#### Prune call sites

Three callers, two with gating and one without:

| Caller | File | Guard before prune |
|---|---|---|
| `loadSessionIfNeeded()` | `ConversationView.swift:722` | none — fires on every open |
| `handleSessionHistoryPayload(_:SessionHistoryPayload)` (v0.4.0) | `SessionSyncManager.swift:580` | `CDMessage.needsPruning()` (count > 60) |
| `handleSessionHistoryPayload(_:SessionHistoryPayloadV5)` (v0.5.0) | `SessionSyncManager.swift:852` | `CDMessage.needsPruning()` (count > 60) |

`CDMessage.pruneOldMessages()` itself applies a threshold of `totalCount > keepCount (50)`.
So `loadSessionIfNeeded` prunes whenever the session has ≥ 51 rows — more aggressive than
the `needsPruning` guard used by `handleSessionHistoryPayload`.

#### Message count timeline that causes the flicker

```
Open session (55 msgs cached)
  │
  ├─ @FetchRequest renders 55 msgs  ← shown immediately
  │
  ├─ loadSessionIfNeeded: prune fires on background ctx
  │     55 > 50 → delete oldest 5 → save
  │     @FetchRequest updates: 50 msgs  ← oldest 5 gone
  │
  └─ subscribe → session_history delta arrives (10 new msgs)
        upsert → 60 msgs
        needsPruning(60 > 60) = false  → no prune
        @FetchRequest updates: 60 msgs  ← all new msgs visible

Net visible sequence: 55 → 50 → 60
User sees: messages disappear, then more appear
```

### Why Now

Commits `907bbee0` (foreground re-subscribe) and `de70a9a4` (clear `liveFromOffset` on
unsubscribe) are the two most recent iOS changes. `907bbee0` introduced the background-stack
re-subscription bug. The prune flicker predates both commits but is more noticeable now that
the foreground path triggers `loadSessionIfNeeded()` more reliably.

### Related Work

- `docs/design/websocket-reconnection-fix.md` — subscription lifecycle background
- `docs/design/refresh-session-list-fix.md` — adjacent refresh-path fix
- Commit `907bbee0` — foreground re-subscribe (source of Bug 1)
- Commit `de70a9a4` — clear `liveFromOffset` on unsubscribe
- Commit `02f329c2` — removed `fetchLimit` from `@FetchRequest`

---

## Detailed Design

### Data Model

No CoreData schema changes. The fix is purely behavioral.

### Fix 1 — Gate the scenePhase handler on `hasSubscribedThisAppear`

**File:** `ios/VoiceCode/Views/ConversationView.swift`

**Current code (lines 655–660):**

```swift
.onChange(of: scenePhase) { oldPhase, newPhase in
    guard newPhase == .active, oldPhase != .active else { return }
    guard !(session.isLocallyCreated && session.messageCount == 0) else { return }
    hasSubscribedThisAppear = false
    client.refreshSubscription(sessionId: session.id.uuidString.lowercased())
}
```

**Problem:** `hasSubscribedThisAppear` is reset to `false` unconditionally before calling
`refreshSubscription`. Views whose `onDisappear` already fired (setting
`hasSubscribedThisAppear = false`) pass right through and issue a spurious subscribe.

**Proposed change:**

```swift
.onChange(of: scenePhase) { oldPhase, newPhase in
    guard newPhase == .active, oldPhase != .active else { return }
    guard !(session.isLocallyCreated && session.messageCount == 0) else { return }
    // Only refresh if this view was actively subscribed at background time.
    // Views below in the NavigationStack had onDisappear fire (which set
    // hasSubscribedThisAppear = false and called unsubscribe). Refreshing
    // them here would re-subscribe sessions the user navigated away from.
    guard hasSubscribedThisAppear else { return }
    hasSubscribedThisAppear = false
    client.refreshSubscription(sessionId: session.id.uuidString.lowercased())
}
```

**Why this works:** `hasSubscribedThisAppear` is `true` only for the view the user was
looking at when the app backgrounded — `onDisappear` did not fire for it, so the flag was
never cleared. All other ConversationViews in the stack had `onDisappear` fire, clearing
the flag. The guard stops them from re-subscribing.

After `refreshSubscription()`, `hasSubscribedThisAppear` is `false`. If `onAppear` fires
afterward (uncommon on foreground return but possible on some iOS versions),
`loadSessionIfNeeded()` runs its normal subscribe path — but `subscriptions[sessionId]`
is `.confirmed` at that point so `client.subscribe()` returns early, making the double-call
a no-op.

### Fix 2 — Remove prune from `loadSessionIfNeeded()`

**File:** `ios/VoiceCode/Views/ConversationView.swift`

**Current code (lines 719–732):**

```swift
// Prune old messages on background context before loading
// iOS only needs recent messages; backend retains full history
let sessionId = session.id
PersistenceController.shared.performBackgroundTask { backgroundContext in
    let pruneStart = Date()
    let deletedCount = CDMessage.pruneOldMessages(sessionId: sessionId, in: backgroundContext)
    let pruneMs = Int(Date().timeIntervalSince(pruneStart) * 1000)
    if deletedCount > 0 {
        try? backgroundContext.save()
        logger.info("⏱️ Pruned \(deletedCount) messages in \(pruneMs)ms")
    } else {
        logger.info("⏱️ No pruning needed (\(pruneMs)ms)")
    }
}
```

**Proposed change:** Remove this block entirely.

**Rationale:** `handleSessionHistoryPayload` (both v0.4.0 and v0.5.0 paths) already prunes
after each batch of incoming messages, gated on `CDMessage.needsPruning()`. That is the
correct callsite: we just received new data and need to bound the local cache. Opening a
session should display existing cached rows without modification. The prune here is
preemptive and produces visible flicker for no user benefit — the backend will deliver a
corrected view via `session_history` within seconds anyway.

The session-size bound is still enforced; it is just moved to the data-arrival path rather
than the view-appear path.

### Component Interactions

**Foreground return — before fix:**

```
App foregrounds (app was on Session B; Session A is below in stack)
  │
  ├─ scenePhase fires for Session A view (hasSubscribedThisAppear = false)
  │     guard !(locallyCreated && empty) → passes
  │     hasSubscribedThisAppear = false (no-op)
  │     refreshSubscription("session-a") → subscribe sent ← spurious
  │
  └─ scenePhase fires for Session B view (hasSubscribedThisAppear = true)
        hasSubscribedThisAppear = false
        refreshSubscription("session-b") → subscribe sent ← correct
```

**Foreground return — after fix:**

```
App foregrounds
  │
  ├─ scenePhase fires for Session A view (hasSubscribedThisAppear = false)
  │     guard hasSubscribedThisAppear → fails → return ← spurious subscribe blocked
  │
  └─ scenePhase fires for Session B view (hasSubscribedThisAppear = true)
        guard hasSubscribedThisAppear → passes
        hasSubscribedThisAppear = false
        refreshSubscription("session-b") → subscribe sent ← correct
```

**Session open message count — after fix:**

```
Open session (55 msgs cached)
  │
  ├─ @FetchRequest renders 55 msgs
  │
  ├─ loadSessionIfNeeded: subscribe fires
  │     (no prune call — removed)
  │
  └─ session_history delta arrives (10 new msgs)
        upsert → 65 msgs
        needsPruning(65 > 60) = true → prune to 50
        @FetchRequest: 55 → 65 → 50

Net visible sequence: 55 → 65 → 50
Still a jump, but no longer caused by opening the session itself;
only caused by new data arriving (expected behavior).
```

The residual 65→50 jump from incoming session_history data is a separate concern
(see Alternatives §5.1). This fix eliminates the 55→50 step that was entirely spurious.

---

## Verification Strategy

### Testing Approach

#### Unit Tests

**Fix 1 — scenePhase guard:**

1. `refreshSubscription` is NOT called for a view where `hasSubscribedThisAppear == false`
   when `scenePhase` transitions to `.active`.
2. `refreshSubscription` IS called for a view where `hasSubscribedThisAppear == true` on
   the same transition.
3. After the scenePhase handler fires for the visible view, `hasSubscribedThisAppear` is
   `false` (ready for the next foreground cycle).

**Fix 2 — prune removal:**

1. Opening a session with 55 cached messages does NOT reduce the count to 50.
2. Receiving a `session_history` payload that pushes the count past 60 DOES trigger prune
   (existing behavior, no change needed — this is a regression guard).
3. `loadSessionIfNeeded` with any message count no longer calls `CDMessage.pruneOldMessages`.

#### Integration Tests

1. **Foreground return with stacked sessions.** Navigate to Session A, navigate to Session B,
   background the app, foreground it. Verify Session A's subscription count does not change
   (was nil, stays nil). Verify Session B receives a fresh subscribe wire message.
2. **Session open with oversized cache.** Pre-populate CoreData with 55 messages for a
   session. Open that session. Verify the message count does not drop to 50 before the first
   session_history reply arrives.
3. **Prune still fires after session_history.** Receive a session_history payload that brings
   total count to 65. Verify pruning fires and reduces to 50.

#### Test Examples

```swift
// MARK: - Fix 1: scenePhase guard
//
// loadSessionIfNeeded() and the scenePhase handler are private to a SwiftUI
// View struct, so we test the guard logic by simulating it inline and use a
// purpose-built mock that overrides refreshSubscription().

// Mock that tracks calls to refreshSubscription without touching the network.
private class MockVoiceCodeClientForScenePhase: VoiceCodeClient {
    var refreshSubscriptionCalled = false
    var lastRefreshedSessionId: String?

    init() {
        super.init(serverURL: "ws://localhost:8080", setupObservers: false)
    }

    override func refreshSubscription(sessionId: String) {
        refreshSubscriptionCalled = true
        lastRefreshedSessionId = sessionId
    }
}

final class ScenePhaseSubscriptionGuardTests: XCTestCase {

    func testScenePhaseDoesNotRefreshUnsubscribedSession() {
        // Arrange: view whose onDisappear already fired — flag is false.
        let client = MockVoiceCodeClientForScenePhase()
        var hasSubscribedThisAppear = false

        // Act: simulate the scenePhase handler with the new guard.
        let newPhase = ScenePhase.active
        let oldPhase = ScenePhase.background
        if newPhase == .active && oldPhase != .active {
            if hasSubscribedThisAppear {          // ← new guard
                hasSubscribedThisAppear = false
                client.refreshSubscription(sessionId: "session-a")
            }
        }

        // Assert: no refresh issued for the already-unsubscribed session.
        XCTAssertFalse(client.refreshSubscriptionCalled)
        XCTAssertFalse(hasSubscribedThisAppear)
    }

    func testScenePhaseRefreshesActiveSession() {
        // Arrange: view that was visible at background time — flag is true.
        let client = MockVoiceCodeClientForScenePhase()
        var hasSubscribedThisAppear = true

        let newPhase = ScenePhase.active
        let oldPhase = ScenePhase.background
        if newPhase == .active && oldPhase != .active {
            if hasSubscribedThisAppear {
                hasSubscribedThisAppear = false
                client.refreshSubscription(sessionId: "session-b")
            }
        }

        XCTAssertTrue(client.refreshSubscriptionCalled)
        XCTAssertEqual(client.lastRefreshedSessionId, "session-b")
        XCTAssertFalse(hasSubscribedThisAppear)   // reset for next foreground cycle
    }
}
```

```swift
// MARK: - Fix 2: no prune on open
//
// loadSessionIfNeeded() is a private method on a SwiftUI View struct and
// cannot be called from a test target. Acceptance criterion 3 ("loadSessionIfNeeded
// no longer contains a CDMessage.pruneOldMessages call") is verified by code
// inspection / grep rather than a unit test. The behavioral tests below verify
// that (a) pruneOldMessages itself works correctly, and (b) the
// handleSessionHistoryPayload path still prunes when it should.
//
// These tests follow the same pattern as SessionSyncManagerOffsetPayloadTests:
// PersistenceController(inMemory: true) for isolation, and a local SessionSyncManager
// instance wired to that controller. Place them in a new XCTestCase subclass with
// setUpWithError / tearDownWithError as shown.

final class PruneOnOpenRegressionTests: XCTestCase {

    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!
    var manager: SessionSyncManager!

    override func setUpWithError() throws {
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
        manager = SessionSyncManager(persistenceController: persistenceController)
    }

    override func tearDownWithError() throws {
        manager = nil
        context = nil
        persistenceController = nil
    }

    func testPruneOldMessagesOnlyFiresAboveThreshold() {
        // 50 messages — pruneOldMessages must not delete any (50 > 50 is false).
        let sessionId = UUID()
        let bgCtx = persistenceController.container.newBackgroundContext()
        bgCtx.performAndWait {
            for i in 0..<50 {
                let msg = CDMessage(context: bgCtx)
                msg.id = UUID()
                msg.sessionId = sessionId
                msg.timestamp = Date(timeIntervalSince1970: Double(i))
                msg.offset = Int64(i)
                msg.text = "message \(i)"
                msg.role = "assistant"
            }
            try! bgCtx.save()

            let deleted = CDMessage.pruneOldMessages(sessionId: sessionId, in: bgCtx)
            XCTAssertEqual(deleted, 0, "pruneOldMessages must not fire when count == keepCount")

            let count = try! bgCtx.count(for: CDMessage.fetchMessages(sessionId: sessionId))
            XCTAssertEqual(count, 50)
        }
    }

    func testHandleSessionHistoryStillPrunesAfterNewData() {
        // Arrange: 55 existing messages; payload adds 10 more → 65 total → prune to 50.
        let sessionId = UUID()
        let sessionIdString = sessionId.uuidString.lowercased()

        // Seed the in-memory store via the view context (matches the pattern in
        // SessionSyncManagerOffsetPayloadTests.seedSession).
        let backendSession = CDBackendSession(context: context)
        backendSession.id = sessionId
        backendSession.backendName = "test"
        backendSession.workingDirectory = "/tmp"
        backendSession.lastModified = Date()
        backendSession.messageCount = 55
        backendSession.preview = ""
        backendSession.provider = "claude"
        backendSession.lastOffsetMerged = 0
        backendSession.liveFromOffset = 0

        for i in 0..<55 {
            let msg = CDMessage(context: context)
            msg.id = UUID()
            msg.sessionId = sessionId
            msg.timestamp = Date(timeIntervalSince1970: Double(i))
            msg.offset = Int64(i)
            msg.text = "existing \(i)"
            msg.role = "user"
        }
        try! context.save()

        // Act: deliver a payload carrying 10 new messages (offsets 55–64).
        let payload = SessionHistoryPayloadV5(
            sessionId: sessionIdString,
            messages: (55..<65).map { i in
                WireMessageV5(
                    sessionId: sessionIdString,
                    offset: Int64(i),
                    role: "user",
                    text: "new \(i)",
                    uuid: UUID().uuidString.lowercased(),
                    timestamp: Date()
                )
            },
            nextOffset: 65,
            endOfFile: true,
            fileReplaced: false,
            fileSignature: "sig1"
        )
        manager.handleSessionHistoryPayload(payload)

        // Assert: count reduced to 50 (oldest 15 deleted).
        // handleSessionHistoryPayload runs on a serial background queue;
        // allow it to drain before checking the persistent store.
        let expectation = XCTestExpectation(description: "prune completes")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            let verifyCtx = self.persistenceController.container.newBackgroundContext()
            verifyCtx.performAndWait {
                let count = try! verifyCtx.count(for: CDMessage.fetchMessages(sessionId: sessionId))
                XCTAssertEqual(count, 50,
                    "session_history prune must fire when count (65) exceeds needsPruning threshold (60)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }
}
```

### Acceptance Criteria

1. Foregrounding the app after navigating Session A → Session B sends exactly one subscribe
   wire message (for Session B). No subscribe is sent for Session A.
2. Opening a session with 55 cached messages displays 55 rows immediately; no rows are
   deleted until the first session_history reply arrives.
3. `loadSessionIfNeeded` no longer contains a `CDMessage.pruneOldMessages` call.
4. `handleSessionHistoryPayload` (v0.5.0 path) still prunes when total count exceeds 60
   after a batch insert. Existing pruning tests pass unchanged.
5. All existing `VoiceCodeClientProtocolVersionTests` pass.
6. `hasSubscribedThisAppear` is `false` after the scenePhase handler fires for the visible
   session.
7. The scenePhase handler is a no-op for any ConversationView whose `onDisappear` has fired.

---

## Alternatives Considered

### 5.1 Re-add `fetchLimit` to `@FetchRequest`

**Approach:** Restore `fetchLimit = 25` on `CDMessage.fetchMessages()`. The UI would always
show at most 25 messages, so CoreData fluctuations from prune and session_history would be
invisible above that watermark.

**Pros:**
- Eliminates *all* prune-related flicker, including the residual 65→50 jump from
  incoming session_history data.
- Previously shipped (removed in commit `02f329c2`).

**Cons:**
- The reason for removal was real: reversed-sort + fetchLimit caused AttributeGraph hangs.
  Although the sort is now ascending, the hang behavior on older iOS versions is unverified.
- Limits the displayed conversation to 25 turns, which users have reported as too few.
- Requires its own dedicated investigation and testing pass before re-enabling.

**Decision:** Deferred. Fix 2 (remove prune-on-open) eliminates the egregious case. The
remaining 65→50 jump is a secondary issue addressed separately.

### 5.2 Check `ActiveSessionManager` instead of `hasSubscribedThisAppear`

**Approach:** In the scenePhase handler, check
`ActiveSessionManager.shared.isActive(session.id)` instead of `hasSubscribedThisAppear`.

**Pros:**
- Single source of truth across views; not tied to per-view SwiftUI state.

**Cons:**
- `ActiveSessionManager.setActiveSession()` is called inside `loadSessionIfNeeded()`, which
  runs *after* the guard. A race exists where the active session is not yet set when the
  scenePhase handler fires on cold launch.
- `isActive` checks the *current* active session, which may differ from "was this view
  subscribed at background time" if the user switched sessions while the app was backgrounded
  via a notification.
- `hasSubscribedThisAppear` already encodes exactly the contract we need: "was this view
  in a subscribed state when the last foreground transition happened."

**Decision:** Rejected. `hasSubscribedThisAppear` is the correct and already-available signal.

### 5.3 Use `needsPruning()` as a guard inside `loadSessionIfNeeded()`

**Approach:** Rather than removing the prune block, wrap it:

```swift
if CDMessage.needsPruning(sessionId: sessionId, in: backgroundContext) {
    CDMessage.pruneOldMessages(sessionId: sessionId, in: backgroundContext)
}
```

`needsPruning` returns true only when count > 60, so a session with 55 messages would not
be pruned.

**Pros:**
- Reduces risk: extreme cases (sessions with 61+ cached rows) are still pruned on open.

**Cons:**
- Does not eliminate the flicker for sessions with 51–60 rows (the common post-session_history
  state).
- Retains conceptual confusion: session open should not be a data-management event.
- `handleSessionHistoryPayload` already calls `needsPruning` after every batch — this is
  strictly defense-in-depth with an existing defense layer.

**Decision:** Rejected. Removing the block entirely is cleaner and delegates pruning to the
correct callsite.

---

## Risks & Mitigations

### 6.1 Risk: Local cache grows unbounded if session_history never arrives

**Scenario:** A session is opened repeatedly without a successful subscribe reply (offline,
server down). Every open previously pruned to 50; without the prune-on-open, the cache
could accumulate past 60 rows across reconnect cycles.

**Likelihood:** Low. If the subscribe fails, no new messages arrive and the count cannot
grow. The cache can only exceed 60 if session_history delivers rows — at which point the
`handleSessionHistoryPayload` prune fires.

**Mitigation:** None required. Growth is bounded by the session_history prune in
`handleSessionHistoryPayload` and by the threshold applied there. A persistent offline
session accumulates exactly the rows present at last sync, which is already bounded by the
prior prune cycle.

### 6.2 Risk: Spurious subscribe for a session the user never explicitly navigated away from

**Scenario:** On iOS, if SwiftUI's NavigationStack keeps a ConversationView alive without
firing `onDisappear` (e.g., during a NavigationStack reset), `hasSubscribedThisAppear`
could remain `true` for a view the user is no longer looking at. The guard would then allow
a spurious `refreshSubscription` on foreground.

**Likelihood:** Very low. SwiftUI fires `onDisappear` reliably for NavigationStack pops.
The risk is limited to edge cases like programmatic stack resets.

**Mitigation:** `refreshSubscription` is idempotent — demoting `.confirmed → .desired` and
re-sending the subscribe wire message is safe and produces a correct server reply. The worst
outcome is one extra subscribe/session_history round-trip for a non-visible session.

**Detection:** Monitor logs for `subscribe` messages where the session differs from the one
reported by `ActiveSessionManager`.

### 6.3 Risk: Regression on macOS NavigationSplitView session switch

**Scenario:** The `onChange(of: session.id)` handler (macOS) calls `loadSessionIfNeeded()`,
which would previously prune. With Fix 2, it no longer prunes. Combined with a
scenePhase-driven `refreshSubscription`, a macOS user who switches sessions frequently
could accumulate cached rows past 60 until the next session_history batch triggers the
`handleSessionHistoryPayload` prune.

**Likelihood:** Low. Session switches on macOS produce a session_history reply within
seconds, which triggers the prune.

**Mitigation:** Acceptable transient state. The `handleSessionHistoryPayload` prune is the
durable enforcement mechanism.

### Rollback Strategy

Both fixes are isolated and independently reversible:

- **Fix 1**: Remove the `guard hasSubscribedThisAppear else { return }` line from the
  `onChange(of: scenePhase)` handler. Restores the previous behavior where all in-tree
  ConversationViews re-subscribe on foreground.
- **Fix 2**: Restore the `PersistenceController.shared.performBackgroundTask { ... }` block
  inside `loadSessionIfNeeded()`. Re-enables prune-on-open.

No CoreData migration is required for either rollback.

### Detection

1. Logs: watch for `subscribe` wire messages on sessions that are not the active session
   after foreground return.
2. Logs: watch for message count drops at session open time before any `session_history`
   frame is logged (indicates prune-on-open regression).
3. Manual: open a session with 55+ cached messages, observe whether the count drops
   immediately (before any network activity) — it should not.
