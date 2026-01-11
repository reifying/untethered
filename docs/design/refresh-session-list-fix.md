# Refresh Session List Fix

## Overview

### Problem Statement

The refresh button on the iOS home page doesn't work and breaks connectivity:

1. **Refresh doesn't update**: Tapping the refresh button doesn't fetch the latest projects/directories list
2. **Connectivity breaks**: After tapping refresh, the WebSocket connection is terminated
3. **Auto-subscribe broken**: When a new project directory is added while connected, it doesn't appear without restarting the app

### Goals

1. Fix the refresh button to properly request an updated session list without breaking authentication
2. Add a dedicated "refresh session list" message type to the WebSocket protocol
3. Preserve existing connection state when refreshing

### Non-goals

- Push notifications for new directories (requires server-side file watching)
- Real-time directory change detection
- Changes to the authentication protocol itself

## Background & Context

### Current State

#### Refresh Button Flow (Broken)

```
User taps refresh button
    │
    ▼
requestSessionList() called
    │
    ▼
Sends: {"type": "connect"}  ← MISSING api_key!
    │
    ▼
Backend authenticate-connect! receives nil api_key
    │
    ▼
Backend sends auth_error + closes connection
    │
    ▼
iOS loses connectivity
```

#### Proper Connect Flow (Working)

```
Initial connection / reconnection
    │
    ▼
Receive "hello" from server
    │
    ▼
sendConnectMessage() called
    │
    ▼
Sends: {"type": "connect", "api_key": "...", ...}
    │
    ▼
Backend authenticates, sends session_list
    │
    ▼
Connection established
```

### Root Cause Analysis

**Bug Location:** `VoiceCodeClient.swift`, lines 1182-1212

The `requestSessionList()` function sends a `connect` message without the `api_key`:

```swift
func requestSessionList() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        sessionListContinuation = continuation

        var message: [String: Any] = [
            "type": "connect"  // ← No api_key included!
        ]

        if let limit = appSettings?.recentSessionsLimit {
            message["recent_sessions_limit"] = limit
        }

        sendMessage(message)
        // ...
    }
}
```

But the backend requires `api_key` for all `connect` messages (from `server.clj`):

```clojure
(defn authenticate-connect! [channel data]
  (let [provided-key (:api-key data)]
    (cond
      (nil? provided-key)
      (do
        (send-auth-error! channel "Missing API key in connect message")
        false)  ; ← Connection closed!
      ;; ...
    )))
```

### Why Now

Users discovered the refresh button breaks their connection, requiring an app restart. This is a critical usability issue that makes the refresh functionality unusable.

### Related Work

- @STANDARDS.md - WebSocket protocol documentation
- @docs/design/websocket-reconnection-fix.md - Related connection handling

## Detailed Design

### Approach: Add `refresh_sessions` Message Type

Rather than reusing the `connect` message (which requires re-authentication), add a new message type specifically for refreshing the session list on an already-authenticated connection.

### Protocol Changes

#### New Message Type: `refresh_sessions` (Client → Backend)

**Message:**
```json
{
  "type": "refresh_sessions",
  "recent_sessions_limit": 10
}
```

**Fields:**
- `type` (required): Always `"refresh_sessions"`
- `recent_sessions_limit` (optional): Maximum number of recent sessions to return (default: 5)

**Preconditions:**
- Client must be authenticated (sent `connect` with valid `api_key` and received `connected`)
- If not authenticated, backend sends `auth_error`

**Response:**
Backend responds with the existing `session_list` and `recent_sessions` messages (same as after `connect`).

### Data Model

No changes to data storage. The backend already has all the data needed; we just need a new message type to request it.

### API Design

#### Backend Handler

**File:** `backend/src/voice_code/server.clj`

Add handler in `handle-message`:

```clojure
(= msg-type "refresh_sessions")
(if (channel-authenticated? channel)
  (do
    (log/info "Client requested session list refresh")
    (let [limit (or (:recent-sessions-limit data) 5)]
      ;; Send session list (reuse existing logic)
      (let [all-sessions (repl/get-all-sessions)
            sorted-sessions (->> all-sessions
                                 (sort-by (comp str/lower-case :last-modified) #(compare %2 %1))
                                 (take 50))
            recent-sessions (map #(select-keys % [:session-id :name :working-directory :last-modified])
                                 sorted-sessions)
            total-non-empty (count (filter #(not= 0 (:message-count %)) all-sessions))]
        (send-to-client! channel
                         {:type :session-list
                          :sessions recent-sessions
                          :total-count total-non-empty}))
      ;; Send recent sessions
      (send-recent-sessions! channel limit)
      ;; Send available commands for current working directory
      (when-let [working-dir (get-in @connected-clients [channel :working-directory])]
        (send-available-commands! channel working-dir))))
  ;; Not authenticated
  (send-auth-error! channel "Not authenticated"))
```

#### iOS Client Changes

**File:** `ios/VoiceCode/Managers/VoiceCodeClient.swift`

Replace `requestSessionList()`:

```swift
func requestSessionList() async {
    // Ensure we're authenticated before requesting
    guard isAuthenticated else {
        print("⚠️ [VoiceCodeClient] Cannot refresh sessions - not authenticated")
        return
    }

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        sessionListContinuation = continuation

        var message: [String: Any] = [
            "type": "refresh_sessions"  // New message type!
        ]

        if let limit = appSettings?.recentSessionsLimit {
            message["recent_sessions_limit"] = limit
            print("🔄 [VoiceCodeClient] Requesting session list refresh (limit: \(limit))")
        } else {
            print("🔄 [VoiceCodeClient] Requesting session list refresh")
        }

        sendMessage(message)

        // Timeout handling
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            if let cont = self?.sessionListContinuation {
                self?.sessionListContinuation = nil
                cont.resume()
                print("⚠️ [VoiceCodeClient] Session list request timed out")
            }
        }
    }
}
```

### Component Interactions

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    Fixed Refresh Flow                                    │
└─────────────────────────────────────────────────────────────────────────┘

User taps refresh button
    │
    ▼
requestSessionList() called
    │
    ├─── Check: isAuthenticated?
    │         │
    │         ├─── No: Log warning, return (no action)
    │         │
    │         └─── Yes: Continue
    │
    ▼
Sends: {"type": "refresh_sessions", "recent_sessions_limit": 10}
    │
    ▼
