# Recipe New Session Support

## Overview

### Problem Statement
When starting a recipe on a new session (one that has never communicated with Claude), the backend fails because it unconditionally uses `:resume-session-id` when invoking Claude CLI. The Claude CLI's `--resume` flag requires an existing session file at `~/.claude/projects/<project>/<session-id>.jsonl`. For new sessions, this file doesn't exist, causing the CLI invocation to fail.

### Goals
1. Enable recipes to start on brand new sessions that have no prior Claude conversation
2. Seamlessly transition from "new session" to "resume session" mode after the first Claude interaction
3. Maintain backward compatibility with existing sessions
4. Preserve the current recipe orchestration loop structure

### Non-goals
- Changing the recipe step definitions or transitions
- Modifying how iOS creates or manages sessions
- Adding new recipe types
- Changing the session locking mechanism

## Background & Context

### Current State

The recipe orchestration flow in `server.clj`:

1. iOS sends `start_recipe` message with `session_id` (the iOS UUID)
2. Backend calls `start-recipe-for-session` to initialize orchestration state
3. Backend calls `execute-recipe-step` which invokes Claude with:
   ```clojure
   :resume-session-id session-id
   ```
4. Claude CLI fails if no `.jsonl` file exists for that session ID

The `invoke-claude-async` function accepts either `:new-session-id` or `:resume-session-id`:
- `:new-session-id` → uses `--session-id <id>` (creates new session)
- `:resume-session-id` → uses `--resume <id>` (requires existing session)

### Why Now
Users attempting to start a recipe from a freshly created session encounter failures. The recipe feature was developed with the assumption that sessions would already have at least one message exchange with Claude.

### Related Work
- @recipe-exit-reason-classification.md - Exit reason handling
- @STANDARDS.md - WebSocket protocol and session ID conventions

## Detailed Design

### Data Model

#### Orchestration State Changes

Current state structure (in `session-orchestration-state` atom):
```clojure
{session-id {:recipe-id :implement-and-review
             :current-step :implement
             :step-count 1
             :step-visit-counts {:implement 1}
             :step-retry-counts {}
             :start-time 1699900000000}}
```

Proposed addition - add `:session-created?` flag:
```clojure
{session-id {:recipe-id :implement-and-review
             :current-step :implement
             :step-count 1
             :step-visit-counts {:implement 1}
             :step-retry-counts {}
             :start-time 1699900000000
             :session-created? false}}  ; <-- new field
```

The `:session-created?` flag tracks whether the Claude session file has been created:
- `false` initially for new sessions
- `true` after first successful Claude invocation
- `true` immediately for existing sessions (detected via metadata check)

### API Design

#### WebSocket Protocol Changes

**`start_recipe` Message** - Optional enhancement (no breaking changes):

Current:
```json
{
  "type": "start_recipe",
  "session_id": "<ios-session-uuid>",
  "recipe_id": "implement-and-review",
  "working_directory": "/path/to/project"
}
```

The `working_directory` field becomes **required for new sessions** since there's no session metadata to extract it from. For existing sessions, it remains optional (backend falls back to stored metadata).

**Error Response** - New error case:
```json
{
  "type": "error",
  "message": "working_directory required for new session",
  "session_id": "<ios-session-uuid>"
}
```

### Code Examples

#### Backend: Session Creation Detection

In `server.clj`, add helper function:

```clojure
(defn session-exists?
  "Check if a Claude session file exists for the given session ID.
   Returns true if session metadata exists (implying .jsonl file exists)."
  [session-id]
  (some? (repl/get-session-metadata session-id)))
```

#### Backend: Modified start_recipe Handler

```clojure
"start_recipe"
(let [recipe-id (keyword (:recipe-id data))
      session-id (:session-id data)
      working-directory (:working-directory data)
      is-new-session? (not (session-exists? session-id))]
  (cond
    (not session-id)
    (send-to-client! channel
                     {:type :error
                      :message "session_id required in start_recipe message"})

    (not recipe-id)
    (send-to-client! channel
                     {:type :error
                      :message "recipe_id required in start_recipe message"})

    ;; New validation: working_directory required for new sessions
    (and is-new-session? (str/blank? working-directory))
    (send-to-client! channel
                     {:type :error
                      :message "working_directory required for new session"
                      :session-id session-id})

    :else
    (if-let [orch-state (start-recipe-for-session session-id recipe-id is-new-session?)]
      ;; ... rest of handler
      )))
```

