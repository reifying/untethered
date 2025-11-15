# Queue Feature Design Document

## Overview

The Queue feature adds a FIFO (First-In-First-Out) thread management system to the VoiceCode iOS app. It sits between the "Recent" and "Projects" sections on the homepage, automatically tracking threads where the user has sent messages and is waiting for agent responses.

**Key Principle**: The queue represents threads that need the user's attention. Threads move to the back of the line when the user sends a message, and are hidden while the agent is actively processing.

## User Experience

### Queue Behavior

1. **Automatic Addition**: When a user sends a message (text or voice) in any thread, that thread is automatically added to the end of the queue
2. **FIFO Ordering**: Threads appear in the order they were added - oldest threads at the top, newest at the bottom
3. **Re-queuing**: If a thread is already in the queue and the user sends another message in it, the thread moves to the end of the queue
4. **Hide In-Progress**: Threads where the agent is actively processing (locked sessions) are hidden from the queue display
5. **Manual Removal**: Users can remove threads from the queue via:
   - Swipe-to-delete in the queue list
   - "Remove from Queue" button in the thread detail view
6. **No Limits**: The queue has no size limit - users manage it by manually removing threads
7. **Optional Feature**: Queue can be disabled entirely via Settings toggle

### UI Layout

```
┌─────────────────────────────────────┐
│  Projects (Home Screen)             │
├─────────────────────────────────────┤
│                                     │
│  Recent ▼                           │
│    • Session A (2 hours ago)        │
│    • Session B (1 day ago)          │
│                                     │
│  Queue ▼                     [NEW]  │
│    • Thread X (oldest)              │
│      ← swipe to remove              │
│    • Thread Y                       │
│    • Thread Z (newest)              │
│                                     │
│  Projects ▼                         │
│    • /path/to/project1              │
│    • /path/to/project2              │
│                                     │
└─────────────────────────────────────┘
```

### Thread Detail View

```
┌─────────────────────────────────────┐
│  ← Back    Thread Name    [X] [⋯]   │
│                        [Remove]     │
├─────────────────────────────────────┤
│  Conversation messages...           │
│                                     │
└─────────────────────────────────────┘
```

The "Remove from Queue" button (X with circle) appears in the toolbar when:
- Queue feature is enabled in Settings
- The current thread is in the queue

## Technical Architecture

### Data Model Changes

#### CoreData Schema Migration

Add three new attributes to the `CDSession` entity:

| Attribute | Type | Optional | Default | Description |
|-----------|------|----------|---------|-------------|
| `isInQueue` | Boolean | No | NO | Whether this session is currently in the queue |
| `queuePosition` | Integer 32 | No | 0 | Position in queue (1-based, 0 = not in queue) |
| `queuedAt` | Date | Yes | nil | Timestamp when added to queue |

**Migration Steps**:
1. Create new model version in Xcode (Editor → Add Model Version)
2. Add the three attributes to `CDSession` entity
3. Set new version as current model
4. CoreData will perform lightweight migration automatically

#### CDSession.swift Extensions

```swift
// Add to CDSession.swift
@NSManaged public var isInQueue: Bool
@NSManaged public var queuePosition: Int32
@NSManaged public var queuedAt: Date?

// Computed property for easy queue checking
var isVisibleInQueue: Bool {
    isInQueue && !markedDeleted
}
```

### State Management

#### Queue State (iOS-Only)

All queue state is stored locally in CoreData. No backend synchronization is required.

**Rationale**: The queue represents a user's personal workflow state on a specific device. It's a UI/UX feature for managing attention, not a conversation property that needs to sync across devices.

#### Lock State Integration

The queue must respect session lock state to hide in-progress work:

```swift
// VoiceCodeClient.swift maintains lock state
@Published var lockedSessions = Set<String>()  // Claude session IDs

// Queue filtering logic
var queuedSessions: [CDSession] {
    sessions
        .filter { $0.isInQueue && !$0.markedDeleted }
        .filter { !isSessionLocked($0) }
        .sorted { $0.queuePosition < $1.queuePosition }
}

private func isSessionLocked(_ session: CDSession) -> Bool {
    let claudeSessionId = session.id.uuidString.lowercased()
    return client.lockedSessions.contains(claudeSessionId)
}
```

