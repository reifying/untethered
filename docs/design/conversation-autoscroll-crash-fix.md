# Conversation Auto-Scroll Crash Fix

## Overview

### Problem Statement

The app can crash on launch with `SIGABRT` from an **uncaught `NSInternalInconsistencyException`** raised by `UICollectionView`:

```
-[UICollectionView _validateScrollingTargetIndexPath:raisingExceptionIfNecessary:]
-[UICollectionView _scrollToItemAtPresentationIndexPath:atScrollPosition:additionalInsets:animated:]
SwiftUI.UpdateCoalescingCollectionView.updateContent()
... ObservableObjectPublisher.send()
... NSManagedObjectContext.mergeChangesFromContextDidSaveNotification
PersistenceController.resetTTSGateCursorsOnAllSessions(then:)   ← merge observer
```

The crash is the auto-scroll in `ConversationView` (`proxy.scrollTo(lastMessage.id, anchor: .bottom)`) being re-resolved by SwiftUI **during a Core Data merge that is simultaneously mutating the message list**. The scroll target's index path is computed against a message set that has already changed (a prune removed rows, or the merge is mid-flight), so UIKit raises on an out-of-bounds index path. Nothing catches the ObjC exception, so `std::terminate` → `abort()`.

This was observed on a real device (crash report `VoiceCode-2026-05-31-203223.ips`, pid 47811) during the heavy launch churn captured in `logs-20260531-203249.txt`: the conversation's message count oscillated `20 → 265 → 20 → 331 → 22` as a large catch-up backlog was paged in and pruned, with `📨 Scrolling to last message (debounced)` firing repeatedly against the moving target.

### Goals

1. The app must not crash when an auto-scroll coincides with a Core Data merge or a prune.
2. The auto-scroll target must always resolve to a **valid, present** index path, regardless of how the message set is changing.
3. A debounced scroll scheduled against one message set must not fire stale against a later, different message set.
4. Preserve existing auto-scroll behavior: scroll to bottom on new messages when enabled, suppress while the user has scrolled up or the "View Full" sheet is open.
5. The scroll-decision logic must be unit-testable without a live UICollectionView.

### Non-goals

- Changing the bounded-window pruning (`CDMessage.maxMessagesPerSession`) — see @docs/design/conversation-refresh-and-prune-fix.md. The cap stays; this fix makes scrolling robust to it.
- Eliminating the launch-time catch-up re-pull (the `@FetchRequest` count churn). That is the positional-offset-protocol limitation tracked separately and only *widens* the crash window — see @docs/design/append-only-message-stream.md.
- Moving the Core Data merge off the main thread. The synchronous main-thread merge in `PersistenceController.swift:197-215` is load-bearing for `@FetchRequest` correctness and is intentionally unchanged.
- The unrelated **reconnection-timer busy-loop** in `VoiceCodeClient.swift` (repeating ~1.2s timer never cancelled on successful connect). That is a separate subsystem and will be addressed in its own change; see @docs/design/websocket-reconnection-fix.md.
- Switching `List` to `LazyVStack`/`ScrollView` (performance regression; same non-goal as @docs/design/view-full-dialog-dismiss-fix.md).

## Background & Context

### Current State

`ConversationView` renders messages from a **live Core Data fetch** and scrolls by message identity:

| Component | Location | Role |
|-----------|----------|------|
| `@FetchRequest var messages: FetchedResults<CDMessage>` | `ConversationView.swift:98` | Live message list, updates on every merge |
| `List { ForEach(messages) { … } }` | `ConversationView.swift:202-203` | UICollectionView-backed list (SwiftUI internal) |
| Initial scroll on appear | `ConversationView.swift:226` | `proxy.scrollTo(lastMessage.id, anchor: .bottom)` |
| Debounced scroll on count change | `ConversationView.swift:268-276` | `asyncAfter(0.3)` then `proxy.scrollTo(lastMessage.id …)` |
| Scroll when loading finishes | `ConversationView.swift:286` | `proxy.scrollTo(lastMessage.id …)` |
| Toggle-button scroll | `ConversationView.swift:1278-1281` | `proxy.scrollTo(lastMessage.id …)` |

