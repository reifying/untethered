# WebSocket Connection & Reconnection Fix

## Overview

### Problem Statement

The macOS desktop client frequently shows "disconnected" status and fails to recover automatically. Specific symptoms include:

1. **Initial connection failure**: After entering settings for the first time, users must exit and re-open the app before the connection works
2. **Reconnection failures**: After a connection drops, the reconnection timer fires but fails to establish a new connection
3. **Stuck state**: The UI shows "disconnected" but manual interaction is required to recover

### Goals

1. Fix the reconnection logic so dropped connections automatically recover
2. Ensure first-time setup in Settings completes the connection properly
3. Maintain backward compatibility with existing iOS client behavior
4. Add instrumentation to diagnose connection issues in the field

### Non-goals

- Server-side keepalive implementation (separate enhancement)
- Changes to the authentication protocol
- WebSocket protocol changes

## Background & Context

### Current State

#### iOS/macOS Client Connection Flow

```
App Launch
    │
    ▼
connect()
    │
    ├─── Guard: if webSocket != nil { return }  ← BUG: blocks reconnection
    │
    ▼
Create URLSessionWebSocketTask
    │
    ▼
webSocket.resume()
    │
    ▼
Set isConnected = true  ← BUG: premature, before hello received
    │
    ▼
receiveMessage() starts message pump
    │
    ▼
setupReconnection() creates timer
```

#### Reconnection Timer Flow

```
Timer fires (repeating at delay interval)
    │
    ▼
Check: if !isConnected
    │
    ├─── Yes: increment attempts, call connect()
    │         │
    │         └─── Guard: if webSocket != nil { return }  ← STUCK HERE
    │
    └─── No: continue waiting
```

#### Failure Detection Flow

```
receiveMessage() gets .failure(error)
    │
    ▼
Set isConnected = false
    │
    ▼
Clear lockedSessions
    │
    ▼
(webSocket reference NOT cleared)  ← ROOT CAUSE
    │
    ▼
Timer fires, calls connect()
    │
    ▼
Guard: webSocket != nil → TRUE → return early
    │
    ▼
STUCK: No new connection created
```

### Why Now

macOS desktop client users report persistent disconnection issues that significantly impact usability. The reconnection logic that works on iOS (where app lifecycle more aggressively cleans up resources) fails on macOS where apps run longer and network transitions are more common.

### Related Work

- @STANDARDS.md - WebSocket protocol documentation
- @docs/design/delta-sync-session-history.md - Related reconnection handling for delta sync

## Detailed Design

### Root Cause Analysis

The core bug is in `VoiceCodeClient.swift`:

**Problem 1: WebSocket reference not cleared on failure**

```swift
// VoiceCodeClient.swift, receiveMessage() failure handler (~line 413)
case .failure(let error):
    DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        self.isConnected = false
        // BUG: webSocket still points to dead URLSessionWebSocketTask
        // No cleanup of webSocket reference
    }
```

**Problem 2: Guard prevents reconnection**

```swift
// VoiceCodeClient.swift, connect() (~line 254)
func connect(sessionId: String? = nil) {
    // This guard blocks reconnection when webSocket points to dead task
    if webSocket != nil {
        logger.debug("WebSocket already exists, skipping")
        return  // ← Reconnection blocked here
    }
    // ... rest of connection logic never reached
}
```

**Problem 3: Premature isConnected = true**

```swift
// VoiceCodeClient.swift, connect() (~line 280)
DispatchQueue.main.async { [weak self] in
    self.isConnected = true  // Set BEFORE hello received
    self.currentError = nil
}
```

### Code Changes

#### Fix 1: Clear WebSocket on Failure

**File:** `ios/VoiceCode/Managers/VoiceCodeClient.swift`

