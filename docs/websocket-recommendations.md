# WebSocket Implementation Recommendations

This document captures findings and recommendations from reviewing our WebSocket implementation against best practices documented in [websocket-best-practices.md](websocket-best-practices.md).

## Executive Summary

**Overall Status:** 9 of 40 best practices fully implemented, 14 partially implemented, 15 not implemented, 2 not applicable.

**Strengths:**
- Robust reconnection with exponential backoff and jitter
- Secure authentication with Keychain storage
- Comprehensive message size handling with server-side truncation
- Delta sync support reduces bandwidth on reconnection
- Clean ping/pong heartbeat implementation

**Critical Gaps (High Priority):**
- No network reachability monitoring (`NWPathMonitor`) - reconnection timer fires blindly
- No clean disconnect on app background - connections die when iOS suspends
- No server heartbeats - can't detect half-open connections from client side
- No background task for in-flight operations before suspension

**Key Recommendations:**
1. Add `NWPathMonitor` for network-aware reconnection (saves battery, better UX)
2. Implement clean disconnect on background with `beginBackgroundTask`
3. Add server-initiated heartbeats for half-open connection detection
4. Complete message acknowledgment system (protocol defined, backend incomplete)

See [Recommended Actions](#recommended-actions) for full prioritized list with implementation phases.

## Summary by Category

| Category | Reviewed | Gaps Found | Recommendations |
|----------|----------|------------|-----------------|
| Connection Management | 3/3 | 1 | 1 |
| Message Delivery | 2/2 | 2 | 2 |
| Authentication | 2/2 | 0 | 0 |
| Mobile-Specific | 3/3 | 8 | 8 |
| Protocol Design | 3/3 | 3 | 3 |
| Detecting Degraded Connections | 3/3 | 16 | 15 |
| Poor Bandwidth Handling | 4/4 | 15 | 11 |
| Intermittent Signal Handling | 4/4 | 16 | 16 |
| App Lifecycle Resilience | 4/4 | 19 | 14 |
| Network Transition Handling | 3/3 | 12 | 12 |
| Server-Side Resilience | 3/3 | 8 | 9 |
| Observability | 3/3 | 16 | 16 |
| Edge Cases | 3/3 | 13 | 11 |

## Findings

### Connection Management

#### 1. Robust reconnection logic (exponential backoff with jitter)
**Status**: Implemented
**Locations**:
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:378-387` - `calculateReconnectionDelay(attempt:)` method
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:389-433` - `setupReconnection()` method
- `ios/VoiceCodeTests/VoiceCodeClientTests.swift:400-435` - Exponential backoff tests
- `ios/VoiceCodeTests/VoiceCodeClientTests.swift:1454-1526` - Jitter distribution tests

**Findings**:
The iOS client implements robust reconnection logic with all recommended features:

1. **Exponential backoff**: Base delay = `min(2^attempt, maxReconnectionDelay)`
   - Attempt 0: 1s, Attempt 1: 2s, Attempt 2: 4s, Attempt 3: 8s, etc.

2. **Jitter**: ±25% random variation applied to base delay
   - Prevents thundering herd when multiple clients reconnect simultaneously
   - Formula: `baseDelay + random(-25%, +25%)`

3. **Maximum delay cap**: 30 seconds (per design spec, line 39)
   - Ensures reasonable worst-case reconnection latency

4. **Backoff reset**: On successful connection (line 558: `reconnectionAttempts = 0`)
   - Also reset on foreground/active (line 141) and forceReconnect (line 353)

5. **Maximum attempts**: 20 attempts (~17 minutes total)
   - After exhausting attempts, shows error message to user (lines 412-420)

6. **Test coverage**: Comprehensive unit tests verify:
   - Exponential growth pattern
   - Jitter distribution (values vary between calls)
   - Minimum 1s delay enforced
   - Cap at 30s base (37.5s max with jitter)

**Gaps**: None identified.

**Recommendations**: None - implementation fully meets best practice.

#### 2. Network transition handling (reachability)
**Status**: Not Implemented
**Locations**:
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:93-131` - `setupLifecycleObservers()` - handles app lifecycle but not network changes
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:389-433` - `setupReconnection()` - timer-based reconnection without reachability awareness

**Findings**:
The iOS client does **not** implement network reachability monitoring. The codebase has no imports of the `Network` framework, no usage of `NWPathMonitor`, and no SCNetworkReachability APIs.

Current behavior:
1. **App lifecycle handling**: The client correctly reconnects on foreground (`willEnterForegroundNotification` on iOS, `didBecomeActiveNotification` on macOS)
2. **Timer-based reconnection**: Uses exponential backoff timer that fires regardless of network state
3. **No proactive reconnection**: When network becomes available after being offline, the client waits for the next timer tick rather than reconnecting immediately
4. **No reachability check**: The reconnection timer continues firing even when the network is unreachable, wasting CPU cycles and battery

What the best practice recommends:
- Listen for reachability/network status changes (NWPathMonitor on iOS)
- Reconnect proactively when network becomes available (immediate, not waiting for timer)
- Don't retry when network is unreachable (pause timer, save battery)

**Gaps**:
1. No `NWPathMonitor` to detect network state changes
2. Reconnection timer fires blindly regardless of network availability
3. No immediate reconnection when network becomes available
4. No pausing of reconnection attempts when network is unreachable

**Recommendations**:
1. Add `NWPathMonitor` to monitor network status changes
2. On network available: immediately attempt reconnection (reset backoff, connect)
3. On network unavailable: pause reconnection timer (stop wasting battery)
4. Track current network status to avoid redundant connection attempts

#### 3. Heartbeats/ping-pong
**Status**: Implemented
**Locations**:
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:35-36` - `pingTimer` property with 30-second interval
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:439-458` - `startPingTimer()` starts after authentication
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:462-466` - `stopPingTimer()` stops on disconnect
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:1115-1118` - `ping()` sends `{"type": "ping"}`
- `backend/src/voice_code/server.clj:handle-message` - Responds with `{"type": "pong"}`

**Findings**:
The iOS client implements heartbeat/ping-pong with all recommended features:

1. **Periodic pings**: 30-second interval (line 36: `pingInterval = 30.0`)
   - Within recommended 30-60 second range
   - Uses `DispatchSourceTimer` for reliable scheduling

2. **Timer lifecycle management**:
   - `startPingTimer()` called after successful authentication (line 597)
   - `stopPingTimer()` called on disconnect (line 329) and connection failure (line 499)
   - Cancels existing timer before creating new one (line 441)

3. **Conditional ping sending**:
   - Only sends if connected AND authenticated (lines 448-452)
   - Prevents unnecessary pings during reconnection

4. **Backend pong response**:
   - Server immediately responds with `{"type": "pong"}` (handle-message case)
   - No authentication required for ping (health check)

5. **iOS URLSessionWebSocketTask built-in ping**:
   - Note: iOS has native ping support, but we use application-level ping for explicit control
   - Application-level ping allows better integration with our auth flow

**Gaps**: None identified.

**Recommendations**: None - implementation fully meets best practice.

### Message Delivery

#### 4. Message acknowledgment system
**Status**: Partial
**Locations**:
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:1280-1287` - `sendMessageAck()` method sends ack for replayed messages
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:599-612` - Handles `replay` message type and sends ack
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:50` - `onReplayReceived` callback for replay messages
- `backend/src/voice_code/server.clj:440-442` - `generate-message-id` function (defined but unused)
- `backend/src/voice_code/server.clj:1380-1382` - `message-ack` handler (logs but takes no action)
- `STANDARDS.md:116-141` - Protocol specification for message acknowledgment
- `ios/VoiceCodeTests/VoiceCodeClientTests.swift:308-355` - Tests for replay handling and ack structure

**Findings**:
The protocol specification in STANDARDS.md defines a complete message acknowledgment system, but the **implementation is incomplete**:

**What's implemented:**
1. **Protocol definition**: STANDARDS.md specifies unique message IDs, buffering, replay on reconnection, and client acks
2. **iOS ack sending**: Client sends `message_ack` when it receives a `replay` message (lines 609-611)
3. **Message ID generation**: Backend has `generate-message-id` function that creates UUIDs
4. **Backend ack handler**: Server handles `message-ack` messages but only logs them (no action taken)

**What's NOT implemented:**
1. **No undelivered message queue**: Backend has no data structure to buffer messages pending acknowledgment
2. **Response messages lack message_id**: `send-to-client!` doesn't include `message_id` field
3. **No replay on reconnection**: Backend doesn't replay unacknowledged messages after client reconnects
4. **No persistence**: Even if buffering existed, it wouldn't survive backend restart
5. **Ack has no effect**: The `message-ack` handler only logs - it doesn't remove messages from any queue

**Best practice requirements:**
- Assign unique IDs to messages requiring delivery confirmation ❌ (IDs generated but not attached)
- Buffer unacknowledged messages for replay on reconnection ❌ (no buffering implemented)
- Client sends `ack` when message is processed ✅ (implemented for replay messages)

**Gaps**:
1. Backend doesn't attach `message_id` to response messages
2. No undelivered message queue/buffer exists
3. No replay of unacknowledged messages on reconnection
4. Ack handler is a no-op (doesn't update any state)

**Recommendations**:
1. **Add undelivered queue per client**: Store messages with IDs until acked
   ```clojure
   ;; In connected-clients atom, add :undelivered-messages map
   {:authenticated true, :undelivered-messages {"msg-id" {...}}}
   ```
2. **Include message_id in responses**: Modify `send-to-client!` to generate and attach message IDs to response types that need acknowledgment
3. **Implement replay on reconnection**: After `connect` succeeds, replay all undelivered messages for that iOS session
4. **Make ack handler remove from queue**: Update `message-ack` handler to remove acknowledged message from undelivered queue

#### 5. Message ordering handling
**Status**: Implemented
**Locations**:
- `STANDARDS.md:443` - Protocol explicitly states "No strict ordering: Messages may be delivered out of order. Timestamps provide ordering hints."
- `ios/VoiceCode/Models/CDMessage.swift:93` - Messages sorted by timestamp ascending for display
- `ios/VoiceCode/Managers/SessionSyncManager.swift:682-690` - Extracts timestamp from messages and stores as serverTimestamp
- `ios/VoiceCode/Models/CDMessage.swift:22` - CDMessage has `serverTimestamp` field for server-assigned timestamps
- `backend/src/voice_code/server.clj:build-session-history-response` - Returns messages in chronological order

**Findings**:
The implementation correctly handles message ordering using timestamps:

1. **Protocol design**: The protocol explicitly tolerates out-of-order delivery (STANDARDS.md:443). This is a deliberate design choice for a system where strict ordering is not required.

2. **Timestamp-based ordering**: Messages include ISO-8601 timestamps from the backend, and iOS sorts messages by timestamp for display:
   - `CDMessage.timestamp` is the primary sort key
   - `CDMessage.serverTimestamp` stores server-assigned timestamp for reconciliation

3. **Server authoritative timestamps**: The backend assigns timestamps when Claude CLI writes messages to .jsonl files. iOS extracts these via `extractTimestamp()` (SessionSyncManager.swift:682-690).

4. **Display ordering**: Messages are always displayed chronologically (oldest first) regardless of arrival order:
   - `CDMessage.fetchMessages()` sorts by timestamp ascending
   - CoreData ensures consistent display ordering

5. **No sequence numbers**: The protocol does not use sequence numbers because:
   - Strict ordering is not a requirement for conversation display
   - Timestamps provide sufficient ordering hints
   - Simpler implementation with lower overhead

**Gaps**: None identified. The protocol explicitly accepts out-of-order delivery and uses timestamps for ordering, which is appropriate for this use case.

**Recommendations**: None - implementation meets the best practice. The decision to tolerate out-of-order delivery with timestamp-based sorting is appropriate for a conversation UI where strict ordering is not critical.

### Authentication

#### 6. Authenticate early in connection lifecycle
**Status**: Implemented
**Locations**:
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:539-554` - `handleMessage()` handles `hello` and immediately calls `sendConnectMessage()`
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:1239-1278` - `sendConnectMessage()` sends API key to backend
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:672-684` - `auth_error` handling sets `requiresReauthentication = true`
- `ios/VoiceCode/Managers/KeychainManager.swift:72-117` - Secure API key storage using iOS Keychain
- `backend/src/voice_code/server.clj:authenticate-connect!` - Validates API key and marks channel authenticated
- `backend/src/voice_code/server.clj:send-auth-error!` - Sends generic auth error and closes connection
- `backend/src/voice_code/server.clj:handle-message` - Enforces auth check for all message types except `ping`

**Findings**:
The implementation fully follows best practices for early authentication:

1. **Immediate authentication after WebSocket opens**:
   - Backend sends `hello` message immediately on connection
   - iOS responds with `connect` message containing API key (lines 1258-1277)
   - No other messages are sent before authentication completes

2. **Auth errors close connection and notify user**:
   - Backend sends `auth_error` with generic message ("Authentication failed") to prevent info leakage
   - Backend immediately closes connection after `auth_error` (line 444)
   - iOS sets `isAuthenticated = false`, `requiresReauthentication = true` (lines 676-678)
   - Reconnection attempts are stopped to prevent infinite retry loops (lines 680-682)
   - User sees authentication UI prompting to re-scan QR code

3. **Credentials stored securely in Keychain**:
   - `KeychainManager` uses `kSecClassGenericPassword` for secure storage
   - `kSecAttrAccessibleAfterFirstUnlock` allows access after first device unlock
   - API key retrieved via `retrieveAPIKey()` for each connect attempt
   - Supports sharing with Share Extension via keychain access groups

4. **Protocol enforcement**:
   - All messages except `ping` require prior authentication (handle-message cond check)
   - Unauthenticated messages receive `auth_error` and connection closes
   - Constant-time comparison prevents timing attacks (`auth/constant-time-equals?`)

5. **Test coverage**:
   - `VoiceCodeClientTests.swift:1376-1392` - Tests auth_error message structure
   - `VoiceCodeClientTests.swift:1558-1582` - Tests `requiresReauthentication` flag behavior
   - `VoiceCodeClientTests.swift:1584-1592` - Tests reconnection skip when reauth required
   - `KeychainManagerTests.swift` - Tests Keychain storage operations

**Gaps**: None identified.

**Recommendations**: None - implementation fully meets best practice.

#### 7. Design for reconnection auth
**Status**: Implemented
**Locations**:
- `ios/VoiceCode/Managers/KeychainManager.swift:72-117` - Secure API key storage with `kSecAttrAccessibleAfterFirstUnlock`
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:44-46` - `apiKey` computed property retrieves from Keychain
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:1239-1278` - `sendConnectMessage()` uses stored API key
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:672-684` - `requiresReauthentication` only set on actual auth failure
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:389-433` - Reconnection logic continues using stored credentials

**Findings**:
The implementation fully supports credential persistence across reconnections without user interaction:

1. **API key persists in Keychain**:
   - Stored using `kSecAttrAccessibleAfterFirstUnlock` accessibility class
   - Survives app restarts, device reboots (after first unlock), and network blips
   - Shared with Share Extension via keychain access group

2. **Automatic credential retrieval on reconnection**:
   - `apiKey` is a computed property that reads from Keychain on each access
   - Every call to `sendConnectMessage()` retrieves the stored key
   - No user interaction required for reconnection authentication

3. **Clear separation of auth failure vs connection failure**:
   - Network failures trigger reconnection with backoff (stored credentials reused)
   - `requiresReauthentication` flag **only** set when backend returns `auth_error`
   - User is only prompted to re-scan QR code when authentication actually fails

4. **Graceful handling of credential absence**:
   - If API key is missing from Keychain, `requiresReauthentication = true` is set
   - Reconnection timer is stopped to avoid pointless retries
   - User sees clear error: "API key not configured. Please scan QR code in Settings."

5. **No token refresh complexity**:
   - API key is a pre-shared secret that doesn't expire
   - Simpler than OAuth/JWT refresh token flows
   - Appropriate for this single-user deployment model

**Gaps**: None identified.

**Recommendations**: None - implementation fully meets best practice.

### Mobile-Specific Concerns

#### 8. Respect message size limits (256KB iOS)
**Status**: Implemented
**Locations**:
- `ios/VoiceCode/Managers/AppSettings.swift:76-80` - `maxMessageSizeKB` setting with UserDefaults persistence
- `ios/VoiceCode/Managers/AppSettings.swift:264` - Default value of 200 KB
- `ios/VoiceCode/Views/SettingsView.swift:147-155` - UI stepper (50-250 KB range) with explanatory text
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:570-572` - Sends `set_max_message_size` after connection
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:1106-1113` - `sendMaxMessageSize()` method
- `backend/src/voice_code/server.clj:102` - `default-max-message-size-kb` constant (100 KB)
- `backend/src/voice_code/server.clj:108-150` - `truncate-text-middle` function with UTF-8 aware truncation
- `backend/src/voice_code/server.clj:153-158` - `get-client-max-message-size-bytes` function
- `backend/src/voice_code/server.clj:160-221` - `truncate-content-block`, `truncate-message-text` for nested structures
- `backend/src/voice_code/server.clj:223-257` - `truncate-messages-array` with iterative budget halving
- `backend/src/voice_code/server.clj:259-328` - `build-session-history-response` with delta sync and per-message truncation
- `backend/src/voice_code/server.clj:330-370` - `truncate-response-text` for response messages
- `backend/src/voice_code/server.clj:454-471` - `send-to-client!` applies truncation before sending
- `backend/test/voice_code/server_test.clj:1539-1669` - Comprehensive truncation tests
- `STANDARDS.md:195-210` - Protocol spec for `set_max_message_size` message

**Findings**:
The implementation fully addresses the iOS 256 KB WebSocket message limit with comprehensive server-side truncation:

1. **Configurable limit** ✅
   - iOS default: 200 KB (conservative margin below 256 KB limit)
   - User-adjustable: 50-250 KB via Settings stepper
   - Backend default: 100 KB (used when client doesn't specify)
   - Setting persisted to UserDefaults, sent to backend after each connection

2. **Server-side truncation** ✅
   - `truncate-text-middle`: Preserves first and last portions of text with `[truncated ~N KB]` marker
   - UTF-8 aware: Handles multi-byte characters correctly at truncation boundaries
   - Applied to all outgoing messages via `send-to-client!` wrapper
   - Handles nested structures: `text` fields, `content` arrays, `tool_result` blocks

3. **Session history smart truncation** ✅
   - `build-session-history-response`: Prioritizes newest messages when budget exhausted
   - Per-message limit: 20 KB individual message cap prevents single large message from consuming entire budget
   - Delta sync: `last_message_id` reduces payload by returning only new messages
   - Returns `is-complete: false` when truncation occurs, enabling pagination

4. **Protocol support** ✅
   - `set_max_message_size` message sent immediately after connection
   - Backend stores per-client setting in `connected-clients` atom
   - Ack response confirms setting: "Max message size set to N KB"

5. **File uploads use HTTP** ✅
   - Large file uploads use HTTP POST endpoint, not WebSocket
   - Share Extension uses `/upload` endpoint with Bearer token auth
   - Avoids WebSocket message size constraints for file transfers
   - Base64 encoding means ~33% overhead, but HTTP has no practical limit

6. **Test coverage** ✅
   - `test-truncate-text-middle-*`: Tests under/at/over limit, preserving ends, marker accuracy
   - `test-truncate-response-text-*`: Tests response message truncation
   - `test-get-client-max-message-size-bytes`: Tests default and client-specific settings
   - `test-handle-set-max-message-size`: Tests message handling and validation
   - `test-build-session-history-*`: Tests budget exhaustion, small/large messages, delta sync

**Gaps**: None identified.

**Recommendations**: None - implementation fully meets best practice with comprehensive server-side truncation, user-configurable limits, and HTTP fallback for large uploads.

#### 9. Handle app lifecycle (background/foreground)
**Status**: Partial
**Locations**:
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:93-131` - `setupLifecycleObservers()` registers for foreground/background notifications
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:133-148` - `handleAppBecameActive()` and `handleAppEnteredBackground()` handlers
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:328-347` - `disconnect()` method with clean WebSocket closure
- `ios/VoiceCode/VoiceCodeApp.swift:183-199` - RootView foreground handler for pending uploads
- `ios/VoiceCode/Views/DirectoryListView.swift:44-45` - `scenePhase` tracking for UI updates
- `ios/VoiceCode/Views/ConversationView.swift:50` - `scenePhase` for suspending message list rendering
- `ios/VoiceCodeTests/VoiceCodeClientTests.swift:464-491` - Lifecycle observer tests
- `ios/VoiceCodeTests/VoiceCodeClientTests.swift:1584-1592` - Foreground reconnection skip test

**Findings**:
The implementation has **partial app lifecycle handling** with foreground reconnection but minimal background handling:

**What's implemented:**

1. **Reconnect on foreground** ✅
   - `setupLifecycleObservers()` registers for platform-specific notifications:
     - iOS: `UIApplication.willEnterForegroundNotification`
     - macOS: `NSApplication.didBecomeActiveNotification`
   - `handleAppBecameActive()` triggers reconnection when app returns to foreground
   - Reconnection backoff is reset on foreground (`reconnectionAttempts = 0`)
   - Reconnection skipped if `requiresReauthentication = true` (prevents loops on invalid key)

2. **Foreground triggers pending work** ✅
   - `RootView` listens for foreground and processes pending uploads (`resourcesManager.processPendingUploads()`)
   - `DirectoryListView` refreshes caches when returning from background
   - `ConversationView` suspends message list rendering in background (`scenePhase != .active`)

3. **Clean disconnect method exists** ✅
   - `disconnect()` calls `webSocket?.cancel(with: .goingAway, reason: nil)`
   - Stops ping timer, cancels reconnection timer
   - Clears locked sessions to prevent stuck state

4. **Test coverage** ✅
   - `testLifecycleObserversSetup()` verifies initialization
   - `testPlatformLifecycleNotifications()` verifies platform conditionals compile
   - `testForegroundReconnectionSkippedWhenReauthRequired()` verifies reauth flag check

**What's NOT implemented:**

1. **No disconnect on background** ❌
   - `handleAppEnteredBackground()` only logs: `"App entering background"`
   - WebSocket connection remains open when app enters background
   - iOS may suspend the app with the WebSocket in an undefined state
   - When iOS suspends the app, the connection dies without clean closure
   - Server sees abrupt disconnect, not graceful `goingAway` close

2. **No background task for critical operations** ❌
   - No use of `UIApplication.beginBackgroundTask` for in-flight operations
   - If user sends prompt and immediately backgrounds app:
     - WebSocket may be suspended mid-response
     - No mechanism to complete the turn before suspension
   - Pending acks are not sent before suspension

3. **No connection state persistence** ⚠️
   - When app backgrounds, connection state (authenticated, subscriptions) is lost
   - On foreground, full reconnection required (hello → connect → restore subscriptions)
   - Could persist last subscription list for faster restoration

**Best practice requirements:**
- Disconnect cleanly on background/suspend ❌ (connection left open, dies when suspended)
- Reconnect on foreground ✅ (implemented with backoff reset)
- Consider background task for critical message delivery ❌ (not implemented)

**Gaps**:
1. No clean disconnect when entering background - WebSocket left open
2. No `beginBackgroundTask` to complete in-flight operations before suspension
3. No sending of pending acks before suspension
4. Server doesn't know if client disconnected intentionally vs was suspended

**Recommendations**:
1. **Add clean disconnect on background**: Close WebSocket gracefully when entering background
   ```swift
   private func handleAppEnteredBackground() {
       print("📱 [VoiceCodeClient] App entering background, disconnecting cleanly")
       disconnect()  // Clean WebSocket close with .goingAway
   }
   ```

2. **Add background task for critical operations**: Complete in-flight turn before suspension
   ```swift
   private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

   private func handleAppEnteredBackground() {
       // Request time to complete critical work
       backgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
           // Expiration handler - clean up and end task
           self?.disconnect()
           if let taskID = self?.backgroundTaskID, taskID != .invalid {
               UIApplication.shared.endBackgroundTask(taskID)
           }
           self?.backgroundTaskID = .invalid
       }

       // If no pending operations, disconnect immediately
       if !hasPendingOperations {
           disconnect()
           endBackgroundTask()
       }
       // Otherwise, wait for turn_complete then disconnect
   }

   // Call when turn completes or times out
   private func endBackgroundTask() {
       if backgroundTaskID != .invalid {
           UIApplication.shared.endBackgroundTask(backgroundTaskID)
           backgroundTaskID = .invalid
       }
   }
   ```

3. **Send pending acks before suspension**: Flush any unsent acknowledgments
   ```swift
   private func handleAppEnteredBackground() {
       // Send any pending message acks
       flushPendingAcks()
       disconnect()
   }
   ```

4. **Consider adding "connection intent" to protocol** (optional): Server could distinguish intentional disconnect from suspension
   ```json
   Client → Backend: {"type": "disconnect", "reason": "background"}
   ```
   This lets server skip buffering messages for clients that explicitly disconnected.

**Priority**: Medium - Current behavior works but wastes server resources maintaining connections to suspended clients, and could lose in-flight responses when user backgrounds during a prompt.

#### 10. Optimize for battery
**Status**: Partial
**Locations**:
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:36` - `pingInterval = 30.0` (30 second ping interval)
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:389-433` - Exponential backoff with jitter prevents rapid reconnection
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:150-172` - Debounce mechanism batches rapid updates
- `ios/VoiceCode/Managers/NotificationManager.swift` - Local notifications only, no push notifications
- `ios/VoiceCodeTests/VoiceCodeClientDebounceTests.swift` - Tests for debouncing behavior

**Findings**:
The implementation has **partial battery optimization** with reasonable ping intervals and debouncing, but lacks push notifications and has room for improvement in reconnection behavior.

**What's implemented:**

1. **Reasonable ping interval** ✅
   - 30 second ping interval (within recommended 30-60 second range)
   - Ping timer only active when connected AND authenticated
   - Timer stops on disconnect, preventing unnecessary network activity
   - Not aggressive polling - single lightweight JSON message

2. **Exponential backoff with jitter** ✅
   - Reconnection delays increase exponentially: 1s → 2s → 4s → ... → 30s (capped)
   - ±25% jitter prevents thundering herd when multiple devices reconnect
   - Prevents battery drain from rapid reconnection attempts
   - Max 20 attempts (~17 minutes total) before stopping completely

3. **UI update debouncing** ✅
   - 100ms debounce window for rapid incoming messages
   - Batches multiple `session_locked`, `command_output`, etc. into single UI update
   - Reduces CPU usage and SwiftUI re-renders
   - `VoiceCodeClientDebounceTests` verifies batching behavior

4. **No aggressive polling** ✅
   - No polling loops for status checks
   - Server pushes updates via WebSocket when data changes
   - Client reacts to events, doesn't poll for them

**What's NOT implemented:**

1. **No push notifications for waking app** ❌
   - `NotificationManager` uses local notifications only (for Claude responses)
   - No Apple Push Notification service (APNs) integration
   - When app is backgrounded/suspended, WebSocket dies with no recovery mechanism
   - User must manually open app to receive updates
   - This is a deliberate design choice (single-user deployment, no push server infrastructure)

2. **No network-aware reconnection** ❌
   - Reconnection timer fires regardless of network availability (see Item 2)
   - Continues retrying on unreachable network, wasting battery
   - Should pause timer when network unavailable

3. **No batch message sending** ⚠️
   - On reconnection, sends individual `subscribe` messages for each active session
   - Could batch multiple subscriptions into single request (see Item 23)
   - Impact is minimal for typical use (1-2 active sessions)

4. **No disconnect on background** ⚠️
   - WebSocket remains open when app enters background (see Item 9)
   - iOS may suspend app with connection in undefined state
   - Clean disconnect would release network resources and save battery
   - However, keeping connection open allows receiving responses to in-flight prompts

**Best practice requirements:**
- Avoid aggressive polling or short ping intervals ✅ (30s ping, no polling)
- Use system push notifications for waking app when possible ❌ (local notifications only, by design)
- Batch non-urgent messages ⚠️ (incoming batched via debounce, outgoing not batched)

**Gaps**:
1. Reconnection timer fires during network unavailability (wasted CPU/radio)
2. No APNs integration for background wake (acceptable given architecture)
3. WebSocket kept open during background (could disconnect to save resources)
4. No batch protocol for outgoing messages (low impact)

**Recommendations**:

1. **Add network-aware reconnection** (see Item 2 for full details):
   - Add `NWPathMonitor` to detect network state
   - Pause reconnection timer when network unavailable
   - Resume/trigger immediately when network becomes available
   - This is the single biggest battery optimization opportunity

2. **Disconnect WebSocket on background** (see Item 9 for full details):
   - Clean disconnect when entering background releases network resources
   - iOS can suspend app without orphaned TCP connection
   - Reduces server resource usage as well
   ```swift
   private func handleAppEnteredBackground() {
       logger.info("📱 [VoiceCodeClient] Entering background, disconnecting")
       disconnect()  // Clean close with .goingAway
   }
   ```

3. **Document push notification non-goal**: Add to README/STANDARDS that push notifications are intentionally not implemented because:
   - Single-user self-hosted architecture
   - Would require push notification server infrastructure
   - APNs certificates and backend integration
   - Local notifications provide "Read Aloud" for foreground responses

4. **Consider batch subscribe protocol** (low priority):
   - If users commonly have many active sessions, implement `subscribe_batch`
   - Reduces reconnection burst from N messages to 1
   - See Item 23 for protocol design

**Priority**: Medium - Network-aware reconnection (Recommendation 1) should be implemented as it addresses the biggest battery drain scenario (reconnecting during network outage). Background disconnect (Recommendation 2) provides incremental improvement. Push notifications (not recommended) would require significant infrastructure changes for marginal benefit.

### Protocol Design

#### 11. Typed messages with clear structure
**Status**: Implemented
**Locations**:
- `backend/src/voice_code/server.clj:23-47` - `snake->kebab`, `kebab->snake`, `convert-keywords`, `parse-json`, `generate-json` - automatic case conversion
- `backend/src/voice_code/server.clj:1954-1962` - `websocket-handler` sends `hello` message with version fields
- `backend/src/voice_code/server.clj:1037-1900` - `handle-message` dispatches on `:type` field using `case`
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:530-534` - iOS validates `type` field presence
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:538-950` - iOS message handler switches on `type` string
- `STANDARDS.md:66-474` - Protocol specification documents all message types

**Findings**:
The implementation fully meets this best practice across all three dimensions:

1. **Include `type` field in all messages** ✅
   - Every message includes a `type` field (e.g., `"type": "connect"`, `"type": "prompt"`)
   - Backend dispatches on `(:type data)` using Clojure's `case` statement
   - iOS validates `type` presence before processing: `guard let type = json["type"] as? String`
   - Unknown types are rejected with error: `"Unknown message type: <type>"`

2. **Consistent naming conventions (snake_case for JSON)** ✅
   - Backend automatically converts between conventions at JSON boundaries:
     - `parse-json`: snake_case → kebab-case (e.g., `session_id` → `:session-id`)
     - `generate-json`: kebab-case → snake_case (e.g., `:session-id` → `session_id`)
   - iOS uses snake_case in all JSON messages (per Swift/JSON convention)
   - STANDARDS.md explicitly documents the convention: "Use **snake_case** for all JSON keys"

3. **Version protocol for future compatibility** ✅
   - Backend sends `hello` message on connection with version info:
     ```json
     {"type": "hello", "version": "0.2.0", "auth_version": 1, ...}
     ```
   - `version`: Overall protocol version (semantic versioning)
   - `auth_version`: Authentication protocol version for forward compatibility
   - iOS checks `auth_version` and warns if server requires newer version (lines 544-550)
   - Future protocol changes can increment `auth_version` to signal incompatibility

**Message Type Inventory** (from STANDARDS.md and code):
- Client → Backend: `connect`, `ping`, `prompt`, `subscribe`, `unsubscribe`, `set_directory`, `set_max_message_size`, `message_ack`, `compact_session`, `kill_session`, `infer_session_name`, `execute_command`, `get_command_history`, `get_command_output`, `upload_file`, `list_resources`, `delete_resource`, `start_recipe`, `exit_recipe`, `get_available_recipes`, `create_worktree_session`, `session_deleted`
- Backend → Client: `hello`, `connected`, `pong`, `ack`, `response`, `error`, `auth_error`, `session_locked`, `turn_complete`, `replay`, `session_history`, `session_list`, `recent_sessions`, `session_updated`, `session_ready`, `session_name_inferred`, `available_commands`, `command_started`, `command_output`, `command_complete`, `command_error`, `command_history`, `command_output_full`, `compaction_complete`, `compaction_error`, `file_uploaded`, `resources_list`, `resource_deleted`, `recipe_started`, `recipe_exited`, `recipe_step_complete`, `available_recipes`, `worktree_session_created`, `worktree_session_error`, `infer_name_error`, `session_killed`

**Gaps**: None identified.

**Recommendations**: None - implementation fully meets best practice.

#### 12. Design idempotent operations
**Status**: Partial
**Locations**:
- `ios/VoiceCode/Managers/SessionSyncManager.swift:171-191` - UUID-based deduplication for incoming messages
- `ios/VoiceCode/Managers/SessionSyncManager.swift:695-700` - `extractMessageId()` extracts UUID from message data
- `backend/src/voice_code/commands.clj:155-156` - `stop-session` returns success for non-existent session (idempotent)
- `backend/src/voice_code/claude.clj:56-59` - `kill-claude-session` returns success for non-existent process (idempotent)
- `backend/src/voice_code/server.clj:1269` - Session locking prevents duplicate prompt processing
- `backend/src/voice_code/server.clj:440` - `generate-message-id` function (defined but not used for responses)
- `STANDARDS.md:436-442` - Protocol specifies message ID and acknowledgment system

**Findings**:
The implementation has **partial idempotency** with key safeguards in place but gaps in message acknowledgment:

**What's implemented:**

1. **Session history deduplication** ✅
   - iOS maintains `existingIds: Set<UUID>` of messages already in CoreData
   - Incoming messages are checked against this set before insertion
   - Duplicate messages are skipped: "skipped N duplicates" logged
   - Uses backend-assigned UUIDs from Claude Code's .jsonl format

2. **Session locking prevents duplicate prompt processing** ✅
   - Backend acquires per-session lock before invoking Claude CLI
   - Concurrent prompts to same session receive `session_locked` message
   - Lock released on completion (success or error)
   - Prevents forked conversations from duplicate sends

3. **Delete/stop operations are idempotent** ✅
   - `stop-session` (commands.clj:155): Returns `{:success true}` even if session doesn't exist
   - `kill-claude-session` (claude.clj:56): Returns `{:success true}` for non-existent processes
   - Client can safely retry these operations without side effects

4. **File uploads delete after processing** ✅
   - `ResourcesManager.processUpload()` deletes `.json` and `.data` files after successful upload
   - Re-processing an upload after completion is a no-op (files don't exist)

5. **Delta sync with `last_message_id`** ✅
   - Client sends `last_message_id` in subscribe requests
   - Backend returns only messages newer than this ID
   - Prevents full history replay on every reconnection

**What's NOT implemented:**

1. **Response messages lack deduplication IDs** ❌
   - `generate-message-id` function exists but isn't called for responses
   - Responses don't include `message_id` field for client deduplication
   - If a response were replayed (hypothetically), client has no way to detect duplicate

2. **No message acknowledgment queue** ❌
   - As documented in Item 4, backend doesn't buffer messages for replay
   - `message-ack` handler is a no-op (only logs)
   - Replayed messages require manual client handling

3. **Command execution not idempotent** ⚠️
   - `execute_command` runs command every time called
   - No command ID deduplication (each call generates new `cmd-<UUID>`)
   - Appropriate for shell commands (user expects each call to run), but replay could cause unintended side effects

4. **Prompts not idempotent** ⚠️
   - If a prompt is sent twice (network retry), session lock prevents concurrent processing
   - But sequential retry would process prompt twice (no prompt deduplication by content or ID)
   - Currently acceptable because prompts aren't automatically retried

**Best practice requirements:**
- Replayed messages shouldn't cause duplicate side effects ⚠️ (partial - some operations idempotent, others not)
- Use message IDs for deduplication ⚠️ (implemented for session sync, not for responses)

**Gaps**:
1. Response messages don't include `message_id` for client-side deduplication
2. No idempotency key for prompt requests (if client retries, prompt runs twice)
3. Command execution has no replay protection (by design, but worth noting)

**Recommendations**:
1. **Add `message_id` to response messages**: Use existing `generate-message-id` function to attach IDs to `response`, `error`, and other important message types. Client can track received IDs and ignore duplicates.
   ```clojure
   ;; In send-response! or similar
   {:type :response
    :message-id (generate-message-id)
    :success true
    ...}
   ```

2. **Consider idempotency key for prompts** (optional): If prompt retries become a concern (e.g., with offline queueing from Item 21), add client-generated `idempotency_key` to prompt messages. Backend checks against recent keys and returns cached response for duplicates.
   ```json
   {"type": "prompt", "idempotency_key": "uuid-from-client", "text": "..."}
   ```

3. **Document command execution behavior**: Make explicit in protocol docs that `execute_command` is intentionally not idempotent - each call runs the command regardless of prior calls.

#### 13. Provide clear error responses
**Status**: Implemented
**Locations**:
- `backend/src/voice_code/server.clj:393-401` - `send-auth-error!` for authentication failures
- `backend/src/voice_code/server.clj:851-898` - Error handling in prompt execution with session-id
- `backend/src/voice_code/server.clj:1136-1258` - Protocol validation errors (missing fields)
- `backend/src/voice_code/server.clj:1409-1417` - `compaction_error` with session context
- `backend/src/voice_code/server.clj:1460-1484` - `infer_name_error` with session context
- `backend/src/voice_code/server.clj:1494-1560` - `worktree_session_error` with context
- `backend/src/voice_code/server.clj:1615-1617` - `command_error` with command-id context
- `backend/src/voice_code/server.clj:1825-1826` - Unknown message type errors
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:659-670` - Generic `error` handler unlocks session
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:672-684` - `auth_error` handler sets `requiresReauthentication`
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:804-815` - `compaction_error` handler unlocks session
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:919-923` - `command_error` handler
- `STANDARDS.md:256-285` - Protocol specification for error response types

**Findings**:
The implementation has **strong error response design** with clear type distinctions and recovery paths:

**1. Auth errors distinguished from protocol errors** ✅

The protocol clearly separates authentication failures from other errors:

- `auth_error`: Authentication-specific failures (invalid API key, missing credentials, unauthenticated message attempts)
  - Backend sends generic message ("Authentication failed") to prevent information leakage
  - Connection closed immediately after sending
  - iOS sets `requiresReauthentication = true` and stops reconnection attempts
  - Recovery path: User must re-scan QR code or re-enter credentials

- `error`: General protocol/processing errors (missing required fields, unknown message types, operation failures)
  - Connection remains open for continued use
  - iOS unlocks session if `session_id` is present
  - Recovery path: User can retry the operation

**2. Domain-specific error types** ✅

The protocol defines specialized error types with rich context for different operations:

| Error Type | Context Fields | Recovery Path |
|------------|----------------|---------------|
| `auth_error` | `message` | Re-authenticate (re-scan QR) |
| `error` | `message`, `session_id` (optional) | Retry operation |
| `compaction_error` | `session_id`, `error` | Retry compaction or ignore |
| `infer_name_error` | `session_id`, `error` | Use default name |
| `worktree_session_error` | `success: false`, `error`, `session_id` | Fix issue and retry |
| `command_error` | `command_id`, `error` | Retry command |
| `session_locked` | `session_id`, `message` | Wait for turn_complete |

**3. Actionable error messages** ✅

Error messages are specific and actionable:
- `"session_id required in subscribe message"` - tells user exactly what's missing
- `"Cannot specify both new_session_id and resume_session_id"` - explains conflict
- `"Recipe not found: <recipe-id>"` - identifies the missing resource
- `"Failed to kill session: <reason>"` - includes underlying error
- `"Session not found: <session-id>"` - identifies invalid reference

**4. Error recovery paths** ✅

Each error type has a defined recovery path:

- **Authentication errors**:
  - iOS sets `requiresReauthentication = true`
  - Reconnection timer stopped (prevents pointless retries)
  - UI shows authentication error with option to re-scan QR

- **Session errors with session_id**:
  - iOS unlocks the session (`lockedSessions.remove(sessionId)`)
  - User can retry the operation with the unlocked session

- **Validation errors**:
  - Error message describes missing/invalid field
  - User/client can correct and retry

- **Operation-specific errors** (compaction, command, worktree):
  - Typed errors enable specific UI handling
  - Context fields (session_id, command_id) enable correlation with pending operations

**5. Error handling consistency** ✅

Backend consistently:
- Includes `session-id` in error responses when operation targets a specific session
- Uses `send-to-client!` wrapper which applies message truncation
- Logs errors with context before sending client response
- Returns appropriate error type based on operation domain

iOS consistently:
- Unlocks sessions when error responses include session_id
- Updates UI state (isProcessing, currentError) on errors
- Logs errors with context for debugging
- Provides callbacks for operation-specific error handling

**Gaps**: None identified. The implementation fully meets the best practice with clear type distinctions, rich context, and defined recovery paths.

**Recommendations**: None - implementation meets best practice.

### Detecting Degraded Connections

#### 14. Implement connection quality monitoring (RTT)
**Status**: Not Implemented
**Locations**:
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:35-36` - `pingTimer` with 30-second interval
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:439-458` - `startPingTimer()` sends pings
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:1115-1118` - `ping()` sends `{"type": "ping"}`
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:686-688` - `pong` handler is empty (just `break`)
- `backend/src/voice_code/server.clj:1051` - Server responds with pong synchronously

**Findings**:
The implementation does **not** track connection quality via RTT (round-trip time). While the ping/pong mechanism exists for keepalive, no timing data is collected or used to detect degraded connections.

**Current ping/pong behavior:**

1. **Client sends periodic pings** ✅
   - Ping sent every 30 seconds (`pingInterval = 30.0`)
   - Timer starts after authentication, stops on disconnect
   - Uses `DispatchSourceTimer` for reliable scheduling

2. **Server responds immediately** ✅
   - Backend handles `"ping"` message type in `handle-message`
   - Sends `{"type": "pong"}` synchronously back to client

3. **No RTT tracking** ❌
   - Client does not record when ping was sent
   - `pong` handler at line 686-688 is empty:
     ```swift
     case "pong":
         // Pong response to ping
         break
     ```
   - No calculation of round-trip time (time between ping sent and pong received)
   - No historical RTT data for trend analysis

4. **No zombie connection detection** ❌
   - If pong never arrives, client has no mechanism to detect this
   - Connection appears alive until TCP layer times out (potentially minutes)
   - No timeout after 2-3x normal RTT as best practice recommends

**What connection quality monitoring would enable:**
- **Baseline RTT**: Track average round-trip time during normal operation
- **Degradation detection**: When current RTT exceeds 2-3x baseline, mark connection as degraded
- **Zombie detection**: If pong doesn't arrive within expected window (e.g., 10 seconds), treat connection as dead
- **User feedback**: Could show connection quality indicator (green/yellow/red)
- **Adaptive behavior**: Adjust timeouts or disable heavy features on slow connections

**Best practice requirements:**
- Track round-trip time (RTT) of ping/pong cycles ❌
- Detect "zombie connections" where TCP is alive but unusable ❌
- If pong doesn't arrive within 2-3x normal RTT, assume connection is degraded ❌

**Gaps**:
1. No timestamp recorded when ping is sent
2. Pong handler does nothing (doesn't cancel any timeout, doesn't track RTT)
3. No RTT history or baseline calculation
4. No timeout mechanism for missing pong responses
5. No connection quality state exposed to UI

**Recommendations**:

1. **Track ping send time and calculate RTT**:
   ```swift
   private var lastPingSentAt: Date?
   private var rttHistory: [TimeInterval] = []
   private let maxRttSamples = 10  // Rolling window

   func ping() {
       lastPingSentAt = Date()
       sendMessage(["type": "ping"])
   }

   // In handleMessage for "pong":
   case "pong":
       if let sentAt = lastPingSentAt {
           let rtt = Date().timeIntervalSince(sentAt)
           recordRtt(rtt)
           logger.debug("🏓 [VoiceCodeClient] Pong received, RTT: \(Int(rtt * 1000))ms")
       }
       lastPingSentAt = nil
       cancelPongTimeout()  // See recommendation 2

   private func recordRtt(_ rtt: TimeInterval) {
       rttHistory.append(rtt)
       if rttHistory.count > maxRttSamples {
           rttHistory.removeFirst()
       }
   }

   var averageRtt: TimeInterval {
       guard !rttHistory.isEmpty else { return 0 }
       return rttHistory.reduce(0, +) / Double(rttHistory.count)
   }
   ```

2. **Add pong timeout for zombie detection**:
   ```swift
   private var pongTimeoutTimer: DispatchSourceTimer?
   private let pongTimeout: TimeInterval = 10.0  // 10 seconds max

   func ping() {
       lastPingSentAt = Date()
       sendMessage(["type": "ping"])
       startPongTimeoutTimer()
   }

   private func startPongTimeoutTimer() {
       pongTimeoutTimer?.cancel()
       let timer = DispatchSource.makeTimerSource(queue: .main)
       timer.schedule(deadline: .now() + pongTimeout)
       timer.setEventHandler { [weak self] in
           guard let self = self else { return }
           logger.warning("⚠️ [VoiceCodeClient] Pong timeout - connection degraded or dead")
           self.handleDegradedConnection()
       }
       timer.resume()
       pongTimeoutTimer = timer
   }

   private func cancelPongTimeout() {
       pongTimeoutTimer?.cancel()
       pongTimeoutTimer = nil
   }
   ```

3. **Implement adaptive timeout based on RTT baseline**:
   ```swift
   private func calculatePongTimeout() -> TimeInterval {
       let baselineRtt = averageRtt
       if baselineRtt > 0 {
           // 3x baseline RTT, minimum 5s, maximum 30s
           return min(max(baselineRtt * 3, 5.0), 30.0)
       }
       return 10.0  // Default when no baseline
   }
   ```

4. **Add connection quality state for UI**:
   ```swift
   enum ConnectionQuality {
       case good      // RTT < 500ms
       case degraded  // RTT 500ms-2000ms or increasing trend
       case poor      // RTT > 2000ms or pong nearly timing out
       case unknown   // No RTT data yet
   }

   @Published var connectionQuality: ConnectionQuality = .unknown

   private func updateConnectionQuality() {
       let rtt = averageRtt
       if rtt == 0 {
           connectionQuality = .unknown
       } else if rtt < 0.5 {
           connectionQuality = .good
       } else if rtt < 2.0 {
           connectionQuality = .degraded
       } else {
           connectionQuality = .poor
       }
   }
   ```

5. **Handle degraded connection state**:
   ```swift
   private func handleDegradedConnection() {
       // Could either:
       // a) Immediately reconnect (aggressive - best for zombie detection)
       // b) Mark as degraded and try one more ping (conservative)
       // c) Trigger UI warning but keep connection (for slow-but-alive)

       // For zombie detection, aggressive approach is best:
       logger.warning("🔌 [VoiceCodeClient] Pong timeout, forcing reconnection")
       webSocket?.cancel(with: .abnormalClosure, reason: nil)
       webSocket = nil
       isConnected = false
       stopPingTimer()
       reconnectionAttempts = 0  // Reset backoff for detection-triggered reconnect
       connect()
   }
   ```

**Priority**: Medium-High - This directly impacts user experience during network instability, which is common on mobile. Implementing pong timeout (Recommendation 2) alone provides significant value as zombie connection detection. RTT tracking (Recommendations 1, 3, 4) provides additional intelligence for adaptive behavior.

**Implementation approach**: Start with pong timeout timer (Recommendation 2) as it's self-contained and catches the most common problem (dead connections). Add RTT tracking later for more nuanced quality monitoring.

#### 15. Application-level timeouts (not just TCP)
**Status**: Partial
**Locations**:
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:312-314` - URLRequest with no timeout configured
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:470-514` - `receiveMessage()` has no timeout, waits indefinitely
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:686-688` - `pong` handler does nothing (no timeout reset)
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:1203-1210` - Session list request with 5s timeout
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:1229-1235` - Session refresh with 10s timeout
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:1374-1391` - Compaction with 60s timeout
- `ios/VoiceCode/Views/RecipeMenuView.swift:167-181` - Recipe start with 15s timeout
- `ios/VoiceCode/Managers/ResourcesManager.swift:292-296` - Upload with 30s timeout
- `backend/src/voice_code/claude.clj:run-process-with-file-redirection` - Claude CLI with timeout support

**Findings**:
The implementation has **inconsistent application-level timeout coverage**:

**What's implemented (specific operations):**

1. **Operation-specific timeouts** ✅
   - Session list request: 5 second timeout
   - Session refresh: 10 second timeout
   - Compaction: 60 second timeout
   - Recipe start: 15 second timeout
   - File uploads: 30 second timeout
   - Claude CLI: 24 hour default timeout (configurable)

2. **Backend Claude invocation** ✅
   - `invoke-claude` accepts `:timeout` parameter (milliseconds)
   - Default: 3600000ms (1 hour) for sync, 86400000ms (24 hours) for async
   - Process forcibly destroyed on timeout

**What's NOT implemented (connection-level):**

1. **WebSocket read timeout** ❌
   - `receiveMessage()` at line 470 uses callback-based receive with no timeout
   - Once called, it waits indefinitely for the next message
   - If the connection goes silent (server unresponsive), client has no way to detect this
   - iOS `URLSessionWebSocketTask` has no built-in read timeout API

2. **URLRequest timeout** ❌
   - At line 312: `let request = URLRequest(url: url)` uses defaults
   - No `timeoutInterval` configured
   - Default is 60 seconds for new connections, but this only affects initial handshake

3. **Ping/pong timeout** ❌ (Covered in detail in item 14)
   - Ping sent every 30 seconds
   - But if pong never arrives, nothing happens
   - No timeout timer to detect missing pong responses

**Why TCP-only timeout is insufficient:**

The best practice warns that "TCP can keep a dead connection open for minutes." This is exactly the problem:

1. **TCP keepalive** is typically 2+ hours by default on iOS
2. If server becomes unresponsive (process hang, network issue), TCP doesn't detect it
3. `receiveMessage()` remains pending, waiting for data that will never arrive
4. User sees "Connected" but app is effectively frozen
5. Only remedy is manual force-reconnect or app restart

**Current behavior on silent server:**
1. User sends prompt → App shows "Processing..."
2. Server stops responding (crash, network partition)
3. App stays in loading state indefinitely
4. Ping timer fires, sends ping (which may or may not arrive)
5. Pong never arrives, but nothing detects this
6. User must manually reconnect or restart app

**Best practice requirements:**
- TCP can keep a dead connection open for minutes ✅ (acknowledged)
- Set aggressive read timeouts (15-30 seconds) ❌
- Treat timeout as connection failure, not just slow response ❌

**Gaps**:
1. No application-level read timeout for WebSocket messages
2. No timeout on WebSocket receive callback (iOS API limitation)
3. URLRequest created without explicit timeout configuration
4. Pong response has no associated timeout (covered in item 14)
5. Loading indicators can spin indefinitely if server goes silent

**Recommendations**:

1. **Implement operation-level timeout pattern consistently**:
   All request-response operations should have timeouts. Current implementation is inconsistent:
   ```swift
   // Pattern already used for session list (5s), session refresh (10s), compaction (60s)
   // Apply to ALL operations that expect a response:

   // For sendPrompt, wrap with timeout:
   func sendPromptWithTimeout(_ text: String, timeout: TimeInterval = 30.0) async throws {
       let timeoutTask = Task {
           try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
           throw TimeoutError.requestTimeout
       }

       let sendTask = Task {
           return try await sendPromptInternal(text)
       }

       do {
           let result = try await sendTask.value
           timeoutTask.cancel()
           return result
       } catch is CancellationError {
           throw TimeoutError.requestTimeout
       }
   }
   ```

2. **Use pong timeout as proxy for read timeout** (See item 14):
   Since iOS doesn't expose read timeout on WebSocket, the ping/pong mechanism can serve as application-level liveness detection:
   ```swift
   // If pong doesn't arrive within 10 seconds of ping, treat connection as dead
   // This effectively gives us a 30s + 10s = 40s maximum silent period
   ```

3. **Add timeout indicator to loading states**:
   ```swift
   // Instead of indefinite spinner, show progress with timeout context
   struct LoadingView: View {
       @State private var elapsedTime: TimeInterval = 0
       let maxTime: TimeInterval = 30.0

       var body: some View {
           VStack {
               ProgressView(value: min(elapsedTime / maxTime, 1.0))
               Text(elapsedTime < maxTime ? "Processing..." : "Taking longer than expected")
           }
       }
   }
   ```

4. **Configure URLRequest timeout for initial connection**:
   ```swift
   func connect() {
       var request = URLRequest(url: url)
       request.timeoutInterval = 15.0  // Fail fast on initial connection
       webSocket = URLSession.shared.webSocketTask(with: request)
       // ...
   }
   ```

5. **Add turn-level timeout for Claude responses**:
   ```swift
   // When waiting for turn_complete after sending prompt:
   private let turnTimeout: TimeInterval = 300.0  // 5 minutes max for Claude response

   func startTurnTimer(forSession sessionId: String) {
       turnTimeoutTimers[sessionId]?.cancel()
       let timer = DispatchSource.makeTimerSource(queue: .main)
       timer.schedule(deadline: .now() + turnTimeout)
       timer.setEventHandler { [weak self] in
           self?.handleTurnTimeout(sessionId: sessionId)
       }
       timer.resume()
       turnTimeoutTimers[sessionId] = timer
   }

   func handleTurnTimeout(sessionId: String) {
       logger.warning("⏱️ Turn timeout for session \(sessionId)")
       // Option 1: Show warning but keep waiting
       // Option 2: Unlock session and let user retry
       // Option 3: Trigger kill_session to force termination
   }
   ```

**Priority**: High - The lack of application-level timeout is a fundamental UX problem. Users cannot detect when their connection is actually dead vs. just slow. Combined with item 14 (pong timeout), this creates resilient dead-connection detection.

**Implementation approach**:
1. First implement pong timeout (item 14) - this gives basic liveness detection
2. Add URLRequest.timeoutInterval for faster initial connection failure
3. Add turn-level timeout with user-visible progress indication
4. Standardize timeout pattern across all request-response operations

#### 16. Distinguish slow from dead connections
**Status**: Not Implemented
**Locations**:
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:686-688` - `pong` handler is empty (no RTT tracking)
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:489-514` - WebSocket failure handler reconnects immediately
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:389-433` - Reconnection uses same delay strategy regardless of failure type
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:36` - Fixed 30s ping interval, not adaptive

**Findings**:
The implementation does **not** distinguish between slow and dead connections. All connection failures are treated identically - immediate reconnection attempt with exponential backoff.

**Current behavior:**

1. **Binary connection state** ❌
   - Connection is either `isConnected = true` or `isConnected = false`
   - No intermediate states for "degraded", "slow", or "unstable"
   - UI only shows "Connected" or "Connecting..." or error

2. **No RTT-based slowness detection** ❌
   - Ping/pong exists but doesn't track timing (see item 14)
   - Cannot differentiate between 50ms RTT (fast) and 5000ms RTT (slow but alive)
   - No baseline to detect degradation from "normal" performance

3. **No progressive timeout strategy** ❌
   - All timeouts are fixed values (30s ping, operation-specific timeouts)
   - No mechanism to increase timeouts when detecting slowness
   - No escalation from "wait longer" to "reconnect"

4. **No message frequency adaptation** ❌
   - Ping interval is fixed at 30 seconds
   - No concept of reducing message frequency on slow connections
   - No batching or deferral of non-critical messages

5. **Same reconnection strategy for all failures** ❌
   - WebSocket error → immediate reconnect attempt
   - Missing pong (currently not detected) → would reconnect immediately
   - Network unreachable → same reconnect loop (wastes battery)
   - No differentiation based on failure type or history

**What the best practice recommends:**

| Condition | Recommended Action |
|-----------|-------------------|
| Slow connection (high RTT but responsive) | Increase timeouts, reduce message frequency, show "slow connection" indicator |
| Dead connection (no response) | Reconnect immediately |
| Progressive detection | First increase timeout, then try again, only reconnect after multiple failures |

**Why this matters:**

Without distinguishing slow from dead:
1. **False reconnections**: A slow-but-alive connection gets torn down and rebuilt, disrupting any in-flight operations
2. **Poor UX on slow networks**: Users on 3G/congested networks experience frequent reconnections instead of graceful degradation
3. **No user feedback**: Users can't tell if the app is slow because of network or because something is broken
4. **Battery drain**: Repeated reconnection attempts on slow (not dead) connections waste resources

**Gaps**:
1. No RTT tracking to detect connection slowness
2. No connection quality state machine (good → slow → dead)
3. No progressive timeout escalation before reconnecting
4. No adaptive ping interval based on connection quality
5. No message frequency reduction for slow connections
6. Reconnection strategy doesn't consider failure type

**Recommendations**:

1. **Implement connection quality state machine**:
   ```swift
   enum ConnectionState {
       case disconnected
       case connecting
       case connected(quality: ConnectionQuality)
   }

   enum ConnectionQuality {
       case good       // RTT < 500ms, stable
       case degraded   // RTT 500ms-2000ms, or increasing trend
       case slow       // RTT > 2000ms, or high variance
       case unresponsive  // Pong timeout approaching
   }

   @Published var connectionState: ConnectionState = .disconnected
   ```

2. **Progressive timeout escalation before declaring dead**:
   ```swift
   private var consecutivePongMisses = 0
   private let maxPongMissesBeforeReconnect = 3

   // In pong timeout handler:
   func handlePongTimeout() {
       consecutivePongMisses += 1

       if consecutivePongMisses >= maxPongMissesBeforeReconnect {
           // Truly dead - reconnect
           logger.warning("🔌 Connection dead after \(consecutivePongMisses) missed pongs, reconnecting")
           forceReconnect()
       } else {
           // Maybe just slow - increase timeout and try again
           let extendedTimeout = pongTimeout * Double(consecutivePongMisses + 1)
           logger.info("⚠️ Pong miss #\(consecutivePongMisses), extending timeout to \(extendedTimeout)s")
           connectionState = .connected(quality: .slow)
           startPongTimeoutTimer(timeout: extendedTimeout)
           ping()  // Try again with longer timeout
       }
   }

   // On successful pong:
   func handlePongReceived() {
       consecutivePongMisses = 0  // Reset counter
       updateConnectionQuality(basedOnRtt: measuredRtt)
   }
   ```

3. **Adaptive behavior for slow connections**:
   ```swift
   func adaptToConnectionQuality(_ quality: ConnectionQuality) {
       switch quality {
       case .good:
           // Normal operation
           pingInterval = 30.0
           enableAutoSpeak = true
       case .degraded:
           // Slight adjustment
           pingInterval = 45.0  // Less frequent pings
           // No behavior change yet
       case .slow:
           // Significant adaptation
           pingInterval = 60.0
           showSlowConnectionBanner = true
           // Disable auto-speak to reduce message frequency
           enableAutoSpeak = false
       case .unresponsive:
           // Waiting for final determination
           showSlowConnectionBanner = true
           // Don't send new messages, queue them instead
       }
   }
   ```

4. **UI indicator for connection quality**:
   ```swift
   // In ConnectionStatusView or header
   var connectionIcon: some View {
       switch connectionState {
       case .disconnected:
           Image(systemName: "wifi.slash")
       case .connecting:
           ProgressView()
       case .connected(let quality):
           switch quality {
           case .good: Image(systemName: "wifi").foregroundColor(.green)
           case .degraded: Image(systemName: "wifi").foregroundColor(.yellow)
           case .slow: Image(systemName: "wifi.exclamationmark").foregroundColor(.orange)
           case .unresponsive: Image(systemName: "wifi.exclamationmark").foregroundColor(.red)
           }
       }
   }
   ```

5. **Different reconnection strategies by failure type**:
   ```swift
   enum DisconnectReason {
       case serverClosed       // Server sent close frame
       case pongTimeout        // Multiple pong timeouts
       case networkError       // TCP/DNS error
       case authFailure        // Auth rejected
       case manual             // User-initiated
   }

   func handleDisconnection(reason: DisconnectReason) {
       switch reason {
       case .pongTimeout:
           // Connection was degrading, reset backoff (likely transient)
           reconnectionAttempts = 0
           connect()
       case .networkError:
           // Network issue, use backoff
           scheduleReconnection()
       case .serverClosed:
           // Server cleanly closed, reconnect soon
           reconnectionAttempts = 0
           DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
               self.connect()
           }
       case .authFailure:
           // Don't reconnect automatically
           requiresReauthentication = true
       case .manual:
           // User disconnected, don't auto-reconnect
           break
       }
   }
   ```

**Priority**: Medium - This builds on items 14 (RTT tracking) and 15 (application timeouts). While not critical for basic functionality, it significantly improves UX on unreliable networks and prevents unnecessary reconnections on slow-but-alive connections.

**Implementation approach**:
1. First implement RTT tracking from item 14 (prerequisite for detecting slowness)
2. Add connection quality enum and state machine
3. Implement progressive pong timeout escalation
4. Add UI indicator for connection quality
5. Implement adaptive behavior (ping interval, message frequency)
6. Differentiate reconnection strategies by failure type

**Dependencies**:
- Item 14 (RTT tracking) must be implemented first
- Item 15 (application timeouts) provides operation-level context

### Poor Bandwidth Handling

#### 17. Implement message prioritization
**Status**: Not Implemented
**Locations**:
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:1525-1546` - `sendMessage()` sends directly to WebSocket without queue
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:539-554` - Auth flow: hello → connect via callback sequencing
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:1280-1287` - `sendMessageAck()` sends acks directly
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:1060-1095` - `sendPrompt()` sends directly
- `backend/src/voice_code/server.clj:455-471` - `send-to-client!` synchronous direct send
- `backend/src/voice_code/server.clj:393-401` - `send-auth-error!` sends and closes

**Findings**:
The implementation has **no message prioritization system**. Both iOS and backend use a "send immediately" model:

**iOS Client:**
1. **No outgoing message queue**: All messages sent directly via `webSocket?.send()` without buffering
2. **Auth sequenced via callbacks**: When `hello` received, `sendConnectMessage()` called immediately - not a priority queue, just sequential flow
3. **Acks sent directly**: `sendMessageAck()` calls `sendMessage()` immediately
4. **Prompts sent directly**: `sendPrompt()` calls `sendMessage()` without any queue check
5. **Session priority exists but different purpose**: `CDBackendSession+PriorityQueue.swift` implements session ordering (which sessions to work on), not message ordering

**Backend Server:**
1. **Direct synchronous sends**: `send-to-client!` uses `http/send!` directly with no queue
2. **No per-client message buffers**: `connected-clients` atom tracks auth state and settings, not pending messages
3. **No priority differentiation**: All message types go through same send path
4. **Message ID generation unused**: `generate-message-id` function exists but is never called

**Current implicit ordering:**
- Auth messages: Sent first only because protocol requires authentication before other messages can be processed
- Acks: Sent on receipt of replay messages (reactive, not prioritized)
- Prompts: Sent whenever user initiates (no queue means no congestion handling)

**Best practice requirements:**
- Queue outgoing messages by priority ❌ (no queue exists)
- Send critical messages (auth, acks) before bulk data ❌ (no priority system)
- Drop or defer low-priority messages under congestion ❌ (no congestion detection or message dropping)

**Gaps**:
1. No outgoing message queue on iOS client
2. No priority classification for message types
3. No congestion detection (network quality not monitored)
4. No mechanism to defer or drop low-priority messages
5. Critical messages (auth, acks) not explicitly prioritized over bulk data

**Recommendations**:
1. **Classify message priorities**:
   - P0 (Critical): `ping`, `pong`, `connect`, `message_ack` - must always be sent immediately
   - P1 (High): `prompt`, `subscribe`, `set_directory` - user-initiated actions
   - P2 (Normal): `set_max_message_size`, `compact_session` - configuration/maintenance
   - P3 (Low): `execute_command`, `get_command_history` - deferrable operations

2. **Add priority queue on iOS** (optional, for degraded network handling):
   ```swift
   struct PrioritizedMessage {
       let message: [String: Any]
       let priority: Int  // 0 = highest
       let timestamp: Date
   }

   private var messageQueue: [PrioritizedMessage] = []
   private var isSending = false

   func queueMessage(_ message: [String: Any], priority: Int = 1) {
       let prioritized = PrioritizedMessage(message: message, priority: priority, timestamp: Date())
       messageQueue.append(prioritized)
       messageQueue.sort { $0.priority < $1.priority || ($0.priority == $1.priority && $0.timestamp < $1.timestamp) }
       processQueue()
   }
   ```

3. **Congestion detection**: Track message send success/failure rate and RTT. When degraded:
   - Increase send delay between messages
   - Drop P3 messages if queue grows too long
   - Coalesce duplicate requests (e.g., multiple `ping` messages)

4. **Priority-aware sending for auth/acks**:
   ```swift
   func sendConnectMessage() {
       queueMessage(connectMessage, priority: 0)  // Critical
   }

   func sendMessageAck(_ messageId: String) {
       queueMessage(ackMessage, priority: 0)  // Critical
   }

   func sendPrompt(_ text: String, ...) {
       queueMessage(promptMessage, priority: 1)  // High
   }
   ```

**Assessment**: Low impact for current single-user deployment. Would become valuable if:
- Network conditions are frequently degraded
- Multiple operations need to be queued (batch scenarios)
- Client needs to handle connection recovery gracefully

#### 18. Support message compression
**Status**: Not Implemented
**Locations**:
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:312-314` - WebSocket created with plain `URLRequest` (no compression options)
- `backend/src/voice_code/server.clj` - http-kit WebSocket handler with no compression configuration
- `backend/deps.edn` - http-kit 2.8.1 dependency (no compression library)
- `backend/src/voice_code/server.clj:108-151` - `truncate-text-middle` uses text-level truncation, not compression

**Findings**:
The implementation has **no message compression support**. Neither iOS nor the backend configure WebSocket compression:

**iOS Client:**
1. **No compression negotiation**: `URLRequest` created with default configuration
   - iOS `URLSessionWebSocketTask` does not enable `permessage-deflate` by default
   - No custom URLSession configuration for compression
   - Messages sent as plain JSON text without compression

2. **No payload-level compression**: Messages are serialized to JSON and sent directly
   - `sendMessage()` passes raw JSON string to `URLSessionWebSocketTask.Message.string()`
   - No `Foundation.Data` compression (e.g., `NSData.compressed(using:)`) applied

**Backend Server:**
1. **http-kit lacks compression**: The http-kit 2.8.1 WebSocket implementation does not support `permessage-deflate` extension
   - No compression negotiation during WebSocket upgrade
   - `http/send!` sends messages as-is without compression
   - No server-side configuration options for WebSocket compression

2. **Truncation instead of compression**: Large messages are truncated, not compressed
   - `truncate-response-text` caps messages at ~100-200 KB by removing middle content
   - This is a size limit workaround, not bandwidth optimization
   - Information is lost, not preserved in compressed form

3. **No protocol-level compression**: JSON payloads have repetitive structures but no optimization
   - Message types, field names repeated verbatim in every message
   - Session IDs (36-character UUIDs) sent in full each time
   - No binary protocol or field abbreviation

**Message Size Analysis:**
- Typical Claude response: 5-50 KB of JSON text (highly compressible)
- Session history: Can exceed 100 KB, currently truncated
- Command output: Variable, potentially large (build logs, test results)
- Text compresses well: 2-4x reduction typical for JSON payloads

**Best practice requirements:**
- Compress payloads over threshold (e.g., 1KB) ❌ (no compression)
- Use per-message compression (permessage-deflate) ❌ (not negotiated)
- Consider protocol-level compression for repetitive structures ❌ (plain JSON)

**Gaps**:
1. No WebSocket `permessage-deflate` extension negotiation (iOS or backend)
2. No payload-level compression for large messages
3. http-kit does not support WebSocket compression extensions
4. No binary protocol or field abbreviation for repetitive data
5. Large messages truncated with data loss rather than compressed

**Recommendations**:
1. **Evaluate backend alternatives** for WebSocket compression:
   - Option A: Replace http-kit with Aleph or Undertow (both support `permessage-deflate`)
   - Option B: Add application-level gzip compression for payloads >1KB
   - Option C: Keep current approach (truncation acceptable for single-user deployment)

2. **If implementing application-level compression**:
   ```clojure
   ;; Backend: compress large payloads
   (require '[clojure.java.io :as io])
   (import '[java.util.zip GZIPOutputStream])

   (defn compress-if-large [json-str threshold-bytes]
     (let [bytes (.getBytes json-str "UTF-8")]
       (if (< (count bytes) threshold-bytes)
         {:compressed false :data json-str}
         {:compressed true
          :data (with-open [baos (java.io.ByteArrayOutputStream.)
                            gzip (GZIPOutputStream. baos)]
                  (.write gzip bytes)
                  (.close gzip)
                  (java.util.Base64/getEncoder (.encode (.toByteArray baos))))})))
   ```

   ```swift
   // iOS: decompress if indicated
   import Compression

   func decompressIfNeeded(_ message: [String: Any]) -> [String: Any] {
       guard let compressed = message["compressed"] as? Bool,
             compressed,
             let data = message["data"] as? String,
             let compressedData = Data(base64Encoded: data) else {
           return message
       }
       // Decompress using NSData.decompressed(using: .zlib)
       // ... parse JSON from decompressed data
   }
   ```

3. **Protocol-level optimization** (lower priority):
   - Define numeric message type codes instead of strings
   - Use short field aliases in JSON (e.g., `"t"` for `"type"`)
   - Consider binary protocol (MessagePack, Protocol Buffers) for high-volume scenarios

**Assessment**: Low-to-medium impact for current single-user deployment:
- **Current workaround is functional**: Truncation handles the iOS 256KB limit
- **Compression would preserve information**: No data loss from large responses
- **Bandwidth reduction**: 2-4x smaller payloads would help on poor mobile networks
- **Implementation cost**: Medium - requires backend library change or application-level protocol
- **Recommendation**: Defer unless mobile data usage or large response handling becomes a pain point. The existing truncation approach is acceptable for the current use case.

#### 19. Implement adaptive payload sizing
**Status**: Not Implemented
**Locations**:
- `ios/VoiceCode/Managers/AppSettings.swift:76-80` - `maxMessageSizeKB` stored in UserDefaults (static user setting)
- `ios/VoiceCode/Views/SettingsView.swift:148-149` - UI Stepper for adjusting max message size (50-250 KB range)
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:570-572` - Sends `set_max_message_size` once on connection
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:1525-1545` - `sendMessage()` logs failures but doesn't track size
- `backend/src/voice_code/server.clj:102` - `default-max-message-size-kb` constant (100 KB)
- `backend/src/voice_code/server.clj:153-158` - `get-client-max-message-size-bytes` returns fixed per-client value
- `backend/src/voice_code/server.clj:462` - Uses client's max-bytes for truncation decisions

**Findings**:
The implementation has **static payload sizing**, not adaptive. The max message size is configured once by the user and sent to the server on connection:

**Current Static Approach:**

1. **User-configured size limit** (not adaptive):
   - `maxMessageSizeKB` is a UserDefaults setting (default: 200 KB, range: 50-250 KB)
   - User manually adjusts via Settings → Stepper control
   - Value sent to backend once after `connect` message succeeds
   - Never changes during session regardless of network conditions

2. **No success/failure tracking by size**:
   - `sendMessage()` logs errors but doesn't record which sizes failed
   - No history of message delivery outcomes
   - No correlation between message size and delivery success rate
   - Error handler sets `currentError` for UI but doesn't inform sizing decisions

3. **No dynamic adjustment**:
   - Max size remains constant until user manually changes it
   - No automatic reduction on repeated failures
   - No escalation back up when network improves
   - No feedback loop from delivery outcomes to size configuration

4. **Server-side truncation is static**:
   - Backend uses client's `max-message-size-kb` for all responses
   - Truncation decision based on JSON byte count vs fixed limit
   - No adaptive behavior based on recent delivery success

**What the best practice recommends:**
- Track successful vs failed message deliveries by size ❌ (no tracking)
- Dynamically reduce max message size on repeated failures ❌ (no dynamic adjustment)
- Request smaller chunks from server when bandwidth is constrained ❌ (no chunk requests)

**Contrast with existing `set_max_message_size` protocol:**
The protocol exists for size configuration, but it's designed for static limits (iOS URLSessionWebSocketTask 256KB constraint), not adaptive bandwidth optimization. The message is sent once after auth, not in response to delivery failures.

**Gaps**:
1. No tracking of message delivery success/failure rates
2. No correlation of delivery outcomes with message sizes
3. No dynamic adjustment of max size based on delivery performance
4. No mechanism to request smaller chunks during bandwidth constraints
5. No escalation strategy to restore larger sizes when conditions improve

**Recommendations**:
1. **Track delivery outcomes with size metadata**:
   ```swift
   struct DeliveryAttempt {
       let messageSize: Int
       let succeeded: Bool
       let timestamp: Date
   }

   private var recentDeliveries: [DeliveryAttempt] = []

   func recordDelivery(size: Int, succeeded: Bool) {
       recentDeliveries.append(DeliveryAttempt(messageSize: size, succeeded: succeeded, timestamp: Date()))
       // Keep last 20 attempts
       if recentDeliveries.count > 20 {
           recentDeliveries.removeFirst()
       }
       adjustMaxSizeIfNeeded()
   }
   ```

2. **Implement adaptive size reduction**:
   ```swift
   func adjustMaxSizeIfNeeded() {
       let largeFailures = recentDeliveries.filter { $0.messageSize > currentMaxSize / 2 && !$0.succeeded }
       if largeFailures.count >= 3 {
           // Reduce max size by 25%
           let newSize = max(50, Int(Double(currentMaxSize) * 0.75))
           updateMaxMessageSize(newSize)
       }
   }
   ```

3. **Add escalation for recovery**:
   ```swift
   func checkForSizeEscalation() {
       let recentAll = recentDeliveries.suffix(10)
       if recentAll.allSatisfy({ $0.succeeded }) && currentMaxSize < userPreferredMaxSize {
           // Gradually restore toward user preference
           let newSize = min(userPreferredMaxSize, Int(Double(currentMaxSize) * 1.1))
           updateMaxMessageSize(newSize)
       }
   }
   ```

4. **Extend protocol for chunk requests** (future enhancement):
   ```json
   {
     "type": "request_chunked",
     "session_id": "...",
     "max_chunk_size_kb": 50,
     "reason": "bandwidth_constrained"
   }
   ```

**Assessment**: Low priority for current single-user deployment:
- **Current truncation works**: Server already handles iOS 256KB limit
- **User can manually adjust**: Settings UI provides control for edge cases
- **Single-user scenario**: No multi-client bandwidth competition
- **Implementation cost**: Medium - requires delivery tracking infrastructure
- **Recommendation**: Defer unless users report issues with message delivery on poor networks. The static approach with manual adjustment is sufficient for current use case. Would become valuable for:
  - Users frequently on degraded mobile networks (3G/edge)
  - Sessions with consistently large responses (code generation, logs)
  - Multi-device deployment where bandwidth varies significantly

#### 20. Use delta sync instead of full sync
**Status**: Implemented
**Locations**:
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:1120` - `subscribe(sessionId:)` sends `last_message_id` for delta sync
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:1148` - `getNewestCachedMessageId(sessionId:context:)` fetches newest cached message UUID
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:576-591` - Reconnection restores subscriptions with delta sync
- `ios/VoiceCode/Managers/SessionSyncManager.swift:141` - `handleSessionHistory()` merges new messages with existing
- `backend/src/voice_code/server.clj:259` - `build-session-history-response` implements delta sync algorithm
- `backend/src/voice_code/server.clj` - Subscribe handler extracts `last-message-id` and passes to response builder
- `STANDARDS.md:210-223` - Protocol documentation for `subscribe` message with `last_message_id`
- `STANDARDS.md:357-361` - Delta sync behavior documentation in `session_history` response
- `ios/VoiceCodeTests/VoiceCodeClientDeltaSyncTests.swift` - iOS delta sync unit tests
- `ios/VoiceCodeTests/SessionSyncManagerDeltaSyncTests.swift` - Session sync manager delta sync tests
- `backend/test/voice_code/server_test.clj` - Backend delta sync tests (`test-build-session-history-delta-sync`, etc.)

**Findings**:
The implementation **fully supports delta sync** for efficient reconnection bandwidth usage:

**iOS Client:**

1. **Sends `last_message_id` in subscribe requests** ✅
   - `subscribe(sessionId:)` calls `getNewestCachedMessageId()` to find newest cached message
   - If found, includes `last_message_id` in the subscribe message
   - Logs indicate delta sync mode: "Subscribing with delta sync, last: <id>"

2. **CoreData query for newest message** ✅
   - `getNewestCachedMessageId(sessionId:context:)` queries `CDMessage` sorted by timestamp descending
   - Returns UUID as lowercase string per STANDARDS.md convention
   - Handles invalid/empty session IDs gracefully (returns nil)

3. **Reconnection uses delta sync** ✅
   - `handleConnectedMessage()` restores active subscriptions after reconnection
   - Each subscription includes `last_message_id` if cached messages exist
   - Dramatically reduces bandwidth on network blips

4. **Merge strategy for incoming messages** ✅
   - `handleSessionHistory()` checks if messages array is empty (no new messages since last sync)
   - Empty response preserves existing messages (no wipe)
   - New messages merged with existing via `handleSessionUpdated()` logic

**Backend Server:**

1. **`build-session-history-response` algorithm** ✅
   - Finds index of `last-message-id` in message array
   - Returns only messages newer than that index
   - Falls back to all messages if ID not found (backward compatible)
   - Returns empty array when `last-message-id` is the newest message

2. **Smart truncation with newest-first priority** ✅
   - Works backwards from newest message
   - Adds messages until byte budget exhausted
   - Per-message truncation (20KB) prevents single large message from consuming budget
   - Returns `is-complete: false` when budget exhausted

3. **Response metadata** ✅
   - `oldest_message_id`: UUID of oldest message in response
   - `newest_message_id`: UUID of newest message in response
   - `is_complete`: Boolean indicating if all requested messages were included
   - `total_count`: Total messages in session (enables pagination awareness)

**Protocol Design:**
```json
// Subscribe request with delta sync
{
  "type": "subscribe",
  "session_id": "<claude-session-id>",
  "last_message_id": "<uuid-of-newest-message-ios-has>"
}

// Response with delta sync metadata
{
  "type": "session_history",
  "session_id": "<claude-session-id>",
  "messages": [...],  // Only messages newer than last_message_id
  "total_count": 150,
  "oldest_message_id": "<uuid>",
  "newest_message_id": "<uuid>",
  "is_complete": true
}
```

**Test Coverage:**
- `VoiceCodeClientDeltaSyncTests.swift`: Tests `getNewestCachedMessageId()` with various scenarios (multiple messages, no messages, invalid UUID, lowercase output)
- `SessionSyncManagerDeltaSyncTests.swift`: Tests `handleSessionHistory()` with empty messages preserving existing
- `server_test.clj`: Tests `build-session-history-response` for delta sync, budget exhaustion, unknown IDs, chronological ordering

**Best practice requirements:**
- Send `last_message_id` to request only new messages ✅
- Server returns diff, not complete state ✅
- Dramatically reduces bandwidth on reconnection ✅

**Gaps**: None identified.

**Recommendations**: None - implementation fully meets best practice.

### Intermittent Signal Handling

#### 21. Design for offline-first
**Status**: Partial
**Locations**:
- `ios/VoiceCode/Models/CDMessage.swift:8-12` - `MessageStatus` enum (`sending`, `confirmed`, `error`)
- `ios/VoiceCode/Views/ConversationView.swift:1139-1147` - UI indicators for message status (clock icon for sending, exclamation for error)
- `ios/VoiceCode/Managers/SessionSyncManager.swift:265` - Sets `messageStatus = .sending` for optimistic messages
- `ios/VoiceCode/Managers/ResourcesManager.swift:82-196` - File-based pending uploads queue
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:1060-1094` - `sendPrompt()` sends directly without queueing
- `ios/VoiceCode/Views/ConversationView.swift:772-774` - Creates optimistic message before sending

**Findings**:
The implementation has **partial offline-first support** with significant gaps:

**What's implemented:**

1. **Pending/synced status UI** ✅
   - `MessageStatus` enum with `sending`, `confirmed`, `error` states
   - UI shows clock icon for pending messages, exclamation for errors
   - Messages created optimistically with `.sending` status before server confirms

2. **Optimistic UI updates** ✅
   - `createOptimisticMessage()` adds user message immediately to CoreData
   - Message appears in conversation instantly without waiting for server
   - Status updated to `.confirmed` when server responds

3. **File uploads queue locally** ✅
   - `ResourcesManager` uses App Group container for pending uploads
   - Share Extension writes `.json` metadata + `.data` files
   - Main app processes queue when connected (`processPendingUploads()`)
   - Survives app termination, reboot, network changes

4. **Session sync on reconnection** ✅
   - Delta sync with `last_message_id` fetches only new messages
   - Session subscriptions restored automatically on reconnect

**What's NOT implemented:**

1. **No prompt queueing when offline** ❌
   - `sendPrompt()` calls `sendMessage()` directly without checking connection state
   - If WebSocket is disconnected, prompt is silently dropped
   - No persistent queue for prompts to retry on reconnection
   - Contrast with file uploads which ARE queued

2. **No automatic retry for failed prompts** ❌
   - Messages can get `.error` status but no automatic retry mechanism
   - User must manually resend failed messages

3. **Limited status feedback** ⚠️
   - No explicit "queued offline" vs "sending" distinction
   - No message count badge showing pending items
   - Error state exists but no UI to retry individual messages

**Best practice requirements:**
- Queue actions locally when offline ❌ (only file uploads queued, not prompts)
- Sync when connection restored ✅ (session history syncs)
- Show pending/synced status in UI ✅ (clock/exclamation icons)

**Gaps**:
1. Prompts sent while offline are dropped, not queued
2. No persistent prompt queue that survives app restart
3. No retry mechanism for failed message sends
4. No offline detection before attempting to send

**Recommendations**:
1. **Add prompt queue to CoreData**: Store prompts with `pending` status before sending
   ```swift
   // In sendPrompt():
   let pendingPrompt = savePendingPrompt(text, sessionId, workingDirectory)
   if isConnected {
       sendPendingPrompt(pendingPrompt)
   }
   // On reconnect: iterate pending prompts and send
   ```

2. **Flush prompt queue on connection**: When WebSocket connects, send all pending prompts in order
   ```swift
   voiceCodeClient.$isConnected
       .filter { $0 }
       .sink { _ in self.sendPendingPrompts() }
   ```

3. **Add retry button for error messages**: Let users tap failed messages to retry

4. **Show offline indicator**: Display "Offline - messages queued" when disconnected with pending items

#### 22. Implement optimistic UI with rollback
**Status**: Partial
**Locations**:
- `ios/VoiceCode/Models/CDMessage.swift:8-12` - `MessageStatus` enum (`sending`, `confirmed`, `error`)
- `ios/VoiceCode/Managers/SessionSyncManager.swift:237-288` - `createOptimisticMessage()` creates message with `.sending` status
- `ios/VoiceCode/Managers/SessionSyncManager.swift:290-312` - `reconcileMessage()` updates status to `.confirmed`
- `ios/VoiceCode/Managers/SessionSyncManager.swift:379-408` - Reconciliation in `handleSessionUpdated()`
- `ios/VoiceCode/Views/ConversationView.swift:771-774` - Creates optimistic message before sending prompt
- `ios/VoiceCode/Views/ConversationView.swift:1139-1147` - UI indicators: clock icon for `.sending`, exclamation for `.error`
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:664-670` - Session unlock on error (but no message status update)
- `ios/VoiceCodeTests/OptimisticUITests.swift:1-112` - Tests for optimistic message creation

**Findings**:
The implementation has **optimistic UI** but lacks **rollback** on server rejection:

**What's implemented (Optimistic UI):**

1. **Immediate UI update on user action** ✅
   - When user sends prompt, `createOptimisticMessage()` immediately creates a `CDMessage` in CoreData
   - Message appears instantly in conversation with `messageStatus = .sending`
   - No waiting for server confirmation before showing the message

2. **Asynchronous server confirmation** ✅
   - Prompt sent to backend via WebSocket while message is already visible
   - When backend echoes user message in `session_updated`, `reconcileMessage()` finds the optimistic message by matching `(sessionId, role, text)`
   - Status updated from `.sending` to `.confirmed`
   - `serverTimestamp` populated with backend's authoritative timestamp

3. **Visual status indicators** ✅
   - `.sending`: Clock icon (⏱️) in caption
   - `.error`: Red exclamation triangle icon (⚠️) in caption
   - `.confirmed`: No indicator (message appears normal)

4. **Session locking** ✅
   - Optimistic session lock (`lockedSessions.insert`) prevents duplicate sends
   - Lock released on `turn_complete` or `error` response

**What's NOT implemented (Rollback):**

1. **No rollback on server rejection** ❌
   - When backend returns `error` message type, the session is unlocked (line 665-670)
   - But the optimistic message's status is **not** updated to `.error`
   - Message remains with `.sending` status indefinitely (visual inconsistency)
   - No code path sets `messageStatus = .error` based on server response

2. **No retry mechanism** ❌
   - Error messages show exclamation icon but there's no tap-to-retry functionality
   - Users cannot resend failed messages without manually re-typing
   - The `.error` state exists in the enum but is never set by the error handler

3. **No deletion of failed messages** ❌
   - Alternative to rollback: delete the optimistic message on failure
   - Currently not implemented - failed sends leave orphan messages

4. **No timeout for unconfirmed messages** ❌
   - If `session_updated` never arrives (e.g., backend crash), message stays `.sending` forever
   - No background job to detect and mark stale `.sending` messages as `.error`

**Best practice requirements:**
- Update UI immediately on user action ✅ (optimistic message created)
- Confirm with server asynchronously ✅ (reconciliation on `session_updated`)
- Rollback UI if server rejects ❌ (error handler doesn't update message status)

**Gaps**:
1. Error response handler doesn't update optimistic message status to `.error`
2. No mechanism to identify which optimistic message corresponds to a failed prompt
3. No timeout handling for messages stuck in `.sending` status
4. No retry UI for error messages

**Recommendations**:
1. **Track optimistic message ID for rollback**: Store the message ID when sending prompt
   ```swift
   // In sendPrompt():
   var pendingMessageId: UUID?
   syncManager.createOptimisticMessage(sessionId: session.id, text: text) { messageId in
       pendingMessageId = messageId
   }
   // Store pendingMessageId for use in error handler
   ```

2. **Update message status on error**: When error response received with session_id, find and update the pending message
   ```swift
   // In handleMessage() "error" case:
   if let sessionId = json["session_id"] as? String,
      let sessionUUID = UUID(uuidString: sessionId) {
       sessionSyncManager.markOptimisticMessageAsError(sessionId: sessionUUID)
   }
   ```

3. **Add `markOptimisticMessageAsError()` method** to SessionSyncManager:
   ```swift
   func markOptimisticMessageAsError(sessionId: UUID) {
       persistenceController.performBackgroundTask { context in
           let request = CDMessage.fetchRequest()
           request.predicate = NSPredicate(
               format: "sessionId == %@ AND status == %@",
               sessionId as CVarArg, MessageStatus.sending.rawValue
           )
           if let messages = try? context.fetch(request) {
               for message in messages {
                   message.messageStatus = .error
               }
               try? context.save()
           }
       }
   }
   ```

4. **Add retry functionality**: Tap error message to retry sending
   ```swift
   // In MessageBubble:
   if message.messageStatus == .error {
       Button("Tap to retry") {
           onRetry(message)
       }
   }
   ```

5. **Add timeout for stale messages**: Background task to mark old `.sending` messages as `.error`
   ```swift
   // Run periodically (e.g., on app foreground)
   func timeoutStaleSendingMessages(olderThan: TimeInterval = 60) {
       let cutoff = Date().addingTimeInterval(-olderThan)
       // Find messages with status=sending and timestamp < cutoff
       // Update their status to .error
   }
   ```

#### 23. Use request coalescing
**Status**: Not Implemented
**Locations**:
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:574-598` - Subscription restoration loop sends individual messages
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:1525-1546` - `sendMessage()` sends immediately without queueing
- `ios/VoiceCodeTests/VoiceCodeClientDebounceTests.swift:1-256` - Debounce tests (incoming updates, not outgoing requests)

**Findings**:
The implementation does **not** implement request coalescing. On reconnection, outgoing messages are sent individually rather than batched, and there's no deduplication of redundant requests.

**What request coalescing addresses:**
Request coalescing is a client-side optimization that:
1. **Batches multiple pending requests** into a single message when possible
2. **Deduplicates redundant requests** (e.g., multiple status checks for the same resource)
3. **Reduces reconnection burst load** on the server

**Current behavior:**

1. **Individual message sending** ❌
   - `sendMessage()` sends each message immediately via WebSocket
   - No outgoing message queue or batching mechanism
   - On reconnection, subscription restoration sends N individual `subscribe` messages (line 578-598):
     ```swift
     for sessionId in self.activeSubscriptions {
         // Sends individual subscribe message for each session
         sendMessage(message)
     }
     ```

2. **No request deduplication** ❌
   - Multiple calls to `subscribe(sessionId:)` for the same session send duplicate messages
   - Multiple `ping` calls are sent individually (though this is appropriate for pings)
   - No tracking of "in-flight" requests to avoid duplicates

3. **No batching protocol** ❌
   - Protocol doesn't support batch operations (e.g., `subscribe_batch` for multiple sessions)
   - Each operation requires its own message round-trip

**Impact:**
- **Reconnection burst**: When client reconnects with N active subscriptions, it sends N+1 messages in rapid succession (`connect` + N `subscribe` messages)
- **Server load**: Backend processes N separate subscription requests instead of one batch
- **Potential race conditions**: Rapid individual messages could interleave with server responses

**What IS implemented (related but different):**

1. **UI update debouncing** (incoming, not outgoing) ✅
   - `VoiceCodeClientDebounceTests` tests debouncing of incoming server messages
   - Multiple rapid `session_locked` messages batch into single UI update
   - This optimizes UI rendering, not network requests

2. **Delta sync** (reduces payload size, not request count) ✅
   - Subscription includes `last_message_id` for incremental sync
   - Reduces response payload, but doesn't reduce number of requests

**Best practice requirements:**
- Batch multiple pending requests into single message ❌ (each request sent individually)
- Deduplicate redundant requests ❌ (no deduplication mechanism)
- Reduce reconnection burst load ❌ (N subscriptions = N messages)

**Gaps**:
1. No outgoing message queue for batching
2. No protocol support for batch subscribe operations
3. No request deduplication before sending
4. Reconnection sends burst of individual messages

**Recommendations**:
1. **Add batch subscribe protocol message** (backend + iOS):
   ```json
   Client → Backend: {
     "type": "subscribe_batch",
     "sessions": [
       {"session_id": "uuid-1", "last_message_id": "msg-uuid-1"},
       {"session_id": "uuid-2", "last_message_id": "msg-uuid-2"}
     ]
   }
   ```
   Backend responds with single `session_history_batch` containing all sessions.

2. **Coalesce subscriptions on reconnection**:
   ```swift
   // Instead of individual messages:
   if !self.activeSubscriptions.isEmpty {
       let sessions = activeSubscriptions.map { sessionId in
           ["session_id": sessionId, "last_message_id": getNewestCachedMessageId(sessionId: sessionId)]
       }
       sendMessage([
           "type": "subscribe_batch",
           "sessions": sessions
       ])
   }
   ```

3. **Add request deduplication** (optional, for high-frequency operations):
   ```swift
   private var pendingRequests = Set<String>()  // Track in-flight request keys

   func subscribe(sessionId: String) {
       let requestKey = "subscribe:\(sessionId)"
       guard !pendingRequests.contains(requestKey) else {
           print("Skipping duplicate subscribe request for \(sessionId)")
           return
       }
       pendingRequests.insert(requestKey)
       // ... send message, remove from set on response
   }
   ```

4. **Consider outgoing message queue** (for offline-first support from Item 21):
   If implementing offline prompt queueing, the queue could also coalesce and deduplicate requests before sending.

**Priority**: Low - Current behavior works correctly, just less efficiently. The typical case is 0-2 active subscriptions, so reconnection burst is minimal. Consider implementing if:
- Users frequently have many active sessions
- Server observability shows reconnection spikes causing issues
- Implementing offline queueing (Item 21) which would naturally include batching

#### 24. Handle half-open connections
**Status**: Not Implemented
**Locations**:
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:439-458` - `startPingTimer()` sends client-initiated pings
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:1115-1118` - `ping()` sends `{"type": "ping"}`
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:686-688` - `pong` handler (empty - just breaks)
- `backend/src/voice_code/server.clj:1051` - Server responds with pong (reactive only)

**Findings**:
The implementation does **not** handle half-open connections. A half-open connection occurs when TCP reports the connection as alive, but the peer is actually unreachable (e.g., server crashed, network path broken). The current ping/pong implementation only detects dead connections reactively, not proactively.

**What half-open connection handling requires:**
1. **Server sends periodic heartbeats**: Server proactively sends heartbeat messages on a timer (not just responding to client pings)
2. **Client expects server heartbeat**: Client tracks when last server heartbeat was received
3. **Missing heartbeat triggers reconnection**: If no server heartbeat arrives within the expected interval, client assumes connection is dead and reconnects

**Current implementation:**

1. **Client-initiated pings only** ❌
   - iOS client sends `ping` every 30 seconds (`pingInterval = 30.0`)
   - Server responds with `pong` synchronously in `handle-message`
   - No server-initiated heartbeats exist

2. **No pong timeout tracking** ❌
   - Client sends ping but doesn't track when pong should arrive
   - `pong` handler at line 686-688 is empty: `case "pong": break`
   - If pong never arrives, client has no mechanism to detect this
   - Connection appears alive until iOS's TCP layer times out (can take minutes)

3. **No server heartbeat timer** ❌
   - Backend has no scheduled task to send periodic messages to clients
   - `broadcast-to-all-clients!` function exists but isn't used for heartbeats
   - Server only sends messages in response to client requests

4. **Detection relies on TCP** ⚠️
   - Half-open connections are only detected when:
     - Client tries to send a message and TCP reports failure
     - iOS's URLSessionWebSocketTask layer times out (platform-dependent, often 60+ seconds)
   - During this window, user sees "Connected" but messages go into a black hole

**Scenario demonstrating the problem:**
1. Client connected, authenticated, sending pings every 30s
2. Server process crashes (or network path breaks silently)
3. Client's TCP socket still "looks" open (no FIN/RST received)
4. Client sends ping... no pong returns
5. Next ping 30s later... still no pong
6. Client continues showing "Connected" for potentially minutes
7. Eventually TCP times out and triggers reconnection

**Why this matters:**
- Users see "Connected" indicator when they can't actually communicate
- Prompts sent during this window appear to be sent but are never delivered
- Mobile networks often create half-open connections (tower handoffs, signal loss)
- iOS background/suspend can leave TCP in ambiguous state on foreground

**Best practice requirements:**
- Server sends periodic heartbeat messages (not just responding to pings) ❌
- Client expects server heartbeat within interval ❌
- Missing server heartbeat triggers reconnection ❌

**Gaps**:
1. No server-initiated heartbeat messages
2. Client doesn't track pong arrival time or timeout
3. No client-side "expected heartbeat" interval that triggers reconnection
4. Half-open connections can persist for minutes before detection

**Recommendations**:

1. **Add pong timeout tracking on iOS**: Track when ping was sent, expect pong within 10s
   ```swift
   private var lastPingSentAt: Date?
   private var pongTimeoutTimer: DispatchSourceTimer?
   private let pongTimeout: TimeInterval = 10.0  // 10 seconds

   func ping() {
       lastPingSentAt = Date()
       sendMessage(["type": "ping"])
       startPongTimeoutTimer()
   }

   private func startPongTimeoutTimer() {
       pongTimeoutTimer?.cancel()
       let timer = DispatchSource.makeTimerSource(queue: .main)
       timer.schedule(deadline: .now() + pongTimeout)
       timer.setEventHandler { [weak self] in
           guard let self = self else { return }
           self.logger.warning("⚠️ [VoiceCodeClient] Pong timeout - connection may be dead")
           // Force reconnection
           self.handleDeadConnection()
       }
       timer.resume()
       pongTimeoutTimer = timer
   }

   // In handleMessage for "pong":
   case "pong":
       pongTimeoutTimer?.cancel()
       pongTimeoutTimer = nil
       logger.debug("🏓 [VoiceCodeClient] Pong received")
   ```

2. **Add handleDeadConnection() helper**:
   ```swift
   private func handleDeadConnection() {
       logger.warning("🔌 [VoiceCodeClient] Detected dead connection, forcing reconnection")
       // Don't wait for TCP timeout - disconnect immediately
       webSocket?.cancel(with: .abnormalClosure, reason: nil)
       webSocket = nil
       isConnected = false
       stopPingTimer()
       // Trigger immediate reconnection (reset backoff since this is detection, not failure)
       reconnectionAttempts = 0
       connect()
   }
   ```

3. **(Optional) Add server-initiated heartbeats**: More robust but requires backend changes
   ```clojure
   ;; Backend: Start heartbeat timer per client
   (defn start-client-heartbeat! [channel]
     (let [timer (async/go-loop []
                   (async/<! (async/timeout 30000))  ; 30 seconds
                   (when (get @connected-clients channel)
                     (http/send! channel (generate-json {:type :heartbeat
                                                         :timestamp (System/currentTimeMillis)}))
                     (recur)))]
       (swap! connected-clients assoc-in [channel :heartbeat-timer] timer)))
   ```

   ```swift
   // iOS: Track server heartbeats
   private var lastServerHeartbeat: Date?
   private let serverHeartbeatTimeout: TimeInterval = 60.0  // Expect heartbeat every 30s, allow 60s buffer

   // In handleMessage:
   case "heartbeat":
       lastServerHeartbeat = Date()

   // In ping timer, also check server heartbeat:
   if let lastHeartbeat = lastServerHeartbeat,
      Date().timeIntervalSince(lastHeartbeat) > serverHeartbeatTimeout {
       handleDeadConnection()
   }
   ```

4. **Protocol addition** (for server heartbeats):
   ```markdown
   ### Server Heartbeat
   Backend → Client: {
     "type": "heartbeat",
     "timestamp": 1699876543210
   }
   Sent every 30 seconds to indicate server is alive.
   Client should reconnect if no heartbeat received within 60 seconds.
   ```

**Priority**: Medium-High - This affects user experience during network instability, which is common on mobile. The client-side pong timeout (Recommendation 1-2) is straightforward and provides significant benefit. Server heartbeats (Recommendation 3-4) provide additional robustness but require more work.

**Implementation approach**: Start with client-side pong timeout tracking - this is a self-contained iOS change that catches the most common half-open scenarios. Server heartbeats can be added later for belt-and-suspenders protection.

### App Lifecycle Resilience

#### 25. Persist pending messages to disk
**Status**: Partial
**Locations**:
- `ios/VoiceCode/Models/CDMessage.swift:8-12` - `MessageStatus` enum with `sending`, `confirmed`, `error` states
- `ios/VoiceCode/Managers/SessionSyncManager.swift:242-288` - `createOptimisticMessage()` creates CoreData message with `.sending` status before network call
- `ios/VoiceCode/Views/ConversationView.swift:771-807` - `sendPrompt()` creates optimistic message BEFORE sending to backend
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:1525-1546` - `sendMessage()` sends directly to WebSocket without retry queue

**Findings**:
The iOS client implements **partial** message persistence through CoreData:

1. **Optimistic messages are persisted**: User messages are saved to CoreData with `status = .sending` BEFORE the network request is made (`createOptimisticMessage()` is called before `sendMessage()`). This satisfies the "write to disk before sending" requirement.

2. **Message status tracking**: The `MessageStatus` enum tracks three states:
   - `.sending` - Optimistic, not yet confirmed by server
   - `.confirmed` - Server acknowledgment received
   - `.error` - Failed to send

3. **Reconciliation on server response**: When `session_updated` arrives from backend, the `handleSessionUpdated()` method reconciles optimistic messages by matching role and text, then updates status to `.confirmed`.

**What's missing**:

1. **No retry queue**: Messages with `.sending` status are not automatically retried on reconnection. If the app terminates after writing the optimistic message but before receiving server confirmation, the message is lost.

2. **No `status = .error` handling**: The code defines a `.error` status but it's never used. Failed sends don't update the message status.

3. **No orphan detection**: On app launch, there's no check for `.sending` messages that need to be retried or marked as failed.

4. **Delete from disk only after ACK**: The best practice says "delete from disk only after server ack" - but we don't delete messages, we update their status. However, there's no mechanism to detect messages that were never acknowledged.

5. **App termination scenario**: If the app is terminated (force quit, crash, or iOS kills it for memory) after `createOptimisticMessage()` but before backend processes the prompt:
   - Message exists in CoreData with `.sending` status
   - Backend never received the prompt
   - On next launch, no code checks for orphaned `.sending` messages

**Gaps**:
1. No retry queue for pending messages on reconnection
2. No startup check for orphaned `.sending` messages
3. No timeout/failure detection for messages stuck in `.sending` state
4. No user-visible indicator for pending messages that haven't been sent

**Recommendations**:
1. **Add startup orphan detection**: On app launch, query for messages with `status = .sending` older than a threshold (e.g., 30 seconds):
   ```swift
   func checkOrphanedMessages() {
       let request = CDMessage.fetchRequest()
       request.predicate = NSPredicate(format: "status == %@", MessageStatus.sending.rawValue)
       let orphans = try? context.fetch(request)
       for message in orphans ?? [] {
           if message.timestamp.timeIntervalSinceNow < -30 {
               message.messageStatus = .error
               // Or: retry sending
           }
       }
   }
   ```

2. **Add retry queue on reconnection**: When WebSocket reconnects after being disconnected, query for `.sending` messages and retry them:
   ```swift
   func retryPendingMessages(sessionId: UUID) {
       let request = CDMessage.fetchRequest()
       request.predicate = NSPredicate(
           format: "sessionId == %@ AND status == %@",
           sessionId as CVarArg,
           MessageStatus.sending.rawValue
       )
       // Resend to backend
   }
   ```

3. **Show pending indicator in UI**: Display a "sending..." indicator for messages with `.sending` status, with option to retry or cancel.

4. **Add failure timeout**: If a message stays in `.sending` for more than N seconds without server acknowledgment, update status to `.error` and notify user.

**Priority**: Medium-High - The current implementation provides partial resilience (messages survive brief disconnections during active session), but doesn't handle app termination scenarios. This is a common mobile scenario (user force quits app, iOS terminates for memory, crash). Users could lose important prompts they thought were sent.

#### 26. Use background URLSession for critical uploads
**Status**: Not Applicable / Partial
**Locations**:
- `ios/VoiceCodeShareExtension/ShareViewController.swift:354-418` - Uses foreground `URLSession.shared.dataTask` for HTTP uploads
- `ios/VoiceCode/Managers/ResourcesManager.swift:264-302` - Uses WebSocket for uploads from main app
- `ios/VoiceCode/Managers/ResourcesManager.swift:83-100` - Processes pending uploads from App Group on connection

**Findings**:
The best practice states: "iOS continues uploads even after app suspension. Completion handler called when app relaunched. **Essential for file uploads, not suitable for WebSocket.**"

The implementation has a **single upload path** with no fallback:

1. **Share Extension (HTTP uploads only)**:
   - Uses `URLSession.shared.dataTask(with:)` - a **foreground** data task
   - No background session configuration (`URLSessionConfiguration.background(withIdentifier:)`)
   - Share Extensions have limited execution time (~30 seconds from `viewDidLoad`)
   - If upload doesn't complete within this window, the extension is terminated and **upload is lost**
   - Current 60-second timeout (`uploadTimeout: TimeInterval = 60.0`) exceeds extension lifetime
   - **No fallback mechanism**: If HTTP upload fails, the file is not saved anywhere

2. **ResourcesManager (unused for Share Extension)**:
   - The main app has `ResourcesManager` with pending-uploads App Group directory
   - However, **the Share Extension does NOT write to this directory**
   - Share Extension only reads from App Group (for server settings at line 294-296)
   - The pending-uploads infrastructure exists but is not connected to Share Extension

**Why background URLSession matters for Share Extensions**:
- Background URLSession is the **only** way to guarantee upload completion from a Share Extension
- When the extension is suspended, iOS takes over the upload
- On completion (success or failure), iOS wakes the app to run the completion handler
- Without this, uploads for files >~1-2MB reliably fail due to extension time limits

**Current (flawed) resilience model**:
```
[User shares file]
      ↓
[Share Extension starts HTTP upload (foreground)]
      ↓
[If upload succeeds within ~30s] → Success
      ↓
[If upload fails/interrupted] → File is LOST (no fallback)
```

This provides **no delivery guarantee** for Share Extension uploads that exceed the extension lifetime.

**Gaps**:
1. Share Extension uses foreground URLSession, not background
2. Large files (>1-2MB) likely fail from Share Extension due to time limits
3. No completion handler registered for background task resumption
4. Upload timeout (60s) exceeds Share Extension lifetime (~30s)
5. **No fallback mechanism** - failed uploads are silently lost
6. ResourcesManager pending-uploads infrastructure is unused by Share Extension

**Recommendations**:
1. **Implement background URLSession for Share Extension uploads**:
   ```swift
   // In ShareViewController
   private lazy var backgroundSession: URLSession = {
       let config = URLSessionConfiguration.background(withIdentifier: "dev.910labs.voice-code.upload")
       config.sessionSendsLaunchEvents = true
       config.isDiscretionary = false // Upload immediately
       return URLSession(configuration: config, delegate: self, delegateQueue: nil)
   }()

   private func uploadData(data: Data, filename: String) {
       // Write data to temp file (background sessions require file URLs)
       let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
       try? data.write(to: tempURL)

       let task = backgroundSession.uploadTask(with: request, fromFile: tempURL)
       task.resume()
   }
   ```

2. **Handle background completion in main app**:
   ```swift
   // In AppDelegate or App struct
   func application(_ application: UIApplication,
                    handleEventsForBackgroundURLSession identifier: String,
                    completionHandler: @escaping () -> Void) {
       // Recreate session and store completion handler
       BackgroundUploadManager.shared.handleEventsForBackgroundURLSession(
           identifier: identifier,
           completionHandler: completionHandler
       )
   }
   ```

3. **Add App Group fallback in Share Extension**: Before starting HTTP upload, write file to pending-uploads directory so ResourcesManager can retry if HTTP fails:
   ```swift
   private func uploadData(data: Data, filename: String) {
       // FIRST: Write to App Group as fallback
       let uploadId = UUID().uuidString.lowercased()
       let pendingDir = containerURL.appendingPathComponent("pending-uploads")
       try? data.write(to: pendingDir.appendingPathComponent("\(uploadId).data"))
       // Write metadata...

       // THEN: Attempt HTTP upload
       // On success: delete from App Group
       // On failure: file remains for ResourcesManager to process
   }
   ```

4. **Reduce upload timeout**: Change `uploadTimeout` from 60s to 25s to fail fast within extension lifetime.

**Priority**: High - Currently **uploads can be silently lost** for large files or slow networks. This is data loss that users won't notice until they try to use the file. Either implement background URLSession or add the App Group fallback (simpler).

#### 27. Implement graceful degradation on background
**Status**: Partial
**Locations**:
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:93-131` - `setupLifecycleObservers()` registers for `didEnterBackgroundNotification` (iOS) and `didResignActiveNotification` (macOS)
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:146-148` - `handleAppEnteredBackground()` is an empty stub (only logs)
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:133-143` - `handleAppBecameActive()` reconnects on foreground
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:60` - `activeSubscriptions: Set<String>` persists subscription state in memory
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:575-593` - Subscription restoration on reconnection with delta sync
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:1120-1140` - `subscribe()` stores `last_message_id` for delta sync
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:1148-1168` - `getNewestCachedMessageId()` retrieves newest cached message ID from CoreData

**Findings**:
The implementation has **partial** graceful degradation with good foreground restoration but incomplete background handling:

**Best practice requirements:**
1. Close WebSocket cleanly before suspension ❌
2. Store connection state (last message ID, session info) ✅
3. Restore state on foreground, not full re-sync ✅

**What's implemented:**

1. **Connection state storage** ✅
   - `activeSubscriptions: Set<String>` tracks which sessions the client is subscribed to
   - CoreData stores all messages with their backend-assigned UUIDs
   - `getNewestCachedMessageId()` queries CoreData to find the newest message ID for any session
   - Session info (working directory, Claude session ID) persists in CoreData via `CDSession` entities

2. **Foreground restoration with delta sync** ✅
   - On reconnection, `activeSubscriptions` is preserved and all subscriptions are restored
   - Each subscription includes `last_message_id` for delta sync (lines 581-592)
   - Backend returns only messages newer than `last_message_id`, avoiding full re-sync
   - This is highly efficient for reconnection after brief background periods

3. **App lifecycle hooks exist** ✅
   - iOS: `didEnterBackgroundNotification` triggers `handleAppEnteredBackground()`
   - macOS: `didResignActiveNotification` triggers `handleAppEnteredBackground()`
   - Foreground: `willEnterForegroundNotification` / `didBecomeActiveNotification` trigger `handleAppBecameActive()`

**What's NOT implemented:**

1. **No proactive WebSocket close on background** ❌
   - `handleAppEnteredBackground()` only logs: `print("📱 [VoiceCodeClient] App entering background")`
   - WebSocket remains open until iOS suspends the app and the connection times out
   - This can lead to:
     - Server holding stale connection state
     - Unpredictable disconnection timing
     - Missed opportunity to send final "going away" message

2. **No graceful close code** ❌
   - When iOS suspends the app, the WebSocket is terminated abruptly (not closed cleanly)
   - Backend sees connection drop without close frame
   - Backend may buffer messages for replay that won't be received until much later

3. **activeSubscriptions not persisted to disk** ⚠️
   - If app is terminated (force quit, crash, iOS memory pressure), `activeSubscriptions` is lost
   - On next launch, subscriptions must be re-established manually
   - However: this is partially mitigated by `session_list` message on reconnection

**Current background flow:**
```
[App enters background]
      ↓
[handleAppEnteredBackground() logs only]
      ↓
[iOS eventually suspends app]
      ↓
[WebSocket times out (server-side) or disconnects on resume attempt]
      ↓
[App enters foreground]
      ↓
[handleAppBecameActive() reconnects]
      ↓
[Subscriptions restored with delta sync ✓]
```

**Recommended background flow:**
```
[App enters background]
      ↓
[Close WebSocket cleanly with .goingAway code]
      ↓
[activeSubscriptions preserved in memory]
      ↓
[iOS suspends app]
      ↓
[App enters foreground]
      ↓
[Reconnect WebSocket]
      ↓
[Restore subscriptions with delta sync]
```

**Gaps**:
1. `handleAppEnteredBackground()` doesn't close WebSocket cleanly
2. No "going away" close code sent to server before suspension
3. `activeSubscriptions` not persisted to disk (lost on app termination)
4. Backend may hold stale connection until timeout

**Recommendations**:
1. **Close WebSocket cleanly on background**:
   ```swift
   private func handleAppEnteredBackground() {
       print("📱 [VoiceCodeClient] App entering background, closing WebSocket")
       // Stop timers
       stopPingTimer()
       reconnectionTimer?.cancel()
       reconnectionTimer = nil

       // Close WebSocket cleanly
       webSocket?.cancel(with: .goingAway, reason: "App backgrounded".data(using: .utf8))
       webSocket = nil

       // Update state (don't clear activeSubscriptions - needed for restore)
       DispatchQueue.main.async { [weak self] in
           self?.isConnected = false
           self?.lockedSessions.removeAll()
       }
   }
   ```

2. **Persist activeSubscriptions to UserDefaults** (optional, for app termination resilience):
   ```swift
   private func persistSubscriptions() {
       UserDefaults.standard.set(Array(activeSubscriptions), forKey: "activeSubscriptions")
   }

   private func loadPersistedSubscriptions() {
       if let subs = UserDefaults.standard.stringArray(forKey: "activeSubscriptions") {
           activeSubscriptions = Set(subs)
       }
   }
   ```

3. **Consider requestBackgroundTask for in-flight operations** (see Item 28):
   If there are pending operations (e.g., waiting for turn_complete), request background execution time to receive them before suspension.

**Priority**: Medium - Current implementation works well for typical usage (brief background periods followed by foreground return). The delta sync mechanism provides efficient state restoration. However, proactive WebSocket close would:
- Free server resources faster
- Provide cleaner disconnect semantics
- Enable server-side handling of "graceful" vs "abrupt" disconnections

#### 28. Request background execution time for cleanup
**Status**: Not Implemented
**Locations**:
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:146-148` - `handleAppEnteredBackground()` is an empty stub (only logs)
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:20` - `lockedSessions` tracks in-flight prompt operations
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:599-612` - `sendMessageAck()` sends acks for replay messages
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:1280-1287` - `sendMessageAck()` method implementation

**Findings**:
The implementation does **not** use `UIApplication.beginBackgroundTask` to request extra execution time when the app enters background. The best practice recommends:
1. Use `beginBackgroundTask` to complete in-flight operations
2. Send pending acks before suspension
3. Persist any unsynced state

**Current behavior:**
1. **No background task request**: `handleAppEnteredBackground()` only logs and does nothing else:
   ```swift
   private func handleAppEnteredBackground() {
       print("📱 [VoiceCodeClient] App entering background")
   }
   ```

2. **In-flight operations abandoned**: The `lockedSessions` set tracks Claude sessions currently processing prompts. When the app backgrounds:
   - These operations continue on the server
   - The response arrives while app is suspended
   - WebSocket connection eventually times out
   - Response may be lost or delayed until reconnection

3. **No pending ack handling**: When replay messages are received, `sendMessageAck()` is called immediately. However, if the app backgrounds between receiving a replay message and completing its processing, the ack may not be sent.

4. **State persistence is partial**: CoreData persists messages, but `lockedSessions` and `activeSubscriptions` are in-memory only and lost on termination.

**Scenarios where background task would help:**

1. **User sends prompt and immediately backgrounds**:
   - Current: WebSocket suspended, response lost until foreground
   - With background task: Extra ~30s to receive response before suspension

2. **Receiving replay messages during reconnection**:
   - Current: If user backgrounds during replay, acks may not send
   - With background task: Complete ack sends before suspension

3. **Graceful WebSocket close**:
   - Current: WebSocket left open, times out ungracefully
   - With background task: Send close frame, update state, then suspend

**Gaps**:
1. No `UIApplication.beginBackgroundTask` usage anywhere in codebase
2. `handleAppEnteredBackground()` is a no-op (only logs)
3. In-flight operations (`lockedSessions`) not completed before suspension
4. No mechanism to send pending acks before suspension
5. No persistence of `lockedSessions` or `activeSubscriptions` for recovery

**Recommendations**:
1. **Request background execution time on background entry**:
   ```swift
   private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

   private func handleAppEnteredBackground() {
       print("📱 [VoiceCodeClient] App entering background")

       #if os(iOS)
       // Request time to complete critical work
       backgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
           // Expiration handler - clean up and end task
           self?.completeBackgroundCleanup()
       }

       // Perform cleanup with time budget
       performBackgroundCleanup()
       #endif
   }

   private func performBackgroundCleanup() {
       // 1. If no in-flight operations, close immediately
       guard !lockedSessions.isEmpty else {
           completeBackgroundCleanup()
           return
       }

       // 2. Wait briefly for in-flight operations to complete
       // Set timeout shorter than background task expiration (~30s)
       DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
           self?.completeBackgroundCleanup()
       }
   }

   private func completeBackgroundCleanup() {
       // Close WebSocket cleanly
       stopPingTimer()
       reconnectionTimer?.cancel()
       reconnectionTimer = nil
       webSocket?.cancel(with: .goingAway, reason: "App backgrounded".data(using: .utf8))
       webSocket = nil

       DispatchQueue.main.async { [weak self] in
           self?.isConnected = false
       }

       // End background task
       #if os(iOS)
       if backgroundTaskID != .invalid {
           UIApplication.shared.endBackgroundTask(backgroundTaskID)
           backgroundTaskID = .invalid
       }
       #endif
   }
   ```

2. **Persist critical state before suspension**:
   ```swift
   private func persistStateForBackground() {
       // Save activeSubscriptions to UserDefaults
       UserDefaults.standard.set(Array(activeSubscriptions), forKey: "activeSubscriptions")

       // Optionally save lockedSessions for UI recovery
       UserDefaults.standard.set(Array(lockedSessions), forKey: "lockedSessions")
   }
   ```

3. **Add timeout for in-flight operations**: Rather than waiting indefinitely, set a reasonable timeout (5-10s) to receive responses for in-flight prompts before closing the connection.

**Priority**: Medium-High - This affects the user experience when backgrounding the app during active Claude interactions. Without background task:
- Responses to prompts sent just before backgrounding may be delayed
- WebSocket closes ungracefully (server sees disconnect, not intentional close)
- No opportunity to send pending acks or persist state

The implementation is straightforward and provides meaningful improvement for a common mobile usage pattern (user sends prompt, switches to another app while waiting).

### Network Transition Handling

#### 29. Handle WiFi to Cellular handoffs
**Status**: Not Implemented
**Locations**:
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:93-131` - `setupLifecycleObservers()` handles app lifecycle but not network interface changes
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:389-433` - `setupReconnection()` timer-based reconnection without interface awareness

**Findings**:
The implementation does **not** detect or handle WiFi-to-Cellular (or Cellular-to-WiFi) network handoffs. This is closely related to item 2 (network reachability) but focuses specifically on network interface changes rather than general connectivity.

**What happens during a network handoff:**
1. Device moves out of WiFi range while connected to WebSocket
2. iOS switches to cellular network
3. Original WebSocket connection becomes stale (bound to old interface)
4. TCP connection may remain "open" but be unusable (zombie connection)
5. Data packets route through new interface but server still expects old connection
6. Eventually fails with timeout or connection reset

**Current behavior:**
1. **No NWPathMonitor**: The codebase has no imports of the `Network` framework and no usage of `NWPathMonitor` to detect interface changes
2. **No interface change detection**: The client doesn't know when the active network interface changes (WiFi → Cellular or vice versa)
3. **Passive failure detection**: The client relies on WebSocket errors or ping/pong failures to detect dead connections
4. **Delayed recovery**: Without proactive reconnection, user may wait 30-60 seconds (ping interval + timeout) before reconnection starts

**Best practice recommends:**
- Monitor for network interface changes using `NWPathMonitor`
- Proactively reconnect on interface change (don't wait for failure)
- May need to re-resolve DNS on new network (handled automatically by URLSession)

**iOS implementation details:**
The `NWPathMonitor` provides `path.usesInterfaceType` to detect:
- `.wifi` - WiFi connection
- `.cellular` - Cellular connection
- `.wiredEthernet` - Wired (Mac only)

Changes in interface type can be detected by comparing current and previous `NWPath` values.

**Gaps**:
1. No `NWPathMonitor` to detect interface type changes
2. No proactive reconnection when WiFi ↔ Cellular switch occurs
3. No tracking of current network interface type
4. Relies on passive failure detection (ping timeout, WebSocket error)

**Recommendations**:
1. **Track interface type with NWPathMonitor** (extends item 2 implementation):
   ```swift
   import Network

   private var pathMonitor: NWPathMonitor?
   private var currentInterfaceType: NWInterface.InterfaceType?

   private func setupNetworkMonitoring() {
       pathMonitor = NWPathMonitor()
       pathMonitor?.pathUpdateHandler = { [weak self] path in
           self?.handlePathUpdate(path)
       }
       pathMonitor?.start(queue: DispatchQueue.global(qos: .utility))
   }
   ```

2. **Detect interface type changes and reconnect proactively**:
   ```swift
   private func handlePathUpdate(_ path: NWPath) {
       let newInterfaceType = determineInterfaceType(path)

       // Check for interface type change (WiFi ↔ Cellular)
       if let current = currentInterfaceType,
          let new = newInterfaceType,
          current != new {
           print("🔄 Network interface changed: \(current) → \(new)")

           // Proactively reconnect - don't wait for connection to fail
           DispatchQueue.main.async { [weak self] in
               self?.handleInterfaceChange()
           }
       }

       currentInterfaceType = newInterfaceType
   }

   private func determineInterfaceType(_ path: NWPath) -> NWInterface.InterfaceType? {
       if path.usesInterfaceType(.wifi) { return .wifi }
       if path.usesInterfaceType(.cellular) { return .cellular }
       if path.usesInterfaceType(.wiredEthernet) { return .wiredEthernet }
       return nil
   }

   private func handleInterfaceChange() {
       // Close current connection (it's bound to old interface)
       webSocket?.cancel(with: .goingAway, reason: "Network interface changed".data(using: .utf8))
       webSocket = nil

       // Immediate reconnection - reset backoff since this isn't a failure
       reconnectionAttempts = 0
       connect(sessionId: sessionId)
   }
   ```

3. **Log interface changes for debugging**:
   ```swift
   print("📶 Network interface: WiFi → Cellular")
   print("📶 Network interface: Cellular → WiFi")
   ```

4. **Consider interface type in connection quality metrics**: Cellular connections typically have higher latency than WiFi, which affects timeout tuning (see item 30).

**Relationship to other items:**
- **Item 2 (Reachability)**: This item focuses on interface changes; item 2 focuses on overall reachability (satisfied vs unsatisfied)
- **Item 30 (Path migration awareness)**: That item covers adjusting timeouts after interface change; this item covers detecting and reconnecting

**Priority**: Medium-High - Network handoffs are common on mobile devices (user walks from WiFi to cellular range). Without proactive handling:
- Connection becomes unresponsive for 30-60 seconds
- User may think app is broken
- Messages sent during handoff may be lost
- Poor user experience in mobile scenarios

#### 30. Implement path migration awareness
**Status**: Not Implemented
**Locations**:
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:35-36` - `pingTimer` with 30-second interval (no RTT tracking)
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:686-688` - `pong` handler is empty (doesn't calculate RTT)
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:1115-1118` - `ping()` sends message without recording timestamp
- No `NWPathMonitor` or `Network` framework imports anywhere in iOS codebase

**Findings**:
The implementation does **not** support path migration awareness. Path migration awareness means adjusting timeout/RTT expectations when the network interface changes, because different network types have different latency characteristics.

**Prerequisites that are also missing:**
1. **RTT tracking** (item 14): No round-trip time measurement exists. The `pong` handler is empty.
2. **Interface change detection** (item 29): No `NWPathMonitor` to detect WiFi ↔ Cellular transitions.

Without RTT tracking and interface change detection, path migration awareness cannot be implemented.

**Why this matters:**
- **WiFi typical RTT**: 10-50ms
- **Cellular 4G typical RTT**: 50-100ms
- **Cellular 3G typical RTT**: 100-500ms

When switching from WiFi to Cellular:
- If timeout was calibrated for WiFi (e.g., 100ms timeout at 3x 33ms RTT)
- Cellular's 150ms RTT would appear "slow" or trigger false timeouts
- Could cause unnecessary reconnections or degraded-connection warnings

**What best practice recommends:**
- New network may have different latency characteristics
- Reset RTT estimates after network change
- Adjust timeouts accordingly

**Current behavior:**
- No RTT baseline exists to reset
- No timeouts are adaptive (all hardcoded or infinite)
- Network interface changes aren't detected
- When reconnecting after interface change, client uses same fixed timeouts regardless of network type

**Gaps**:
1. No RTT tracking to establish baseline for any network type
2. No mechanism to detect network interface changed (prerequisite from item 29)
3. No RTT history reset after network change
4. No network-type-aware timeout configuration (WiFi vs Cellular defaults)

**Recommendations**:

1. **First implement prerequisites** (items 14 and 29):
   - RTT tracking: Record ping timestamp, calculate RTT on pong, maintain rolling average
   - Interface detection: Use `NWPathMonitor` to detect WiFi ↔ Cellular transitions

2. **Reset RTT history on interface change**:
   ```swift
   private func handleInterfaceChange(from oldType: NWInterface.InterfaceType?,
                                      to newType: NWInterface.InterfaceType?) {
       logger.info("📶 [VoiceCodeClient] Interface changed: \(String(describing: oldType)) → \(String(describing: newType))")

       // Reset RTT history - old measurements are invalid for new network
       rttHistory.removeAll()
       connectionQuality = .unknown

       // Optionally: set initial estimates based on network type
       if let type = newType {
           applyNetworkTypeDefaults(type)
       }
   }
   ```

3. **Apply network-type-specific defaults**:
   ```swift
   private func applyNetworkTypeDefaults(_ type: NWInterface.InterfaceType) {
       switch type {
       case .wifi:
           // WiFi: faster expected response, shorter initial timeout
           initialPongTimeout = 5.0  // 5 seconds
           logger.debug("📶 Using WiFi defaults (5s initial timeout)")
       case .cellular:
           // Cellular: higher latency expected, longer initial timeout
           initialPongTimeout = 10.0  // 10 seconds
           logger.debug("📶 Using Cellular defaults (10s initial timeout)")
       default:
           initialPongTimeout = 10.0  // Conservative default
       }
   }
   ```

4. **Adaptive timeout recalibration**:
   After network change, the adaptive timeout logic (from item 14 recommendation) will naturally recalibrate:
   ```swift
   private func calculatePongTimeout() -> TimeInterval {
       let baselineRtt = averageRtt
       if baselineRtt > 0 {
           // 3x baseline RTT, with network-type-aware bounds
           let multiplier: Double = 3.0
           let minTimeout = currentInterfaceType == .cellular ? 5.0 : 3.0
           let maxTimeout: Double = 30.0
           return min(max(baselineRtt * multiplier, minTimeout), maxTimeout)
       }
       return initialPongTimeout  // Use network-type default until calibrated
   }
   ```

**Relationship to other items:**
- **Item 14 (RTT tracking)**: Must implement RTT tracking first; this item extends it with reset-on-change
- **Item 29 (WiFi/Cellular handoff)**: Must implement interface detection first; this item extends it with RTT awareness
- **Item 16 (Slow vs dead)**: Network-aware timeouts help distinguish slow cellular from dead connection

**Priority**: Medium - This is an enhancement that builds on items 14 and 29. Should be implemented after those prerequisites are in place. Provides better user experience on mobile by avoiding false "degraded" warnings when switching from WiFi to Cellular.

**Implementation order**:
1. Item 14: RTT tracking (required)
2. Item 29: Interface change detection (required)
3. Item 30: Path migration awareness (this item)

#### 31. Handle captive portals
**Status**: Not Implemented
**Locations**:
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:489-514` - WebSocket receive failure handler
- `ios/VoiceCodeShareExtension/ShareViewController.swift:354-420` - HTTP upload error handling

**Findings**:
The implementation does **not** detect or handle captive portals. A captive portal is a network that requires authentication via a web page (common in hotels, airports, coffee shops) before allowing internet access.

**What captive portals do:**
- Intercept HTTP requests and return 302 redirects to a login page
- WebSocket connections fail silently or with generic network errors
- iOS `URLSessionWebSocketTask` receives errors like `NSURLErrorNotConnectedToInternet` or connection resets

**Current behavior:**
1. **WebSocket connections**: When the device connects to a captive portal network, WebSocket connections fail with generic errors. The client enters reconnection backoff loop, retrying indefinitely until max attempts (20) are exhausted.

2. **HTTP uploads (Share Extension)**: HTTP POST requests would receive 302 redirects to the captive portal login page. The current code handles `HTTPURLResponse` status codes but doesn't specifically detect redirects to login pages.

3. **User experience**: The app shows "Unable to connect" after exhausting retries, but doesn't explain that a captive portal may be blocking access. Users have no indication they need to open Safari and authenticate with the network.

**What the best practice recommends:**
- Detect redirect responses (302 to login page)
- Notify user instead of infinite retry
- Re-check connectivity after user interaction

**Detection approaches:**
1. **HTTP probe before WebSocket**: Make an HTTP request to a known endpoint and check if response is redirected to a different host
2. **iOS CaptiveNetwork API**: Use `NEHotspotHelper` to detect captive networks (requires special entitlement)
3. **System connectivity check**: Use `captive.apple.com` probe (what iOS uses) or monitor for `kCFErrorDomainCFNetwork` errors

**Gaps**:
1. No detection of captive portal networks
2. No specific error message for captive portal scenario
3. No guidance for users to open Safari and authenticate
4. No re-check mechanism after user authenticates with portal

**Recommendations**:
1. **Add captive portal detection probe**: Before WebSocket connection, make HTTP request to backend's HTTP endpoint (or a dedicated `/health` endpoint). If response redirects to different host, assume captive portal.
   ```swift
   func checkCaptivePortal() async -> Bool {
       let probe = URL(string: "http://\(serverHost):\(serverPort)/health")!
       let (_, response) = try? await URLSession.shared.data(from: probe)
       if let httpResponse = response as? HTTPURLResponse,
          (300...399).contains(httpResponse.statusCode) {
           return true  // Likely captive portal
       }
       return false
   }
   ```

2. **Show captive portal alert**: When detected, show alert: "This network requires login. Please open Safari to authenticate, then try again."
   ```swift
   func showCaptivePortalAlert() {
       let alert = UIAlertController(
           title: "Network Login Required",
           message: "This network requires authentication. Please open Safari to log in, then return to this app.",
           preferredStyle: .alert
       )
       alert.addAction(UIAlertAction(title: "Open Safari", style: .default) { _ in
           UIApplication.shared.open(URL(string: "http://captive.apple.com")!)
       })
       alert.addAction(UIAlertAction(title: "Retry", style: .default) { _ in
           self.forceReconnect()
       })
   }
   ```

3. **Pause reconnection on captive portal**: Don't burn through retry attempts when captive portal is detected. Wait for user to acknowledge alert before retrying.

4. **Re-check on foreground**: When app returns to foreground after user potentially authenticated with portal, automatically retry connection.

### Server-Side Resilience

#### 32. Implement server-side connection draining
**Status**: Not Implemented
**Locations**:
- `backend/src/voice_code/server.clj:2017-2029` - Graceful shutdown hook (saves state, no client notification)
- `backend/src/voice_code/server.clj:445-455` - `broadcast-to-all-clients!` function (exists but unused for draining)
- `backend/src/voice_code/server.clj:96` - `connected-clients` atom tracks active connections
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:538-1041` - Message handler (no "reconnect" message type)

**Findings**:
The implementation does **not** support server-side connection draining. Connection draining allows a server to notify clients before shutdown so they can gracefully reconnect to a new instance without experiencing connection failures.

**Current server shutdown behavior:**
1. JVM shutdown hook triggers (`Runtime/addShutdownHook`)
2. Filesystem watcher stopped (`repl/stop-watcher!`)
3. Session index saved to disk (`repl/save-index!`)
4. HTTP server stopped with 100ms timeout (`@server-state :timeout 100`)
5. Clients experience abrupt connection close

**What clients experience:**
- WebSocket connections terminate suddenly with no warning
- iOS clients enter reconnection backoff loop, burning through retry attempts
- If server restarts quickly, clients reconnect within 1-30s (depending on backoff)
- If server is down for extended period, clients exhaust 20 retry attempts (~17 min total)

**What the best practice recommends:**
- Before shutdown, send "reconnect" hint to clients
- Allow graceful migration to new server instance
- Clients reconnect to healthy instance proactively

**Infrastructure note:**
This is a single-server deployment (no load balancer), so "migrate to new instance" doesn't directly apply. However, draining would still improve restart UX.

**Gaps**:
1. No "reconnect" or "draining" message type in protocol
2. No client handling for server-initiated reconnection hint
3. Clients discover server is down only through connection failure
4. Backend doesn't notify clients before stopping WebSocket server

**Recommendations**:
1. **Add "draining" message type to protocol**: Server sends this before shutdown
   ```json
   Backend → Client: {
     "type": "draining",
     "message": "Server shutting down, please reconnect",
     "retry_after_ms": 5000
   }
   ```

2. **Broadcast draining message in shutdown hook**: Before closing connections
   ```clojure
   ;; In shutdown hook, before stopping server
   (broadcast-to-all-clients! {:type :draining
                               :message "Server shutting down"
                               :retry-after-ms 5000})
   (Thread/sleep 1000) ;; Give clients time to receive message
   ```

3. **Handle "draining" in iOS client**: Trigger immediate reconnection with delay
   ```swift
   case "draining":
       print("⚠️ [VoiceCodeClient] Server draining, will reconnect")
       let retryAfter = json["retry_after_ms"] as? Int ?? 5000
       disconnect() // Clean disconnect
       DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(retryAfter)) {
           self.connect()
       }
   ```

4. **Reset backoff on draining**: Client should not count draining-triggered disconnect against retry attempts (it's expected, not a failure)

#### 33. Use connection affinity with fallback
**Status**: Not Applicable (Single Server Architecture)
**Locations**:
- `ios/VoiceCode/Managers/AppSettings.swift:18-19` - Single `serverURL` and `serverPort` properties
- `ios/VoiceCode/Managers/AppSettings.swift:82-86` - `fullServerURL` computed property (single endpoint)
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:37` - Single `serverURL` property
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:358-373` - `updateServerURL()` for manual URL change
- `backend/src/voice_code/server.clj:92-98` - `connected-clients` atom (ephemeral channel routing)
- `backend/src/voice_code/replication.clj` - Filesystem-based session persistence (local only)

**Findings**:
This best practice is **not applicable** to the current architecture. Connection affinity with fallback is designed for multi-server deployments with load balancers, which this system does not have.

**Current architecture: Single server**

1. **Single server configuration** ✅ (by design)
   - iOS stores one `serverURL` and `serverPort` in AppSettings
   - No server pool, no load balancer, no failover configuration
   - Reconnection always targets the same single server

2. **Implicit session affinity**
   - Session affinity exists implicitly because there's only one server
   - All clients connect to the same backend instance
   - Session state is automatically available (single filesystem)

3. **Session persistence is local**
   - Session files stored in `~/.claude/projects/<project>/<session-id>.jsonl`
   - No replication between servers (would require external coordination)
   - Each server instance has independent session storage

4. **Ephemeral connection routing**
   - `connected-clients` atom maps WebSocket channel → client state
   - Channels exist only during active connections (not persistent)
   - No cross-server message routing capability

**What connection affinity would require:**
If multi-server deployment were needed in the future:
- Persistent session store (database, Redis, or replicated filesystem)
- Server discovery/registration mechanism
- Load balancer with sticky sessions (L7 session affinity)
- Cross-server session state replication
- Distributed locking for Claude CLI execution

**Why single server is appropriate here:**
- Personal/single-user deployment model
- Claude CLI sessions are local to machine running backend
- Session files live alongside Claude Code installation
- No horizontal scaling requirements identified

**Gaps**: None - single server architecture is intentional and appropriate for the use case.

**Recommendations**: None currently needed. If multi-server deployment becomes a requirement in the future:
1. Add server list configuration to iOS (with primary/fallback URLs)
2. Implement health check endpoint for server selection
3. Add session routing layer (external load balancer or application-level)
4. Consider centralized session state (Redis for session metadata, shared filesystem for .jsonl files)

#### 34. Implement circuit breaker pattern
**Status**: Partial
**Locations**:
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:38-40` - `reconnectionAttempts`, `maxReconnectionDelay`, `maxReconnectionAttempts` properties
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:389-433` - `setupReconnection()` with max attempts check
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:411-421` - Max attempts reached: shows error and stops retrying
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:351-356` - `forceReconnect()` resets attempts and reconnects
- `ios/VoiceCode/Views/ConversationView.swift:285-296` - Error display when connection fails

**Findings**:
The implementation has **partial circuit breaker behavior** with max retry limits, but lacks the key circuit breaker concept of "open/half-open/closed" states and automatic recovery attempts.

**What's implemented:**

1. **Maximum retry attempts** ✅
   - `maxReconnectionAttempts = 20` (approximately 17 minutes of retry time)
   - After 20 consecutive failures, reconnection stops permanently
   - User sees error: "Unable to connect to server after 20 attempts. Please check your server settings."

2. **Battery drain prevention** ✅ (partial)
   - Exponential backoff with jitter spreads out retries (1s → 2s → 4s → ... → 30s)
   - Maximum delay capped at 30 seconds
   - After max attempts, timer is cancelled completely (no more retries)
   - However: retries continue for full 17 minutes even if server is clearly down

3. **User-visible error state** ✅
   - `currentError` is displayed in red text at bottom of ConversationView
   - Error text is tappable to copy to clipboard
   - Shows specific message about max attempts reached

4. **Manual retry available** ✅
   - `forceReconnect()` method resets `reconnectionAttempts = 0` and immediately reconnects
   - User can tap connection status indicator to trigger manual reconnect
   - This is the "close circuit" mechanism - requires user action

**What's NOT implemented:**

1. **No automatic circuit reset** ❌
   - Classic circuit breaker pattern has "half-open" state where circuit automatically tries one probe request after cooldown
   - Current implementation: once max attempts reached, circuit stays "open" forever until user manually forces reconnect
   - Server could recover after 18 minutes, but client won't know unless user taps reconnect

2. **No early circuit open** ❌
   - Circuit opens only after 20 consecutive failures (~17 minutes)
   - Best practice suggests opening circuit after N failures (e.g., 3-5) within a time window
   - Current behavior: 20 minutes of failed retries before showing "service unavailable"

3. **No failure categorization** ❌
   - All failures count equally toward max attempts
   - Should distinguish between:
     - Connection refused (server down) → open circuit quickly
     - Timeout (server slow) → continue retrying
     - Auth error → stop immediately (already handled via `requiresReauthentication`)

4. **No health probe endpoint** ❌
   - No lightweight `/health` endpoint for quick connectivity checks
   - Could use HTTP health check before attempting full WebSocket connection
   - Would enable faster detection of server recovery

5. **No "service unavailable" distinct state** ⚠️
   - Current error message is generic: "Unable to connect to server after 20 attempts"
   - No distinct UI state for "circuit open - server unavailable"
   - No countdown or indicator showing when automatic retry will occur

**Best practice requirements:**
- After N consecutive failures, stop retrying temporarily ✅ (20 failures stops retrying permanently)
- Prevents battery drain on persistent server outage ⚠️ (partial - stops after 17 min, not immediately)
- Show "service unavailable" instead of endless spinner ✅ (shows error after max attempts)

**Gaps**:
1. Circuit opens too late (20 failures / ~17 minutes vs recommended 3-5 failures)
2. No automatic "half-open" recovery probes after cooldown
3. No failure type differentiation (connection refused should open circuit faster)
4. No health check endpoint for lightweight connectivity probes

**Recommendations**:

1. **Implement faster circuit opening**: Open circuit after 3-5 consecutive failures within 60 seconds
   ```swift
   private var consecutiveFailures = 0
   private var firstFailureTime: Date?
   private let circuitOpenThreshold = 5
   private let circuitOpenWindow: TimeInterval = 60.0

   private func recordFailure() {
       let now = Date()
       if let first = firstFailureTime,
          now.timeIntervalSince(first) > circuitOpenWindow {
           // Window expired, reset
           consecutiveFailures = 1
           firstFailureTime = now
       } else {
           consecutiveFailures += 1
           if firstFailureTime == nil {
               firstFailureTime = now
           }
       }

       if consecutiveFailures >= circuitOpenThreshold {
           openCircuit()
       }
   }
   ```

2. **Add automatic half-open probes**: After circuit opens, periodically probe for recovery
   ```swift
   private var circuitState: CircuitState = .closed  // closed, open, halfOpen
   private var circuitOpenedAt: Date?
   private let circuitCooldown: TimeInterval = 60.0  // 1 minute

   private func checkCircuitRecovery() {
       guard circuitState == .open,
             let openedAt = circuitOpenedAt,
             Date().timeIntervalSince(openedAt) > circuitCooldown else { return }

       // Transition to half-open, try one probe
       circuitState = .halfOpen
       print("🔌 [VoiceCodeClient] Circuit half-open, probing server...")
       connect()  // Single probe attempt
   }

   // On successful connection:
   func connectionSucceeded() {
       circuitState = .closed
       consecutiveFailures = 0
       firstFailureTime = nil
   }

   // On probe failure in half-open state:
   func probeFailedInHalfOpen() {
       circuitState = .open
       circuitOpenedAt = Date()  // Reset cooldown
   }
   ```

3. **Add health check endpoint**: Backend HTTP endpoint for lightweight probes
   ```clojure
   ;; In server.clj routes
   (GET "/health" [] {:status 200 :body "ok"})
   ```
   ```swift
   // iOS: Check health before full WebSocket connection
   func probeServerHealth() async -> Bool {
       let url = URL(string: serverURL.replacingOccurrences(of: "ws://", with: "http://")
                                     .replacingOccurrences(of: "wss://", with: "https://") + "/health")!
       do {
           let (_, response) = try await URLSession.shared.data(from: url)
           return (response as? HTTPURLResponse)?.statusCode == 200
       } catch {
           return false
       }
   }
   ```

4. **Differentiate failure types**: Connection refused should open circuit immediately
   ```swift
   private func categorizeFailure(_ error: Error) -> FailureCategory {
       let nsError = error as NSError
       switch nsError.code {
       case NSURLErrorCannotConnectToHost, NSURLErrorNotConnectedToInternet:
           return .serverDown  // Open circuit immediately
       case NSURLErrorTimedOut:
           return .timeout  // Continue retrying with backoff
       default:
           return .unknown  // Count toward threshold
       }
   }
   ```

5. **Add circuit state to UI**: Show distinct "Service Unavailable" state with auto-recovery countdown
   ```swift
   @Published var circuitState: CircuitState = .closed
   @Published var nextProbeIn: TimeInterval?  // Seconds until next probe

   // In UI:
   if client.circuitState == .open {
       VStack {
           Text("Server Unavailable")
               .font(.headline)
           if let nextProbe = client.nextProbeIn {
               Text("Retrying in \(Int(nextProbe))s")
                   .font(.caption)
           }
           Button("Retry Now") { client.forceReconnect() }
       }
   }
   ```

**Priority**: Medium - Current behavior works but wastes battery retrying for 17 minutes before giving up. Users on mobile networks may experience extended periods of failed retries when temporarily out of coverage. Implementing faster circuit opening (Recommendation 1) and half-open probes (Recommendation 2) would significantly improve UX with moderate implementation effort.

### Observability

#### 35. Log connection lifecycle events
**Status**: Partial
**Locations**:
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:136-147` - App lifecycle (foreground/background) logged with `print()`
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:282-297` - WebSocket state cleanup logged with `logger`
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:304-315` - `connect()` logs URL and task resumed
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:328-345` - `disconnect()` logs lock clearing
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:401-426` - Reconnection attempts logged
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:491-511` - Connection failures logged with `logger.error`
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:542-565` - Hello/connected messages logged
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:674-683` - Auth errors logged
- `ios/VoiceCode/Managers/LogManager.swift:27-38` - Central log capture with timestamps
- `backend/src/voice_code/server.clj:1952` - `"WebSocket connection established"` with remote-addr
- `backend/src/voice_code/server.clj:1971` - `"WebSocket connection closed"` with status
- `backend/src/voice_code/server.clj:1057` - `"Client connected and authenticated"`
- `backend/src/voice_code/server.clj:424` - `"Client authenticated successfully"`
- `backend/src/voice_code/server.clj:397` - `"Authentication failed"` with reason

**Findings**:
Connection lifecycle logging is **partially implemented** with significant gaps:

**What's implemented:**

1. **iOS connection events** ✅
   - Connect attempt: `"Connecting to WebSocket: <url>"` (line 304)
   - Hello received: `"Received hello from server, connection confirmed"` (line 542)
   - Connected: `"Session registered: <message>"` (line 562)
   - Disconnect: Logs lock clearing (line 345)
   - Reconnection attempts: Logs attempt count and delay (line 426)
   - Max attempts reached: Logs error message (line 414)
   - Auth errors: Logs and sets `requiresReauthentication` (line 674-679)

2. **iOS failure logging** ✅
   - WebSocket receive failures: `logger.error` with localized description (line 491)
   - JSON parse failures: Logged with message prefix (line 525)
   - Missing API key: Logged with error (line 1242)

3. **Backend connection events** ✅
   - Connection established: `"WebSocket connection established"` with `remote-addr` (line 1952)
   - Connection closed: `"WebSocket connection closed"` with status (line 1971)
   - Authentication: Logs success/failure with reason (lines 397, 424)
   - Client authenticated: `"Client connected and authenticated"` (line 1057)

**What's NOT implemented:**

1. **No network type logging** ❌
   - iOS doesn't log whether connection is on WiFi, cellular, or captive network
   - Backend doesn't log network characteristics
   - Critical for debugging intermittent connectivity issues

2. **No timestamp correlation** ⚠️
   - iOS uses `print()` and `logger` interchangeably
   - `print()` has no timestamp; `LogManager.shared.log()` adds timestamp
   - Some connection events use `print()`, others use `LogManager`
   - Makes log correlation difficult

3. **Mixed logging mechanisms** ⚠️
   - `print()` statements go to Xcode console but not LogManager
   - `logger` (OSLog) goes to system logs but not LogManager
   - `LogManager.shared.log()` captures to in-memory buffer for debug view
   - Connection lifecycle logs are split across all three

4. **No RTT/latency logging** ❌
   - Ping/pong cycle doesn't log round-trip time
   - No visibility into connection quality degradation

5. **Incomplete failure reasons** ⚠️
   - Backend logs generic "WebSocket connection closed" without distinguishing:
     - Normal close (user disconnected)
     - Error close (network failure)
     - Timeout close (no heartbeat)
   - iOS logs `error.localizedDescription` which may be vague

**Best practice requirements:**
- Connect, disconnect, reconnect with timestamps ⚠️ (logged, but timestamps inconsistent)
- Failure reasons (timeout, auth, server error) ⚠️ (some reasons, not all)
- Network type at time of event ❌ (not implemented)

**Gaps**:
1. Network type (WiFi/cellular) not logged
2. Connection lifecycle events use inconsistent logging (print vs logger vs LogManager)
3. RTT/latency not logged for ping/pong cycles
4. Backend close reason not distinguished (normal vs error)
5. Timestamps not attached to all connection logs

**Recommendations**:
1. **Standardize iOS connection logging to LogManager**:
   ```swift
   // Replace all connection lifecycle print() with LogManager
   LogManager.shared.log(
       "WebSocket connected: \(serverURL)",
       category: "Connection"
   )
   ```

2. **Add network type to connection logs** (requires NWPathMonitor from Item 2):
   ```swift
   // After implementing NWPathMonitor
   LogManager.shared.log(
       "Connection established on \(networkType): \(serverURL)",
       category: "Connection"
   )
   ```

3. **Log RTT on ping/pong cycles**:
   ```swift
   let pingTime = Date()
   // After receiving pong:
   let rtt = Date().timeIntervalSince(pingTime)
   LogManager.shared.log(
       "Ping/pong RTT: \(Int(rtt * 1000))ms",
       category: "Connection"
   )
   ```

4. **Enhance backend close reason logging**:
   ```clojure
   (http/on-close channel
     (fn [status]
       (log/info "WebSocket connection closed"
                 {:status status
                  :close-reason (case status
                                  :normal "client disconnect"
                                  :going-away "client going away"
                                  :error "connection error"
                                  "unknown")
                  :duration-ms (- (System/currentTimeMillis)
                                  connection-start-time)})))
   ```

5. **Add connection duration to close logs**:
   - Track connection start time in `connected-clients` atom
   - Log duration on close for session length visibility

**Priority**: Medium - Current logging is sufficient for basic debugging but lacks the detail needed to diagnose intermittent mobile connectivity issues. Network type logging (Recommendation 2) is most valuable but requires NWPathMonitor from Item 2. Standardizing to LogManager (Recommendation 1) is low-effort and improves log coherence.

#### 36. Track client-side metrics
**Status**: Not Implemented
**Locations**:
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:38` - `reconnectionAttempts` counter (ephemeral, not persisted/reported)
- `ios/VoiceCode/Managers/LogManager.swift` - Basic log capture, no metrics aggregation
- `backend/src/voice_code/replication.clj:build-index!` - Logs `elapsed-ms` for index build (one-time operation)
- `backend/src/voice_code/commands.clj:spawn-process` - Tracks `duration-ms` for command execution
- `backend/src/voice_code/commands-history.clj:complete-session!` - Stores `duration-ms` per command

**Findings**:
Client-side metrics tracking is **not implemented**. The system has no mechanism to track or report connection health metrics over time.

**What the best practice recommends:**
1. **Connection success rate**: Track successful vs failed connection attempts over time
2. **Average reconnection time**: How long it takes to restore connection after disconnect
3. **Message delivery latency**: Time from sending prompt to receiving response
4. **Systemic issue identification**: Aggregate metrics to detect patterns (e.g., all users failing at same time = server issue)

**What's currently implemented:**

1. **Reconnection attempt counter** (ephemeral) ⚠️
   - `reconnectionAttempts` in VoiceCodeClient (line 38)
   - Incremented per attempt, reset on success
   - **Not persisted** - lost on app restart
   - **Not reported** - only used for backoff calculation
   - No success/failure rate calculation

2. **Command execution timing** (partial) ⚠️
   - Backend tracks `duration-ms` for shell commands
   - Stored in history index for later retrieval
   - This is for commands, not WebSocket/Claude interactions

3. **Prompt execution** ❌
   - No timing from prompt send to response received
   - No tracking of Claude CLI invocation duration
   - No latency metrics exposed to client

4. **Log manager** ❌
   - Captures text logs but no structured metrics
   - No aggregation or statistics
   - No time-series data

**What's NOT implemented:**

1. **No metrics collection infrastructure** ❌
   - No metrics store (in-memory or persistent)
   - No counters for connection success/failure
   - No timing histograms for latency

2. **No connection success rate** ❌
   - `reconnectionAttempts` tracks attempts but not outcomes
   - No ratio of successful connects vs total attempts
   - No trending over time (is it getting worse?)

3. **No average reconnection time** ❌
   - Reconnection delay is calculated, but time-to-successful-reconnect is not measured
   - Don't know: "After disconnect, how long until working again?"

4. **No message delivery latency** ❌
   - Prompt send time not recorded
   - Response receive time not correlated with send
   - No end-to-end latency measurement
   - No visibility into slow responses

5. **No metrics reporting/export** ❌
   - No telemetry to external service
   - No local dashboard or debug view
   - No way to aggregate across users to detect systemic issues

6. **No ping/pong RTT tracking** ❌
   - Pings sent every 30 seconds
   - Pong receipt not timed
   - No RTT metric calculated
   - No connection quality indicator based on latency

**Gaps**:
1. No connection success/failure counters
2. No reconnection duration tracking
3. No message delivery latency measurement
4. No ping/pong RTT metrics
5. No metrics persistence or reporting infrastructure
6. No way to detect systemic issues across sessions

**Recommendations**:

1. **Add ConnectionMetrics struct to iOS**:
   ```swift
   class ConnectionMetrics {
       // Counters
       var connectAttempts: Int = 0
       var connectSuccesses: Int = 0
       var connectFailures: Int = 0

       // Timing
       var lastDisconnectTime: Date?
       var reconnectionDurations: [TimeInterval] = []
       var pingRTTs: [TimeInterval] = []

       // Computed
       var successRate: Double {
           guard connectAttempts > 0 else { return 0 }
           return Double(connectSuccesses) / Double(connectAttempts)
       }
       var averageReconnectTime: TimeInterval {
           guard !reconnectionDurations.isEmpty else { return 0 }
           return reconnectionDurations.reduce(0, +) / Double(reconnectionDurations.count)
       }
       var averagePingRTT: TimeInterval {
           guard !pingRTTs.isEmpty else { return 0 }
           return pingRTTs.reduce(0, +) / Double(pingRTTs.count)
       }
   }
   ```

2. **Track connection outcomes in VoiceCodeClient**:
   ```swift
   // On successful connection (in handleMessage for "connected")
   metrics.connectSuccesses += 1
   if let disconnectTime = metrics.lastDisconnectTime {
       let reconnectDuration = Date().timeIntervalSince(disconnectTime)
       metrics.reconnectionDurations.append(reconnectDuration)
   }

   // On failed connection (in startListening catch block)
   metrics.connectFailures += 1

   // On disconnect
   metrics.lastDisconnectTime = Date()
   ```

3. **Track ping/pong RTT**:
   ```swift
   private var lastPingTime: Date?

   func ping() {
       lastPingTime = Date()
       sendMessage(["type": "ping"])
   }

   // In handleMessage for "pong"
   if let pingTime = lastPingTime {
       let rtt = Date().timeIntervalSince(pingTime)
       metrics.pingRTTs.append(rtt)
       // Keep last 100 RTTs for rolling average
       if metrics.pingRTTs.count > 100 {
           metrics.pingRTTs.removeFirst()
       }
   }
   ```

4. **Track message delivery latency**:
   ```swift
   private var pendingPromptTimes: [String: Date] = [:] // session-id -> send time

   func sendPrompt(...) {
       pendingPromptTimes[sessionId] = Date()
       sendMessage(...)
   }

   // In handleMessage for "response" or "turn_complete"
   if let sendTime = pendingPromptTimes.removeValue(forKey: sessionId) {
       let latency = Date().timeIntervalSince(sendTime)
       metrics.responseLatencies.append(latency)
   }
   ```

5. **Expose metrics in debug view**:
   - Add metrics summary to DebugLogsView
   - Show: success rate, avg reconnect time, avg RTT, avg response latency
   - Helps users diagnose their own connectivity issues

6. **Optional: Persist metrics to UserDefaults**:
   - Save daily aggregates for trending analysis
   - "Is my connection getting worse over time?"

**Priority**: Medium-Low - Metrics are valuable for debugging and understanding user experience issues, but the app functions without them. The most impactful metric would be ping/pong RTT (Recommendation 3) since it enables connection quality detection from Item 14. Implementing the basic ConnectionMetrics struct (Recommendation 1) provides a foundation for all other metrics.

#### 37. User-visible connection status
**Status**: Partial
**Locations**:
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:17` - `@Published var isConnected = false` (binary state)
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:351-356` - `forceReconnect()` for manual reconnection
- `ios/VoiceCode/Views/ConversationView.swift:242-257` - Connection status button UI
- `ios/VoiceCode/Views/AuthenticationRequiredView.swift` - Authentication error state view

**Findings**:
The iOS client implements user-visible connection status with partial coverage:

1. **States displayed**:
   - "Connected" (green dot) - when `isConnected = true`
   - "Disconnected" (red dot) - when `isConnected = false`

2. **Manual reconnection**: Users can tap the status indicator to trigger `forceReconnect()`, which resets backoff and reconnects immediately.

3. **Authentication errors**: A dedicated `AuthenticationRequiredView` shows when `requiresReauthentication = true`, displaying error message and QR scan/manual entry options.

4. **Location**: Connection status is visible only in `ConversationView` (bottom of chat). It is not visible in the main `DirectoryListView` project list.

**Gaps**:
1. **No "Connecting..." state** - The UI jumps directly from "Disconnected" to "Connected" with no intermediate state. Users see red during the multi-second reconnection process.

2. **No degraded connection indication** - There's no visual distinction between a healthy connection and a slow/degraded one (as would be detected by RTT monitoring from Item 14).

3. **Status not visible globally** - Connection status is only shown in conversation view. Users in the project list or settings don't know if they're connected.

4. **No reconnection progress** - During reconnection attempts, users don't see "Reconnecting (attempt 3/20)" or similar feedback.

5. **No "Offline" state** - There's no network-unavailable state distinct from server-unavailable (since NWPathMonitor isn't implemented per Item 2).

**Recommendations**:
1. **Add "Connecting..." state**:
   ```swift
   enum ConnectionState {
       case disconnected
       case connecting
       case connected
       case degraded  // Future: when RTT exceeds threshold
   }

   @Published var connectionState: ConnectionState = .disconnected
   ```
   Update UI to show yellow dot and "Connecting..." text during connection attempts.

2. **Show connection status globally**:
   - Add status indicator to navigation bar or toolbar in `DirectoryListView`
   - Use compact form (just colored dot) when space is limited
   - Consider adding to macOS menu bar for always-visible status

3. **Add reconnection progress feedback**:
   ```swift
   var statusText: String {
       switch connectionState {
       case .disconnected:
           if reconnectionAttempts > 0 {
               return "Reconnecting (\(reconnectionAttempts)/\(maxReconnectionAttempts))..."
           }
           return "Disconnected"
       case .connecting:
           return "Connecting..."
       case .connected:
           return "Connected"
       case .degraded:
           return "Slow Connection"
       }
   }
   ```

4. **Show "Offline" when network unreachable** (depends on Item 2):
   ```swift
   case .disconnected:
       if !networkPath.isReachable {
           return "Offline"
       }
   ```

5. **Avoid false "Connected" for degraded connections** (depends on Item 14):
   - If ping/pong RTT exceeds 2x baseline, show "Slow Connection" (yellow)
   - If pong not received within timeout, show "Connection Lost" (red)

**Priority**: Medium - Current "Connected/Disconnected" toggle works but leaves users uncertain during reconnection. The "Connecting..." state (Recommendation 1) is highest value for lowest effort. Global status (Recommendation 2) and progress feedback (Recommendation 3) provide significant UX improvements. Degraded state detection (Recommendation 5) depends on Item 14 implementation.

### Edge Cases

#### 38. Clock skew handling
**Status**: Partial
**Locations**:
- `ios/VoiceCode/Managers/SessionSyncManager.swift:682-689` - `extractTimestamp(from:)` parses server timestamps from backend messages
- `ios/VoiceCode/Managers/SessionSyncManager.swift:784-789` - Server timestamp used for message.timestamp when available
- `ios/VoiceCode/Managers/SessionSyncManager.swift:264` - Optimistic messages use client `Date()` initially
- `ios/VoiceCode/Models/CDMessage.swift:22` - `serverTimestamp` field stores authoritative server time
- `ios/VoiceCode/Models/CDMessage.swift:93` - Messages sorted by `timestamp` field for display
- `backend/test/voice_code/real_jsonl_test.clj:117-129` - Tests verify timestamps come from Claude CLI in ISO-8601 format

**Findings**:
The implementation **partially** follows this best practice:

1. **Server assigns authoritative timestamps**:
   - All message timestamps originate from Claude CLI which writes ISO-8601 timestamps to `.jsonl` session files
   - Backend passes these timestamps through to iOS unchanged
   - iOS parses and stores server timestamps via `extractTimestamp(from:)`

2. **Server timestamps used for ordering**:
   - Messages are sorted by `timestamp` field in CoreData
   - When server timestamp is available, it's used for both `timestamp` and `serverTimestamp` fields
   - `CDMessage.fetchMessages()` sorts ascending by timestamp for chronological display

3. **Protocol acknowledges out-of-order delivery**:
   - `STANDARDS.md:443` explicitly states: "No strict ordering: Messages may be delivered out of order. Timestamps provide ordering hints."

**Gaps**:
1. **Optimistic messages use client time**: When creating optimistic messages before server confirmation, iOS uses `Date()` (client clock) for the initial `timestamp`. This could cause ordering issues if the client clock is skewed:
   - Optimistic message created at client time T1
   - Server responds with timestamp T2 (could be before T1 if client clock ahead)
   - Message may appear out of order until reconciliation updates to server timestamp

2. **No clock skew detection or warning**: The system doesn't detect when client/server clocks are significantly different. Large skew (>30s) could cause confusing UI behavior during optimistic message display.

**Recommendations**:
1. **Use relative positioning for optimistic messages**: Instead of absolute timestamps, position optimistic messages after the most recent confirmed message and update position on server confirmation. This avoids clock skew issues entirely for optimistic UI.

2. **Add optional clock skew detection**: On first server response, compare server timestamp to client time. If skew exceeds threshold (e.g., 30 seconds), log a warning. This aids debugging without adding complexity:
   ```swift
   // In SessionSyncManager.handleSessionUpdated
   if let serverTime = extractTimestamp(from: messageData) {
       let skew = abs(serverTime.timeIntervalSinceNow)
       if skew > 30 {
           logger.warning("Clock skew detected: \(Int(skew))s between client and server")
       }
   }
   ```

#### 39. Protect against replay attacks
**Status**: Not Implemented
**Locations**:
- `backend/src/voice_code/auth.clj:26-34` - `generate-api-key` generates static 128-bit key
- `backend/src/voice_code/auth.clj:95-110` - `constant-time-equals?` compares keys securely (prevents timing attacks)
- `backend/src/voice_code/server.clj:403-425` - `authenticate-connect!` validates API key with no timestamp/nonce
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:1258-1261` - Connect message sends only `type`, `api_key`, `session_id`
- `ios/VoiceCode/Managers/AppSettings.swift:82-86` - `fullServerURL` constructs `ws://` URLs (not `wss://`)
- `STANDARDS.md:93-105` - Protocol spec defines connect message with no anti-replay fields

**Findings**:
The current implementation does **not** protect against replay attacks:

1. **Static pre-shared key**: Authentication uses a single static API key (`untethered-<32 hex chars>`) that never changes during the session lifetime. Once captured, this key can be used indefinitely.

2. **No nonce or timestamp**: The connect message contains only:
   - `type`: "connect"
   - `session_id`: iOS session UUID (optional)
   - `api_key`: The static key

   There is no nonce, timestamp, or challenge-response mechanism to prevent credential reuse.

3. **No stale credential rejection**: The backend performs simple key comparison with no time-based validation. A captured connect message can be replayed hours or days later.

4. **Unencrypted transport**: The production configuration uses `ws://` (WebSocket over HTTP), not `wss://` (WebSocket over TLS). The API key is transmitted in plaintext over the local network, making interception trivial for an attacker on the same network.

5. **Mitigating factors**:
   - The backend uses constant-time comparison to prevent timing attacks
   - The system is designed for local network use (developer machine to iOS device on same LAN)
   - Key has 128 bits of entropy (strong against brute force)

**Threat scenarios without replay protection**:
- **Network eavesdropping**: Attacker on same WiFi network captures plaintext connect message, replays to gain session control
- **Man-in-the-middle**: Attacker intercepts connection, captures API key, connects separately to backend
- **Session hijacking**: Captured credentials allow sending prompts to user's Claude sessions

**Gaps**:
1. **No transport encryption**: `ws://` used instead of `wss://` - API key transmitted in plaintext
2. **No nonce in connect message**: Same connect message can be replayed indefinitely
3. **No timestamp validation**: Backend doesn't reject stale authentication attempts
4. **No challenge-response**: No server-side challenge to prevent credential capture and reuse
5. **No session binding**: Once authenticated, no mechanism to verify subsequent messages came from same client

**Recommendations**:
1. **Enable TLS (High Priority)**: Switch from `ws://` to `wss://` to encrypt all traffic. This is the single most impactful change. Even without nonces, TLS prevents eavesdropping and passive replay attacks. The backend would need TLS certificate configuration.

2. **Add challenge-response authentication (Medium Priority)**:
   - Server sends random `challenge` in hello message
   - Client computes `response = HMAC-SHA256(api_key, challenge)`
   - Client sends `response` in connect message instead of raw `api_key`
   - Server verifies HMAC matches expected value
   - Challenge is single-use, preventing replay of captured responses

3. **Add timestamp with bounded validity (Low Priority with TLS)**:
   - Client includes `timestamp` in connect message
   - Server rejects if timestamp differs from server time by more than 30 seconds
   - Limits replay window to 30 seconds (requires approximate clock sync)

4. **Implement nonce tracking (Low Priority with TLS)**:
   - Server maintains set of recently-used nonces (last 5 minutes)
   - Client includes random `nonce` in connect message
   - Server rejects if nonce was already used
   - Completely prevents replay within tracking window

Note: For a local-network developer tool, TLS alone may be sufficient. Challenge-response adds significant complexity but provides stronger guarantees for security-sensitive deployments.

#### 40. Handle message corruption
**Status**: Partial
**Locations**:
- `backend/src/voice_code/server.clj:44-47` - `parse-json` function uses Cheshire for JSON parsing
- `backend/src/voice_code/server.clj:1828-1831` - `handle-message` outer try-catch catches all exceptions including parse errors
- `backend/src/voice_code/server.clj:1043` - Type field extraction with no explicit validation
- `backend/src/voice_code/server.clj:1820-1826` - Unknown message type returns error
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:517-534` - `handleMessage()` validates UTF-8, JSON parsing, and type field
- `ios/VoiceCode/Managers/VoiceCodeClient.swift:536-1000+` - Switch statement handling message types

**Findings**:
The implementation **partially** follows this best practice with both platforms handling parse errors gracefully without crashing, but with gaps in validation completeness and logging consistency:

**Backend (Clojure):**

1. **JSON parsing error handling** ✅
   - All message handling is wrapped in a try-catch block (`handle-message` lines 1828-1831)
   - JSON parse errors from Cheshire are caught along with all other exceptions
   - Server sends error response: `{"type": "error", "message": "Error processing message: <exception message>"}`
   - Server does not crash on malformed JSON

2. **Error logging** ⚠️
   - Parse errors are logged via `log/error` with exception stack trace
   - Gap: Only logs the exception message, not the actual malformed JSON content that caused the failure
   - Makes debugging difficult when clients send invalid payloads

3. **Type field validation** ⚠️
   - No explicit validation that `type` field exists before routing
   - If `type` is missing, `(:type data)` returns `nil`
   - `nil` type falls through to default handler which sends "Unknown message type" error
   - Works but no explicit log entry for "missing type field"

4. **Per-message field validation** ⚠️
   - Each message type has ad-hoc field validation (e.g., `session_id required in subscribe message`)
   - No centralized schema validation
   - Validation is inconsistent across message types

**iOS (Swift):**

1. **JSON parsing error handling** ✅
   - `handleMessage()` validates JSON parsing explicitly (line 524-528)
   - Uses `try?` with `JSONSerialization` - failures return early without crashing
   - Logs error with first 200 characters of the malformed message

2. **Type field validation** ✅
   - Explicitly checks for `type` field (lines 530-534)
   - Logs "Message missing 'type' field" with list of keys present
   - Returns early if type missing

3. **UTF-8 validation** ✅
   - Validates UTF-8 encoding before JSON parsing (lines 518-522)
   - Logs error if conversion fails

4. **Silent failures in field extraction** ⚠️
   - Many message types use optional chaining (`if let`) for field extraction
   - When optional extraction fails, message is silently ignored
   - Example: `replay` message with missing `text` field is ignored without logging
   - Inconsistent: some validation logs, some doesn't

5. **Unknown message types** ⚠️
   - Switch statement has no `default` case
   - Unknown message types are silently ignored
   - No logging when unrecognized message type received

**Gaps**:
1. **Backend: No malformed JSON logging** - When parse fails, the actual invalid JSON content is not logged, making debugging difficult
2. **Backend: No explicit type field check** - Missing `type` falls through to default handler silently
3. **iOS: Silent field extraction failures** - Optional extraction failures don't log what field was missing
4. **iOS: No default case** - Unknown message types are silently ignored
5. **Both: No schema validation** - Each message type has ad-hoc validation instead of centralized schema enforcement
6. **Both: No malformed message metrics** - No counters for how often invalid messages are received

**Recommendations**:
1. **Add detailed parse error logging to backend**:
   ```clojure
   (defn parse-json-safely
     "Parse JSON with detailed error logging"
     [s]
     (try
       (json/parse-string s snake->kebab)
       (catch Exception e
         (log/warn "Malformed JSON received:" (subs s 0 (min 500 (count s))))
         (throw e))))
   ```

2. **Add explicit type field validation to backend**:
   ```clojure
   (let [data (parse-json msg)
         msg-type (:type data)]
     (when-not msg-type
       (log/warn "Message missing type field:" (keys data))
       (send-error! channel "Message must have a 'type' field"))
     ;; ... continue processing
   ```

3. **Add default case to iOS switch statement**:
   ```swift
   default:
       logger.warning("⚠️ [VoiceCodeClient] Unknown message type: \(type)")
       LogManager.shared.log("Unknown message type: \(type)", category: "VoiceCodeClient")
   ```

4. **Add consistent field extraction logging to iOS**:
   ```swift
   case "replay":
       guard let messageData = json["message"] as? [String: Any] else {
           logger.warning("⚠️ [VoiceCodeClient] replay message missing 'message' field")
           return
       }
       guard let text = messageData["text"] as? String else {
           logger.warning("⚠️ [VoiceCodeClient] replay message missing 'text' field")
           return
       }
       // ... continue processing
   ```

5. **Consider JSON schema validation (optional)**: For critical message types, add schema validation to ensure all required fields are present with correct types before processing.

**Priority**: Low - Current implementation prevents crashes and handles errors gracefully. The gaps are primarily around debugging ergonomics (knowing what went wrong) rather than stability. Unknown message types being silently ignored is the most impactful gap for protocol evolution.

## Recommended Actions

### High Priority

These items have significant impact on reliability, user experience, or battery life.

**Network Reachability Monitoring** (Item 2)
- Add `NWPathMonitor` to VoiceCodeClient to detect network state changes
- Pause reconnection timer when network is unreachable (saves battery)
- Immediately reconnect when network becomes available (better UX)
- Foundation for items 29, 30 (network transition handling)

**WiFi to Cellular Handoff** (Item 29)
- Monitor for network interface changes via `NWPathMonitor`
- Proactively reconnect on interface change (don't wait for failure)
- Requires item 2 (Network Reachability) as prerequisite

**Half-Open Connection Detection** (Item 24)
- Add server-initiated heartbeats (not just client pings)
- Client expects server heartbeat within interval
- Detects zombie connections where server thinks client is gone but client thinks it's connected

**Background Execution for Cleanup** (Item 28)
- Use `beginBackgroundTask` to complete in-flight operations before suspension
- Send pending acks before app suspends
- Clean WebSocket disconnect on background (item 9)

**App Lifecycle - Clean Disconnect on Background** (Item 9)
- Close WebSocket gracefully when entering background
- Currently left open, dies when iOS suspends app
- Server wastes resources on connections to suspended clients

### Medium Priority

These items improve robustness and developer experience.

**Message Acknowledgment System** (Item 4)
- Implement undelivered message queue per iOS session in backend
- Attach `message_id` to response messages
- Replay unacknowledged messages on client reconnection
- Make `message-ack` handler remove messages from queue

**Offline Prompt Queueing** (Item 21)
- Add persistent prompt queue to CoreData
- Queue prompts when offline instead of silently dropping
- Flush queue in order when connection is restored

**Connection Quality Monitoring (RTT)** (Item 14)
- Track ping/pong round-trip times
- Detect degraded connections before they fail
- Foundation for item 16 (slow vs dead detection)

**Slow vs Dead Connection Detection** (Item 16)
- Distinguish slow connections (increase timeouts) from dead (reconnect)
- Progressive timeout increases before declaring dead
- Requires item 14 (RTT tracking)

**Application-Level Timeouts** (Item 15)
- Add read timeout for prompt responses (beyond TCP)
- Consider timeout per operation type (prompts longer than pings)
- TCP can keep dead connections open for minutes

**Circuit Breaker Pattern** (Item 34)
- After N consecutive failures, stop retrying temporarily
- Show "service unavailable" instead of endless spinner
- Prevents battery drain on persistent server outage

**Graceful Degradation on Background** (Item 27)
- Store connection state before suspension
- Restore subscriptions efficiently on foreground
- Persist last message IDs for delta sync

**Persist Pending Messages to Disk** (Item 25)
- Write outgoing prompts to disk before sending
- Delete from disk only after server ack
- Survives app termination

**User-Visible Connection Status** (Item 37)
- Show explicit "Connecting...", "Connected", "Offline" states
- Currently inferred from `isConnected` + `isAuthenticated`
- Add "Degraded" state for slow connections
- Manual reconnect button

**Idempotent Operations** (Item 12)
- Add message deduplication on backend
- Prevent duplicate prompts on reconnection/retry
- Use message IDs for deduplication

### Low Priority / Nice to Have

These items are valuable but have lower impact or are rarely needed.

**Message Prioritization** (Item 17)
- Queue outgoing messages by priority
- Send critical messages (auth, acks) before bulk data
- Only matters under severe congestion

**Message Compression** (Item 18)
- Use per-message compression for payloads over threshold
- WebSocket permessage-deflate extension
- Reduces bandwidth on slow connections

**Adaptive Payload Sizing** (Item 19)
- Track successful vs failed message deliveries by size
- Dynamically reduce max message size on repeated failures
- Complex to implement, marginal benefit

**Request Coalescing** (Item 23)
- Batch multiple pending requests into single message
- Deduplicate redundant requests
- Only relevant for high-volume scenarios

**Path Migration Awareness** (Item 30)
- Reset RTT estimates after network change
- Adjust timeouts for new network characteristics
- Depends on items 2, 14

**Captive Portal Detection** (Item 31)
- HTTP probe before WebSocket to detect redirect
- Show user-friendly alert
- Pause reconnection while user authenticates

**Server-Side Connection Draining** (Item 32)
- Send "reconnect" hint before server shutdown
- Graceful client migration to new instance
- Only relevant for zero-downtime deploys

**Client-Side Metrics** (Item 36)
- Track connection success rate, reconnection time, latency
- Export for monitoring/debugging
- Useful for diagnosing systemic issues

**Log Connection Lifecycle Events** (Item 35)
- Structured logging for connect/disconnect/reconnect
- Include network type, failure reasons
- Partially implemented, needs enhancement

**Optimistic UI Rollback** (Item 22)
- Track optimistic state for potential rollback
- Implement rollback mechanism on rejection
- Currently fire-and-forget

**Clock Skew Handling** (Item 38)
- Calculate clock offset from server timestamps
- Apply offset when comparing times
- Mostly handled by server-authoritative timestamps

**Replay Attack Protection** (Item 39)
- Add nonce/timestamp to auth messages
- Server rejects stale or reused credentials
- Low risk given pre-shared key model

**Battery Optimization** (Item 10)
- Add network-aware ping interval (shorter on WiFi)
- Batch non-urgent messages
- Mostly addressed by fixing item 2

**Message Corruption Handling** (Item 40)
- Log unknown message types (currently silent)
- Add structured validation logging
- Current implementation prevents crashes

### Not Applicable

**Connection Affinity with Fallback** (Item 33)
- Single-server architecture, not relevant
- Would be needed for multi-server deployment

**Background URLSession** (Item 26)
- Already using HTTP POST for file uploads
- Not suitable for WebSocket; alternative approach in place

## Implementation Dependencies

```
Item 2 (Reachability) ─┬─> Item 29 (WiFi/Cellular Handoff)
                       └─> Item 30 (Path Migration)
                       └─> Item 10 (Battery - network-aware ping)

Item 14 (RTT Tracking) ──> Item 16 (Slow vs Dead)
                       └─> Item 30 (Path Migration)

Item 9 (Background Disconnect) ──> Item 28 (Background Task)

Item 4 (Message Ack) ──> Item 25 (Persist Messages)
                     └─> Item 21 (Offline Queue)
```

## Implementation Notes

**Suggested Implementation Order:**

1. **Phase 1 - Network Awareness** (High impact, foundational)
   - Item 2: NWPathMonitor integration
   - Item 29: WiFi/Cellular handoff
   - Item 9: Clean disconnect on background

2. **Phase 2 - Connection Resilience**
   - Item 24: Server heartbeats
   - Item 14: RTT tracking
   - Item 16: Slow vs dead detection
   - Item 34: Circuit breaker

3. **Phase 3 - Message Reliability**
   - Item 4: Message acknowledgment
   - Item 21: Offline queue
   - Item 25: Persist pending messages

4. **Phase 4 - Polish**
   - Item 37: Connection status UI
   - Item 35: Structured logging
   - Remaining low-priority items as needed