All four scroll sites target `messages.last?.id` — a `CDMessage.id` (`UUID`) that can be **pruned out of the fetch** at any moment.

Two Core Data writers drive merges into the view context, both active at launch:

1. **`PersistenceController.resetTTSGateCursorsOnAllSessions`** (`PersistenceController.swift:153`) runs once per launch and installs a global observer (`PersistenceController.swift:197-215`) that synchronously merges *every* background-context save into `viewContext` on the main queue (`performAndWait` → `mergeChanges`).
2. **`SessionSyncManager.handleSessionHistoryPayload`** (`SessionSyncManager.swift`) saves each incoming `session_history` batch on a background context and posts `NSManagedObjectContextDidSave`.

When (2) saves while the user is on a conversation, the observer from (1) merges it on the main thread → the `@FetchRequest` mutates → SwiftUI runs `UpdateCoalescingCollectionView.updateContent()` → it re-applies the active `ScrollViewReader` target → if `lastMessage.id`'s row was just pruned (or the diff is mid-apply), the index path is invalid → **crash**.

### Why Now

- A real launch crash was captured (`VoiceCode-2026-05-31-203223.ips`) on the freshly deployed `blueparrott-sync-fixes` build.
- It is timing-dependent: the same build survived the *immediate* relaunch through the same sequence, so it will surface intermittently in the field, predominantly on launches where a session has a large backlog and a stale cursor (maximal count churn).
- The recent client message-sync work (retain-the-tail prune, file_replaced reconciliation) made the conversation list churn more visible, which raised the question "is the list robust to churn?" — and the answer is no at the scroll layer.

### Related Work

- @docs/design/conversation-refresh-and-prune-fix.md — the bounded-window prune that drives count churn.
- @docs/design/view-full-dialog-dismiss-fix.md — prior fix for `List` cell recycling destroying view state; establishes the "don't depend on per-row identity surviving churn" precedent and the auto-scroll-suppression-while-sheet-open rule.
- @docs/design/append-only-message-stream.md — the offset-protocol catch-up that produces the large backlog re-pull.
- @docs/design/websocket-reconnection-fix.md — reconnection subsystem (separate; see Non-goals).

## Detailed Design

### Data Model

No Core Data schema change, no migration. The only "data" that changes is the **scroll-target identity**:

Before — scroll to a fetch-managed, prunable per-message identity:

```
scroll target = messages.last?.id        // CDMessage.id : UUID, may vanish on prune
```

After — scroll to a constant sentinel that is always the last row and never removed:

```
scroll target = ConversationView.bottomAnchorID   // "conversation-bottom-anchor" : String, always present
```

The anchor is a zero-height row appended *after* `ForEach(messages)` inside the same `List`, so the list always has at least one row and the anchor's index path (`numberOfItems - 1`) is always valid.

### API Design

This is a view-layer change with **no network/protocol surface** — no WebSocket message changes (see @docs/protocol/websocket-protocol.md), no public API, no breaking changes, no deprecations. The only new internal contract is a pure decision helper:

```swift
/// Pure auto-scroll decisions, extracted from ConversationView so the policy
/// is unit-testable without a live UICollectionView. No SwiftUI / UIKit here.
///
/// Scope note: this helper covers only the *policy* (whether/when to scroll).
/// The crash-preventing part — that the List actually *targets the anchor* —
/// is not expressible here (it lives in the SwiftUI view body) and is covered
/// by code review (AC1) and the manual repro (AC8), not by a unit test.
enum AutoScrollDecision {

    /// Schedule-time gate: a count change should schedule an auto-scroll only
    /// when the list grew, auto-scroll is enabled, and the sheet is not open.
    static func shouldAutoScroll(oldCount: Int,
                                 newCount: Int,
                                 autoScrollEnabled: Bool,
                                 isSheetOpen: Bool) -> Bool {
        guard newCount > oldCount else { return false }  // only on growth
        return shouldStillScroll(autoScrollEnabled: autoScrollEnabled, isSheetOpen: isSheetOpen)
    }

    /// Fire-time re-gate (no counts): growth was already established at schedule
    /// time; by the time the debounced closure runs the user may have toggled
    /// auto-scroll off or opened the "View Full" sheet, so re-check just those.
    static func shouldStillScroll(autoScrollEnabled: Bool, isSheetOpen: Bool) -> Bool {
        autoScrollEnabled && !isSheetOpen
    }

    /// A debounced scroll is stale if a newer scroll was scheduled after it.
    /// `scheduledGeneration` is captured at schedule time; `currentGeneration`
    /// is read at fire time. (Documents the coalescing intent; the comparison
    /// itself is trivial.)
    static func isCurrent(scheduledGeneration: Int, currentGeneration: Int) -> Bool {
        scheduledGeneration == currentGeneration
    }
}
```

