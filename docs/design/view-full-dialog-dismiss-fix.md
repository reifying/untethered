# View Full Dialog Dismiss Fix

## Overview

### Problem Statement

When a user opens a message via "View Full" and is reading it in the detail sheet, new inbound messages arriving cause the sheet to be dismissed out from under the user. The root cause is that the `.sheet` presentation and its controlling `@State` live on `CDMessageView`—a child of `List`'s `ForEach`. `List` manages cell lifecycle via UICollectionView/NSCollectionView and can recreate or recycle cells when `@FetchRequest` data changes, resetting `@State` and dismissing the sheet.

### Goals

1. Incoming messages must never dismiss the open "View Full" sheet
2. The sheet holds its own captured snapshot of the message, immune to list-level churn
3. Message pruning cannot destroy a message the user is actively reading
4. Streaming messages (status == `.sending`) continue to show live text updates in the sheet
5. Auto-scroll is suppressed while the sheet is open

### Non-goals

- Changing the 50-message pruning window size
- Modifying `List` → `LazyVStack` (performance regression)
- Platform-specific sheet presentation changes (existing `NavigationController` wrapper works as-is)
- Gold-plating auto-scroll re-engagement with gesture detection

## Background & Context

### Current State

The "View Full" flow today:

| Component | Location | Role |
|-----------|----------|------|
| `CDMessageView` | `ConversationView.swift:1164` | Renders one message in the list |
| `@State showFullMessage` | `ConversationView.swift:1169` | Controls sheet presentation |
| `.sheet(isPresented:)` | `ConversationView.swift:1234` | Presents `MessageDetailView` |
| `MessageDetailView` | `ConversationView.swift:1242` | Full message view with actions |

The sheet is owned by `CDMessageView`, which lives inside `ForEach(messages)` inside a `List`. When new messages arrive via `@FetchRequest`, `List` can recycle cells, destroying `@State` and dismissing the sheet.

Secondary dismissal paths:
- **`file_replaced` purge** (SessionSyncManager.swift:730-760): deletes all messages, triggers `isLoading = true`, destroying the entire `List` tree
- **Message pruning** (SessionSyncManager.swift:586-587): when count exceeds 60, oldest messages are deleted—if the viewed message is among them, it's destroyed
- **UUID mutation during upsert** (SessionSyncManager.swift:1032-1033): optimistic "sending" messages can have their UUID changed on confirmation, destroying ForEach identity

### Why Now

Users report the sheet dismissing while reading long assistant responses. The issue is reproducible on both iOS and macOS whenever backend activity delivers new messages to the active session.

### Related Work

- @docs/design/selectable-text-component.md - `SelectableText` used inside `MessageDetailView`
- @docs/design/conversation-refresh-and-prune-fix.md - Pruning mechanics

## Detailed Design

### Data Model

#### `MessageSnapshot` (new struct)

```swift
/// Captured snapshot of a message for stable sheet presentation.
/// Decoupled from CoreData—survives list churn, pruning, and cell recycling.
struct MessageSnapshot: Identifiable {
    /// Fresh UUID per presentation—avoids SwiftUI's same-id no-re-present bug
    /// when the user taps "View Full" on the same message twice.
    let id: UUID
    /// The CoreData message UUID (for analytics and live-text @FetchRequest lookup).
    let messageId: UUID
    let role: String
    let timestamp: Date
    let sessionId: UUID
    let workingDirectory: String?
    let text: String

    init(from message: CDMessage) {
        self.id = UUID()
        self.messageId = message.id
        self.role = message.role
        self.timestamp = message.timestamp
        self.sessionId = message.sessionId
        self.workingDirectory = message.session?.workingDirectory
        self.text = message.text
    }
}
```

Key decisions:
- `id` is a fresh UUID per presentation, not the message UUID. SwiftUI's `.sheet(item:)` won't re-present if the item has the same `id` as the previous presentation. Minting a fresh UUID guarantees re-tapping "View Full" on the same message works.
- `messageId` is the CoreData message UUID, used by `MessageDetailView`'s internal `@FetchRequest` to bind live text for streaming messages.

No CoreData schema changes. No migration needed.

### Code Examples

#### ConversationView Changes

The sheet moves from `CDMessageView` to `ConversationView`. New state:

```swift
struct ConversationView: View {
    // ... existing state ...
    @State private var fullMessageSnapshot: MessageSnapshot?

    var body: some View {
        VStack(spacing: 0) {
            // ... existing pruned-gap banner, stalled-chain banner ...

            ZStack(alignment: .bottomTrailing) {
                // ... existing if/else branches for isLoading, empty, active ...
            }

            Divider()

            // ... input area ...
        }
        // Sheet presented at ConversationView level—immune to List cell recycling
        .sheet(item: $fullMessageSnapshot) { snapshot in
            MessageDetailView(
                snapshot: snapshot,
                voiceOutput: voiceOutput,
                onInferName: handleInferName
            )
        }
        // ... existing modifiers ...
    }
}
```

