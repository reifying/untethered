# WebSocket Implementation Recommendations

This document captures findings and recommendations from reviewing our WebSocket implementation against best practices.

## Summary

| Category | Reviewed | Gaps Found | Recommendations |
|----------|----------|------------|-----------------|
| Connection Management | 3/3 | 1 | 1 |
| Message Delivery | 2/2 | 2 | 2 |
| Authentication | 2/2 | 0 | 0 |
| Mobile-Specific | 0/3 | - | - |
| Protocol Design | 2/3 | 3 | 3 |
| Detecting Degraded Connections | 0/3 | - | - |
| Poor Bandwidth Handling | 0/4 | - | - |
| Intermittent Signal Handling | 1/4 | 4 | 4 |
| App Lifecycle Resilience | 0/4 | - | - |
| Network Transition Handling | 1/3 | 1 | 1 |
| Server-Side Resilience | 1/3 | 4 | 4 |
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

<!-- Add findings for items 8-10 here -->

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

<!-- Add findings for item 13 here -->

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

<!-- Add findings for items 22-24 here -->

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

<!-- Add findings for items 33-34 here -->

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