#### Error / failure cases

There is no error *response* to return — the failure mode is a fatal exception, and the design eliminates the condition that raises it rather than catching it. The relevant "cases" are the inputs that must not crash:

| Case | Old behavior | New behavior |
|------|--------------|--------------|
| Target row pruned between schedule and fire | scroll to `UUID` → invalid index path → **crash** | scroll to always-present anchor → valid index path |
| List shrinks below the cached target index (deferred re-resolution of an earlier target) | index path out of bounds → **crash** | anchor is always the last row, so its index path is always in bounds |
| Multiple debounced scrolls queued during churn | each fires against latest fetch (racy) | only the newest generation fires |
| "View Full" sheet open | suppressed (already) | suppressed (preserved) |
| User scrolled up | suppressed (already) | suppressed (preserved) |

### Code Examples

#### Happy path — stable anchor + coalesced debounce

The `List` gains a constant trailing anchor:

```swift
extension ConversationView {
    static let bottomAnchorID = "conversation-bottom-anchor"
}

// Inside the List, AFTER ForEach(messages):
List {
    ForEach(messages) { message in
        CDMessageView(message: message, /* … */)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowSeparator(.hidden)
    }

    // Always-present, zero-height bottom anchor. Never removed, so its index
    // path is always valid — scrolling to it can never raise.
    Color.clear
        .frame(height: 0)
        .id(Self.bottomAnchorID)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
}
```

Every scroll site targets the anchor instead of `messages.last?.id`:

```swift
// ConversationView.swift:226 (initial), :286 (loading finished), :1281 (toggle)
proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
```

The debounced count-change handler coalesces via a generation token so a stale scroll cannot fire:

```swift
@State private var scrollGeneration = 0   // bumped on every scheduled scroll

.onChange(of: messages.count) { oldCount, newCount in
    // … existing isLoading / purge-spinner handling …

    guard AutoScrollDecision.shouldAutoScroll(
            oldCount: oldCount,
            newCount: newCount,
            autoScrollEnabled: autoScrollEnabled,
            isSheetOpen: fullMessageSnapshot != nil) else {
        return
    }

    scrollGeneration += 1
    let scheduled = scrollGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        // Superseded by a newer scroll → drop this one.
        guard AutoScrollDecision.isCurrent(scheduledGeneration: scheduled,
                                           currentGeneration: scrollGeneration) else { return }
        // Re-check policy (no counts): the user may have toggled auto-scroll off
        // or opened the "View Full" sheet during the debounce window.
        guard AutoScrollDecision.shouldStillScroll(
                autoScrollEnabled: autoScrollEnabled,
                isSheetOpen: fullMessageSnapshot != nil) else { return }
        LogManager.shared.log("📨 Scrolling to bottom anchor (debounced, gen \(scheduled))",
                              category: "ConversationView")
        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
    }
}
```

#### Error-handling pattern — never scroll to a prunable identity

The invariant is enforced structurally: there is exactly one scroll target string constant, and it is the only thing ever passed to `scrollTo`. A grep-able convention (enforced in code review, AC1) guarantees no site reintroduces `scrollTo(<message id>)`:

```swift
// WRONG — reintroduces the crash (target can be pruned mid-merge):
// proxy.scrollTo(messages.last?.id, anchor: .bottom)

// RIGHT — constant anchor, always valid:
proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
```

#### Edge case — rapid prune churn

During the launch catch-up, `messages.count` toggles `20 → 265 → 20 → 331 → 22`. Each growth schedules a generation; only the final generation survives the `isCurrent` guard, so a single scroll lands after the churn settles — and it targets the anchor, which is valid even while the diff is mid-apply.