```swift
// BEFORE (lines 413-424):
case .failure(let error):
    DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        logger.debug("🔄 VoiceCodeClient updating: isConnected=false (failure)")
        self.isConnected = false
        self.scheduleUpdate(key: "currentError", value: error.localizedDescription as String?)
        self.scheduleUpdate(key: "lockedSessions", value: Set<String>())
        self.flushPendingUpdates()
        print("🔓 [VoiceCodeClient] Cleared all locked sessions on connection failure")
    }

// AFTER:
case .failure(let error):
    // Clear WebSocket reference inside main queue to ensure thread safety
    // Both connect() and this failure handler must access webSocket on main thread
    DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }

        // Clear WebSocket reference to enable reconnection
        self.webSocket?.cancel(with: .goingAway, reason: nil)
        self.webSocket = nil

        logger.debug("🔄 VoiceCodeClient updating: isConnected=false (failure)")
        self.isConnected = false
        self.scheduleUpdate(key: "currentError", value: error.localizedDescription as String?)
        self.scheduleUpdate(key: "lockedSessions", value: Set<String>())
        self.flushPendingUpdates()
        print("🔓 [VoiceCodeClient] Cleared WebSocket and locked sessions on connection failure")
    }
```

**Thread Safety Note:** The `webSocket` property must be accessed from the main thread. The `receiveMessage()` completion handler runs on URLSession's delegate queue, so we move all `webSocket` access inside `DispatchQueue.main.async`. This ensures both `connect()` (which runs on main thread) and the failure handler access `webSocket` on the same thread.

#### Fix 2: Improve connect() Guard Logic

**File:** `ios/VoiceCode/Managers/VoiceCodeClient.swift`

```swift
// BEFORE (lines 254-286):
func connect(sessionId: String? = nil) {
    if webSocket != nil {
        logger.debug("🔄 [VoiceCodeClient] connect() called but WebSocket already exists, skipping")
        return
    }
    // ... rest of connect logic

// AFTER:
func connect(sessionId: String? = nil) {
    // If we have an existing WebSocket, check if it's still valid
    if let existingSocket = webSocket {
        // Check the task state - if it's not running, clean it up
        switch existingSocket.state {
        case .running:
            logger.debug("🔄 [VoiceCodeClient] connect() called but WebSocket is running, skipping")
            return
        case .suspended:
            logger.info("🔄 [VoiceCodeClient] Cleaning up suspended WebSocket")
            existingSocket.cancel(with: .goingAway, reason: nil)
            webSocket = nil
        case .canceling:
            logger.info("🔄 [VoiceCodeClient] Cleaning up canceling WebSocket")
            existingSocket.cancel(with: .goingAway, reason: nil)
            webSocket = nil
        case .completed:
            logger.info("🔄 [VoiceCodeClient] Cleaning up completed WebSocket")
            existingSocket.cancel(with: .goingAway, reason: nil)
            webSocket = nil
        @unknown default:
            logger.warning("🔄 [VoiceCodeClient] Unknown WebSocket state, cleaning up")
            existingSocket.cancel(with: .goingAway, reason: nil)
            webSocket = nil
        }
    }

    self.sessionId = sessionId
    // ... rest of connect logic unchanged
```

#### Fix 3: Defer isConnected Until Hello Received

**File:** `ios/VoiceCode/Managers/VoiceCodeClient.swift`

```swift
// BEFORE (in connect(), lines 280-285):
DispatchQueue.main.async { [weak self] in
    guard let self = self else { return }
    logger.debug("🔄 VoiceCodeClient updating: isConnected=true")
    self.isConnected = true
    self.currentError = nil
}

// AFTER (in connect()):
// Remove the immediate isConnected = true
// Instead, clear error and log connection attempt
DispatchQueue.main.async { [weak self] in
    guard let self = self else { return }
    logger.debug("🔄 VoiceCodeClient: WebSocket created, awaiting hello")
    self.currentError = nil
    // Note: isConnected will be set true when we receive "hello"
}

// AFTER (in handleMessage(), "hello" case, around line 438):
case "hello":
    // Mark as connected when we receive hello from server
    self.isConnected = true
    print("📡 [VoiceCodeClient] Received hello from server, connection confirmed")

    // Check auth_version for compatibility (future-proofing)
    if let authVersion = json["auth_version"] as? Int {
        // ... existing auth version handling
```

