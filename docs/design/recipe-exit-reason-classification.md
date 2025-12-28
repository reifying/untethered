# Recipe Exit Reason Classification

## Overview

### Problem Statement
When a recipe hits a guardrail limit (max-step-visits or max-total-steps), the system logs "Recipe exited" and sends `recipe-exited` with a reason string, but treats this the same as a normal recipe completion. The user correctly identified that hitting `max-iterations` (now `max-total-steps`) is not a "completion" — it's a safety limit being triggered, which indicates the recipe may not have achieved its goal.

### Goals
1. Classify exit reasons into distinct categories: successful completion, guardrail exit, and error
2. Provide different messaging and UI treatment based on exit category
3. Enable iOS to display appropriate status indicators (success vs. warning vs. error)
4. Improve logging to distinguish between normal exits and safety limit triggers

### Non-goals
- Changing the guardrail logic itself
- Adding new guardrail types
- Persisting exit state across server restarts (handled separately)

## Background & Context

### Current State
The orchestration loop handles three exit scenarios identically:

1. **Normal exit**: Recipe step's `on-outcome` specifies `{:action :exit :reason "..."}`
2. **Guardrail exit**: `should-exit-recipe?` returns a reason string when limits exceeded
3. **Error exit**: JSON parsing fails, Claude invocation fails, or unexpected errors

All three send the same message structure:
```clojure
(send-to-client! channel
                 {:type :recipe-exited
                  :session-id session-id
                  :reason exit-reason})
```

The `reason` field contains a string like:
- `"task-committed"` (normal completion)
- `"design-committed"` (normal completion)
- `"tasks-committed"` (normal completion)
- `"no-changes-to-commit"` (normal completion)
- `"clarification-needed"` (normal completion - user input needed)
- `"implementation-blocked"` (normal completion - cannot proceed)
- `"no-design-document-found"` (normal completion - prerequisite missing)
- `"user-provided-other"` (normal completion - user chose custom exit)
- `"max-total-steps"` (guardrail)
- `"max-step-visits-exceeded:code-review"` (guardrail)
- `"orchestration-error"` (error)
- `"error"` (Claude invocation failed)
- `"internal-error"` (exception in callback)
- `"no-prompt"` (no step prompt available)

### Why Now
The first end-to-end recipe test revealed that a recipe ran 5 iterations (implement → code-review → fix → code-review → implement) and hit the step limit. The log showed "Recipe exited" with reason `max-total-steps`, which is confusing because:
1. The recipe didn't complete successfully — it was stopped by a safety limit
2. The iOS client has no way to distinguish this from successful completion
3. User cannot tell if the task was actually finished

### Related Work
- @STANDARDS.md - WebSocket protocol documentation
- @backend/src/voice_code/recipes.clj - Recipe definitions with guardrails
- @backend/src/voice_code/orchestration.clj - Orchestration state management

## Detailed Design

### Data Model

#### Exit Reason Categories

Introduce an exit category enum with three values:

```clojure
;; Exit categories
(def exit-categories
  #{:completed      ;; Recipe achieved its goal normally
    :guardrail     ;; Safety limit prevented continuation
    :error})       ;; Something went wrong

;; Category classification rules
(def guardrail-prefixes
  #{"max-total-steps"
    "max-step-visits-exceeded"})

(def error-reasons
  #{"orchestration-error"
    "error"
    "internal-error"
    "no-prompt"})
```

#### Exit Result Structure

Before:
```clojure
{:action :exit :reason "task-committed"}
```

After:
```clojure
{:action :exit
 :reason "task-committed"
 :category :completed}
```

#### WebSocket Message Changes

Before:
```json
{
  "type": "recipe_exited",
  "session_id": "abc123",
  "reason": "max-total-steps"
}
```

After:
```json
{
  "type": "recipe_exited",
  "session_id": "abc123",
  "reason": "max-total-steps",
  "category": "guardrail",
  "message": "Recipe stopped: reached maximum step limit (100 steps)"
}
```

### API Design

#### New Function: `classify-exit-reason`

```clojure
(defn classify-exit-reason
  "Classify an exit reason into a category.
   Returns :completed, :guardrail, or :error."
  [reason]
  (cond
    ;; Check for guardrail prefixes
    (some #(str/starts-with? reason %) guardrail-prefixes)
    :guardrail

    ;; Check for known error reasons
    (contains? error-reasons reason)
    :error

    ;; Everything else is a normal completion
    :else
    :completed))
```

#### New Function: `exit-reason->message`