#### Backend: Modified start-recipe-for-session

```clojure
(defn start-recipe-for-session
  "Initialize orchestration state for a session.
   is-new-session? indicates whether this is a brand new session with no Claude history."
  [session-id recipe-id is-new-session?]
  (if-let [state (orch/create-orchestration-state recipe-id)]
    (let [state-with-session-flag (assoc state :session-created? (not is-new-session?))]
      (swap! session-orchestration-state assoc session-id state-with-session-flag)
      (orch/log-orchestration-event "recipe-started" session-id recipe-id
                                     (:current-step state)
                                     {:is-new-session is-new-session?})
      state-with-session-flag)
    (do
      (log/error "Recipe not found" {:recipe-id recipe-id :session-id session-id})
      nil)))
```

#### Backend: Modified execute-recipe-step

Key change - conditionally use `:new-session-id` vs `:resume-session-id`:

```clojure
(defn execute-recipe-step
  "Execute a single step of a recipe and handle the response.
   ..."
  ([channel session-id working-dir orch-state recipe]
   (execute-recipe-step channel session-id working-dir orch-state recipe nil))
  ([channel session-id working-dir orch-state recipe prompt-override]
   (let [step-prompt (or prompt-override (get-next-step-prompt session-id orch-state recipe))
         current-step (:current-step orch-state)
         session-created? (:session-created? orch-state)]
     (if step-prompt
       (do
         (log/info "Executing recipe step"
                   {:session-id session-id
                    :recipe-id (:recipe-id orch-state)
                    :step current-step
                    :session-created? session-created?
                    :step-count (:step-count orch-state)})

         ;; Send step transition notification (only for non-retry)
         (when-not prompt-override
           (send-to-client! channel
                            {:type :recipe-step-started
                             :session-id session-id
                             :step current-step
                             :step-count (:step-count orch-state)}))

         ;; Invoke Claude with appropriate session ID type
         (claude/invoke-claude-async
          step-prompt
          (fn [response]
            (try
              (if (:success response)
                (let [response-text (:result response)
                      current-orch-state (get-session-recipe-state session-id)]
                  ;; Mark session as created after first successful invocation
                  (when (and current-orch-state (not session-created?))
                    (swap! session-orchestration-state
                           update session-id
                           assoc :session-created? true))
                  ;; ... rest of response handling
                  )
                ;; ... error handling
                ))
            ;; ... exception handling
            ))
          ;; Conditionally pass new-session-id or resume-session-id
          ;; For new sessions (session-created? = false), use :new-session-id
          ;; For existing sessions (session-created? = true), use :resume-session-id
          (if session-created? :resume-session-id :new-session-id) session-id
          :working-directory working-dir
          :model (get-step-model recipe current-step)
          :timeout-ms 86400000))
       ;; ... no prompt error handling
       ))))
```

### Component Interactions

#### Sequence Diagram: New Session Recipe Start

```
iOS                    Backend                           Claude CLI
 |                        |                                  |
 |--start_recipe--------->|                                  |
 |  session_id: abc123    |                                  |
 |  recipe_id: impl       |                                  |
 |  working_dir: /proj    |                                  |
 |                        |                                  |
 |                        |--session-exists?(abc123)         |
 |                        |  returns: false                  |
 |                        |                                  |
 |                        |--start-recipe-for-session        |
 |                        |  is-new-session?: true           |
 |                        |  state[:session-created?]=false  |
 |                        |                                  |
 |<--recipe_started-------|                                  |
 |                        |                                  |
 |                        |--execute-recipe-step             |
 |                        |  session-created?=false          |
 |                        |                                  |
 |                        |--invoke-claude-async------------>|
 |                        |  :new-session-id abc123          |
 |                        |  (uses --session-id abc123)      |
 |                        |                                  |
 |                        |<--success------------------------|
 |                        |  .jsonl file now exists          |
 |                        |                                  |
 |                        |--update state                    |
 |                        |  :session-created? = true        |
 |                        |                                  |
 |                        |--execute-recipe-step (step 2)    |
 |                        |  session-created?=true           |
 |                        |                                  |
 |                        |--invoke-claude-async------------>|
 |                        |  :resume-session-id abc123       |
 |                        |  (uses --resume abc123)          |
```

