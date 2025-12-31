# WorkStream and Provider Session Refactor

## Overview

### Problem Statement

The iOS frontend has inconsistent naming for session identifiers, mixing concepts of "iOS session" and "backend/Claude session." The current naming (`backendName`, `sessionId`, `iosSessionId`, `claudeSessionId`) is confusing and conflates two distinct concepts:

1. **Work Stream** - The user's conversation container, persisting across provider sessions
2. **Provider Session** - The backend AI session (Claude, Cursor, etc.) that may be replaced/compacted

Additionally, the codebase uses `backendName` as both a display name and a UUID string depending on context, creating ambiguity.

### Goals

1. Establish consistent naming convention across the iOS codebase
2. Clearly separate work stream identity from provider session identity
3. Support future multi-provider scenarios (Claude, Cursor, Copilot, etc.)
4. Enable rollback-safe evolutionary migration
5. Prepare for work stream ID ≠ provider session ID (they will diverge again)

### Non-goals

- Changing the WebSocket protocol (backend changes are out of scope)
- Adding 1:N relationship between work streams and provider sessions (defer until needed)
- Renaming Core Data entities in this phase (too risky for rollback)
- Modifying backend Clojure code

## Background & Context

### Current State

#### Core Data Model

```
CDBackendSession (ephemeral, synced from backend)
├── id: UUID                    ← shared key with CDUserSession
├── backendName: String         ← INCONSISTENT: sometimes display name, sometimes UUID
├── workingDirectory: String
├── messages: [CDMessage]       ← 1:N relationship
├── isLocallyCreated: Bool
├── lastModified: Date
├── messageCount: Int32
├── preview: String
├── unreadCount: Int32
└── (queue/priority fields)

CDUserSession (persistent, user customizations)
├── id: UUID                    ← shared key (implicit join, no Core Data relationship)
├── customName: String?
├── isUserDeleted: Bool
└── createdAt: Date

CDMessage
├── id: UUID
├── sessionId: UUID             ← FK to CDBackendSession.id (rename to workStreamId in Phase 5)
├── session: CDBackendSession   ← Core Data relationship
├── role: String
├── text: String
└── timestamp: Date
```

**Note on CDMessage.sessionId:** This property references `CDBackendSession.id` and semantically represents the work stream ID. Renaming it to `workStreamId` is deferred to Phase 5 (entity rename phase) to minimize breaking changes. During Phases 1-4, the property name remains `sessionId` but conceptually represents the work stream.

#### Naming Inconsistencies

| Current Usage | Type | Context |
|---------------|------|---------|
| `session.id` | `UUID` | Core Data property |
| `sessionId` | `String` or `UUID` | Parameter names (inconsistent types) |
| `sessionID` | `String` | Rare variant |
| `session_id` | `String` | JSON/WebSocket |
| `iosSessionId` | `String` | VoiceCodeClient.sendPrompt parameter |
| `backendName` | `String` | Display name OR UUID string |

#### Usage of `backendName`

Evidence shows `backendName` is used inconsistently:

**As display name (original intent):**
```swift
session.backendName = "Terminal: voice-code - 2025-10-17 14:30"
```

**As UUID string (current unified model):**
```swift
session.backendName = sessionId.uuidString.lowercased()
```

### Why Now

The codebase is preparing for:
1. Work stream ID and provider session ID to diverge again
2. Multi-provider support (not just Claude)
3. Cleaner abstraction for session management

### Related Work

- @STANDARDS.md - Naming conventions (snake_case JSON, kebab-case Clojure, camelCase Swift)
- @ios-navigation-architecture.md - Navigation patterns

## Detailed Design

### Naming Convention

#### Core Concepts

| Concept | Swift (camelCase) | JSON (snake_case) | Type | Description |
|---------|-------------------|-------------------|------|-------------|
| iOS conversation container | `workStreamId` | `work_stream_id` | `UUID` | Persists across provider sessions |
| Backend AI session | `providerSessionId` | `provider_session_id` | `String` | May be replaced/compacted |
| AI provider type | `provider` | `provider` | `String` | "claude", "cursor", etc. |

#### Naming Rules