```clojure
(defn exit-reason->message
  "Generate a human-readable message for an exit reason."
  [reason category]
  (case category
    :completed
    (case reason
      "task-committed" "Task implementation committed successfully"
      "design-committed" "Design document committed successfully"
      "tasks-committed" "Implementation tasks created and committed"
      "no-changes-to-commit" "No changes to commit"
      "clarification-needed" "Needs clarification before continuing"
      "implementation-blocked" "Implementation blocked - cannot proceed"
      "no-design-document-found" "Design document not found"
      "user-provided-other" "Recipe exited by user choice"
      ;; Default for other completion reasons
      (str "Completed: " reason))

    :guardrail
    (cond
      (= reason "max-total-steps")
      "Recipe stopped: reached maximum step limit"

      (str/starts-with? reason "max-step-visits-exceeded:")
      (let [step-name (subs reason (count "max-step-visits-exceeded:"))]
        (str "Recipe stopped: step '" step-name "' visited too many times"))

      :else
      (str "Recipe stopped by safety limit: " reason))

    :error
    (case reason
      "orchestration-error" "Recipe failed: could not parse agent response"
      "error" "Recipe failed: Claude invocation error"
      "internal-error" "Recipe failed: internal error"
      "no-prompt" "Recipe failed: no prompt available"
      (str "Recipe failed: " reason))))
```

#### Updated `process-orchestration-response`

Both exit paths (guardrail and normal) need to classify and add messages:

```clojure
;; In process-orchestration-response, guardrail exit case:
(if exit-reason
  (let [category (orch/classify-exit-reason exit-reason)
        message (orch/exit-reason->message exit-reason category)]
    (log/info "Recipe stopped by guardrail"
              {:session-id session-id
               :recipe-id (:recipe-id orch-state)
               :step current-step
               :reason exit-reason
               :category category})
    (exit-recipe-for-session session-id exit-reason)
    (send-to-client! channel
                     {:type :recipe-exited
                      :session-id session-id
                      :reason exit-reason
                      :category category
                      :message message})
    {:action :exit :reason exit-reason :category category})
  ;; ... normal transition
  )

;; In process-orchestration-response, normal exit case (when step returns :exit action):
:exit
(let [reason (:reason next-action)
      category (orch/classify-exit-reason reason)
      message (orch/exit-reason->message reason category)]
  (exit-recipe-for-session session-id reason)
  (send-to-client! channel
                   {:type :recipe-exited
                    :session-id session-id
                    :reason reason
                    :category category
                    :message message})
  {:action :exit :reason reason :category category})
```

#### Updated `execute-recipe-step` Logging

Before:
```clojure
(log/info "Recipe exited"
          {:session-id session-id
           :reason (:reason result)})
```

After:
```clojure
(log/info (case (:category result)
            :completed "Recipe completed"
            :guardrail "Recipe stopped by guardrail"
            :error "Recipe failed"
            "Recipe exited")
          {:session-id session-id
           :reason (:reason result)
           :category (:category result)})
```

### Component Interactions

#### Sequence: Recipe Exit Flow

```
Claude Response → process-orchestration-response
                          ↓
                  Parse JSON outcome
                          ↓
                  determine-next-action → {:action :exit :reason "..."}
                          ↓
                  classify-exit-reason → :completed/:guardrail/:error
                          ↓
                  exit-reason->message → "Human readable message"
                          ↓
                  Send recipe_exited with category + message
                          ↓
                  iOS displays appropriate UI treatment
```

#### iOS UI Treatment (guidance for iOS implementation)

| Category    | Color   | Icon     | Action                    |
|-------------|---------|----------|---------------------------|
| `:completed`  | Green   | ✓ check  | Show success, dismiss     |
| `:guardrail`  | Yellow  | ⚠ warning | Show warning, offer retry |
| `:error`      | Red     | ✗ error  | Show error, offer retry   |

### Protocol Documentation Update

Update @STANDARDS.md WebSocket protocol section to document the enhanced `recipe_exited` message:

```markdown
**Recipe Exited**
\`\`\`json
{
  "type": "recipe_exited",
  "session_id": "<claude-session-id>",
  "reason": "<exit-reason-string>",
  "category": "<completed|guardrail|error>",
  "message": "<human-readable-message>",
  "error": "<error-details>"  // Optional, only present for errors
}
\`\`\`

**Fields:**
- `reason`: Machine-readable exit reason (e.g., "task-committed", "max-total-steps")
- `category`: Classification of exit type
  - `completed`: Recipe achieved its goal normally
  - `guardrail`: Safety limit prevented continuation (may not have achieved goal)
  - `error`: Something went wrong during execution
- `message`: Human-readable description suitable for display
- `error`: Additional error details (only present when category is "error")
```

