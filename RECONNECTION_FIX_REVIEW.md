# Reconnection Fix Design Review

## Executive Summary

The proposed design addresses a real subscription loss problem but introduces significant architectural complexity. The core issue is correctly identified: subscriptions are orphaned on reconnection because iOS doesn't re-subscribe when `ConversationView` remains visible. However, the solution may be over-engineered for the actual problem scope.

## Problem Analysis

### Correctly Identified Issues

1. **Subscription orphaning on reconnect**: ✅ Real issue
   - iOS subscribes via `onAppear` in ConversationView:228
   - Reconnection doesn't trigger `onAppear`
   - Backend tracks subscriptions in global `watcher-state/subscribed-sessions` set
   - No per-channel subscription tracking

2. **Split state architecture**: ✅ Valid concern
   - `connected-clients` (server.clj:30): Maps channel → client info
   - `watcher-state/subscribed-sessions` (replication.clj:302): Global set of session IDs
   - No linkage between which channel cares about which session

3. **View lifecycle controls network state**: ✅ Architectural weakness
   - Subscribe/unsubscribe tied to SwiftUI view lifecycle
   - Fragile for network interruptions

### Current Implementation Details

**Backend subscription tracking (replication.clj:304-322)**:
```clojure
(defonce watcher-state
  (atom {:subscribed-sessions #{}  ; Global set, no channel association
         ...}))

(defn subscribe-to-session! [session-id]
  (swap! watcher-state update :subscribed-sessions conj (str/lower-case session-id)))

(defn unsubscribe-from-session! [session-id]
  (swap! watcher-state update :subscribed-sessions disj (str/lower-case session-id)))
```

**Backend broadcast logic (server.clj:222-229)**:
```clojure
(defn on-session-updated [session-id new-messages]
  ;; Sends to ALL clients, filtered only by deletion status
  (doseq [[channel client-info] @connected-clients]
    (when-not (is-session-deleted-for-client? channel session-id)
      (send-to-client! channel {:type :session-updated ...}))))
```

**iOS subscription pattern (ConversationView.swift:193-203)**:
```swift
.onAppear {
    loadSessionIfNeeded()
    setupVoiceInput()
}
.onDisappear {
    ActiveSessionManager.shared.clearActiveSession()
    client.unsubscribe(sessionId: session.id.uuidString)
}

private func loadSessionIfNeeded() {
    client.subscribe(sessionId: session.id.uuidString)
}
```

## Proposed Solution Analysis

### Strengths

1. **Server-side state preservation**: Backend remembers what client was viewing
2. **Automatic restoration**: Reconnection with same client-id restores subscription
3. **Reference counting**: Smart filesystem watcher subscription/unsubscription
4. **TTL-based cleanup**: Prevents indefinite state accumulation

### Concerns

#### 1. **Client ID Persistence Strategy Is Flawed**

**Proposed implementation**:
```swift
if let uuid = UIDevice.current.identifierForVendor?.uuidString {
    self.clientId = uuid
} else {
    // Fallback to UserDefaults
}
```

**Critical problem**: `identifierForVendor` changes when:
- App is uninstalled and reinstalled
- All apps from same vendor are removed from device
- Various iOS bugs (documented since iOS 10)

**Impact**:
- Client state loss on app reinstall = exactly the problem we're trying to solve
- Backend accumulates orphaned client registries
- UserDefaults fallback only works if IDFV is nil (rare)

**Better approach**: Always use UUID stored in UserDefaults or Keychain

#### 2. **Architectural Complexity vs. Problem Scope**

The design adds:
- New global state: `client-registry` (client-id → state)
- Enhanced `connected-clients` tracking
- New message types: `set_active_session`, `clear_active_session`, `active_session_restored`
- Background cleanup task
- Reference counting logic for watcher subscriptions

**Is this justified?** Consider simpler alternatives:
- Fix iOS to re-subscribe on reconnect (detect reconnection, call subscribe)
- Backend: track subscriptions per channel, restore on same channel reconnect
- Use WebSocket connection ID as natural client identifier

#### 3. **Race Conditions in Cleanup Logic**

**From design (section 7)**:
```clojure
(when-let [active-session (:active-session-id state)]
  ;; Create temporary channel for reference counting
  (maybe-unsubscribe-from-watcher nil active-session))
```

**Problem**: Reference counting with `nil` channel:
```clojure
(defn count-active-clients-for-session [session-id]
  (count (filter #(= session-id (:active-session-id %))
                 (vals @connected-clients))))
```

This won't find the client being cleaned up (already removed from `client-registry`). The reference count will be incorrect.

#### 4. **Active Session Model vs. Current Architecture Mismatch**