#### Fix 4: Add Connection State Logging

**File:** `ios/VoiceCode/Managers/VoiceCodeClient.swift`

Add detailed logging to diagnose issues in the field:

```swift
// Add a helper to convert URLSessionTask.State to readable string
private func socketStateString(_ state: URLSessionTask.State?) -> String {
    guard let state = state else { return "nil" }
    switch state {
    case .running: return "running"
    case .suspended: return "suspended"
    case .canceling: return "canceling"
    case .completed: return "completed"
    @unknown default: return "unknown(\(state.rawValue))"
    }
}

// Add a computed property for connection state summary
private var connectionStateDescription: String {
    let socketState = socketStateString(webSocket?.state)
    return "socket=\(socketState), connected=\(isConnected), authenticated=\(isAuthenticated), attempts=\(reconnectionAttempts)"
}

// Use in key places:
private func setupReconnection() {
    // ... existing setup code

    timer.setEventHandler { [weak self] in
        guard let self = self else { return }

        logger.info("🔄 Reconnection timer fired: \(self.connectionStateDescription)")

        // ... existing reconnection logic
    }
}
```

This produces actionable log output like:
```
🔄 Reconnection timer fired: socket=completed, connected=false, authenticated=false, attempts=3
```

### Component Interactions

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    Fixed Connection Flow                                 │
└─────────────────────────────────────────────────────────────────────────┘

App / Reconnection Timer
        │
        ▼
    connect()
        │
        ├─── Check webSocket.state
        │         │
        │         ├─── .running → return (already connected)
        │         │
        │         └─── other → clean up, continue
        │
        ▼
    Create URLSessionWebSocketTask
        │
        ▼
    webSocket.resume()
        │
        ▼
    receiveMessage() starts
        │
        ▼
    Receive "hello" message
        │
        ▼
    Set isConnected = true  ← NOW AT CORRECT TIME
        │
        ▼
    sendConnectMessage() with API key
        │
        ▼
    Receive "connected" confirmation
        │
        ▼
    Set isAuthenticated = true


┌─────────────────────────────────────────────────────────────────────────┐
│                    Fixed Failure Recovery                                │
└─────────────────────────────────────────────────────────────────────────┘

receiveMessage() gets .failure
        │
        ▼
    webSocket.cancel()
    webSocket = nil  ← CRITICAL: Clear reference
        │
        ▼
    Set isConnected = false
        │
        ▼
    Timer fires after delay
        │
        ▼
    connect()
        │
        ├─── Check webSocket → nil (cleared!)
        │
        ▼
    Create new URLSessionWebSocketTask
        │
        ▼
    Connection succeeds
```

### Migration Strategy

No migration needed. Changes are purely client-side and backward compatible.

## Verification Strategy

### Testing Approach

#### Unit Tests

1. **WebSocket cleanup on failure**: Verify `webSocket` is nil after receive failure
2. **Connect guard logic**: Verify connect() creates new socket when existing is not running
3. **isConnected timing**: Verify isConnected is false until hello received

#### Integration Tests

1. **Reconnection after network drop**: Simulate network failure, verify automatic recovery
2. **Settings flow**: Enter settings, configure, exit - verify connection established
3. **Multiple reconnection attempts**: Verify exponential backoff and eventual success

#### Manual Tests

1. **macOS network transition**: Switch WiFi networks, verify reconnection
2. **Sleep/wake**: Close laptop lid, open, verify reconnection
3. **Server restart**: Stop backend, start backend, verify client reconnects

### Test Examples

The existing test file (`VoiceCodeClientTests.swift`) tests behavior through public interfaces. Since `webSocket` is private, we test observable behavior rather than internal state.

```swift
// VoiceCodeClientTests.swift

// MARK: - isConnected Timing Tests (Fix 3)

