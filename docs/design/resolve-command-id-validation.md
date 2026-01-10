# Command ID Resolution Validation

## Overview

### Problem Statement

The `resolve-command-id` function in @backend/src/voice_code/commands.clj:17-40 accepts any string and performs string manipulation without validating input. This can produce malformed shell commands or throw exceptions for edge cases like `nil`, empty strings, or incomplete prefixes (e.g., `"git."` without a subcommand).

### Goals

1. Validate command IDs before processing to prevent malformed shell commands
2. Add debug logging to provide visibility into command resolution
3. Return clear errors for invalid inputs instead of silently producing garbage
4. Add comprehensive unit tests for edge cases

### Non-goals

- Changing the command ID format or resolution rules
- Adding new command prefixes beyond `git.` and `bd.`
- Validating that resolved commands actually exist on the system

## Background & Context

### Current State

The `resolve-command-id` function in @backend/src/voice_code/commands.clj:17-40:

```clojure
(defn resolve-command-id
  "Resolve a command_id to a shell command string.

  Examples:
  - git.status -> git status
  - git.worktree.list -> git worktree list
  - bd.ready -> bd ready
  - docker.up -> make docker-up
  - build -> make build"
  [command-id]
  (cond
    ;; Git commands (supports nested like git.worktree.list)
    (str/starts-with? command-id "git.")
    (let [subcommand (subs command-id 4)] ; Remove 'git.' prefix
      (str "git " (str/replace subcommand "." " ")))

    ;; Beads (bd) commands
    (str/starts-with? command-id "bd.")
    (let [subcommand (subs command-id 3)] ; Remove 'bd.' prefix
      (str "bd " (str/replace subcommand "." " ")))

    ;; All other commands are Makefile targets
    :else
    (str "make " (str/replace command-id "." "-"))))
```

**Current issues:**

1. **`nil` input**: `str/starts-with?` throws `NullPointerException`
2. **Empty string `""`**: Falls through to `:else`, produces `"make "` (invalid)
3. **`"git."` (empty subcommand)**: Produces `"git "` (runs `git` with no command)
4. **`"bd."` (empty subcommand)**: Produces `"bd "` (runs `bd` with no command)
5. **`"git"` or `"bd"` (no dot)**: Falls through to `:else`, produces `"make git"` or `"make bd"`
6. **No logging**: Can't diagnose resolution issues from logs

### Why Now

This improvement was identified during a codebase review as a small, high-value defensive coding fix. Invalid command IDs could come from:
- Malformed iOS app messages
- Future refactoring bugs
- Manual testing with bad inputs

### Related Work

- @STANDARDS.md - Command Execution Protocol section defines valid command ID formats
- @backend/test/voice_code/available_commands_test.clj - Existing tests for command discovery

## Detailed Design

### Validation Rules

A valid command ID must:
1. Be a non-nil, non-blank string
2. If prefixed with `git.` or `bd.`, have at least one character after the prefix
3. Match the pattern for its type (git command, bd command, or Makefile target)

### Code Changes

**File: backend/src/voice_code/commands.clj**

```clojure
(defn validate-command-id
  "Validate that a command-id is well-formed.

   Returns nil if valid, or an error message string if invalid.

   Validation rules:
   - Must be a non-nil, non-blank string
   - If starts with 'git.' or 'bd.', must have subcommand after prefix"
  [command-id]
  (cond
    (nil? command-id)
    "command-id cannot be nil"

    (not (string? command-id))
    (format "command-id must be a string, got %s" (type command-id))

    (str/blank? command-id)
    "command-id cannot be blank"

    (= command-id "git.")
    "git command-id requires a subcommand after 'git.'"

    (= command-id "bd.")
    "bd command-id requires a subcommand after 'bd.'"

    :else nil))

(defn resolve-command-id
  "Resolve a command_id to a shell command string.

   Throws ExceptionInfo if command-id is invalid.

   Examples:
   - git.status -> git status
   - git.worktree.list -> git worktree list
   - bd.ready -> bd ready
   - docker.up -> make docker-up
   - build -> make build"
  [command-id]
  (when-let [error (validate-command-id command-id)]
    (throw (ex-info error {:command-id command-id :error error})))

  (let [resolved (cond
                   ;; Git commands (supports nested like git.worktree.list)
                   (str/starts-with? command-id "git.")
                   (let [subcommand (subs command-id 4)]
                     (str "git " (str/replace subcommand "." " ")))

                   ;; Beads (bd) commands
                   (str/starts-with? command-id "bd.")
                   (let [subcommand (subs command-id 3)]
                     (str "bd " (str/replace subcommand "." " ")))

                   ;; All other commands are Makefile targets
                   :else
                   (str "make " (str/replace command-id "." "-")))]
    (log/debug "Resolved command-id" {:command-id command-id :shell-command resolved})
    resolved))
```