Auto-scroll suppression in the existing `onChange(of: messages.count)` handler:

```swift
.onChange(of: messages.count) { oldCount, newCount in
    // ... existing isLoading logic ...

    // Auto-scroll to new messages if enabled AND no sheet is open
    guard newCount > oldCount else { return }
    guard fullMessageSnapshot == nil else {
        logger.debug("📨 Skipping auto-scroll (View Full sheet open)")
        return
    }

    if autoScrollEnabled {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard self.autoScrollEnabled,
                  self.fullMessageSnapshot == nil,
                  let lastMessage = self.messages.last else { return }
            proxy.scrollTo(lastMessage.id, anchor: .bottom)
        }
    }
}
```

#### CDMessageView Changes

Drops `@State showFullMessage` and `.sheet`, takes a closure instead:

```swift
struct CDMessageView: View {
    let message: CDMessage
    let voiceOutput: VoiceOutputManager
    let onInferName: (String) -> Void
    let onViewFull: (MessageSnapshot) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // ... existing role indicator ...

            VStack(alignment: .leading, spacing: 4) {
                // ... existing role label, message text ...

                Button(action: {
                    onViewFull(MessageSnapshot(from: message))
                }) {
                    HStack(spacing: 4) {
                        if message.isTruncated {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption2)
                            Text("View Full")
                                .font(.caption)
                        } else {
                            Image(systemName: "ellipsis.circle")
                                .font(.caption2)
                            Text("Actions")
                                .font(.caption)
                        }
                    }
                    .foregroundColor(.blue)
                }

                // ... existing status/timestamp HStack ...
            }
        }
        .padding(12)
        .background(Color(message.role == "user" ? .systemBlue : .systemGreen).opacity(0.1))
        .cornerRadius(12)
        // No .sheet here — lifted to ConversationView
    }
}
```

Usage in ForEach:

```swift
ForEach(messages) { message in
    CDMessageView(
        message: message,
        voiceOutput: voiceOutput,
        onInferName: handleInferName,
        onViewFull: { snapshot in
            fullMessageSnapshot = snapshot
        }
    )
    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    .listRowSeparator(.hidden)
}
```

#### MessageDetailView Changes

Accepts `MessageSnapshot` instead of `CDMessage`. Uses its own `@FetchRequest` to get live text for streaming messages:

```swift
struct MessageDetailView: View {
    let snapshot: MessageSnapshot
    @ObservedObject var voiceOutput: VoiceOutputManager
    let onInferName: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showCopiedConfirmation = false

    /// Live message lookup — always prefer live text (handles streaming updates
    /// and confirmed final text). Falls back to snapshot only if pruned/deleted.
    @FetchRequest private var liveMessages: FetchedResults<CDMessage>

    init(snapshot: MessageSnapshot, voiceOutput: VoiceOutputManager, onInferName: @escaping (String) -> Void) {
        self.snapshot = snapshot
        self.voiceOutput = voiceOutput
        self.onInferName = onInferName
        _liveMessages = FetchRequest(
            fetchRequest: CDMessage.fetchMessage(id: snapshot.messageId),
            animation: nil
        )
    }

    /// Live text when the message still exists in CoreData; snapshot as fallback
    /// when pruned/deleted. Streaming messages update live; confirmed messages
    /// "naturally freeze" because the server stops updating them.
    private var currentText: String {
        liveMessages.first?.text ?? snapshot.text
    }

    var body: some View {
        NavigationController(minWidth: 500, minHeight: 400) {
            messageDetailContent
        }
    }

    private var messageDetailContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                SelectableText(text: currentText)
                    .padding()
            }

            Divider()

            HStack(spacing: 20) {
                Button(action: {
                    ClipboardUtility.copy(currentText)
                    ClipboardUtility.triggerSuccessHaptic()
                    withAnimation { showCopiedConfirmation = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { showCopiedConfirmation = false }
                    }
                }) {
                    VStack(spacing: 4) {
                        Image(systemName: showCopiedConfirmation ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(.title2)
                            .foregroundColor(showCopiedConfirmation ? .green : .primary)
                        Text(showCopiedConfirmation ? "Copied!" : "Copy")
                            .font(.caption)
                            .foregroundColor(showCopiedConfirmation ? .green : .primary)
                    }
                }

                Button(action: {
                    if voiceOutput.isSpeaking {
                        voiceOutput.stop()
                    } else {
                        let processedText = TextProcessor.prepareForSpeech(from: currentText)
                        voiceOutput.speak(
                            processedText,
                            workingDirectory: snapshot.workingDirectory,
                            sessionId: snapshot.sessionId
                        )
                    }
                }) {
                    VStack(spacing: 4) {
                        Image(systemName: voiceOutput.isSpeaking ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.title2)
                            .foregroundColor(voiceOutput.isSpeaking ? .red : .primary)
                        Text(voiceOutput.isSpeaking ? "Stop" : "Read Aloud")
                            .font(.caption)
                    }
                }

                Button(action: {
                    onInferName(currentText)
                    dismiss()
                }) {
                    VStack(spacing: 4) {
                        Image(systemName: "sparkles.rectangle.stack")
                            .font(.title2)
                        Text("Infer Name")
                            .font(.caption)
                    }
                }
            }
            .padding()
            .background(Color.systemBackground)
        }
        .navigationTitle("Full Message")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarBuilder.doneButton { dismiss() }
        }
    }
}
```