**Critical Timing**:
- When user sends message: session is immediately locked (optimistically) and added to queue
- Queue display filters out locked sessions, so newly-sent threads won't appear
- When agent finishes (`turn_complete`): lock is released, thread becomes visible in queue
- This ensures queue only shows threads ready for user attention

### Queue Position Management

#### Position Assignment

Queue positions are 1-based integers representing FIFO order:
- Position 1 = oldest (first to be reviewed)
- Position N = newest (last to be reviewed)
- Position 0 = not in queue

When adding a thread to the queue:
```swift
// Find highest current position
let maxPosition = sessions
    .filter { $0.isInQueue }
    .map { $0.queuePosition }
    .max() ?? 0

// Assign next position
session.isInQueue = true
session.queuePosition = maxPosition + 1
session.queuedAt = Date()
```

#### Position Reordering

When removing a thread from the middle of the queue, compact positions to avoid gaps:

```swift
func removeFromQueue(_ session: CDSession) {
    let removedPosition = session.queuePosition

    // Mark as not in queue
    session.isInQueue = false
    session.queuePosition = 0
    session.queuedAt = nil

    // Decrement all higher positions
    let sessionsToReorder = sessions.filter {
        $0.isInQueue && $0.queuePosition > removedPosition
    }

    for s in sessionsToReorder {
        s.queuePosition -= 1
    }

    try? viewContext.save()
}
```

**Example**:
```
Before removal:        After removing position 2:
1. Thread A           1. Thread A
2. Thread B  ← remove 2. Thread C (was 3)
3. Thread C           3. Thread D (was 4)
4. Thread D
```

#### Re-queuing Existing Threads

When user sends another message in a thread already in the queue, move it to the end:

```swift
func addToQueue(_ session: CDSession) {
    if session.isInQueue {
        // Already in queue - move to end
        let currentPosition = session.queuePosition
        let maxPosition = sessions
            .filter { $0.isInQueue }
            .map { $0.queuePosition }
            .max() ?? 0

        // Decrement positions between current and max
        let sessionsToReorder = sessions.filter {
            $0.isInQueue &&
            $0.queuePosition > currentPosition &&
            $0.id != session.id
        }

        for s in sessionsToReorder {
            s.queuePosition -= 1
        }

        // Move to end
        session.queuePosition = maxPosition
        session.queuedAt = Date()
    } else {
        // New to queue - add at end
        let maxPosition = sessions
            .filter { $0.isInQueue }
            .map { $0.queuePosition }
            .max() ?? 0

        session.isInQueue = true
        session.queuePosition = maxPosition + 1
        session.queuedAt = Date()
    }

    try? viewContext.save()
}
```

### Code Changes

#### 1. AppSettings.swift

Add queue enabled toggle:

```swift
@Published var queueEnabled: Bool {
    didSet {
        UserDefaults.standard.set(queueEnabled, forKey: "queueEnabled")
    }
}

// In init()
self.queueEnabled = UserDefaults.standard.object(forKey: "queueEnabled") as? Bool ?? false
```

**Default**: `false` (disabled) - users must opt-in to queue feature

#### 2. SettingsView.swift

Add queue settings section after Recent section (~line 88):

```swift
Section(header: Text("Queue")) {
    Toggle("Enable Queue", isOn: $settings.queueEnabled)

    Text("Show threads in queue on the Projects view. Threads are added when you send a message and removed manually.")
        .font(.caption)
        .foregroundColor(.secondary)
}
```

#### 3. DirectoryListView.swift

Add queue section between Recent and Projects:

```swift
// Add state for collapsible section
@State private var isQueueExpanded = true

// Add computed property for queued sessions
private var queuedSessions: [CDSession] {
    sessions
        .filter { $0.isInQueue && !$0.markedDeleted }
        .filter { !isSessionLocked($0) }
        .sorted { $0.queuePosition < $1.queuePosition }
}

private func isSessionLocked(_ session: CDSession) -> Bool {
    let claudeSessionId = session.id.uuidString.lowercased()
    return client.lockedSessions.contains(claudeSessionId)
}

// In List body, between Recent and Projects sections
if settings.queueEnabled && !queuedSessions.isEmpty {
    Section(isExpanded: $isQueueExpanded) {
        ForEach(queuedSessions) { session in
            NavigationLink(value: session.id) {
                CDSessionRowContent(session: session)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    removeFromQueue(session)
                } label: {
                    Label("Remove", systemImage: "xmark.circle")
                }
            }
        }
    } header: {
        Text("Queue")
    }
}

// Add remove function
private func removeFromQueue(_ session: CDSession) {
    let removedPosition = session.queuePosition
    session.isInQueue = false
    session.queuePosition = 0
    session.queuedAt = nil

    // Reorder remaining queue items
    let sessionsToReorder = sessions.filter {
        $0.isInQueue && $0.queuePosition > removedPosition
    }

    for s in sessionsToReorder {
        s.queuePosition -= 1
    }

    do {
        try viewContext.save()
    } catch {
        print("Error removing from queue: \(error)")
    }
}
```

#### 4. ConversationView.swift

Add queue management in message sending and toolbar:

```swift
// In sendPromptText() function, after clearing draft
private func sendPromptText(_ text: String) {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else { return }

    draftManager.clearDraft(sessionID: sessionID)

    // *** ADD TO QUEUE ***
    if settings.queueEnabled {
        addToQueue(session)
    }

    // Existing optimistic locking and message sending code...
}

// Add queue management functions
private func addToQueue(_ session: CDSession) {
    if session.isInQueue {
        // Already in queue - move to end
        let currentPosition = session.queuePosition
        let fetchRequest = CDSession.fetchActiveSessions()
        fetchRequest.predicate = NSPredicate(format: "isInQueue == YES")
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CDSession.queuePosition, ascending: false)]
        fetchRequest.fetchLimit = 1

        guard let maxPosition = (try? viewContext.fetch(fetchRequest).first?.queuePosition) else { return }

        // Decrement positions between current and max
        let reorderRequest = CDSession.fetchActiveSessions()
        reorderRequest.predicate = NSPredicate(
            format: "isInQueue == YES AND queuePosition > %d AND id != %@",
            currentPosition,
            session.id as CVarArg
        )

        if let sessionsToReorder = try? viewContext.fetch(reorderRequest) {
            for s in sessionsToReorder {
                s.queuePosition -= 1
            }
        }

        session.queuePosition = maxPosition
        session.queuedAt = Date()
    } else {
        // New to queue - add at end
        let fetchRequest = CDSession.fetchActiveSessions()
        fetchRequest.predicate = NSPredicate(format: "isInQueue == YES")
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CDSession.queuePosition, ascending: false)]
        fetchRequest.fetchLimit = 1

        let maxPosition = (try? viewContext.fetch(fetchRequest).first?.queuePosition) ?? 0

        session.isInQueue = true
        session.queuePosition = maxPosition + 1
        session.queuedAt = Date()
    }

    try? viewContext.save()
}

private func removeFromQueue(_ session: CDSession) {
    guard session.isInQueue else { return }

    let removedPosition = session.queuePosition
    session.isInQueue = false
    session.queuePosition = 0
    session.queuedAt = nil

    // Reorder remaining queue items
    let fetchRequest = CDSession.fetchActiveSessions()
    fetchRequest.predicate = NSPredicate(format: "isInQueue == YES AND queuePosition > %d", removedPosition)

    if let sessionsToReorder = try? viewContext.fetch(fetchRequest) {
        for s in sessionsToReorder {
            s.queuePosition -= 1
        }
    }

    try? viewContext.save()
}

// In toolbar, add remove button after existing buttons
.toolbar {
    ToolbarItem(placement: .navigationBarTrailing) {
        HStack(spacing: 16) {
            // Existing buttons: auto-scroll, compact, refresh, export, rename, copy ID

            // Queue remove button
            if settings.queueEnabled && session.isInQueue {
                Button(action: {
                    removeFromQueue(session)
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.orange)
                }
                .accessibilityLabel("Remove from Queue")
            }
        }
    }
}
```

#### 5. CDSession.swift

Add queue-related properties:

```swift
@NSManaged public var isInQueue: Bool
@NSManaged public var queuePosition: Int32
@NSManaged public var queuedAt: Date?
```

## Edge Cases & Error Handling

### Edge Case: Multiple Devices

**Scenario**: User has VoiceCode running on multiple iOS devices with different queue states.

