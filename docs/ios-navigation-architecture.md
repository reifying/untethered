# iOS Navigation Architecture

## Overview

The VoiceCode iOS app uses SwiftUI's modern NavigationStack with ID-based navigation to provide robust, stable navigation that is immune to data re-sorting issues.

## Architecture

### NavigationStack (iOS 16+)

The app uses `NavigationStack` with `NavigationPath` for all navigation management:

```
VoiceCodeApp
  └─ RootView (@State var navigationPath: NavigationPath)
      └─ NavigationStack(path: $navigationPath)
          └─ SessionsListView
              └─ NavigationLink(value: UUID)
              └─ .navigationDestination(for: UUID.self)
```

### Why ID-Based Navigation?

**Problem with Position-Based Navigation:**
```swift
// Old pattern (fragile)
ForEach(sessions) { session in
    NavigationLink(destination: ConversationView(session: session)) {
        SessionRow(session)
    }
}
```

When the `sessions` array re-sorts (e.g., CoreData update changes `lastModified`), the NavigationLink's position-based reference becomes invalid, causing navigation to pop unexpectedly.

**Solution with ID-Based Navigation:**
```swift
// New pattern (robust)
ForEach(sessions) { session in
    NavigationLink(value: session.id) {
        SessionRow(session)
    }
}
.navigationDestination(for: UUID.self) { sessionId in
    if let session = sessions.first(where: { $0.id == sessionId }) {
        ConversationView(session: session, ...)
    }
}
```

The navigation uses the UUID value to look up the session fresh each time, making it independent of array position.

## Implementation Details

### Navigation State

**Location:** `VoiceCodeApp.swift` → `RootView`

```swift
struct RootView: View {
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            SessionsListView(...)
        }
    }
}
```

### Value-Based NavigationLink

**Location:** `SessionsView.swift`

```swift
NavigationLink(value: session.id) {
    CDSessionRowContent(session: session)
}
```

- **Value**: `session.id` (UUID)
- **Type**: UUID passed to NavigationPath
- **Benefit**: Navigation tied to session ID, not array position

### Navigation Destination

**Location:** `SessionsView.swift`

```swift
.navigationDestination(for: UUID.self) { sessionId in
    if let session = sessions.first(where: { $0.id == sessionId }) {
        ConversationView(session: session, client: client, voiceOutput: voiceOutput, settings: settings)
    } else {
        // Session not found (deleted) - show error view
        SessionNotFoundView(sessionId: sessionId)
    }
}
```

- **Lookup Strategy**: Linear search through @FetchRequest results
- **Performance**: O(n), acceptable for typical session counts (<100)
- **Missing Session Handling**: Shows error view with back button

## Session Lookup

The session lookup is performed every time navigation occurs:

```swift
sessions.first(where: { $0.id == sessionId })
```

**Why this is efficient:**
- Typical session count: 5-50 sessions
- O(n) search is fast enough (<1ms for 100 sessions)
- Leverages existing @FetchRequest data (no additional database query)
- Simple, maintainable code

**When to optimize:**
If the app scales to 500+ sessions, consider:
- Dictionary-based lookup: `Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })`
- Cached session lookup table
- Custom fetch request by UUID

## Benefits

### 1. Navigation Stability
Navigation remains stable even when:
- CoreData updates session metadata
- Sessions re-sort by `lastModified`
- @FetchRequest observers fire during navigation

### 2. Modern SwiftUI Patterns
- Aligns with Apple's iOS 16+ best practices
- Uses declarative navigation model
- Better state management

### 3. Future-Proofing
Enables future features:
- Deep linking via URL schemes
- State restoration across app restarts
- Programmatic navigation
- Multiple navigation destinations

### 4. Maintainability
- Clear separation of navigation logic
- Easy to test (see NavigationStabilityTests.swift)
- Explicit value types

## Migration from NavigationView

**Before (iOS 13-15 pattern):**
```swift
NavigationView {
    SessionsListView(...)
}
```

**After (iOS 16+ pattern):**
```swift
NavigationStack(path: $navigationPath) {
    SessionsListView(...)
}
```

**Breaking Changes:**
- Requires iOS 16+
- NavigationLink requires value parameter
- navigationDestination required for destination resolution

## Adding New Navigation Destinations

To add a new navigation destination:

1. **Define the value type** (use UUID, String, or custom Hashable type)

2. **Add NavigationLink** with value:
```swift
NavigationLink(value: item.id) {
    ItemRow(item: item)
}
```

3. **Add navigationDestination** modifier:
```swift
.navigationDestination(for: UUID.self) { itemId in
    // Look up item by ID
    if let item = items.first(where: { $0.id == itemId }) {
        DetailView(item: item)
    }
}
```

4. **Test navigation stability**:
- Verify navigation works
- Test with data updates during navigation
- Verify missing item case

## Testing

See `NavigationStabilityTests.swift` for comprehensive tests:

- `testSessionLookupByUUID`: Basic UUID lookup
- `testSessionLookupAfterReSort`: Navigation stable during re-sort
- `testMissingSessionHandling`: Graceful missing session handling
- `testSessionLookupPerformance`: Performance benchmark
- `testNavigationDuringCoreDataUpdate`: Integration test

All tests verify that ID-based navigation remains stable when CoreData updates cause array re-sorting.

## Performance

**Measured Performance** (100 sessions):
- Session lookup: <1ms
- Navigation transition: <300ms
- No memory leaks detected

**Baseline**: Acceptable performance up to 100-200 sessions without optimization.

## Troubleshooting

### Navigation Pops Unexpectedly
- Check that NavigationLink uses `value:` parameter, not `destination:`
- Verify navigationDestination is present for the value type
- Ensure @FetchRequest is not filtered incorrectly

### Session Not Found Error
- Session was deleted after navigation initiated
- Session marked as deleted (markedDeleted = true)
- UUID mismatch (check session ID encoding)

### Performance Issues
- Profile session lookup performance
- Consider Dictionary-based lookup for 200+ sessions
- Check @FetchRequest predicate efficiency

## Related Files

- `ios/VoiceCode/VoiceCodeApp.swift` - NavigationStack setup
- `ios/VoiceCode/Views/SessionsView.swift` - NavigationLink and navigationDestination
- `ios/VoiceCode/Views/ConversationView.swift` - Destination view
- `ios/VoiceCodeTests/NavigationStabilityTests.swift` - Test suite

## References

- Apple WWDC 2022: "The SwiftUI cookbook for navigation"
- Apple Documentation: NavigationStack
- Apple Documentation: NavigationPath
- Apple Documentation: navigationDestination