**Design assumption**: "iOS UI shows one conversation at a time"

**Current reality**:
- iOS can have multiple ConversationViews in navigation stack (backgrounded but not destroyed)
- SessionsView lists all sessions with live updates
- Multiple sessions may receive updates simultaneously
- ConversationView.swift doesn't restrict to single active session

**Proposed model breaks**:
- User navigates Session A → Session B → back to A
- Only Session B is "active" according to backend
- Session A stops receiving updates while "backgrounded" in nav stack
- User sees stale data when navigating back

#### 5. **Migration Path Complexity**

**From design**:
> 1. Backend first: Deploy new message handlers alongside old subscribe/unsubscribe
> 2. Test with old iOS
> 3. Deploy iOS
> 4. Remove old code

**Reality check**:
- Requires dual protocol support during transition
- Testing burden: old iOS + new iOS + old backend + new backend combinations
- Rollback complexity if issues found in production
- Must maintain backward compatibility indefinitely (users don't update apps)

#### 6. **TTL Cleanup Edge Cases**

**From design (section 7)**:
```clojure
(defn cleanup-stale-clients! []
  "Remove client registrations older than 1 hour"
  (let [now (System/currentTimeMillis)
        ttl-ms (* 60 60 1000)]  ; 1 hour
    ...))
```

**Edge cases**:
- User leaves app open in background for 61 minutes → subscription lost silently
- Network flaky, reconnects every 30 minutes → survives
- Network stable, user backgrounds app for 2 hours → subscription lost
- No notification to iOS that subscription was cleaned up

**Better**: Heartbeat-based keepalive, or infinite TTL until explicit cleanup

#### 7. **No Handling of Multiple Devices**

**Scenario**: User has iPhone + iPad, both with same `identifierForVendor`:
- Same vendor ID across devices from same developer
- Both devices connect with identical client-id
- Backend treats as same client
- Only latest device gets subscriptions
- Other device silently stops receiving updates

**From Apple docs**: IDFV is "the same for apps from the same vendor on the same device" but different across devices from the same vendor.

**This concern is actually invalid** - IDFV is unique per device. But the design doesn't document this assumption.

## Current Architecture Advantages

The existing subscribe/unsubscribe model has underappreciated benefits:

1. **Simple mental model**: Client explicitly declares interest
2. **Stateless backend**: No client session state to manage
3. **No cleanup needed**: Subscriptions naturally expire with connection
4. **Easy debugging**: Clear subscription → message flow
5. **Works with current UI**: Multiple views can subscribe independently

## Alternative Solutions

### Option A: Client-Side Reconnection Fix (Simplest)

**iOS changes only**:
```swift
// VoiceCodeClient.swift
var activeSubscriptions: Set<String> = []

func subscribe(sessionId: String) {
    activeSubscriptions.insert(sessionId)
    sendMessage(["type": "subscribe", "session_id": sessionId])
}

func unsubscribe(sessionId: String) {
    activeSubscriptions.remove(sessionId)
    sendMessage(["type": "unsubscribe", "session_id": sessionId])
}

private func handleConnected() {
    // Re-subscribe to all previously active sessions
    for sessionId in activeSubscriptions {
        sendMessage(["type": "subscribe", "session_id": sessionId])
    }
}
```

**Pros**:
- Zero backend changes
- Fixes root cause: reconnection doesn't re-subscribe
- Maintains current architecture
- Simple to test and debug

**Cons**:
- Client must track subscriptions
- Relies on iOS to detect reconnection correctly

### Option B: Per-Channel Subscription Tracking

**Backend changes**:
```clojure
(defonce connected-clients
  (atom {}))  ; channel -> {:subscriptions #{session-ids}}

(defn on-session-updated [session-id new-messages]
  (doseq [[channel client-info] @connected-clients]
    (when (contains? (:subscriptions client-info) session-id)
      (send-to-client! channel {...}))))
```

**Reconnection flow**:
- iOS reconnects, gets new channel
- Backend loses subscription (tied to old channel)
- iOS re-subscribes (existing `onAppear` logic)
- Seamless recovery

**Pros**:
- Minimal backend changes
- Correct channel-subscription linkage
- No new concepts (client-id, TTL, etc.)
- Works with existing iOS code

**Cons**:
- Doesn't auto-restore (iOS must re-subscribe)
- Requires iOS reconnection detection

### Option C: Hybrid - Minimal Server State

**Backend tracks subscriptions per client-id**:
```clojure
(defonce connected-clients
  (atom {}))  ; channel -> {:client-id <uuid>, :subscriptions #{}}

(defonce client-registry
  (atom {}))  ; client-id -> {:subscriptions #{}, :last-seen <ts>}
```

**On reconnect with same client-id**:
1. Restore subscriptions from `client-registry`
2. Send `session_history` for each restored subscription
3. Resume normal operation

**Pros**:
- Auto-restore on reconnection
- Much simpler than full proposed design
- No active session concept, no TTL complexity

**Cons**:
- Still requires client-id management
- Adds some backend state

## Recommendations

### 1. Start with Option A (Client-Side Fix)

**Rationale**:
- Solves the immediate problem
- Zero risk to backend stability
- Can ship immediately
- Validates the reconnection scenario works

**Implementation**:
```swift
// Track active subscriptions across reconnections
private var activeSubscriptions = Set<String>()

func subscribe(sessionId: String) {
    activeSubscriptions.insert(sessionId)
    let message = ["type": "subscribe", "session_id": sessionId]
    sendMessage(message)
}

func unsubscribe(sessionId: String) {
    activeSubscriptions.remove(sessionId)
    let message = ["type": "unsubscribe", "session_id": sessionId]
    sendMessage(message)
}

private func handleMessage(_ text: String) {
    // ... existing code ...
    case "connected":
        self.reconnectionAttempts = 0
        // RESUBSCRIBE on reconnection
        for sessionId in self.activeSubscriptions {
            self.subscribe(sessionId: sessionId)
        }
```

### 2. If Server-Side State Is Required, Use Option C

**Only if**:
- Client-side tracking proves insufficient
- Auto-restore is a hard requirement
- Willing to accept state management complexity

**Changes from proposed design**:
- ✅ Keep: client-id concept, subscription restoration
- ❌ Remove: active session model, reference counting, TTL cleanup
- ✅ Add: Simple client-id → subscriptions map
- ✅ Keep: All existing subscriptions (don't force single active)

### 3. Fix Client ID Implementation

**If any server-side state is used**:

```swift
class VoiceCodeClient {
    private let clientId: String

    init() {
        // ALWAYS use UserDefaults, never rely on IDFV
        if let stored = UserDefaults.standard.string(forKey: "voice_code_client_id") {
            self.clientId = stored
        } else {
            let newId = UUID().uuidString
            UserDefaults.standard.set(newId, forKey: "voice_code_client_id")
            self.clientId = newId
        }
    }
}
```

**Rationale**: IDFV is unreliable across reinstalls. UserDefaults survives app updates but not reinstalls, which is acceptable for this use case.

### 4. Address Active Session Model Mismatch

**Current design assumes**: Single active session
**Reality**: Multiple sessions may be viewed/backgrounded

**Options**:
1. Abandon active session model → use subscription set (recommended)
2. Track active session + backgrounded sessions
3. Document that backgrounded sessions won't update (breaking change)

### 5. Testing Strategy

**Before implementing either solution**:

1. **Reproduce the bug**:
   - Open ConversationView for session A
   - Trigger network disconnect (airplane mode)
   - Send prompt to session A from terminal
   - Reconnect network
   - Verify message does NOT appear (confirms bug)

2. **Validate the fix**:
   - Apply Option A (client-side fix)
   - Repeat test
   - Verify message DOES appear

3. **Edge cases**:
   - Multiple sessions open in nav stack
   - Reconnection during active prompt
   - Backend restart during active session

## Positive Aspects of Proposed Design

Despite concerns, the design document demonstrates:

1. **Thorough problem analysis**: Root cause correctly identified
2. **Complete specification**: Detailed code examples, message formats
3. **Migration planning**: Backward compatibility considered
4. **Reference counting**: Elegant filesystem watcher optimization
5. **Cleanup strategy**: Prevents indefinite state growth

## Summary

**Problem**: Real and correctly identified
**Proposed solution**: Architecturally sound but over-engineered
**Recommendation**: Start with simple client-side fix (Option A), escalate to minimal server state (Option C) only if needed

**Key concerns**:
1. Client ID persistence using IDFV is unreliable
2. Active session model doesn't match current multi-session UI
3. Complexity burden may exceed benefit
4. Simpler solutions exist

**Validation needed**:
- Test that client-side resubscribe solves the problem
- Measure frequency of reconnection events in production
- Assess whether auto-restore is worth the complexity

## Questions for Design Author

1. Have you reproduced the subscription loss bug with specific test steps?
2. Why is active session model required vs. tracking all subscriptions per client?
3. What happens to backgrounded ConversationViews in nav stack?
4. How will client-id persistence across app reinstalls be handled?
5. Can we solve this with iOS-side reconnection detection instead?
6. What is the expected frequency of network reconnections in production use?