### Component Interactions

**Message arrival flow (after fix):**

```
WebSocket → handleMessage → SessionSyncManager.upsertMessage
    → backgroundContext.save()
    → @FetchRequest fires on ConversationView.messages
    → List re-renders, CDMessageView cells may be recycled
    → fullMessageSnapshot on ConversationView is UNAFFECTED (lives above List)
    → .sheet(item:) remains presented
    → MessageDetailView's @FetchRequest updates if the specific message changed
    → User continues reading undisturbed
```

**Auto-scroll suppression:**

```
onChange(messages.count) fires
    → guard fullMessageSnapshot == nil → FAILS (sheet open)
    → auto-scroll skipped
    → user closes sheet
    → autoScrollEnabled remains in its current state (no jump to bottom)
    → next manual toggle of auto-scroll re-engages normally
```

**Streaming message in sheet:**

```
User opens "View Full" on sending message
    → snapshot captured with current (partial) text
    → MessageDetailView's @FetchRequest binds to live CDMessage
    → currentText = liveMessages.first?.text (updates live as message streams)
    → message completes: server stops updating text
    → currentText still reads live.text (now frozen at final value)
    → no source-switch, no regression to partial snapshot text
```

**Pruning while sheet is open:**

```
New messages push count past 60
    → pruneOldMessages deletes oldest messages
    → The viewed message might be among them
    → MessageDetailView's @FetchRequest returns empty → liveMessages.first == nil
    → currentText = snapshot.text (snapshot is a value type, not affected)
    → Sheet remains open with captured content
```

## Verification Strategy

### Testing Approach

#### Unit Tests

1. **`MessageSnapshot` initialization**: verify all fields are captured correctly from a `CDMessage`
2. **`MessageSnapshot` identity**: verify each init mints a fresh `id` (two snapshots from the same message have different `id` values)
3. **`currentText` logic**: verify live-text preference and snapshot fallback when message is deleted

#### Integration Tests (XCTest + CoreData in-memory stack)

4. **Sheet state survives message insertion**: create a `ConversationView` test harness, set `fullMessageSnapshot`, insert new messages into CoreData, verify `fullMessageSnapshot` is unchanged
5. **Pruning does not nil the snapshot**: set `fullMessageSnapshot` referencing a message, trigger pruning that deletes that message, verify snapshot is still present and its text is accessible
6. **Auto-scroll suppressed when sheet open**: simulate `messages.count` change with `fullMessageSnapshot != nil`, verify scroll proxy is not called

#### End-to-End Tests (manual / UI test)

7. Open "View Full" on a message → send a new message from another device → sheet remains open with correct content
8. Open "View Full" on a streaming message → observe text updating live → message completes → text freezes
9. Open "View Full" → wait for 10+ new messages (trigger pruning if near threshold) → sheet remains open
10. Open "View Full" → new messages arrive → background list does NOT scroll → close sheet → list stays where it was
11. Close sheet → tap "View Full" on the same message → sheet re-presents correctly

### Test Examples