```swift
// Sequence within ~1s:
//   gen 1 scheduled (count → 85)   … superseded
//   gen 2 scheduled (count → 265)  … superseded
//   gen 3 scheduled (count → 331)  … superseded
//   gen 4 scheduled (count → 22)   ← only this fires: scrollGeneration == 4
```

### Component Interactions

Crash flow today (the condition we remove):

```
handleSessionHistoryPayload (bg ctx) ── save ──▶ NSManagedObjectContextDidSave
                                                      │
                              main-queue observer (PersistenceController:201)
                                                      │  viewContext.mergeChanges (performAndWait)
                                                      ▼
                          @FetchRequest messages mutates ──▶ SwiftUI updateContent()
                                                      │
                                 re-applies ScrollViewReader target = messages.last.id
                                                      │  (row pruned → index path invalid)
                                                      ▼
                       _validateScrollingTargetIndexPath  ──▶  NSException ──▶ abort()
```

Fixed flow:

```
… same merge … ──▶ SwiftUI updateContent()
                                                      │
                                 re-applies target = bottomAnchorID (always last, always valid)
                                                      ▼
                                          scroll succeeds, no exception
```

Integration points:
- `ConversationView.swift` — anchor row + four scroll-call edits + generation token (only file with behavior change).
- `AutoScrollDecision` — new small pure type (new file `ios/VoiceCode/Utils/AutoScrollDecision.swift`, or nested in `ConversationView.swift`).
- No change to `PersistenceController`, `SessionSyncManager`, `CDMessage`, or the WebSocket layer.

Dependencies: none added. `DispatchQueue`, `ScrollViewProxy`, `@FetchRequest` are already in use.

## Verification Strategy

**What is and isn't unit-testable.** Unit tests cover the auto-scroll *policy* (`AutoScrollDecision`) only. The crash-preventing behavior — that the `List` actually targets the always-present anchor (AC1) and that the target is independent of pruning (AC5) — lives in the SwiftUI view body, cannot be exercised by a unit test (a "test" that compares the `bottomAnchorID` constant to itself is tautological and is deliberately *not* included), and is instead enforced by code review (AC1) and the UI/manual repro (AC8). The anchor is a *structural* fix inferred from the crash backtrace (`updateContent()` re-resolving a scroll target); the manual repro is the decisive validation, not a unit test.

- **Unit tests** (policy): `AutoScrollDecision.shouldAutoScroll`, `.shouldStillScroll`, and `.isCurrent` across the truth table — growth/no-growth, enabled/disabled, sheet open/closed, current/superseded generation. Extends the existing pure-logic style in `AutoScrollTests.swift` (e.g. `testScrollPositionDetection_*`). Run via `make test-class CLASS=AutoScrollDecisionTests`.
- **Cross-platform compile**: `ConversationView` is shared with `VoiceCodeMac` (macOS backs the list with `NSCollectionView`, which has the same invalid-index-path failure mode; the anchor fix is platform-agnostic). Verify both targets build: `make build-mac` and the iOS build inside `make test`.
- **UI test** (automated crash guard): an `XCUITest` (`AutoScrollCrashUITests`) that launches into a session seeded with a large backlog and drives rapid scrolling/refresh; pass = the app process stays alive (no `SIGABRT`). This is the closest automated proxy for the crash, since the unit layer cannot reach the collection view.
- **Manual repro** (decisive gate): see the explicit stale-cursor steps in Acceptance Criteria #8. Repeat 10× because the crash is intermittent.

### Test Examples

