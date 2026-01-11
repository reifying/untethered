# WebSocket Implementation Recommendations

This document captures findings and recommendations from reviewing our WebSocket implementation against best practices.

## Summary

| Category | Reviewed | Gaps Found | Recommendations |
|----------|----------|------------|-----------------|
| Connection Management | 3/3 | 1 | 1 |
| Message Delivery | 2/2 | 2 | 2 |
| Authentication | 2/2 | 0 | 0 |
| Mobile-Specific | 2/3 | 4 | 4 |
| Protocol Design | 3/3 | 3 | 3 |
| Detecting Degraded Connections | 0/3 | - | - |
| Poor Bandwidth Handling | 0/4 | - | - |
| Intermittent Signal Handling | 4/4 | 16 | 16 |
| App Lifecycle Resilience | 0/4 | - | - |
| Network Transition Handling | 1/3 | 1 | 1 |
| Server-Side Resilience | 2/3 | 4 | 4 |
| Observability | 0/3 | - | - |
| Edge Cases | 0/3 | - | - |

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

<!-- Add findings for item 10 here -->

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

<!-- Add findings for items 14-16 here -->

### Poor Bandwidth Handling

<!-- Add findings for items 17-20 here -->

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

<!-- Add findings for items 25-28 here -->

### Network Transition Handling

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

<!-- Add findings for item 34 here -->

### Observability

<!-- Add findings for items 35-37 here -->

### Edge Cases

<!-- Add findings for items 38-40 here -->

## Recommended Actions

### High Priority

**Network Reachability Monitoring** (Item 2)
- Add `NWPathMonitor` to VoiceCodeClient to detect network state changes
- Pause reconnection timer when network is unreachable (battery savings)
- Immediately reconnect when network becomes available (better UX)
- See [Network Transition Handling findings](#2-network-transition-handling-reachability) for full details

### Medium Priority

**Message Acknowledgment System** (Item 4)
- Implement undelivered message queue per iOS session in backend
- Attach `message_id` to response messages that require acknowledgment
- Replay unacknowledged messages on client reconnection
- Make `message-ack` handler remove messages from queue
- See [Message acknowledgment findings](#4-message-acknowledgment-system) for full details

**Offline Prompt Queueing** (Item 21)
- Add persistent prompt queue to CoreData (similar to file uploads queue)
- Queue prompts when offline instead of silently dropping
- Flush queue in order when connection is restored
- Add retry mechanism for failed message sends
- See [Offline-first design findings](#21-design-for-offline-first) for full details

### Low Priority / Nice to Have

**Captive Portal Detection** (Item 31)
- Add HTTP probe before WebSocket connection to detect redirect responses
- Show user-friendly alert explaining they need to authenticate with the network
- Open Safari to captive.apple.com to trigger iOS's built-in captive portal handling
- Pause reconnection timer while waiting for user to authenticate
- See [Captive portal handling findings](#31-handle-captive-portals) for full details

## Implementation Notes

<!-- Add any implementation-specific notes, code snippets, or architectural considerations here -->