Backend receives message
    │
    ├─── Check: channel-authenticated?
    │         │
    │         ├─── No: Send auth_error (shouldn't happen)
    │         │
    │         └─── Yes: Continue
    │
    ▼
Backend sends session_list message
    │
    ▼
Backend sends recent_sessions message
    │
    ▼
iOS processes responses, updates UI
    │
    ▼
Connection remains established ✓
```

### Migration Strategy

**Backward Compatibility:**
- Old clients sending `connect` without `api_key` will still fail (existing behavior)
- New clients will use `refresh_sessions` for refresh operations
- No changes to the initial authentication flow

**Rollout:**
1. Deploy backend changes first (adds new message type)
2. Deploy iOS client changes (uses new message type)
3. Old clients continue working normally until updated

## Verification Strategy

### Testing Approach

#### Unit Tests

**Backend (Clojure):**
1. Test `refresh_sessions` returns session list when authenticated
2. Test `refresh_sessions` returns `auth_error` when not authenticated
3. Test `refresh_sessions` respects `recent_sessions_limit`

**iOS (Swift):**
1. Test `requestSessionList()` sends correct message type
2. Test `requestSessionList()` checks authentication state
3. Test timeout handling

#### Integration Tests

1. Connect, authenticate, then send `refresh_sessions` - verify session list received
2. Send `refresh_sessions` before `connect` - verify `auth_error` received
3. Verify connection remains open after `refresh_sessions`

#### Manual Tests

1. Start app, verify initial session list loads
2. Add a new project directory on the backend
3. Tap refresh button - verify new directory appears
4. Verify connection status remains "connected" after refresh
5. Send a prompt after refresh - verify it works

### Test Examples

**Backend Test (Clojure):**

```clojure
;; File: backend/test/voice_code/refresh_sessions_test.clj
(ns voice-code.refresh-sessions-test
  (:require [clojure.test :refer :all]
            [voice-code.server :as server]))

;; Test fixtures and helpers (same pattern as server_auth_test.clj)

(def test-api-key "voice-code-a1b2c3d4e5f678901234567890abcdef")

(defn with-test-api-key
  "Fixture that sets up a known API key for testing"
  [f]
  (let [original-key @server/api-key]
    (reset! server/api-key test-api-key)
    (try
      (f)
      (finally
        (reset! server/api-key original-key)))))

(use-fixtures :each with-test-api-key)

;; Tests

(deftest refresh-sessions-test
  (testing "refresh_sessions returns session list when authenticated"
    (let [sent-messages (atom [])
          fake-channel (Object.)]
      ;; Mock dependencies
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    org.httpkit.server/close (fn [_] nil)
                    voice-code.replication/get-all-sessions (constantly [])
                    server/send-recent-sessions! (fn [_ _] nil)]
        ;; First authenticate
        (server/handle-message fake-channel
                               (server/generate-json {:type "connect"
                                                      :api-key test-api-key}))
        (is (server/channel-authenticated? fake-channel))

        ;; Clear messages from connect
        (reset! sent-messages [])

        ;; Send refresh request
        (server/handle-message fake-channel
                               (server/generate-json {:type "refresh_sessions"
                                                      :recent-sessions-limit 5}))

        ;; Should have sent session_list
        (is (some #(= "session_list" (:type (server/parse-json %))) @sent-messages)
            "Should receive session_list response")

        ;; Clean up
        (swap! server/connected-clients dissoc fake-channel))))

  (testing "refresh_sessions fails when not authenticated"
    (let [sent-messages (atom [])
          closed (atom false)
          fake-channel (Object.)]
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    org.httpkit.server/close (fn [_] (reset! closed true))]
        ;; Send refresh without authenticating first
        (server/handle-message fake-channel
                               (server/generate-json {:type "refresh_sessions"}))

        ;; Should have sent auth_error
        (is (= 1 (count @sent-messages)))
        (let [resp (server/parse-json (first @sent-messages))]
          (is (= "auth_error" (:type resp))))
        (is @closed "Should close connection")))))
```

**iOS Test (Swift):**

```swift
// File: ios/VoiceCodeTests/RefreshSessionsTests.swift
import XCTest
@testable import VoiceCode

// MARK: - Mock Client for Testing

private class MockVoiceCodeClientForRefresh: VoiceCodeClient {
    var sentMessages: [[String: Any]] = []

    init() {
        super.init(serverURL: "ws://localhost:8080", setupObservers: false)
    }

    override func sendMessage(_ message: [String: Any]) {
        sentMessages.append(message)
    }
}

// MARK: - Tests

final class RefreshSessionsTests: XCTestCase {

    func testRequestSessionListSendsRefreshSessionsMessage() {
        // Given: An authenticated client
        let client = MockVoiceCodeClientForRefresh()

        // Simulate authentication flow
        client.handleMessage("""
            {"type": "hello", "message": "Welcome", "version": "0.2.0", "auth_version": 1}
            """)
        client.handleMessage("""
            {"type": "connected", "message": "Session registered", "session_id": "test"}
            """)

        // Wait for async state updates
        let authExpectation = expectation(description: "Authentication complete")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            authExpectation.fulfill()
        }
        wait(for: [authExpectation], timeout: 1.0)

        XCTAssertTrue(client.isAuthenticated)
        client.sentMessages.removeAll()  // Clear messages from auth flow

        // When: requestSessionList is called
        let refreshExpectation = expectation(description: "Refresh sent")
        Task {
            await client.requestSessionList()
            await MainActor.run {
                refreshExpectation.fulfill()
            }
        }
        wait(for: [refreshExpectation], timeout: 2.0)

