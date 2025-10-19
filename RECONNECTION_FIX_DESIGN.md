# Reconnection Subscription Loss - Design Fix

## Problem

Messages are lost when the iOS client reconnects after network interruption.

### Root Cause

**Subscriptions are lost on reconnection:**

1. User opens session `355DE6A1-7105-4187-9CC5-30F13B7AFB62` in `ConversationView`
2. iOS subscribes via WebSocket: `client.subscribe(sessionId: "355DE6A1...")`
3. Backend adds session to `watcher-state/subscribed-sessions` (global set)
4. **Network interruption** (WiFi drop, cell handoff, etc.)
5. Backend `on-close` calls `unregister-channel!` - removes from `connected-clients` only
6. **Backend does NOT unsubscribe from filesystem watcher** - subscription orphaned
7. iOS reconnects with new WebSocket channel, sends "connect"
8. **iOS does NOT re-subscribe** - `ConversationView` still visible, `onAppear` doesn't fire
9. New messages arrive → `on-session-updated` broadcasts to all clients
10. **Message lost** - new channel not associated with subscription

### Current Architecture Issues

1. **Split state**: Subscriptions in `watcher-state/subscribed-sessions` (set), clients in `connected-clients` (map). No linkage.

2. **No per-channel tracking**: Backend doesn't know which channel cares about which session.

3. **View lifecycle controls network state**: Subscribe on `onAppear`, unsubscribe on `onDisappear`. Reconnection doesn't trigger `onAppear`.

4. **No subscription restoration**: Backend has no memory of what client was subscribed to before disconnect.

## Proposed Solution: Active Session Tracking

Track only the **currently-open session** per client, with automatic restoration on reconnect.

### Design Principles

1. **Match reality**: iOS UI shows one conversation at a time - only subscribe to what's visible
2. **Server remembers**: Backend tracks active session per client-id, survives reconnections
3. **Automatic restoration**: Reconnect with same client-id = subscription restored
4. **Efficient**: Filesystem watcher only watches actively-viewed sessions

### Architecture Changes

#### Backend Changes

**1. Enhanced client tracking** (`server.clj`):

```clojure
(defonce connected-clients
  (atom {}))  
  ; channel -> {:client-id <uuid>
  ;             :active-session-id <session-id or nil>
  ;             :deleted-sessions #{session-ids}}

(defonce client-registry
  (atom {}))
  ; client-id -> {:channel <channel>
  ;              :active-session-id <session-id or nil>
  ;              :last-seen <timestamp>}
```

**2. New message types**:

```clojure
;; Client -> Backend
"set_active_session" {:client_id <uuid>, :session_id <uuid>}
"clear_active_session" {:client_id <uuid>}

;; Backend -> Client
"active_session_restored" {:session_id <uuid>}
```

**3. Active session management**:

```clojure
(defn handle-set-active-session [channel client-id session-id]
  ;; Unsubscribe from previous active session (if any)
  (when-let [old-session (get-in @connected-clients [channel :active-session-id])]
    (maybe-unsubscribe-from-watcher channel old-session))
  
  ;; Update state
  (swap! connected-clients assoc-in [channel :active-session-id] session-id)
  (swap! client-registry assoc client-id {:channel channel
                                          :active-session-id session-id
                                          :last-seen (System/currentTimeMillis)})
  
  ;; Subscribe to new session in filesystem watcher
  (maybe-subscribe-to-watcher channel session-id)
  
  ;; Send full session history
  (send-session-history channel session-id))

(defn handle-clear-active-session [channel client-id]
  (when-let [active-session (get-in @connected-clients [channel :active-session-id])]
    (maybe-unsubscribe-from-watcher channel active-session))
  
  (swap! connected-clients assoc-in [channel :active-session-id] nil)
  (swap! client-registry assoc-in [client-id :active-session-id] nil))
```

**4. Subscription reference counting**:

```clojure
(defn count-active-clients-for-session [session-id]
  "Count how many clients have this session active"
  (count (filter #(= session-id (:active-session-id %)) 
                 (vals @connected-clients))))

(defn maybe-subscribe-to-watcher [channel session-id]
  "Subscribe to filesystem watcher only if this is the first client viewing this session"
  (when (= 1 (count-active-clients-for-session session-id))
    (log/info "First client viewing session, subscribing to watcher" 
              {:session-id session-id})
    (repl/subscribe-to-session! session-id)))

(defn maybe-unsubscribe-from-watcher [channel session-id]
  "Unsubscribe from filesystem watcher only if this was the last client viewing this session"
  (when (zero? (count-active-clients-for-session session-id))
    (log/info "Last client stopped viewing session, unsubscribing from watcher" 
              {:session-id session-id})
    (repl/unsubscribe-from-session! session-id)))
```

**5. Reconnection handling**:

```clojure
(defn handle-connect [channel data]
  (let [client-id (:client-id data)]
    (if-let [previous-state (get @client-registry client-id)]
      ;; Reconnecting client
      (do
        (log/info "Client reconnecting" {:client-id client-id 
                                         :active-session (:active-session-id previous-state)})
        
        ;; Update registry with new channel
        (swap! client-registry assoc-in [client-id :channel] channel)
        (swap! client-registry assoc-in [client-id :last-seen] (System/currentTimeMillis))
        
        ;; Restore client state
        (swap! connected-clients assoc channel 
               {:client-id client-id
                :active-session-id (:active-session-id previous-state)
                :deleted-sessions #{}})
        
        ;; If client had an active session, restore subscription
        (when-let [active-session (:active-session-id previous-state)]
          (maybe-subscribe-to-watcher channel active-session)
          (http/send! channel 
                      (generate-json {:type :active-session-restored
                                      :session-id active-session})))
        
        ;; Send session list as usual
        (send-session-list channel))
      
      ;; New client
      (do
        (log/info "New client connecting" {:client-id client-id})
        (swap! client-registry assoc client-id {:channel channel
                                                :active-session-id nil
                                                :last-seen (System/currentTimeMillis)})
        (swap! connected-clients assoc channel {:client-id client-id
                                                :active-session-id nil
                                                :deleted-sessions #{}})
        (send-session-list channel)))))
```

**6. Cleanup on disconnect**:

```clojure
(defn unregister-channel! [channel]
  (when-let [client-info (get @connected-clients channel)]
    (let [client-id (:client-id client-info)
          active-session (:active-session-id client-info)]
      
      ;; Don't unsubscribe from watcher - client might reconnect
      ;; Subscription will be restored if they reconnect within TTL
      
      ;; Just mark channel as disconnected
      (swap! client-registry assoc-in [client-id :channel] nil)
      (swap! connected-clients dissoc channel)
      
      (log/info "Client disconnected, state preserved" 
                {:client-id client-id 
                 :active-session active-session}))))
```

**7. TTL-based cleanup** (new background task):

```clojure
(defn cleanup-stale-clients! []
  "Remove client registrations older than 1 hour"
  (let [now (System/currentTimeMillis)
        ttl-ms (* 60 60 1000) ; 1 hour
        stale-clients (filter (fn [[client-id state]]
                                (and (nil? (:channel state))
                                     (> (- now (:last-seen state)) ttl-ms)))
                              @client-registry)]
    (doseq [[client-id state] stale-clients]
      (log/info "Cleaning up stale client" {:client-id client-id})
      
      ;; Unsubscribe from active session if any
      (when-let [active-session (:active-session-id state)]
        ;; Create temporary channel for reference counting
        (maybe-unsubscribe-from-watcher nil active-session))
      
      (swap! client-registry dissoc client-id))))

;; Run cleanup every 15 minutes
(defn start-cleanup-task! []
  (future
    (while true
      (Thread/sleep (* 15 60 1000))
      (cleanup-stale-clients!))))
```

**8. Update `on-session-updated`**:

```clojure
(defn on-session-updated [session-id new-messages]
  (log/debug "Session updated" {:session-id session-id :message-count (count new-messages)})
  
  ;; Send only to clients with this session active
  (doseq [[channel client-info] @connected-clients]
    (when (and (= session-id (:active-session-id client-info))
               (not (is-session-deleted-for-client? channel session-id)))
      (send-to-client! channel
                       {:type :session-updated
                        :session-id session-id
                        :messages new-messages}))))
```

