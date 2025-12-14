# Orchestration Technical Design

## Overview

This document describes how orchestration integrates into the existing voice-code-orchestration architecture to support automated workflow recipes.

## Architecture Context

**Existing System**:
- Backend: Clojure HTTP-Kit WebSocket server in `backend/src/voice_code/`
- Message flow: iOS → WebSocket → `server.clj` (dispatcher) → `claude.clj` (invoke Claude CLI) → filesystem → `replication.clj` (watch & broadcast) → iOS
- Session state: Persisted in JSONL files at `~/.claude/projects/{project}/{session-id}.jsonl`
- Locking: Per-session locks prevent concurrent Claude CLI invocations

**Key files**:
- `server.clj`: Main message handler (handle-message function with case on message type)
- `claude.clj`: Invokes Claude CLI, parses JSON output
- `replication.clj`: Filesystem watcher, session indexing, subscription management

---

## 1. Backend Integration Points

### 1.1 New Modules Required

**`recipes.clj`** - Recipe definitions and state machine logic
- Define recipes as data structures (state machines)
- Recipe selection logic
- Outcome validation
- Transition determination

**`orchestration.clj`** - Orchestration loop and prompt construction
- Track active recipe per session
- Construct prompts with JSON outcome appending
- Parse JSON responses and extract outcomes
- Determine next action based on outcome
- Handle invalid JSON (retry with guidance)
- Manage recipe state transitions

### 1.2 Modifications to `server.clj`

**New message type**: `"start_recipe"`
- Input: `{type: "start_recipe", recipe_id: "implement-and-review", session_id: "...", ios_session_id: "..."}`
- Action: Acquire session lock, determine first prompt, call orchestration loop
- Output: Send first prompt via normal prompt flow or error if recipe not found

**Modification to `"prompt"` handler**:
- Check if session is in active recipe
- If yes: intercept response, parse JSON outcome, determine next action
- If no: normal prompt flow (no JSON parsing)

**New message types for recipe control**:
- `"exit_recipe"`: User manually exits orchestration, return to normal chat
- `"get_available_recipes"`: List available recipes to iOS

### 1.3 Session State Extension

Current session tracking in `replication.clj`:
- Session metadata: ID, name, working directory, last modified, message count

Add:
```clojure
{:session-id "..."
 :active-recipe {:recipe-id "implement-and-review"
                 :current-step "code-review"           ; e.g., "implement", "code-review", "fix"
                 :iteration-count 1                    ; track loops to enforce guardrails
                 :max-iterations 5}
 :recipe-history [{:step "implement" :outcome "complete" :timestamp "..."}
                  {:step "code-review" :outcome "issues-found" :timestamp "..."}]}
```

Storage: Extend session metadata file (edn) or in-memory atom. Filesystem-watched for persistence.

---

## 2. Recipe Definition Structure

### 2.1 Recipe Format (Clojure)

```clojure
(def implement-and-review-recipe
  {:id :implement-and-review
   :description "Implement task, review, and fix issues in a loop"
   :initial-step :implement
   :steps
   {:implement
    {:prompt "Run bd ready and implement the task."
     :outcomes #{:complete :other}
     :on-outcome
     {:complete {:next-step :code-review}
      :other {:action :exit :reason "user-provided-other"}}}

    :code-review
    {:prompt "Perform a code review on the task that you just completed."
     :outcomes #{:no-issues :issues-found :other}
     :on-outcome
     {:no-issues {:next-step :implement}  ; loop back
      :issues-found {:next-step :fix}
      :other {:action :exit :reason "user-provided-other"}}}

    :fix
    {:prompt "Address the issues found."
     :outcomes #{:complete :other}
     :on-outcome
     {:complete {:next-step :code-review}  ; re-review
      :other {:action :exit :reason "user-provided-other"}}}

   :guardrails
   {:max-iterations 5  ; prevent runaway loops
    :exit-on-other true}})  ; any "other" outcome exits
```

### 2.2 Validation

Validate recipes at load time using Clojure spec:
- All `next-step` values reference defined steps
- All outcomes in `on-outcome` map are in `:outcomes` set
- Guardrails have sensible values
- No cycles (graph analysis)

---

## 3. Response Parsing

### 3.1 JSON Extraction from Claude Response

Claude's `--output-format json` produces a structure like:
```json
{
  "thinking": "...",
  "text": "...",
  "command": "...",
  "type": "..."
}
```