1. **`workStreamId`** - Always `UUID` type, represents the iOS-side conversation
2. **`providerSessionId`** - Always `String` type (UUID format), represents the backend session
3. **`provider`** - Always `String`, lowercase provider name
4. **`name`** - Display name (user-set or inferred), never an ID

### Data Model Changes

#### Phase 1: Add New Properties (Non-Breaking)

Add optional properties to `CDBackendSession`:

```swift
// CDBackendSession.swift - additions
@objc(CDBackendSession)
public class CDBackendSession: NSManagedObject {
    // Existing (unchanged)
    @NSManaged public var id: UUID
    @NSManaged public var backendName: String
    // ... other existing properties

    // New properties (optional for migration safety)
    @NSManaged public var providerSessionId: String?
    @NSManaged public var provider: String?
}
```

Core Data model version (VoiceCode 3.xcdatamodel):
```xml
<entity name="CDBackendSession" ...>
    <!-- Existing attributes unchanged -->
    <attribute name="id" attributeType="UUID" .../>
    <attribute name="backendName" attributeType="String"/>
    <!-- ... -->

    <!-- New attributes -->
    <attribute name="providerSessionId" optional="YES" attributeType="String"/>
    <attribute name="provider" optional="YES" attributeType="String" defaultValueString="claude"/>
</entity>
```

#### Computed Properties for Compatibility

```swift
extension CDBackendSession {
    /// Work stream ID - the iOS conversation identifier
    /// This is the primary key, renamed for clarity
    var workStreamId: UUID {
        return id
    }

    /// Effective provider session ID with fallback
    /// During migration: falls back to workStreamId if not set
    var effectiveProviderSessionId: String {
        providerSessionId ?? id.uuidString.lowercased()
    }

    /// Effective provider with fallback
    var effectiveProvider: String {
        provider ?? "claude"
    }

    /// Effective name for display - excludes UUID-formatted strings
    /// Note: This complements the existing displayName(context:) method.
    /// The existing method checks CDUserSession for custom names first.
    /// This helper determines if backendName contains a valid display name.
    var hasValidDisplayName: Bool {
        // If backendName is a UUID string, it's not a valid display name
        return UUID(uuidString: backendName) == nil && !backendName.isEmpty
    }
}
```

**Note:** The existing `displayName(context:)` method already handles user customizations via CDUserSession lookup. The new `hasValidDisplayName` computed property helps identify whether `backendName` contains an actual name vs. a UUID string, which can be used to decide whether to show a placeholder.

### Migration Strategy

#### Phase Shipping Recommendations

| Phase | Can Ship Together | Minimum Viable Release |
|-------|-------------------|------------------------|
| Phase 1 (Add properties) | Yes, with 2-4 | **Required first** |
| Phase 2 (Dual-write) | Yes, with 1, 3-4 | Recommended with 1 |
| Phase 3 (Dual-read) | Yes, with 1-2, 4 | Recommended with 1-2 |
| Phase 4 (Background migration) | Yes, with 1-3 | Recommended with 1-3 |
| Phase 5 (Entity rename) | **No, separate release** | Future, after validation |

**Recommended approach:** Ship Phases 1-4 together in a single release. This ensures:
- New properties exist before any code tries to write to them
- All read/write paths are updated atomically
- Background migration runs on first launch after update

**Phase 5 must be a separate release** after Phases 1-4 are validated in production for at least 2-4 weeks.

#### Phase 1: Add New Properties (Ship First)

1. Create new Core Data model version with optional properties
2. Add lightweight migration mapping
3. Deploy - old data continues working, new fields are nil

**Rollback safe:** Old app version ignores new fields.

#### Phase 2: Dual-Write

Update all write paths to populate both old and new properties:

```swift
// When creating/updating sessions
session.backendName = name                           // old (keep writing)
session.providerSessionId = providerSessionId        // new
session.provider = "claude"                          // new
```

**Rollback safe:** Old app reads `backendName`, ignores new fields.

#### Phase 3: Dual-Read with Fallback

Use computed properties that prefer new fields, fall back to old:

```swift
// Reading provider session ID
let sessionId = session.effectiveProviderSessionId  // prefers new, falls back to old
```