#### iOS Changes

**1. Generate persistent client-id** (`VoiceCodeClient.swift`):

```swift
class VoiceCodeClient: ObservableObject {
    private let clientId: String
    
    init(serverURL: String, ...) {
        // Use device UUID as persistent client-id
        if let uuid = UIDevice.current.identifierForVendor?.uuidString {
            self.clientId = uuid
        } else {
            // Fallback: generate and persist
            if let stored = UserDefaults.standard.string(forKey: "voice_code_client_id") {
                self.clientId = stored
            } else {
                let newId = UUID().uuidString
                UserDefaults.standard.set(newId, forKey: "voice_code_client_id")
                self.clientId = newId
            }
        }
        // ... rest of init
    }
}
```

**2. Send client-id in connect**:

```swift
private func sendConnectMessage() {
    let message: [String: Any] = [
        "type": "connect",
        "client_id": clientId
    ]
    print("📤 [VoiceCodeClient] Sending connect with client_id: \(clientId)")
    sendMessage(message)
}
```

**3. Replace subscribe/unsubscribe with active session**:

```swift
func setActiveSession(_ sessionId: String) {
    let message: [String: Any] = [
        "type": "set_active_session",
        "client_id": clientId,
        "session_id": sessionId
    ]
    print("📖 [VoiceCodeClient] Setting active session: \(sessionId)")
    sendMessage(message)
}

func clearActiveSession() {
    let message: [String: Any] = [
        "type": "clear_active_session",
        "client_id": clientId
    ]
    print("📕 [VoiceCodeClient] Clearing active session")
    sendMessage(message)
}
```

**4. Handle restored session** (`VoiceCodeClient.swift`):

```swift
case "active_session_restored":
    if let sessionId = json["session_id"] as? String {
        print("🔄 [VoiceCodeClient] Active session restored on reconnect: \(sessionId)")
        // No action needed - SessionSyncManager will receive session_updated messages
    }
```

**5. Update ConversationView**:

```swift
.onAppear {
    loadSessionIfNeeded()
    setupVoiceInput()
    
    // Set active session instead of subscribe
    client.setActiveSession(session.id.uuidString)
}
.onDisappear {
    ActiveSessionManager.shared.clearActiveSession()
    
    // Clear active session instead of unsubscribe
    client.clearActiveSession()
}
```

**6. Remove old subscribe/unsubscribe methods** from `VoiceCodeClient.swift`.

### Migration Path

1. **Backend first**: Deploy new message handlers alongside old subscribe/unsubscribe (backward compatible)
2. **Test with old iOS**: Verify old subscribe still works
3. **Deploy iOS**: Update to use set_active_session
4. **Remove old code**: After all clients updated, remove subscribe/unsubscribe handlers

### Benefits

1. **No lost messages on reconnect**: Backend remembers active session via client-id
2. **Efficient watching**: Only watch files actively being viewed (reduces filesystem watcher load)
3. **Automatic cleanup**: TTL removes abandoned clients after 1 hour
4. **Simple mental model**: One active session = one subscription
5. **Matches UI**: iOS only shows one conversation at a time

### Testing

**Reconnection scenario:**
1. Open ConversationView for session A
2. Verify `set_active_session` sent, watcher subscribed
3. Disconnect network
4. Send prompt via terminal (creates new message)
5. Reconnect network
6. Verify iOS receives `active_session_restored`
7. Verify new message appears in ConversationView

**Navigation scenario:**
1. Open ConversationView for session A
2. Navigate to session B
3. Verify `set_active_session` for B, watcher unsubscribes from A
4. Send prompt to session A via terminal
5. Verify iOS does NOT receive update (not active)
6. Navigate back to session A
7. Verify full history includes new message

**Cleanup scenario:**
1. Disconnect client with active session
2. Wait 61 minutes
3. Verify client-id removed from registry
4. Verify watcher unsubscribed from session