The agent's orchestration outcome JSON will be embedded in the response `text` field. We need to:

1. **Extract from JSON response**: Get `response["text"]` from Claude
2. **Find JSON block**: Search for JSON object pattern in text (e.g., `{...}` on its own line)
3. **Parse JSON**: Try to parse the extracted JSON block
4. **Validate structure**: Ensure `outcome` field exists and is in expected outcomes

### 3.2 Parsing Logic (pseudocode)

```clojure
(defn extract-outcome-json [response-text]
  "Extract orchestration JSON from Claude's response text"
  ;; Try multiple strategies:
  ;; 1. Look for `{...}` on final lines
  ;; 2. If found, try to parse as JSON
  ;; 3. If malformed, try simple repair (remove markdown fences, etc.)
  ;; 4. If still fails, return nil (invalid JSON)
  )

(defn parse-orchestration-outcome [claude-response expected-outcomes]
  "Parse outcome from Claude response"
  ;; Extract text from JSON response
  ;; Find JSON block
  ;; Parse and validate against expected-outcomes
  ;; Return {:outcome :no-issues} or {:outcome :other :otherDescription "..."} or error
  )
```

### 3.3 JSON Repair Strategies

When `parse-orchestration-outcome` encounters malformed JSON:

1. **Remove markdown code fences**: `json {...}\n` → `{...}`
2. **Trim whitespace and comments**: Leading/trailing content
3. **Check for incomplete objects**: Missing closing braces
4. **Return error** if still unparseable

### 3.4 Invalid JSON Handling

If parsing fails:
1. Log the malformed JSON with session ID for debugging
2. Send back to agent: `"Please respond again with JSON per the instructions. Respond with a JSON object with an 'outcome' field. Your possible outcomes: {outcomes}..."`
3. Increment retry counter
4. If max retries exceeded: `exit recipe, notify user`

---

## 4. Orchestration Loop (Backend)

### 4.1 Flow Diagram

```
start_recipe message from iOS
    ↓
Acquire session lock
    ↓
Get recipe definition
    ↓
Initialize active-recipe state
    ↓
Determine current step
    ↓
Get step prompt
    ↓
Append outcome requirements to prompt
    ↓
Invoke Claude with modified prompt
    ↓
Claude responds with JSON outcome
    ↓
Parse outcome
    ├─ Success: outcome found and valid
    │  ↓
    │  Validate outcome is in expected outcomes
    │  ↓
    │  Look up transition in recipe
    │  ├─ next-step: Update recipe state, loop back to "Determine current step"
    │  ├─ exit: Release lock, return to normal chat, notify iOS
    │  └─ error: Log and exit
    │
    └─ Failure: invalid JSON or parse error
       ↓
       Retry with guidance prompt
       ├─ Max retries: exit recipe, notify user
       └─ Retry count < max: loop back to "Invoke Claude"
```

### 4.2 Prompt Appending

For each orchestrated prompt, append:

```
{outcome_format_block}
```

Where `outcome_format_block` is:

```
End your response with a JSON block on the last line:
{"outcome": "<outcome>"}

or if needed:

{"outcome": "other", "otherDescription": "<brief description>"}

Your possible outcomes for this step: {outcome1}, {outcome2}, ...
```

Example for code review step:
```
End your response with a JSON block on the last line:
{"outcome": "<outcome>"}

or if needed:

{"outcome": "other", "otherDescription": "<brief description>"}

Your possible outcomes for this step: no-issues, issues-found, other
```

---

## 5. iOS Frontend Integration

### 5.1 New Message Types (iOS sends)

**Start recipe**:
```json
{
  "type": "start_recipe",
  "recipe_id": "implement-and-review",
  "session_id": "existing-session-id-or-null",
  "working_directory": "/path/to/project"
}
```

**Exit recipe**:
```json
{
  "type": "exit_recipe",
  "session_id": "active-session-id"
}
```

**Get available recipes**:
```json
{
  "type": "get_available_recipes"
}
```

### 5.2 New Message Types (Backend sends)

**Recipe started**:
```json
{
  "type": "recipe_started",
  "recipe_id": "implement-and-review",
  "session_id": "session-uuid",
  "step": "implement"
}
```

**Recipe step prompt** (same as normal response, but includes outcome requirements):
- Normal `response` message with modified prompt text that includes JSON requirements