func testIsConnectedFalseAfterConnect() {
    // Given: A fresh client
    let client = VoiceCodeClient(serverURL: testServerURL, setupObservers: false)

    // When: connect() is called (before any server response)
    client.connect()

    // Then: isConnected should still be false (waiting for hello)
    // Note: With Fix 3, isConnected is only set true on receiving "hello"
    XCTAssertFalse(client.isConnected)

    client.disconnect()
}

func testIsConnectedTrueAfterHelloMessage() {
    // Given: A client that has connected
    let client = VoiceCodeClient(serverURL: testServerURL, setupObservers: false)
    client.connect()
    XCTAssertFalse(client.isConnected)

    // When: Hello message is received from server
    // Note: handleMessage is internal for testing
    client.handleMessage("""
        {"type": "hello", "message": "Welcome", "version": "0.2.0", "auth_version": 1}
        """)

    // Then: isConnected should now be true
    XCTAssertTrue(client.isConnected)

    client.disconnect()
}

func testIsConnectedFalseAfterDisconnect() {
    // Given: A connected client
    let client = VoiceCodeClient(serverURL: testServerURL, setupObservers: false)
    client.connect()
    client.handleMessage("""
        {"type": "hello", "message": "Welcome", "version": "0.2.0", "auth_version": 1}
        """)
    XCTAssertTrue(client.isConnected)

    // When: disconnect() is called
    client.disconnect()

    // Then: isConnected should be false
    XCTAssertFalse(client.isConnected)
}

// MARK: - Reconnection Behavior Tests (Fix 1 & 2)

func testMultipleConnectCallsAreSafe() {
    // Given: A client
    let client = VoiceCodeClient(serverURL: testServerURL, setupObservers: false)

    // When: connect() is called multiple times
    client.connect()
    client.connect()  // Should not crash or create duplicate sockets
    client.connect()

    // Then: Client should be in a valid state
    // (Fix 2 ensures second/third calls either skip or clean up)
    client.disconnect()
    XCTAssertFalse(client.isConnected)
}

func testDisconnectThenConnectWorks() {
    // Given: A client that was connected then disconnected
    let client = VoiceCodeClient(serverURL: testServerURL, setupObservers: false)
    client.connect()
    client.handleMessage("""
        {"type": "hello", "message": "Welcome", "version": "0.2.0", "auth_version": 1}
        """)
    XCTAssertTrue(client.isConnected)

    client.disconnect()
    XCTAssertFalse(client.isConnected)

    // When: connect() is called again (simulating reconnection)
    client.connect()

    // Then: Should be able to receive hello again
    // (Fix 1 ensures webSocket is cleared on disconnect, allowing new connection)
    client.handleMessage("""
        {"type": "hello", "message": "Welcome", "version": "0.2.0", "auth_version": 1}
        """)
    XCTAssertTrue(client.isConnected)

    client.disconnect()
}

func testForceReconnectResetsState() {
    // Given: A client with some reconnection attempts
    let client = VoiceCodeClient(serverURL: testServerURL, setupObservers: false)
    client.connect()

    // When: forceReconnect() is called
    client.forceReconnect()

    // Then: Client should reset attempts and be ready to connect
    // (Observable via isConnected becoming false, then true on hello)
    XCTAssertFalse(client.isConnected)

    client.handleMessage("""
        {"type": "hello", "message": "Welcome", "version": "0.2.0", "auth_version": 1}
        """)
    XCTAssertTrue(client.isConnected)

    client.disconnect()
}

// MARK: - Lock Clearing Tests (related to Fix 1)