### Error Handling

The function throws `ExceptionInfo` with structured data for invalid inputs:

```clojure
;; Example exception data
{:command-id nil
 :error "command-id cannot be nil"}

{:command-id "git."
 :error "git command-id requires a subcommand after 'git.'"}
```

Callers (e.g., WebSocket message handlers) should catch this exception and return an appropriate error response to the client.

### Caller Updates

The `spawn-process` function in @backend/src/voice_code/commands.clj:42-125 is called with the resolved shell command, not the command ID. The resolution happens in `handle-execute-command` in @backend/src/voice_code/server.clj.

No caller changes needed if we let the exception propagate. The WebSocket handler at @backend/src/voice_code/server.clj:1040 has a top-level `try/catch` that catches all exceptions and sends error responses to clients.

**Note on redundant validation:** The caller at server.clj:1571 already validates `(not command-id)` before calling `resolve-command-id`. The nil check in `validate-command-id` is intentionally redundant as defense-in-depth—the function protects itself regardless of caller behavior.

### Design Decision: Standalone `"git"` and `"bd"` (without dots)

The current behavior resolves `"git"` to `"make git"` and `"bd"` to `"make bd"`. This is technically incorrect (these aren't valid Makefile targets in practice), but:

1. These inputs would never come from `available_commands` (which always produces dotted IDs for git/bd commands)
2. Adding validation for these edge cases increases complexity with minimal practical benefit
3. If someone manually sends `"git"`, getting `"make git"` and a "target not found" error is acceptable feedback

**Decision:** Do not validate standalone `"git"` or `"bd"`. Focus validation on the cases that produce genuinely broken commands (empty subcommands like `"git."`).

## Verification Strategy

### Unit Tests

Create or extend test file to cover `resolve-command-id` and `validate-command-id`:

**File: backend/test/voice_code/commands_test.clj**

```clojure
(ns voice-code.commands-test
  (:require [clojure.test :refer :all]
            [voice-code.commands :as commands]))

;; ============================================================================
;; validate-command-id tests
;; ============================================================================

(deftest validate-command-id-test
  (testing "nil input returns error"
    (is (= "command-id cannot be nil" (commands/validate-command-id nil))))

  (testing "empty string returns error"
    (is (= "command-id cannot be blank" (commands/validate-command-id ""))))

  (testing "blank string returns error"
    (is (= "command-id cannot be blank" (commands/validate-command-id "   "))))

  (testing "non-string input returns error"
    (is (string? (commands/validate-command-id 123)))
    (is (string? (commands/validate-command-id :keyword))))

  (testing "git. without subcommand returns error"
    (is (= "git command-id requires a subcommand after 'git.'"
           (commands/validate-command-id "git."))))

  (testing "bd. without subcommand returns error"
    (is (= "bd command-id requires a subcommand after 'bd.'"
           (commands/validate-command-id "bd."))))

  (testing "valid command-ids return nil"
    (is (nil? (commands/validate-command-id "git.status")))
    (is (nil? (commands/validate-command-id "git.worktree.list")))
    (is (nil? (commands/validate-command-id "bd.ready")))
    (is (nil? (commands/validate-command-id "bd.list")))
    (is (nil? (commands/validate-command-id "build")))
    (is (nil? (commands/validate-command-id "docker.up")))))

;; ============================================================================
;; resolve-command-id tests
;; ============================================================================

(deftest resolve-command-id-test
  (testing "git commands"
    (is (= "git status" (commands/resolve-command-id "git.status")))
    (is (= "git push" (commands/resolve-command-id "git.push")))
    (is (= "git worktree list" (commands/resolve-command-id "git.worktree.list"))))

  (testing "bd commands"
    (is (= "bd ready" (commands/resolve-command-id "bd.ready")))
    (is (= "bd list" (commands/resolve-command-id "bd.list"))))

  (testing "Makefile targets (default case)"
    (is (= "make build" (commands/resolve-command-id "build")))
    (is (= "make docker-up" (commands/resolve-command-id "docker.up")))
    (is (= "make docker-compose-up" (commands/resolve-command-id "docker.compose.up")))
    (is (= "make test" (commands/resolve-command-id "test")))))

(deftest resolve-command-id-throws-on-invalid-input
  (testing "nil throws ExceptionInfo"
    (is (thrown-with-msg? clojure.lang.ExceptionInfo
                          #"command-id cannot be nil"
                          (commands/resolve-command-id nil))))

  (testing "empty string throws ExceptionInfo"
    (is (thrown-with-msg? clojure.lang.ExceptionInfo
                          #"command-id cannot be blank"
                          (commands/resolve-command-id ""))))

  (testing "git. without subcommand throws ExceptionInfo"
    (is (thrown-with-msg? clojure.lang.ExceptionInfo
                          #"requires a subcommand"
                          (commands/resolve-command-id "git."))))

  (testing "bd. without subcommand throws ExceptionInfo"
    (is (thrown-with-msg? clojure.lang.ExceptionInfo
                          #"requires a subcommand"
                          (commands/resolve-command-id "bd."))))

  (testing "exception contains command-id in ex-data"
    (try
      (commands/resolve-command-id nil)
      (is false "Should have thrown")
      (catch clojure.lang.ExceptionInfo e
        (is (= nil (:command-id (ex-data e))))
        (is (string? (:error (ex-data e))))))))
```

### Integration Tests

The existing tests in @backend/test/voice_code/available_commands_test.clj cover the integration path. No additional integration tests needed since:
1. Valid command IDs are tested via existing available_commands tests
2. Invalid command IDs will now throw exceptions caught by WebSocket handlers

### Acceptance Criteria

1. `resolve-command-id` throws `ExceptionInfo` for `nil` input
2. `resolve-command-id` throws `ExceptionInfo` for empty/blank string input
3. `resolve-command-id` throws `ExceptionInfo` for `"git."` (no subcommand)
4. `resolve-command-id` throws `ExceptionInfo` for `"bd."` (no subcommand)
5. `resolve-command-id` logs resolved command at debug level
6. All existing command resolution behavior unchanged for valid inputs
7. All new tests pass
8. All existing tests continue to pass

## Alternatives Considered

### Alternative 1: Return `nil` for invalid inputs

```clojure
(defn resolve-command-id [command-id]
  (when (valid? command-id)
    (cond ...)))
```

**Rejected because:**
- Callers might not check for `nil`, leading to `NullPointerException` downstream
- Harder to debug since the error is silent
- Exceptions provide clear error messages and stack traces

### Alternative 2: Return a result map with success/error

```clojure
(defn resolve-command-id [command-id]
  (if-let [error (validate-command-id command-id)]
    {:success false :error error}
    {:success true :shell-command (resolve ...)}))
```

**Rejected because:**
- More complex API that requires callers to destructure
- Inconsistent with Clojure idiom of throwing for programmer errors
- Invalid command IDs are programmer errors, not expected runtime conditions

### Alternative 3: Validate at the caller level only

Keep `resolve-command-id` simple and validate in the WebSocket handler.

**Rejected because:**
- Validation logic would be duplicated if multiple callers exist
- The function should protect itself from invalid inputs
- Defensive programming is appropriate for public functions

## Risks & Mitigations

### Risk 1: Breaking existing callers that pass unexpected inputs

**Likelihood:** Low. Current callers pass command IDs from `available_commands` or user input that should already be valid.

**Mitigation:**
- Run full test suite to verify no existing tests fail
- The exception message clearly identifies the problem
- Add logging so issues are visible in production logs

### Risk 2: Performance impact from validation

**Likelihood:** Negligible. Validation is a few string comparisons, not measurable against process spawning.

**Mitigation:** None needed.

### Risk 3: Debug logging too verbose in production

**Likelihood:** Low. Debug level is typically disabled in production.

**Mitigation:** Use `log/debug` not `log/info` so it's filtered by default.

## Implementation Checklist

- [ ] Add `validate-command-id` function to `commands.clj`
- [ ] Update `resolve-command-id` to validate and log
- [ ] Create `backend/test/voice_code/commands_test.clj` with unit tests
- [ ] Run `make test` to verify all tests pass
- [ ] Manual test via iOS app to confirm command execution still works