#### Sequence Diagram: Existing Session Recipe Start

```
iOS                    Backend                           Claude CLI
 |                        |                                  |
 |--start_recipe--------->|                                  |
 |  session_id: xyz789    |                                  |
 |  recipe_id: impl       |                                  |
 |                        |                                  |
 |                        |--session-exists?(xyz789)         |
 |                        |  returns: true                   |
 |                        |                                  |
 |                        |--start-recipe-for-session        |
 |                        |  is-new-session?: false          |
 |                        |  state[:session-created?]=true   |
 |                        |                                  |
 |<--recipe_started-------|                                  |
 |                        |                                  |
 |                        |--execute-recipe-step             |
 |                        |  session-created?=true           |
 |                        |                                  |
 |                        |--invoke-claude-async------------>|
 |                        |  :resume-session-id xyz789       |
 |                        |  (uses --resume xyz789)          |
```

## Verification Strategy

### Testing Approach

#### Unit Tests

1. **`session-exists?` function tests**
   - Returns `false` when `get-session-metadata` returns `nil`
   - Returns `true` when `get-session-metadata` returns data

2. **`start-recipe-for-session` tests**
   - Sets `:session-created? false` when `is-new-session?` is `true`
   - Sets `:session-created? true` when `is-new-session?` is `false`

3. **Orchestration state update tests**
   - `:session-created?` transitions from `false` to `true` after successful invocation

#### Integration Tests

1. **New session recipe start**
   - Mock `get-session-metadata` to return `nil`
   - Verify `invoke-claude-async` called with `:new-session-id`
   - Verify state updates to `:session-created? true` after success

2. **Existing session recipe start**
   - Mock `get-session-metadata` to return valid metadata
   - Verify `invoke-claude-async` called with `:resume-session-id`

3. **Missing working_directory validation**
   - New session without `working_directory` returns error

### Test Examples

Tests would be added to `backend/test/voice_code/server_test.clj`:

```clojure
(ns voice-code.server-test
  (:require [clojure.test :refer :all]
            [voice-code.server :as server]
            [voice-code.claude :as claude]
            [voice-code.replication :as repl]
            [voice-code.recipes :as recipes]))

(deftest start-recipe-for-session-test
  (testing "new session sets session-created? to false"
    ;; Reset state before test
    (reset! server/session-orchestration-state {})
    (let [state (server/start-recipe-for-session "new-session-id" :implement-and-review true)]
      (is (some? state))
      (is (false? (:session-created? state)))))

  (testing "existing session sets session-created? to true"
    (reset! server/session-orchestration-state {})
    (let [state (server/start-recipe-for-session "existing-session-id" :implement-and-review false)]
      (is (some? state))
      (is (true? (:session-created? state))))))

(deftest session-exists-test
  (testing "returns false when no metadata"
    (with-redefs [repl/get-session-metadata (constantly nil)]
      (is (false? (server/session-exists? "unknown-session")))))

  (testing "returns true when metadata exists"
    (with-redefs [repl/get-session-metadata (constantly {:session-id "known"})]
      (is (true? (server/session-exists? "known-session"))))))

(deftest execute-recipe-step-session-id-type-test
  ;; Use simple keyword for mock channel - org.httpkit.server/send! is mocked via with-redefs
  (let [mock-channel :test-ch
        mock-recipe (recipes/get-recipe :implement-and-review)]

    (testing "uses new-session-id when session not created"
      (let [invoke-args (atom nil)]
        (reset! server/session-orchestration-state {})
        (with-redefs [org.httpkit.server/send! (fn [_ _] true)
                      claude/invoke-claude-async
                      (fn [prompt callback & opts]
                        (reset! invoke-args (apply hash-map opts))
                        nil)
                      server/get-next-step-prompt (constantly "test prompt")]
          (server/execute-recipe-step mock-channel "session-1" "/test/dir"
                                      {:recipe-id :implement-and-review
                                       :current-step :implement
                                       :step-count 1
                                       :session-created? false}
                                      mock-recipe)
          (is (contains? @invoke-args :new-session-id))
          (is (not (contains? @invoke-args :resume-session-id))))))

    (testing "uses resume-session-id when session created"
      (let [invoke-args (atom nil)]
        (reset! server/session-orchestration-state {})
        (with-redefs [org.httpkit.server/send! (fn [_ _] true)
                      claude/invoke-claude-async
                      (fn [prompt callback & opts]
                        (reset! invoke-args (apply hash-map opts))
                        nil)
                      server/get-next-step-prompt (constantly "test prompt")]
          (server/execute-recipe-step mock-channel "session-1" "/test/dir"
                                      {:recipe-id :implement-and-review
                                       :current-step :implement
                                       :step-count 1
                                       :session-created? true}
                                      mock-recipe)
          (is (contains? @invoke-args :resume-session-id))
          (is (not (contains? @invoke-args :new-session-id))))))))
```

