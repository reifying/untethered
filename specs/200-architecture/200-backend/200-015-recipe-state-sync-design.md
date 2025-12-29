# Recipe State Synchronization Design

## 1. Overview

### Problem Statement

When a recipe completes on the backend (e.g., Claude returns `{"outcome": "committed"}`), the iOS client may not receive the `recipe_exited` message due to network issues or WebSocket reconnection. This causes the recipe to appear "stuck" in the UI indefinitely, even though it has completed.

### Goals

- Ensure recipe state is always eventually consistent between backend and iOS
- Provide immediate robustness for the common case (recipe exits, turn completes)
- Handle edge cases (reconnection mid-recipe, missed messages)
- Add observability for diagnosing future issues

### Non-Goals

- Guaranteed exactly-once delivery of `recipe_exited` (solved via state sync instead)
- Persisting recipe state across backend restarts (recipes don't survive restart anyway)
- Changes to the recipe execution logic itself

## 2. Background & Context

### Current State

The iOS client tracks recipe state via the `activeRecipes` dictionary in `VoiceCodeClient`. This state is updated purely based on WebSocket messages:

1. `recipe_started` → adds entry to `activeRecipes`
2. `recipe_exited` → removes entry from `activeRecipes`

When a recipe step completes, the backend sends two messages in sequence:
1. `recipe_exited` - signals recipe completion with reason
2. `turn_complete` - signals Claude CLI finished processing

The iOS client has no mechanism to recover if `recipe_exited` is missed, and no way to sync recipe state on WebSocket reconnection.

### Why Now

A user reported that a design recipe for session `41d7c44d-...` did not exit in the UI after returning `{"outcome":"committed"}`. Investigation revealed:
- The Claude session file confirmed the correct outcome was returned
- The backend server was restarted after the event, so logs were unavailable
- The root cause is the lack of state synchronization mechanisms

### Related Work

- @voice-code/STANDARDS.md - WebSocket protocol documentation
- @voice-code/backend/src/voice_code/server.clj - Backend WebSocket handlers
- @voice-code/ios/VoiceCode/Managers/VoiceCodeClient.swift - iOS WebSocket client

## 3. Detailed Design

### Data Model

No persistent data model changes. The fix operates on in-memory state:

**Backend** - `session-orchestration-state` atom (existing):
```clojure
;; session-id -> {:recipe-id :current-step :step-count :step-visit-counts ...}
```

**iOS** - `activeRecipes` dictionary (existing):
```swift
@Published var activeRecipes: [String: ActiveRecipe] = [:]  // session-id -> ActiveRecipe
```

### API Design

#### New Message Type: `active_recipes_sync`

Sent by backend to iOS after `connect` message is processed.

**Request**: N/A (server-initiated)

**Response**:
```json
{
  "type": "active_recipes_sync",
  "recipes": {
    "41d7c44d-2486-4609-9038-13f6c85b43ac": {
      "recipe_id": "document-design",
      "recipe_label": "Document Design",
      "current_step": "commit",
      "step_count": 3
    }
  }
}
```

When no recipes are active:
```json
{
  "type": "active_recipes_sync",
  "recipes": {}
}
```

#### Modified Message: `turn_complete`

No protocol change. iOS handling is enhanced to clear recipe state as a safety net.

### Code Examples

#### Fix 1: Safety Net - `turn_complete` Clears Recipe State (iOS)

**File**: `ios/VoiceCode/Managers/VoiceCodeClient.swift`

```swift
case "turn_complete":
    // Backend signals that Claude CLI has finished (turn is complete)
    if let sessionId = json["session_id"] as? String {
        print("✅ [VoiceCodeClient] Received turn_complete for \(sessionId)")

        // Note: Subscription now happens earlier via session_ready message
        // This is kept as fallback for compatibility
        if !self.activeSubscriptions.contains(sessionId) {
            print("📥 [VoiceCodeClient] Auto-subscribing to new session after turn_complete (fallback): \(sessionId)")
            self.subscribe(sessionId: sessionId)
        }

        // Safety net: Clear any active recipe for this session
        // This handles cases where recipe_exited message was missed (e.g., network issues)
        let currentRecipes = getCurrentValue(for: "activeRecipes", current: self.activeRecipes)
        if currentRecipes[sessionId] != nil {
            var updatedRecipes = currentRecipes
            updatedRecipes.removeValue(forKey: sessionId)
            scheduleUpdate(key: "activeRecipes", value: updatedRecipes)
            print("🏁 [VoiceCodeClient] Cleared recipe state on turn_complete (safety net): \(sessionId)")
        }

        let currentSessions = getCurrentValue(for: "lockedSessions", current: self.lockedSessions)
        if currentSessions.contains(sessionId) {
            var updatedSessions = currentSessions
            updatedSessions.remove(sessionId)
            scheduleUpdate(key: "lockedSessions", value: updatedSessions)
            print("🔓 [VoiceCodeClient] Unlocked session: \(sessionId) (turn complete, remaining locks: \(updatedSessions.count))")
            if !updatedSessions.isEmpty {
                print("   Still locked: \(Array(updatedSessions))")
            }
        }
    }
```

#### Fix 2: Recipe State Sync on Reconnection

**File**: `backend/src/voice_code/server.clj`

Add helper function:
```clojure
(defn get-active-recipes-for-client
  "Get all active recipes as a map of session-id -> recipe info for client sync"
  []
  (into {}
    (map (fn [[session-id state]]
           (let [recipe (recipes/get-recipe (:recipe-id state))]
             [session-id {:recipe-id (name (:recipe-id state))
                          :recipe-label (:label recipe)
                          :current-step (name (:current-step state))
                          :step-count (:step-count state)}]))
         @session-orchestration-state)))
```

In the `"connect"` handler, after sending `available-commands`:
```clojure
;; Send active recipes state for reconnection sync
(let [active-recipes (get-active-recipes-for-client)]
  (log/info "Sending active recipes sync" {:count (count active-recipes)})
  (send-to-client! channel
                   {:type :active-recipes-sync
                    :recipes active-recipes}))
```

**File**: `ios/VoiceCode/Managers/VoiceCodeClient.swift`

Add handler in `handleMessage`:
```swift
case "active_recipes_sync":
    // Sync active recipes state on reconnection
    // This replaces local state with server state to ensure consistency
    if let recipesDict = json["recipes"] as? [String: [String: Any]] {
        var syncedRecipes: [String: ActiveRecipe] = [:]
        for (sessionId, recipeJson) in recipesDict {
            if let recipeId = recipeJson["recipe_id"] as? String,
               let recipeLabel = recipeJson["recipe_label"] as? String,
               let currentStep = recipeJson["current_step"] as? String,
               let stepCount = recipeJson["step_count"] as? Int {
                syncedRecipes[sessionId] = ActiveRecipe(
                    recipeId: recipeId,
                    recipeLabel: recipeLabel,
                    currentStep: currentStep,
                    stepCount: stepCount
                )
            }
        }
        scheduleUpdate(key: "activeRecipes", value: syncedRecipes)
        if !syncedRecipes.isEmpty {
            print("🔄 [VoiceCodeClient] Synced \(syncedRecipes.count) active recipes on connect")
        }
    } else {
        // No recipes field or invalid format - clear any stale state
        let currentRecipes = getCurrentValue(for: "activeRecipes", current: self.activeRecipes)
        if !currentRecipes.isEmpty {
            scheduleUpdate(key: "activeRecipes", value: [:])
            print("🔄 [VoiceCodeClient] Cleared stale recipe state on connect")
        }
    }
```

#### Fix 3: Enhanced Logging for Recipe Exit

**File**: `backend/src/voice_code/server.clj`

Modify `send-to-client!` to return success/failure while preserving existing logging:
```clojure
(defn send-to-client!
  "Send message to a specific channel if it's connected. Returns true if sent, false otherwise."
  [channel message-data]
  (if (contains? @connected-clients channel)
    (do
      (log/info "Sending message to client" {:type (:type message-data)
                                              :session-id (:session-id message-data)})
      (let [json-str (generate-json message-data)]
        (log/info "JSON payload" {:json json-str})  ; Preserve existing payload logging
        (try
          (http/send! channel json-str)
          (log/info "Message sent successfully" {:type (:type message-data)})
          true
          (catch Exception e
            (log/warn e "Failed to send to client" {:type (:type message-data)
                                                     :session-id (:session-id message-data)})
            false))))
    (do
      (log/warn "Channel not in connected-clients, skipping send"
                {:type (:type message-data)
                 :session-id (:session-id message-data)})
      false)))
```

In `process-orchestration-response`, enhance the `:exit` case:
```clojure
:exit
(do
  (log/info "Recipe exiting" {:session-id session-id
                               :reason (:reason next-action)
                               :recipe-id (:recipe-id orch-state)
                               :step (:current-step orch-state)})
  (exit-recipe-for-session session-id (:reason next-action))
  (let [sent? (send-to-client! channel
                                {:type :recipe-exited
                                 :session-id session-id
                                 :reason (:reason next-action)})]
    (when-not sent?
      (log/warn "recipe_exited message not sent - client may have stale state"
                {:session-id session-id})))
  next-action)
```

### Component Interactions

**Normal Recipe Exit Flow**:
```
Backend                          iOS
   |                              |
   |-- recipe_exited ------------>|  (removes from activeRecipes)
   |-- turn_complete ------------>|  (unlocks session, safety net clears recipe if missed)
   |                              |
```

**Reconnection Flow**:
```
iOS                              Backend
 |                                  |
 |-- connect ------------------->   |
 |                                  |
 |<-- session-list -------------    |
 |<-- recent-sessions ----------    |
 |<-- available-commands -------    |
 |<-- active_recipes_sync ------    |  (NEW: syncs recipe state)
 |                                  |
```

**Missed recipe_exited Recovery**:
```
Backend                          iOS
   |                              |
   |-- recipe_exited -----X       |  (lost due to network)
   |-- turn_complete ------------>|  (safety net clears activeRecipes)
   |                              |
```

## 4. Verification Strategy

### Testing Approach

#### Unit Tests

**iOS Tests** (`ios/VoiceCodeTests/VoiceCodeClientRecipeTests.swift`):

Uses the existing test pattern with `client.handleMessage()` and Combine expectations:

```swift
func testTurnCompleteClearsRecipeState() throws {
    let expectation = XCTestExpectation(description: "Recipe cleared on turn_complete")

    // Setup: Manually set an active recipe (simulating recipe_started was received)
    var initialRecipes = client.activeRecipes
    initialRecipes["test-session"] = ActiveRecipe(
        recipeId: "document-design",
        recipeLabel: "Document Design",
        currentStep: "commit",
        stepCount: 3
    )
    // Note: In actual test, we'd send recipe_started message first

    let cancellable = client.$activeRecipes
        .dropFirst()
        .sink { recipes in
            if recipes["test-session"] == nil {
                expectation.fulfill()
            }
        }

    // Act: Send turn_complete for that session
    let message = """
    {"type": "turn_complete", "session_id": "test-session"}
    """
    client.handleMessage(message)

    wait(for: [expectation], timeout: 1.0)
    cancellable.cancel()
}

func testActiveRecipesSyncPopulatesState() throws {
    let expectation = XCTestExpectation(description: "Recipes synced on connect")

    let cancellable = client.$activeRecipes
        .dropFirst()
        .sink { recipes in
            if recipes["session-123"] != nil {
                XCTAssertEqual(recipes["session-123"]?.recipeId, "document-design")
                XCTAssertEqual(recipes["session-123"]?.currentStep, "review")
                XCTAssertEqual(recipes["session-123"]?.stepCount, 2)
                expectation.fulfill()
            }
        }

    let message = """
    {
        "type": "active_recipes_sync",
        "recipes": {
            "session-123": {
                "recipe_id": "document-design",
                "recipe_label": "Document Design",
                "current_step": "review",
                "step_count": 2
            }
        }
    }
    """
    client.handleMessage(message)

    wait(for: [expectation], timeout: 1.0)
    cancellable.cancel()
}

func testActiveRecipesSyncClearsStaleState() throws {
    let expectation = XCTestExpectation(description: "Stale recipes cleared")

    // First, add a recipe via recipe_started
    let startMessage = """
    {
        "type": "recipe_started",
        "session_id": "stale-session",
        "recipe_id": "old-recipe",
        "recipe_label": "Old Recipe",
        "current_step": "step1",
        "step_count": 1
    }
    """
    client.handleMessage(startMessage)

    // Wait for recipe to be added, then test sync clears it
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        let cancellable = self.client.$activeRecipes
            .dropFirst()
            .sink { recipes in
                if recipes.isEmpty {
                    expectation.fulfill()
                }
            }

        // Receive sync with empty recipes
        let syncMessage = """
        {"type": "active_recipes_sync", "recipes": {}}
        """
        self.client.handleMessage(syncMessage)

        // Store cancellable to prevent deallocation
        _ = cancellable
    }

    wait(for: [expectation], timeout: 2.0)
}
```

**Backend Tests** (`backend/test/voice_code/orchestration_server_test.clj`):

Add to existing test file, following established patterns:

```clojure
(deftest get-active-recipes-for-client-test
  (testing "returns empty map when no active recipes"
    (reset! server/session-orchestration-state {})
    (is (= {} (server/get-active-recipes-for-client))))

  (testing "returns formatted recipe data"
    ;; Use start-recipe-for-session to set up state properly
    (let [session-id "test-session-recipes"]
      (server/start-recipe-for-session session-id :document-design false)
      (let [result (server/get-active-recipes-for-client)]
        (is (= 1 (count result)))
        (is (= "document-design" (get-in result [session-id :recipe-id])))
        (is (= "Document Design" (get-in result [session-id :recipe-label])))
        (is (string? (get-in result [session-id :current-step])))
        (is (pos-int? (get-in result [session-id :step-count]))))
      ;; Cleanup
      (server/exit-recipe-for-session session-id "test-cleanup"))))

(deftest send-to-client-returns-status-test
  (testing "returns false when channel not in connected-clients"
    ;; Use a dummy channel object (any value works since we're testing the check)
    (let [fake-channel (Object.)]
      (is (false? (server/send-to-client! fake-channel {:type :test})))))

  (testing "returns true when channel is connected and send succeeds"
    ;; This requires integration test setup with actual WebSocket
    ;; For unit test, we verify the return value contract via the false case above
    ;; Full integration test covers the success path
    ))
```

**Note**: The `send-to-client!` success case requires an actual WebSocket channel. The unit test verifies the "channel not connected" path returns `false`. The success path (`true` return) is verified in integration tests where a real WebSocket connection is established.

#### Integration Tests

**1. Reconnection Sync Test**

Tests that recipe state is correctly synced when client reconnects mid-recipe.

Setup:
1. Start backend server
2. Connect iOS client via WebSocket
3. Start a recipe (e.g., `document-design`) for a session
4. Verify `recipe_started` is received and `activeRecipes` is populated

Test:
1. Disconnect the WebSocket (simulate network interruption)
2. Verify client's `activeRecipes` still contains the recipe (local state preserved)
3. Reconnect the WebSocket
4. Verify `active_recipes_sync` message is received
5. Verify `activeRecipes` matches server state (recipe still active)

Cleanup:
1. Exit the recipe
2. Disconnect client

**2. Safety Net Recovery Test**

Tests that `turn_complete` clears recipe state when `recipe_exited` is missed.

Setup:
1. Connect iOS client
2. Start a recipe for a session
3. Verify recipe is in `activeRecipes`

Test:
1. On backend, complete the recipe (outcome triggers exit)
2. Intercept/drop the `recipe_exited` WebSocket message (test infrastructure)
3. Allow `turn_complete` message through
4. Verify `activeRecipes` is cleared despite missing `recipe_exited`
5. Verify console log shows "Cleared recipe state on turn_complete (safety net)"

**3. Empty Sync Clears Stale State Test**

Tests that stale local state is cleared when server reports no active recipes.

Setup:
1. Connect iOS client
2. Manually inject stale recipe into `activeRecipes` (simulating prior session)

Test:
1. Disconnect and reconnect WebSocket
2. Verify `active_recipes_sync` with empty `recipes` is received
3. Verify `activeRecipes` is now empty

These integration tests require the test infrastructure to:
- Control WebSocket message delivery (intercept/drop specific messages)
- Access client's internal state (`activeRecipes`)
- Trigger backend recipe state changes

### Acceptance Criteria

1. When `turn_complete` is received for a session with an active recipe, the recipe is cleared from `activeRecipes`
2. When iOS connects/reconnects, it receives `active_recipes_sync` with current server state
3. iOS `activeRecipes` is replaced with server state on receiving `active_recipes_sync`
4. Empty `active_recipes_sync` clears any stale local recipe state
5. Backend logs include session-id when sending `recipe_exited`
6. Backend logs warning when `recipe_exited` cannot be sent (channel disconnected)
7. All existing recipe tests continue to pass

## 5. Alternatives Considered

### Alternative A: Buffer `recipe_exited` for Redelivery

Similar to how Claude responses are buffered for undelivered message replay.

**Pros**: Guarantees delivery of the original message

**Cons**:
- Significant complexity to implement message buffering
- Requires tracking acknowledgments per message type
- Overkill for a state that can be easily synced

**Decision**: Rejected. State sync on reconnection is simpler and handles more cases.

### Alternative B: Include Recipe State in `turn_complete`

Add `recipe_exited: true/false` or `active_recipe: null` field to `turn_complete`.

**Pros**: Single message handles both concerns

**Cons**:
- Conflates two distinct events (turn completion vs recipe completion)
- Breaking change to existing message format
- Doesn't help with reconnection sync

**Decision**: Rejected. Separate messages are clearer. The safety net achieves similar robustness.

### Alternative C: Polling for Recipe State

iOS periodically requests recipe state from backend.

**Pros**: Simple to implement, always eventually consistent

**Cons**:
- Increased network traffic
- Latency in state updates
- Not real-time

**Decision**: Rejected. Push-based sync on connect is more efficient.

## 6. Risks & Mitigations

### Risk: Race Condition Between `recipe_exited` and `active_recipes_sync`

If a recipe exits exactly as client reconnects, there could be a brief inconsistency where `active_recipes_sync` shows the recipe as active, then `recipe_exited` clears it.

**Detection**: Log timestamps on both messages; monitor for rapid state changes

**Mitigation**: The `turn_complete` safety net (Fix 1) provides final cleanup. Worst case is a brief UI flash.

### Risk: Increased Message Volume on Connect

Sending `active_recipes_sync` adds one message per connection.

**Detection**: Monitor message counts in backend logs

**Mitigation**: Message is small (typically empty). Only contains data when recipes are actively running, which is uncommon at connection time.

### Risk: iOS State Replacement Causes UI Flicker

Replacing `activeRecipes` entirely might cause brief UI inconsistency.

**Detection**: Test on device with slow animations enabled

**Mitigation**: Use `scheduleUpdate` batching. Recipe state changes are infrequent.

### Rollback Strategy

All three fixes are backward compatible:
- Fix 1: iOS-only change, no protocol impact
- Fix 2: New message type, old iOS ignores unknown types
- Fix 3: Logging-only, no behavioral change

Rollback: Deploy previous iOS version. Backend changes are additive and harmless.