**Behavior**: Queue state is device-local and does not sync. Each device maintains its own queue.

**Rationale**: The queue represents personal workflow state on a specific device. Cross-device sync would require backend changes and conflict resolution logic, adding complexity for minimal benefit.

### Edge Case: App Restart

**Scenario**: User force-quits app or device restarts while sessions are in queue.

**Behavior**: Queue state persists in CoreData. On app restart, queue is restored exactly as it was.

**Implementation**: No special handling needed - CoreData persistence handles this automatically.

### Edge Case: Backend Session Deletion

**Scenario**: Backend deletes a session that is in the iOS queue (e.g., via `session_deleted` message or session cleanup).

**Behavior**: Session is marked `markedDeleted = true` in CoreData. Queue filtering excludes deleted sessions.

**Implementation**: Existing `markedDeleted` flag prevents deleted sessions from appearing in queue.

### Edge Case: Session Lock Timeout

**Scenario**: Agent processing hangs indefinitely, session remains locked forever.

**Behavior**: User can manually unlock via "Tap to Unlock" button in ConversationView. Queue will show the thread once unlocked.

**Implementation**: Existing manual unlock mechanism handles this. No queue-specific changes needed.

### Edge Case: Concurrent Queue Modifications

**Scenario**: User rapidly sends messages in multiple threads, triggering concurrent queue position updates.

**Behavior**: CoreData serializes saves on the main context. Last save wins.

**Risk**: Low - queue position conflicts are cosmetic (threads might appear in slightly wrong order).

**Mitigation**: All queue operations happen on `viewContext` (main thread), ensuring serial execution.

### Edge Case: Empty Queue

**Scenario**: User removes all threads from queue, leaving it empty.

**Behavior**: Queue section is hidden entirely (same as Recent section when empty).

**Implementation**: `if settings.queueEnabled && !queuedSessions.isEmpty { ... }` condition hides section.

### Edge Case: Queue Disabled Mid-Session

**Scenario**: User disables queue feature in Settings while threads are in queue.

**Behavior**: Queue section is hidden, but `isInQueue` flags remain set in CoreData. If user re-enables queue later, threads reappear.

**Rationale**: Preserving queue state allows users to toggle the feature without losing their workflow state.

**Alternative Considered**: Clear all queue state when disabled. Rejected because users might disable accidentally and lose their queue.

## Testing Strategy

### Unit Tests

1. **Queue Position Management**
   - Test adding first thread to empty queue (position = 1)
   - Test adding multiple threads (positions increment correctly)
   - Test removing thread from middle (positions compact)
   - Test re-queuing existing thread (moves to end)

2. **Lock State Filtering**
   - Test locked sessions are hidden from queue
   - Test unlocked sessions appear in queue
   - Test lock/unlock transitions update queue visibility

3. **Settings Integration**
   - Test queue disabled hides section
   - Test queue enabled shows section (when non-empty)
   - Test toggling feature preserves queue state

### Integration Tests

1. **Message Sending Flow**
   - Test sending message adds thread to queue
   - Test sending second message re-queues thread
   - Test queue position updates correctly

2. **Removal Flow**
   - Test swipe-to-delete removes from queue
   - Test toolbar button removes from queue
   - Test position reordering after removal

3. **UI State Synchronization**
   - Test queue updates when lock state changes
   - Test queue persists across app restarts
   - Test queue updates when sessions are deleted

### Manual Testing Scenarios

1. **Normal Workflow**
   - Create 5 threads, send messages in each
   - Verify queue shows threads in FIFO order
   - Verify in-progress threads are hidden
   - Remove threads via swipe and toolbar button
   - Verify positions update correctly

2. **Concurrent Usage**
   - Send messages in multiple threads rapidly
   - Verify queue order is correct
   - Verify no position conflicts

3. **Settings Toggle**
   - Disable queue, verify section hidden
   - Re-enable queue, verify threads reappear
   - Verify no data loss

4. **Edge Cases**
   - Force-quit app with threads in queue
   - Restart app, verify queue restored
   - Delete session from queue
   - Verify queue updates correctly

## Performance Considerations

### CoreData Query Optimization

Queue display requires filtering and sorting all sessions:

```swift
sessions
    .filter { $0.isInQueue && !$0.markedDeleted }
    .filter { !isSessionLocked($0) }
    .sorted { $0.queuePosition < $1.queuePosition }
```

**Optimization**: Add compound index on `(isInQueue, queuePosition)` in CoreData model.

**Expected Load**: Most users will have <100 total sessions, <20 in queue. Performance impact is negligible.

### Lock State Observation

Queue must react to `lockedSessions` changes in real-time to hide/show threads.

**Implementation**: `VoiceCodeClient.lockedSessions` is `@Published`, so SwiftUI automatically recomputes `queuedSessions` when it changes.

**Performance**: Set membership check `O(1)`, negligible overhead.

### Position Reordering Complexity

Removing from middle of queue requires updating all higher positions: `O(n)` where n = queue size.

**Expected Load**: Queue size typically <20 threads. Updating 20 integers is <1ms.

**Optimization**: Batch saves when removing multiple threads, but not needed for MVP.

## Future Enhancements

### Possible Future Features (Out of Scope for MVP)

1. **Custom Queue Ordering**: Allow manual drag-to-reorder threads in queue
2. **Queue Filters**: Filter queue by project/directory
3. **Queue Statistics**: Show total queued threads, estimated time to review
4. **Auto-Remove on View**: Automatically remove from queue when user views thread
5. **Queue Sync**: Sync queue state via backend for multi-device consistency
6. **Queue Notifications**: Notify when queued threads are ready for review
7. **Batch Operations**: Select multiple threads and remove from queue at once
8. **Queue History**: Track when threads were added/removed from queue

### Backward Compatibility

**Migration Path**: Users upgrading from versions without queue feature will have:
- All sessions with `isInQueue = false` (default)
- Empty queue on first launch
- Queue disabled by default in Settings

**Data Loss**: None - existing session data is unaffected.

## Open Questions

1. **Should queue state survive session deletion?**
   - Current design: No - deleted sessions are filtered out
   - Alternative: Keep queue metadata for deleted sessions (for undo?)
   - Decision: Current design is simpler and sufficient

2. **Should we show queue size in section header?**
   - Current design: Just "Queue" header
   - Alternative: "Queue (5)" showing count
   - Decision: Keep simple for MVP, can add count later

3. **Should we add a "Clear Queue" button?**
   - Current design: No bulk removal
   - Alternative: Add "Clear All" button in section header
   - Decision: Keep simple for MVP, users can swipe to remove

4. **Should we persist isQueueExpanded state?**
   - Current design: Defaults to expanded on each app launch
   - Alternative: Save to UserDefaults
   - Decision: Keep simple for MVP, always expanded is fine

## Implementation Checklist

- [ ] Create CoreData model version with queue attributes
- [ ] Add queue properties to CDSession.swift
- [ ] Add `queueEnabled` setting to AppSettings.swift
- [ ] Add queue toggle to SettingsView.swift
- [ ] Add queue section to DirectoryListView.swift
- [ ] Add queue filtering logic (hide locked sessions)
- [ ] Add swipe-to-delete in queue list
- [ ] Add queue management in ConversationView.sendPromptText()
- [ ] Add "Remove from Queue" button in ConversationView toolbar
- [ ] Implement addToQueue() function with re-queuing logic
- [ ] Implement removeFromQueue() function with position compacting
- [ ] Write unit tests for queue position management
- [ ] Write integration tests for message sending flow
- [ ] Write integration tests for removal flow
- [ ] Manual testing of all scenarios
- [ ] Update user documentation (if any exists)

## Success Metrics

How we'll know the feature is working correctly:

1. **Functional Correctness**
   - Threads are added to queue when user sends messages ✓
   - Queue displays threads in FIFO order ✓
   - In-progress threads are hidden from queue ✓
   - Removal (swipe and button) works correctly ✓
   - Queue persists across app restarts ✓

2. **User Experience**
   - Queue section appears between Recent and Projects ✓
   - Swipe gesture feels natural and responsive ✓
   - Settings toggle shows/hides queue immediately ✓
   - No lag or performance issues ✓

3. **Code Quality**
   - No CoreData migration errors ✓
   - No threading issues or race conditions ✓
   - Unit tests pass ✓
   - Integration tests pass ✓
   - No crashes or errors in logs ✓