### Acceptance Criteria

1. Starting a recipe on a new session (no prior Claude interaction) succeeds
2. The first recipe step uses `--session-id` flag (not `--resume`)
3. Subsequent recipe steps use `--resume` flag
4. Existing sessions continue to work with `--resume` from the first step
5. Starting a recipe on a new session without `working_directory` returns a clear error message
6. Recipe state includes `:session-created?` flag that transitions correctly
7. Logging indicates whether session is new or existing

## Alternatives Considered

### Alternative 1: iOS Passes is_new_session Flag

**Approach**: iOS explicitly sends `is_new_session: true/false` in `start_recipe` message.

**Pros**:
- Explicit contract between iOS and backend
- No backend detection logic needed

**Cons**:
- Requires iOS changes
- iOS must track session state more carefully
- Potential for iOS/backend state mismatch

**Decision**: Rejected. Backend detection is simpler and more reliable since the backend is the source of truth for session existence.

### Alternative 2: Always Use --session-id

**Approach**: Always use `--session-id` instead of `--resume` for all recipe steps.

**Pros**:
- Simpler implementation
- No state tracking needed

**Cons**:
- May have different behavior than `--resume` (unclear from Claude CLI docs)
- Breaks existing session continuity expectations
- May cause issues with context window management

**Decision**: Rejected. The distinction between new and resume modes exists for a reason; we should respect it.

### Alternative 3: Create Empty Session Before Recipe

**Approach**: Send a no-op prompt to create the session file before starting the recipe.

**Pros**:
- Recipe logic stays unchanged
- Session file always exists when recipe starts

**Cons**:
- Adds latency (extra Claude invocation)
- Wastes API tokens
- Creates confusing conversation history

**Decision**: Rejected. Wasteful and creates poor UX.

## Risks & Mitigations

### Risk 1: State Inconsistency After Crash

**Risk**: If backend crashes after first step but before updating `:session-created?`, the flag could be wrong on restart.

**Mitigation**: The flag is derived from session existence check at recipe start. If the session file exists (because first step completed), `session-exists?` will return `true` on next recipe start attempt. The flag is only used within a single recipe execution.

### Risk 2: Race Condition in State Update

**Risk**: Multiple concurrent updates to `session-orchestration-state` could cause inconsistency.

**Mitigation**: Use `swap!` with `update` for atomic updates. The session lock already prevents concurrent recipe steps on the same session.

### Risk 3: iOS Sends Stale working_directory

**Risk**: iOS might send an incorrect working directory that doesn't match the project.

**Mitigation**: This is an existing issue not introduced by this change. The validation ensures a directory is provided; correctness is the user's responsibility.

### Rollback Strategy

If issues are discovered:
1. Revert the code changes
2. No data migration needed (`:session-created?` is ephemeral state)
3. Users can continue using recipes only on existing sessions (previous behavior)