        // Then: Should send refresh_sessions message type
        let refreshMessage = client.sentMessages.first { ($0["type"] as? String) == "refresh_sessions" }
        XCTAssertNotNil(refreshMessage, "Should send refresh_sessions message")
        XCTAssertEqual(refreshMessage?["type"] as? String, "refresh_sessions")
    }

    func testRequestSessionListRequiresAuthentication() {
        // Given: A client that is not authenticated
        let client = MockVoiceCodeClientForRefresh()
        XCTAssertFalse(client.isAuthenticated)

        // When: requestSessionList is called without authentication
        let expectation = expectation(description: "Refresh attempted")
        Task {
            await client.requestSessionList()
            await MainActor.run {
                expectation.fulfill()
            }
        }
        wait(for: [expectation], timeout: 2.0)

        // Then: No message should be sent (guard prevents it)
        let refreshMessage = client.sentMessages.first { ($0["type"] as? String) == "refresh_sessions" }
        XCTAssertNil(refreshMessage, "Should NOT send refresh_sessions when not authenticated")
    }
}
```

### Acceptance Criteria

1. Tapping the refresh button sends `refresh_sessions` (not `connect`)
2. Refresh button only works when `isAuthenticated == true`
3. Session list updates after tapping refresh
4. WebSocket connection remains open after refresh
5. Backend returns `auth_error` for `refresh_sessions` without prior authentication
6. Existing `connect` flow unchanged (still requires `api_key`)
7. Pull-to-refresh works correctly (uses same mechanism)

## Alternatives Considered

### 1. Add `api_key` to `requestSessionList()`

**Approach:** Include the API key in the existing `connect` message:

```swift
var message: [String: Any] = [
    "type": "connect",
    "api_key": apiKey  // Add the key
]
```

**Pros:**
- Minimal code change
- No protocol changes

**Cons:**
- Reuses authentication message for non-auth purpose
- Semantically incorrect (not "connecting", just refreshing)
- Backend would need to handle re-authentication mid-session

**Decision:** Rejected. Muddies the protocol semantics and complicates backend logic.

### 2. Cache Session List Client-Side

**Approach:** Don't request from backend; instead, cache and refresh from local CoreData.

**Pros:**
- No network request
- Faster UI update

**Cons:**
- Doesn't solve the problem (new directories come from backend)
- Stale data issue
- Doesn't help when backend has new sessions

**Decision:** Rejected. The goal is to get fresh data from the backend.

### 3. Use HTTP Endpoint Instead of WebSocket

**Approach:** Add GET `/sessions` REST endpoint for session list.

**Pros:**
- Clean separation of concerns
- HTTP is simpler for one-off requests

**Cons:**
- Adds another communication channel to maintain
- Need to handle authentication separately
- Inconsistent with existing WebSocket-based protocol

**Decision:** Rejected. Maintaining a single WebSocket connection is simpler and more consistent.

## Risks & Mitigations

### 1. Risk: Backend Version Mismatch

**Risk:** Old backend doesn't recognize `refresh_sessions` message.

**Mitigation:** Old backends will log an unknown message type warning but won't crash. Client can fall back to not refreshing (connection remains stable). Add version check if needed.

### 2. Risk: Race Condition with Authentication

**Risk:** User taps refresh while authentication is in progress.

**Mitigation:** The `isAuthenticated` guard in `requestSessionList()` prevents this. If not authenticated yet, the request is simply ignored.

### 3. Risk: Timeout Without Response

**Risk:** Backend doesn't respond to `refresh_sessions` (bug or network issue).

**Mitigation:** Existing 5-second timeout in `requestSessionList()` handles this gracefully - continuation resumes with warning logged.

### Rollback Strategy

1. Backend: Remove `refresh_sessions` handler, old clients unaffected
2. iOS: Revert `requestSessionList()` changes (refresh button will break connectivity again)
3. No data migration needed

### Detection

1. Monitor logs for `refresh_sessions` messages
2. Track connection drops immediately after refresh (should decrease)
3. User reports of "refresh button breaks connection" (should stop)