```swift
import XCTest
import CoreData
@testable import VoiceCode

final class MessageSnapshotTests: XCTestCase {
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!

    override func setUpWithError() throws {
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
    }

    override func tearDownWithError() throws {
        persistenceController = nil
        context = nil
    }

    private func makeMessage(text: String, role: String = "assistant") -> CDMessage {
        let msg = CDMessage(context: context)
        msg.id = UUID()
        msg.sessionId = UUID()
        msg.role = role
        msg.text = text
        msg.timestamp = Date()
        msg.messageStatus = .confirmed
        return msg
    }

    func testSnapshotCapturesAllFields() {
        let message = makeMessage(text: "Hello world")

        let snapshot = MessageSnapshot(from: message)

        XCTAssertEqual(snapshot.messageId, message.id)
        XCTAssertEqual(snapshot.role, message.role)
        XCTAssertEqual(snapshot.text, message.text)
        XCTAssertEqual(snapshot.timestamp, message.timestamp)
        XCTAssertEqual(snapshot.sessionId, message.sessionId)
    }

    func testSnapshotMintsUniqueId() {
        let message = makeMessage(text: "test", role: "user")

        let snapshot1 = MessageSnapshot(from: message)
        let snapshot2 = MessageSnapshot(from: message)

        XCTAssertNotEqual(snapshot1.id, snapshot2.id)
        XCTAssertEqual(snapshot1.messageId, snapshot2.messageId)
    }

    func testSnapshotTextIsValueCopy() {
        let message = makeMessage(text: "original text")

        let snapshot = MessageSnapshot(from: message)
        message.text = "modified text"

        XCTAssertEqual(snapshot.text, "original text")
    }
}
```

### Acceptance Criteria

1. Opening "View Full" and receiving new inbound messages does NOT dismiss the sheet (iOS and macOS)
2. The sheet displays the correct message text after the underlying CDMessage is pruned from CoreData
3. Streaming messages (status == `.sending`) show live text updates in the sheet without dismissing
4. Once a streaming message completes (status == `.confirmed`), the sheet text freezes at the final value
5. Tapping "View Full" on the same message twice (close then re-open) presents the sheet both times
6. Auto-scroll does not fire while the sheet is open
7. Closing the sheet does not trigger a jump-to-bottom scroll
8. Copy, Read Aloud, and Infer Name actions all use the freshest available text
9. No regressions: "View Full" still works for truncated messages, "Actions" still works for non-truncated messages
10. Works identically on iOS and macOS (no platform-specific behavioral differences)

## Alternatives Considered

### A. Keep `.sheet` on CDMessageView, use `@StateObject` wrapper

Store `showFullMessage` in a `@StateObject` (class-based) tied to the message UUID, so `List` cell recycling doesn't reset it.

**Rejected**: Solves the @State reset but doesn't solve pruning (the CDMessage object still gets deleted). Also adds object lifecycle complexity. The snapshot approach is simpler and solves both problems.

### B. Replace `List` with `LazyVStack` in `ScrollView`

`LazyVStack` doesn't recycle cells the same way, so `@State` would be preserved.

**Rejected**: The comment at ConversationView.swift:173 notes `List` was chosen for "native cell reuse and 10x better performance." Reverting to `LazyVStack` would regress scroll performance for long conversations. The bug should be fixed without sacrificing the performance win.

### C. Present sheet from a stable overlay above the `List`

Use a `ZStack` overlay that renders `MessageDetailView` as a custom full-screen view rather than a system sheet.

**Rejected**: Loses system sheet behavior (drag to dismiss, accessibility, platform conventions). The `.sheet(item:)` approach on ConversationView gets the same stability without reimplementing sheet mechanics.

### D. Suppress `@FetchRequest` updates while sheet is open

Pause the fetch request or ignore CoreData notifications while the sheet is presented.

**Rejected**: Would prevent the user from seeing new messages appear in the background list (visible on iPad/macOS split view). The fix should be scoped to the sheet, not throttle the entire data flow.

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| `@FetchRequest` inside `MessageDetailView` fires excessively on unrelated CoreData changes | Low | Performance degradation in sheet | Fetch is `fetchLimit: 1` with a UUID predicate—very cheap. Monitor with `RenderTracker`. |
| Snapshot text shown after pruning diverges from final message text (live text unavailable once CDMessage is deleted) | Very low | User sees text from open-time rather than final server state | Acceptable: only occurs after pruning deletes the message; user can close and re-open to get fresh snapshot. |
| `onViewFull` closure on `CDMessageView` captures stale state | Low | Snapshot has wrong workingDirectory or text | Closure executes at tap time, reading fresh values from the `CDMessage`. No stale capture. |
| Auto-scroll suppression stays active after sheet dismissed (state bug) | Low | User loses auto-scroll | Guard uses `fullMessageSnapshot == nil`; SwiftUI nils it on sheet dismiss. No manual cleanup needed. |

**Rollback strategy**: Revert the commit. The change is purely client-side (no backend/protocol changes) and confined to `ConversationView.swift` + new `MessageSnapshot.swift`. No data migration.