```swift
final class AutoScrollDecisionTests: XCTestCase {

    // MARK: shouldAutoScroll (schedule-time gate)

    func testShouldAutoScroll_onGrowthWhenEnabledAndSheetClosed() {
        XCTAssertTrue(AutoScrollDecision.shouldAutoScroll(
            oldCount: 20, newCount: 22, autoScrollEnabled: true, isSheetOpen: false))
    }

    func testShouldNotAutoScroll_whenCountDidNotGrow() {
        // A prune shrinks the count — must never auto-scroll on shrink.
        XCTAssertFalse(AutoScrollDecision.shouldAutoScroll(
            oldCount: 331, newCount: 22, autoScrollEnabled: true, isSheetOpen: false))
    }

    func testShouldNotAutoScroll_whenSheetOpen() {
        XCTAssertFalse(AutoScrollDecision.shouldAutoScroll(
            oldCount: 20, newCount: 22, autoScrollEnabled: true, isSheetOpen: true))
    }

    func testShouldNotAutoScroll_whenDisabled() {
        XCTAssertFalse(AutoScrollDecision.shouldAutoScroll(
            oldCount: 20, newCount: 22, autoScrollEnabled: false, isSheetOpen: false))
    }

    // MARK: shouldStillScroll (fire-time re-gate, no counts)

    func testShouldStillScroll_enabledAndSheetClosed() {
        XCTAssertTrue(AutoScrollDecision.shouldStillScroll(autoScrollEnabled: true, isSheetOpen: false))
    }

    func testShouldNotStillScroll_whenSheetOpenedDuringDebounce() {
        XCTAssertFalse(AutoScrollDecision.shouldStillScroll(autoScrollEnabled: true, isSheetOpen: true))
    }

    func testShouldNotStillScroll_whenDisabledDuringDebounce() {
        XCTAssertFalse(AutoScrollDecision.shouldStillScroll(autoScrollEnabled: false, isSheetOpen: false))
    }

    // MARK: isCurrent (coalescing)

    func testStaleScrollIsDropped() {
        // gen 2 scheduled, then gen 4 scheduled → the gen-2 closure must not fire.
        XCTAssertFalse(AutoScrollDecision.isCurrent(scheduledGeneration: 2, currentGeneration: 4))
        XCTAssertTrue(AutoScrollDecision.isCurrent(scheduledGeneration: 4, currentGeneration: 4))
    }
}
```