## Verification Strategy

### Testing Approach

#### Unit Tests

1. `classify-exit-reason` - test all reason strings map to correct categories
2. `exit-reason->message` - test all reason/category combos produce readable messages
3. `should-exit-recipe?` - verify guardrail detection still works

#### Integration Tests

1. Recipe completes normally → verify category is `:completed`
2. Recipe hits max-total-steps → verify category is `:guardrail`
3. Recipe hits max-step-visits → verify category is `:guardrail`
4. JSON parsing fails twice → verify category is `:error`

### Test Examples

```clojure
(ns voice-code.orchestration-test
  (:require [clojure.test :refer :all]
            [clojure.string :as str]
            [voice-code.orchestration :as orch]))

(deftest classify-exit-reason-test
  (testing "guardrail reasons"
    (is (= :guardrail (orch/classify-exit-reason "max-total-steps")))
    (is (= :guardrail (orch/classify-exit-reason "max-step-visits-exceeded:code-review"))))

  (testing "error reasons"
    (is (= :error (orch/classify-exit-reason "orchestration-error")))
    (is (= :error (orch/classify-exit-reason "error")))
    (is (= :error (orch/classify-exit-reason "internal-error"))))

  (testing "completion reasons"
    (is (= :completed (orch/classify-exit-reason "task-committed")))
    (is (= :completed (orch/classify-exit-reason "design-committed")))
    (is (= :completed (orch/classify-exit-reason "no-changes-to-commit")))
    (is (= :completed (orch/classify-exit-reason "clarification-needed")))
    (is (= :completed (orch/classify-exit-reason "implementation-blocked")))
    (is (= :completed (orch/classify-exit-reason "no-design-document-found")))
    (is (= :completed (orch/classify-exit-reason "user-provided-other")))))

(deftest exit-reason->message-test
  (testing "guardrail messages are descriptive"
    (let [msg (orch/exit-reason->message "max-total-steps" :guardrail)]
      (is (str/includes? msg "maximum step limit"))))

  (testing "step-specific guardrail messages include step name"
    (let [msg (orch/exit-reason->message "max-step-visits-exceeded:code-review" :guardrail)]
      (is (str/includes? msg "code-review"))))

  (testing "completion messages are positive"
    (let [msg (orch/exit-reason->message "task-committed" :completed)]
      (is (str/includes? msg "successfully")))))
```

### Acceptance Criteria

1. Exit reasons are classified into exactly one of: `:completed`, `:guardrail`, `:error`
2. WebSocket `recipe_exited` message includes `category` field
3. WebSocket `recipe_exited` message includes human-readable `message` field
4. Log messages use category-specific prefixes ("Recipe completed", "Recipe stopped by guardrail", "Recipe failed")
5. All existing exit reasons have defined classifications
6. iOS can distinguish between success, warning, and error states
7. STANDARDS.md WebSocket protocol documentation updated with new `recipe_exited` message fields

## Alternatives Considered

### Alternative 1: Boolean `success` field
Instead of a category enum, add a simple boolean `success` field.

**Rejected because**: Doesn't distinguish between guardrail (warning) and error (failure). User would not know if the recipe was stopped safely or if something went wrong.

### Alternative 2: Separate message types
Use `recipe_completed`, `recipe_stopped`, `recipe_failed` instead of `recipe_exited`.

**Rejected because**: Breaking change to the protocol. Adding a `category` field is additive and backward-compatible.

### Alternative 3: Infer category on iOS from reason string
Let iOS parse the reason string to determine category.

**Rejected because**: Duplicates logic across platforms. Backend should own the classification logic since it defines the reason strings.

## Risks & Mitigations

### Risk: Missing exit reason classification
New exit reasons added in the future might not be classified correctly.

**Mitigation**: Default to `:completed` for unknown reasons (fail safe). Add test that enumerates all known reason strings from recipes and verifies they have explicit classifications.

### Risk: iOS not handling new category field
Older iOS versions might not understand the new fields.

**Mitigation**: Fields are additive. iOS can ignore them if not understood. The existing `reason` field is preserved.

### Risk: Log message format changes break log parsers
If any tooling parses log messages, the change from "Recipe exited" to "Recipe completed/stopped/failed" could break.

**Mitigation**: Include structured data in log metadata. The important information is in the structured fields, not the message prefix.

## Quality Checklist
- [x] All code examples are syntactically correct
- [x] Examples match the codebase's style and conventions
- [x] Verification steps are specific and actionable
- [x] Cross-references to related files use @filename.md format
- [x] No placeholder text remains