**Rollback safe:** Computed properties don't affect storage.

#### Phase 4: Background Data Migration

Populate new fields from old for existing data:

```swift
/// WorkStreamMigration.swift
/// Handles migration of session data to new schema

import Foundation
import CoreData

enum WorkStreamMigration {
    /// Migrates existing sessions to populate providerSessionId and provider fields.
    /// Safe to call multiple times (idempotent).
    static func migrateToNewSchema(context: NSManagedObjectContext) {
        let request = CDBackendSession.fetchRequest()
        guard let sessions = try? context.fetch(request) else {
            return
        }

        var migratedCount = 0
        for session in sessions {
            if session.providerSessionId == nil {
                // Current unified model: workStreamId == providerSessionId
                session.providerSessionId = session.id.uuidString.lowercased()
                session.provider = "claude"
                migratedCount += 1
            }
        }

        if migratedCount > 0 {
            do {
                try context.save()
                print("WorkStreamMigration: Migrated \(migratedCount) sessions")
            } catch {
                print("WorkStreamMigration: Failed to save - \(error)")
            }
        }
    }
}
```

**Migration Trigger:** Call from `PersistenceController.init()` after container setup:

```swift
// In PersistenceController.swift
init(inMemory: Bool = false) {
    container = NSPersistentContainer(name: "VoiceCode")
    // ... existing container configuration ...

    container.loadPersistentStores { description, error in
        // ... existing error handling ...

        // Run data migration on background context
        self.performBackgroundTask { context in
            WorkStreamMigration.migrateToNewSchema(context: context)
        }
    }
}
```

**Rollback safe:** Just populates nullable fields. Old app versions ignore these fields.

#### Phase 5: Entity Rename (Future, Breaking)

Only after Phases 1-4 are stable in production:

1. Rename `CDBackendSession` → `CDWorkStream`
2. Rename `backendName` → `name`
3. Make `providerSessionId` and `provider` non-optional
4. Remove fallback logic

**NOT rollback safe** - requires careful coordination.

### API Signature Updates

#### VoiceCodeClient

```swift
// Before
func subscribe(sessionId: String)
func unsubscribe(sessionId: String)
func sendPrompt(_ text: String, iosSessionId: String, sessionId: String?, ...)
func compactSession(sessionId: String)
func killSession(sessionId: String)

// After (Phase 2+)
func subscribe(workStreamId: UUID)
func unsubscribe(workStreamId: UUID)
func sendPrompt(_ text: String, workStreamId: UUID, providerSessionId: String?, ...)
func compactSession(providerSessionId: String)
func killSession(providerSessionId: String)
```

Note: Internal implementation still sends snake_case to WebSocket (`session_id`), but Swift API uses new naming.

#### SessionSyncManager

```swift
// Before
func handleSessionHistory(sessionId: String, messages: [[String: Any]])
func createOptimisticMessage(sessionId: UUID, text: String, ...)
func handleSessionUpdated(sessionId: String, messages: [[String: Any]])

// After
func handleSessionHistory(workStreamId: UUID, messages: [[String: Any]])
func createOptimisticMessage(workStreamId: UUID, text: String, ...)
func handleSessionUpdated(workStreamId: UUID, messages: [[String: Any]])
```

### Code Examples

#### Creating a New Work Stream

```swift
func createWorkStream(in directory: String, context: NSManagedObjectContext) -> CDBackendSession {
    let workStreamId = UUID()

    let session = CDBackendSession(context: context)
    session.id = workStreamId
    session.workingDirectory = directory
    session.lastModified = Date()
    session.isLocallyCreated = true

    // Dual-write: old and new properties
    session.backendName = ""  // No name yet (not a UUID!)
    session.providerSessionId = workStreamId.uuidString.lowercased()
    session.provider = "claude"

    return session
}
```

#### Sending a Prompt