func testLockedSessionsClearedOnDisconnect() {
    // Given: A client with a locked session
    let client = VoiceCodeClient(serverURL: testServerURL, setupObservers: false)
    client.connect()
    client.handleMessage("""
        {"type": "hello", "message": "Welcome", "version": "0.2.0", "auth_version": 1}
        """)

    // Simulate locked session via session_locked message
    client.handleMessage("""
        {"type": "session_locked", "session_id": "test-session-123", "message": "Session locked"}
        """)
    XCTAssertTrue(client.lockedSessions.contains("test-session-123"))

    // When: disconnect() is called
    client.disconnect()

    // Then: Locked sessions should be cleared
    // (Fix 1 ensures locks are cleared when connection fails/closes)
    XCTAssertTrue(client.lockedSessions.isEmpty)
}
```

**Note on Testing Internal State:** The `webSocket` property is intentionally private. To fully test the state-checking logic in Fix 2, consider:
1. Adding a `@testable` internal property `var webSocketState: URLSessionTask.State?` that exposes just the state
2. Using integration tests with a real/mock server
3. Testing behavior indirectly through connection lifecycle methods

### Acceptance Criteria

1. After a connection failure, the reconnection timer successfully creates a new connection
2. WebSocket reference is nil after any connection failure
3. `isConnected` is false until the server sends a "hello" message
4. Settings flow completes successfully on first attempt (no exit/re-open required)
5. macOS network transitions (WiFi switch, sleep/wake) recover automatically
6. All existing iOS client tests continue to pass
7. Connection state logging provides actionable diagnostics

## Alternatives Considered

### 1. Always Disconnect Before Connect

**Approach:** Unconditionally call `disconnect()` at the start of `connect()`.

```swift
func connect(sessionId: String? = nil) {
    disconnect()  // Always clean up first
    // ... rest of connect logic
}
```

**Pros:**
- Simpler logic, no state checking
- Guarantees clean slate

**Cons:**
- Unnecessary cleanup when already disconnected
- May cancel in-progress connections that would have succeeded
- Disrupts the "guard against duplicate connections" intent

**Decision:** Rejected. The state-checking approach preserves the guard's intent while fixing the bug.

### 2. Use a Connection Lock/Mutex

**Approach:** Add thread synchronization to prevent concurrent connect() calls.

```swift
private let connectLock = NSLock()

func connect(sessionId: String? = nil) {
    connectLock.lock()
    defer { connectLock.unlock() }
    // ... connection logic
}
```

**Pros:**
- Eliminates race conditions
- More robust in edge cases

**Cons:**
- Adds complexity
- Swift's URLSessionWebSocketTask is already main-thread-safe
- Overkill for the actual problem (stuck reference, not race)

**Decision:** Rejected. The root cause is the stale reference, not thread safety.

### 3. Periodic Health Check

**Approach:** Add a health-check ping that detects dead connections proactively.

**Pros:**
- Detects silent failures faster
- Doesn't wait for receive() to fail

**Cons:**
- Adds complexity
- Requires server changes for keepalive
- Not the root cause of the current issue

**Decision:** Deferred. Worth considering as a separate enhancement but doesn't fix the current reconnection bug.

## Risks & Mitigations

### 1. Risk: Premature WebSocket Cleanup

**Risk:** Clearing the WebSocket reference too aggressively could disrupt valid connections.

**Mitigation:** Only clear on actual failure (`.failure` case in receive). The state check in `connect()` preserves running connections.

### 2. Risk: isConnected Timing Change

**Risk:** Changing when `isConnected` becomes true could affect UI that depends on this state.

**Mitigation:** The UI should already handle the connection being in-progress. The "hello" message arrives within milliseconds of connection. Add a "connecting..." state if needed.

### 3. Risk: Platform-Specific Behavior

**Risk:** URLSessionWebSocketTask state behavior may differ between iOS and macOS.

**Mitigation:** Test on both platforms. The state checking is defensive - unknown states trigger cleanup.

### Rollback Strategy

1. Changes are client-only, no backend changes required
2. Revert the three fixes in `VoiceCodeClient.swift` to restore previous behavior
3. Previous behavior is functional on iOS (where app lifecycle provides cleanup)

### Detection

1. Monitor reconnection success rate in logs
2. Track `connectionStateDescription` in crash reports
3. User reports of "stuck disconnected" state