UI-level crash guard (the part the unit layer can't reach):

```swift
// AutoScrollCrashUITests.swift — VoiceCodeUITests target
final class AutoScrollCrashUITests: XCTestCase {
    func testRapidChurnDoesNotCrash() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedLargeSession", "1"]   // seed a big backlog on launch
        app.launch()
        app.cells.firstMatch.tap()                                // open the seeded conversation
        // Drive rapid scrolling while history streams/prunes underneath.
        let list = app.collectionViews.firstMatch
        for _ in 0..<20 { list.swipeUp(); list.swipeDown() }
        // Pass condition: the process is still running (a SIGABRT would drop it
        // out of .runningForeground).
        XCTAssertTrue(app.state == .runningForeground)
    }
}
```

### Acceptance Criteria

1. All four `proxy.scrollTo(...)` sites in `ConversationView.swift` (`:226`, `:275`, `:286`, `:1281`) target `bottomAnchorID`; none targets a `CDMessage.id`. *(Verified by code review — a `grep -n "scrollTo(" ConversationView.swift` shows only `bottomAnchorID` targets.)*
2. The `List` contains exactly one always-present, zero-height anchor row with `.id(bottomAnchorID)` after `ForEach(messages)`. *(Code review.)*
3. `AutoScrollDecision.shouldAutoScroll` returns `false` whenever `newCount <= oldCount`, `autoScrollEnabled == false`, or `isSheetOpen == true`, and `true` only on growth with auto-scroll enabled and sheet closed; `shouldStillScroll` returns `true` only when enabled and sheet closed. *(Unit tests.)*
4. A debounced scroll whose `scheduledGeneration` differs from the current `scrollGeneration` does not call `scrollTo`. *(Unit test on `isCurrent`; behavior wired in the view.)*
5. Because the scroll target is the constant `bottomAnchorID` (never `messages.last?.id`), pruning the newest rows cannot leave the target pointing at a removed row. *(Structural — guaranteed by AC1/AC2 above; not a separate unit test, since asserting a constant against itself proves nothing.)*
6. The existing `AutoScrollTests` suite continues to pass unchanged. *(`make test-class CLASS=AutoScrollTests`.)*
7. The shared `ConversationView` compiles for **both** platforms after the change: `make build-mac` and the iOS build in `make test` both succeed.
8. **Manual crash repro** (decisive gate, intermittent — run 10×): (a) open the target session so the app holds a local window of ~20 messages; (b) force-quit the app; (c) let the session grow on the server to ≥ several hundred messages beyond the local cursor (drive the agent, or run the backend's history generator) so the next subscribe must page in a large catch-up; (d) relaunch and immediately open that session while `session_history` batches stream and prune. **Pass** = zero `_validateScrollingTargetIndexPath` entries across the run's `.ips` reports, and the conversation lands pinned to the newest message after the churn settles.

## Alternatives Considered

1. **Catch the ObjC exception** via an `NSException`→Swift bridging `try` shim around `scrollTo`. Rejected: masks the real inconsistency, is fragile across SwiftUI versions, and leaves the collection view in an undefined state.
2. **Guard only — check `id` membership before scrolling** (`if messages.contains(where: { $0.id == target }) { scrollTo(target) }`). Rejected: insufficient. The check passes at call time, but SwiftUI re-resolves the target *later*, during the merge's `updateContent()`, by which point the row can be gone. The crash is in the deferred resolution, not the call.
3. **Increase / remove the debounce.** Rejected: tuning the delay narrows but never closes the race, and a longer delay degrades responsiveness.
4. **Move the merge off the main thread / make it async.** Rejected: the synchronous main-thread merge (`PersistenceController.swift:212`) is required for `@FetchRequest` consistency and is explicitly documented as load-bearing; changing it risks `AttributeGraph` crashes elsewhere.
5. **Replace `List` with `ScrollView`+`LazyVStack`.** Rejected: performance regression for long conversations and loss of cell recycling (same non-goal as @docs/design/view-full-dialog-dismiss-fix.md).

**Chosen:** stable bottom anchor (removes the invalid-index condition structurally) + generation-coalesced debounce (removes stale fires) + extracted pure decision helper (testable policy). Trade-off: one extra always-present zero-height row and a small amount of state; negligible cost, and the policy becomes unit-testable instead of buried in the view body.

## Risks & Mitigations

| Risk | Detection | Mitigation |
|------|-----------|------------|
| **Anchor does not fully eliminate the crash.** The fix is inferred from the backtrace; the crash is intermittent SwiftUI-internal scroll re-resolution, so a structural argument is not a proof. | Manual repro AC8 (10×) + ongoing `.ips` monitoring for `_validateScrollingTargetIndexPath` | An always-present last row makes the *common* invalid-index path impossible; if a residual case survives, the `.ips` reports will name the surviving scroll site and we escalate to suppressing auto-scroll during active merges |
| Zero-height anchor row introduces visible spacing or a stray separator | Visual inspection on iOS device + macOS | `EdgeInsets()` + `.frame(height: 0)` + `.listRowSeparator(.hidden)` |
| `scrollTo(anchor, .bottom)` does not land flush at the newest message | Manual launch-and-open test (AC8) | Anchor is the last row; `.bottom` aligns it to the viewport bottom, placing the last message just above — verified manually |
| macOS (`NSCollectionView`) behaves differently from iOS (`UICollectionView`) for the shared view | `make build-mac` + manual check on the Mac app | Same fix applies (both raise on invalid index paths); macOS is exercised manually since the crash report originated on iOS |
| Coalescing drops the final needed scroll | AC4 unit test + manual test that the view ends pinned to bottom | The newest generation always equals `scrollGeneration`, so exactly one scroll fires |
| Regression in existing auto-scroll behavior (toggle button, unread counter) | `AutoScrollTests` suite (AC6) | Behavior preserved; only the *target* and *coalescing* change |
| A future edit reintroduces `scrollTo(message.id)` | Code review + AC1 grep convention | Single `bottomAnchorID` constant; document the invariant inline |

**Rollback strategy:** the change is confined to `ConversationView.swift` plus one new helper type. Reverting the commit restores the prior behavior with no schema, protocol, or persisted-state implications (no migration to undo). Blast radius is a single view.

**Detection in the field:** continue to monitor crash reports (`.ips`) for `_validateScrollingTargetIndexPath`; a recurrence after this ships indicates a missed scroll site. The debounced scroll logs its generation, so the in-app log (`LogManager`, category `ConversationView`) shows which scroll actually fired.