```swift
func sendMessage(to session: CDBackendSession, text: String) {
    let workStreamId = session.workStreamId
    let providerSessionId = session.effectiveProviderSessionId

    // Optimistic UI update
    client.sessionSyncManager.createOptimisticMessage(
        workStreamId: workStreamId,
        text: text
    ) { messageId in
        // Build WebSocket message (still uses snake_case for protocol)
        var message: [String: Any] = [
            "type": "prompt",
            "text": text
        ]

        if session.isLocallyCreated {
            message["new_session_id"] = providerSessionId
        } else {
            message["resume_session_id"] = providerSessionId
        }

        client.send(message)
    }
}
```

#### Handling Session Lock

```swift
// Before: confusing mix of ID types
client.lockedSessions.insert(sessionId)  // What type? String? Which ID?

// After: explicit types
client.lockedProviderSessions.insert(providerSessionId)  // String, provider's session
```

### Component Interactions

#### Work Stream Lifecycle

```
┌─────────────────────────────────────────────────────────────────┐
│ iOS App                                                         │
│                                                                 │
│  User taps "New Session"                                        │
│         │                                                       │
│         ▼                                                       │
│  ┌─────────────────────┐                                        │
│  │ Create CDBackendSession                                      │
│  │ - id = new UUID (workStreamId)                               │
│  │ - providerSessionId = workStreamId.lowercased()              │
│  │ - provider = "claude"                                        │
│  │ - isLocallyCreated = true                                    │
│  └─────────┬───────────┘                                        │
│            │                                                    │
│  User sends first prompt                                        │
│            │                                                    │
│            ▼                                                    │
│  ┌─────────────────────┐      WebSocket        ┌──────────────┐ │
│  │ sendPrompt(         │ ──────────────────▶   │ Backend      │ │
│  │   workStreamId,     │   new_session_id      │              │ │
│  │   providerSessionId │                       │ Creates      │ │
│  │ )                   │                       │ .jsonl file  │ │
│  └─────────────────────┘                       └──────────────┘ │
│                                                                 │
│  Session now exists on backend                                  │
│  isLocallyCreated = false                                       │
│                                                                 │
│  Subsequent prompts use resume_session_id                       │
└─────────────────────────────────────────────────────────────────┘
```

#### Future: Provider Session Divergence

```
┌─────────────────────────────────────────────────────────────────┐
│ Work Stream (id: abc-123)                                       │
│ ├── providerSessionId: "xyz-789"  (current Claude session)      │
│ ├── provider: "claude"                                          │
│ │                                                               │
│ │   After compaction:                                           │
│ │                                                               │
│ ├── providerSessionId: "new-456"  (new Claude session)          │
│ ├── provider: "claude"                                          │
│ │                                                               │
│ │   Work stream ID unchanged, provider session ID changed       │
└─────────────────────────────────────────────────────────────────┘
```

## Verification Strategy

### Testing Approach

#### Unit Tests

1. **Computed property tests**
   - `effectiveProviderSessionId` returns `providerSessionId` when set
   - `effectiveProviderSessionId` falls back to `id.lowercased()` when nil
   - `effectiveProvider` returns `provider` when set
   - `effectiveProvider` falls back to "claude" when nil
   - `hasValidDisplayName` returns `false` for UUID-format `backendName`
   - `hasValidDisplayName` returns `false` for empty `backendName`
   - `hasValidDisplayName` returns `true` for real display names