**Recipe exited**:
```json
{
  "type": "recipe_exited",
  "session_id": "session-uuid",
  "reason": "no-issues" | "user-requested" | "max-iterations" | "other"
}
```

**Recipe error**:
```json
{
  "type": "recipe_error",
  "session_id": "session-uuid",
  "error": "Recipe not found" | "Invalid JSON response from agent" | "Max retries exceeded"
}
```

### 5.3 Settings Toggle

In SettingsView:
- Toggle: "Enable Recipe Orchestration"
- When disabled: Recipes unavailable, normal chat only
- When enabled: Recipe menu appears in UI

### 5.4 Recipe Menu

New UI component or menu option:
- List available recipes with descriptions
- User taps recipe → `start_recipe` message sent to backend
- Confirmation: "Starting recipe '{recipe-name}'. First prompt: {preview}..."

---

## 6. Error Handling & Edge Cases

### 6.1 Invalid JSON

**Scenario**: Agent doesn't return valid JSON
- **Action**: Send back with guidance, increment retry counter (up to 3)
- **Log**: Include session ID, step name, malformed response snippet
- **Exit**: If max retries exceeded, send `recipe_error` and return to normal chat

### 6.2 Unexpected Outcome

**Scenario**: Agent returns outcome not in recipe's expected outcomes for this step
- **Action**: Log as warning, treat as `other`, exit recipe
- **Log**: Include recipe ID, step, returned outcome, expected outcomes

### 6.3 Max Iterations

**Scenario**: Recipe loop reaches max iterations (e.g., review finds issues repeatedly)
- **Action**: Exit recipe with reason "max-iterations", notify iOS
- **Log**: Which step hit the limit, how many iterations

### 6.4 Session Lock Timeout

**Scenario**: Claude process hangs or times out while in recipe
- **Action**: Release lock, send error, exit recipe
- **Same behavior** as normal prompt timeout

### 6.5 User Cancels Recipe

**Scenario**: User sends `exit_recipe` while orchestration is active
- **Action**: Acquire lock (if not held), release lock, exit recipe
- **Next prompt**: Normal chat, no recipe enforcement

---

## 7. Testing Strategy

### 7.1 Unit Tests

**recipes.clj**:
- Recipe definition validation (spec tests)
- Transition logic (given outcome X at step Y, what's next step?)
- Cycle detection (no infinite loops in recipe graph)

**orchestration.clj**:
- JSON extraction and parsing
  - Valid JSON: happy path
  - Malformed JSON: repair strategies
  - Invalid JSON: error handling
- Outcome validation (outcome in expected set)
- Prompt appending (outcome requirements correctly formatted)
- State transitions (recipe state updates correctly)

**server.clj**:
- `start_recipe` message handling
- `exit_recipe` message handling
- Recipe state persistence

### 7.2 Integration Tests

- Full orchestration loop: start recipe → multiple steps → exit
- Loop scenarios: code review → fix → re-review → no issues → back to implement
- Invalid JSON with retry
- Max iterations enforcement
- Recipe chaining (future feature, but design should support it)

---

## 8. Implementation Phases

### Phase 1: Core Orchestration (MVP)
- Define implement-and-review recipe
- Implement recipes.clj and orchestration.clj
- Modify server.clj to support start_recipe and exit_recipe
- JSON parsing with basic repair and retry logic
- Unit tests with high coverage
- **No iOS UI changes yet** (manual message construction for testing)

### Phase 2: iOS Integration
- Add recipe menu to SettingsView
- Implement start_recipe message sending
- Handle recipe_started, recipe_exited messages
- Show active recipe status in ConversationView
- Settings toggle for orchestration

### Phase 3: Enhanced UX (Future)
- Visual indication of recipe progress
- Step-by-step tracking
- Recipe history in session metadata
- Pause/resume within recipe

---

## 9. Success Criteria for MVP

1. **Recipes defined in Clojure** with full test coverage
2. **JSON parsing robust**: Handles malformed JSON, retries with guidance
3. **Orchestration loop functional**: Completes implement → review → fix cycle without user intervention
4. **Guardrails enforced**: Max iterations, exit on other outcomes
5. **Manual testing**: Can trigger recipe via direct message (no iOS UI yet)
6. **Documentation**: Clear prompt format requirements for agent
7. **Logging**: All outcomes, transitions, errors logged with session context
