# WebSocket Implementation Recommendations

This document captures findings and recommendations from reviewing our WebSocket implementation against best practices.

## Summary

| Category | Reviewed | Gaps Found | Recommendations |
|----------|----------|------------|-----------------|
| Connection Management | 3/3 | 1 | 1 |
| Message Delivery | 2/2 | 2 | 2 |
| Authentication | 1/2 | 0 | 0 |
| Mobile-Specific | 0/3 | - | - |
| Protocol Design | 0/3 | - | - |
| Detecting Degraded Connections | 0/3 | - | - |
| Poor Bandwidth Handling | 0/4 | - | - |
| Intermittent Signal Handling | 0/4 | - | - |
| App Lifecycle Resilience | 0/4 | - | - |
| Network Transition Handling | 0/3 | - | - |
| Server-Side Resilience | 0/3 | - | - |
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

<!-- Add findings for item 7 here -->

### Mobile-Specific Concerns

<!-- Add findings for items 8-10 here -->

### Protocol Design

<!-- Add findings for items 11-13 here -->

### Detecting Degraded Connections

<!-- Add findings for items 14-16 here -->

### Poor Bandwidth Handling

<!-- Add findings for items 17-20 here -->

### Intermittent Signal Handling

<!-- Add findings for items 21-24 here -->

### App Lifecycle Resilience

<!-- Add findings for items 25-28 here -->

### Network Transition Handling

<!-- Add findings for items 29-31 here -->

### Server-Side Resilience

<!-- Add findings for items 32-34 here -->

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

<!-- Add additional medium priority recommendations here -->

### Low Priority / Nice to Have

<!-- Add low priority recommendations here -->

## Implementation Notes

<!-- Add any implementation-specific notes, code snippets, or architectural considerations here -->