2. **Migration helper tests**
   - Background migration populates new fields correctly
   - Migration is idempotent (running twice doesn't break data)
   - Migration handles multiple sessions correctly

#### Integration Tests

1. **Session creation flow**
   - New session has correct `providerSessionId` and `provider`
   - Both old and new properties are populated (dual-write)

2. **Session reading flow**
   - Sessions with only old properties work (fallback)
   - Sessions with new properties use new values

3. **WebSocket message formatting**
   - Messages still use `session_id` (snake_case) for protocol
   - Correct ID (providerSessionId) is sent

#### Rollback Tests

1. **Simulate old app version**
   - Create session with new properties
   - Verify old code paths still work (ignore new fields)

### Test Examples

```swift
// WorkStreamMigrationTests.swift

import XCTest
import CoreData
@testable import VoiceCode

final class WorkStreamMigrationTests: XCTestCase {
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

    // MARK: - Helper to create session with all required properties

    private func createSession(
        id: UUID = UUID(),
        backendName: String = "Test Session",
        workingDirectory: String = "/test/path",
        providerSessionId: String? = nil,
        provider: String? = nil
    ) -> CDBackendSession {
        let session = CDBackendSession(context: context)
        session.id = id
        session.backendName = backendName
        session.workingDirectory = workingDirectory
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.isLocallyCreated = false
        session.isInQueue = false
        session.queuePosition = 0
        session.isInPriorityQueue = false
        session.priority = 10
        session.priorityOrder = 0
        session.providerSessionId = providerSessionId
        session.provider = provider
        return session
    }

    // MARK: - Computed Property Tests

    func testEffectiveProviderSessionId_withProviderSessionId() throws {
        let session = createSession(providerSessionId: "explicit-provider-session-id")

        XCTAssertEqual(session.effectiveProviderSessionId, "explicit-provider-session-id")
    }

    func testEffectiveProviderSessionId_withoutProviderSessionId() throws {
        let workStreamId = UUID()
        let session = createSession(id: workStreamId, providerSessionId: nil)

        XCTAssertEqual(session.effectiveProviderSessionId, workStreamId.uuidString.lowercased())
    }

    func testEffectiveProvider_withProvider() throws {
        let session = createSession(provider: "cursor")

        XCTAssertEqual(session.effectiveProvider, "cursor")
    }

    func testEffectiveProvider_withoutProvider() throws {
        let session = createSession(provider: nil)

        XCTAssertEqual(session.effectiveProvider, "claude")
    }

    func testHasValidDisplayName_withUUIDBackendName() throws {
        let session = createSession(backendName: UUID().uuidString.lowercased())

        // UUID string is not a valid display name
        XCTAssertFalse(session.hasValidDisplayName)
    }

    func testHasValidDisplayName_withRealName() throws {
        let session = createSession(backendName: "My Project Session")

        XCTAssertTrue(session.hasValidDisplayName)
    }

    func testHasValidDisplayName_withEmptyName() throws {
        let session = createSession(backendName: "")

        XCTAssertFalse(session.hasValidDisplayName)
    }

    // MARK: - Migration Tests

    func testMigration_populatesNewFields() throws {
        let workStreamId = UUID()
        let session = createSession(
            id: workStreamId,
            backendName: "Old Session",
            providerSessionId: nil,
            provider: nil
        )

        try context.save()

        // Run migration
        WorkStreamMigration.migrateToNewSchema(context: context)

        // Verify new fields populated
        XCTAssertEqual(session.providerSessionId, workStreamId.uuidString.lowercased())
        XCTAssertEqual(session.provider, "claude")
    }

    func testMigration_isIdempotent() throws {
        let session = createSession(
            providerSessionId: "already-set",
            provider: "cursor"
        )

        try context.save()

        // Run migration twice
        WorkStreamMigration.migrateToNewSchema(context: context)
        WorkStreamMigration.migrateToNewSchema(context: context)

        // Original values preserved
        XCTAssertEqual(session.providerSessionId, "already-set")
        XCTAssertEqual(session.provider, "cursor")
    }

    func testMigration_handlesMultipleSessions() throws {
        let session1 = createSession(backendName: "Session 1", providerSessionId: nil)
        let session2 = createSession(backendName: "Session 2", providerSessionId: "existing-id")
        let session3 = createSession(backendName: "Session 3", providerSessionId: nil)

        try context.save()

        WorkStreamMigration.migrateToNewSchema(context: context)

        // Only sessions without providerSessionId should be migrated
        XCTAssertEqual(session1.providerSessionId, session1.id.uuidString.lowercased())
        XCTAssertEqual(session2.providerSessionId, "existing-id")  // Unchanged
        XCTAssertEqual(session3.providerSessionId, session3.id.uuidString.lowercased())
    }
}
```

### Acceptance Criteria

1. New Core Data model version adds `providerSessionId` and `provider` as optional attributes
2. Lightweight migration succeeds from previous model version
3. `effectiveProviderSessionId` returns correct value with and without explicit `providerSessionId`
4. `effectiveProvider` returns "claude" as default when `provider` is nil
5. New sessions are created with both old (`backendName`) and new (`providerSessionId`, `provider`) properties
6. Existing sessions continue to work via fallback logic
7. All existing tests pass without modification
8. App can be rolled back to previous version without data loss
9. `hasValidDisplayName` returns `false` for UUID-formatted `backendName` values
10. Background migration runs on app launch and populates new fields for existing sessions
11. All 5 dual-write locations (listed in Risk 2) are updated to write both old and new properties

## Alternatives Considered

### Alternative 1: Immediate Entity Rename

**Approach**: Rename `CDBackendSession` to `CDWorkStream` and all properties in one change.

**Pros**:
- Clean, single migration
- No dual-write complexity

**Cons**:
- Not rollback safe
- Requires updating all code references simultaneously
- Higher risk of bugs

**Decision**: Rejected. Evolutionary approach is safer for production app.

### Alternative 2: Create New Entity, Deprecate Old

**Approach**: Create `CDWorkStream` as new entity, migrate data, then delete `CDBackendSession`.

**Pros**:
- Clean separation during transition
- Can run both in parallel

**Cons**:
- More complex Core Data model
- Relationship management between old and new entities
- More code to maintain during transition

**Decision**: Rejected. Adding properties to existing entity is simpler.

### Alternative 3: 1:N Relationship Now

**Approach**: Immediately implement `CDWorkStream` 1:N `CDProviderSession` relationship.

**Pros**:
- Future-proof for multi-session scenarios
- Cleaner conceptual model

**Cons**:
- Significant Core Data schema change
- More complex migration
- Not needed for current requirements
- Harder to roll back

**Decision**: Rejected. YAGNI - add complexity when actually needed.

## Risks & Mitigations

### Risk 1: Core Data Migration Failure

**Risk**: Lightweight migration fails on some devices.

**Mitigation**:
- Test migration with various data states
- Add migration error handling with fallback to fresh database
- Monitor crash reports after release

### Risk 2: Inconsistent Dual-Write

**Risk**: Some code paths write to old property but not new.

**Mitigation**:
- Grep for all `backendName =` assignments
- Add unit tests verifying dual-write
- Code review checklist item

**Locations requiring dual-write updates (as of current codebase):**

| File | Line | Current Code | Action Required |
|------|------|--------------|-----------------|
| `Views/DirectoryListView.swift` | 667 | `session.backendName = sessionId.uuidString.lowercased()` | Add `providerSessionId` and `provider` writes |
| `Views/SessionsForDirectoryView.swift` | 241 | `session.backendName = sessionId.uuidString.lowercased()` | Add `providerSessionId` and `provider` writes |
| `Managers/SessionSyncManager.swift` | 319 | `session.backendName = ""` | Add `providerSessionId = nil`, `provider = "claude"` |
| `Managers/SessionSyncManager.swift` | 699 | `session.backendName = name` | Add `providerSessionId` (from backend) and `provider` writes |
| `Managers/PersistenceController.swift` | 20 | Preview data setup | Update for test consistency |

**Search command to verify all locations:**
```bash
grep -rn '\.backendName\s*=' iOS/VoiceCode/
```

### Risk 3: Fallback Logic Bugs

**Risk**: `effectiveProviderSessionId` fallback doesn't work correctly.

**Mitigation**:
- Comprehensive unit tests for computed properties
- Test with both nil and non-nil values
- Manual testing with old/new data

### Risk 4: WebSocket Protocol Confusion

**Risk**: Mixing up Swift naming (workStreamId) with WebSocket naming (session_id).

**Mitigation**:
- Keep WebSocket serialization in one place (VoiceCodeClient)
- Clear comments at boundary points
- Protocol remains unchanged (backend changes are out of scope)

### Rollback Strategy

**Phases 1-4** (adding optional properties, dual-write, fallback read, background migration):

1. Deploy previous app version from TestFlight/App Store
2. New properties are ignored by old code
3. No data migration needed
4. Users continue working normally

**Phase 5** (entity rename - future):

1. This phase requires careful planning
2. May need data export/import mechanism
3. Consider feature flag to control rollout
4. Defer until Phases 1-4 are proven stable
