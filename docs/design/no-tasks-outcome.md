# No Tasks Outcome for Implement Recipe

## Overview

### Problem Statement
The `implement-and-review` recipe's `:implement` step instructs the agent to "Run `bd ready` to see the task details" but only provides outcomes for when a task exists (`:complete`, `:blocked`, `:other`). When `bd ready` returns no tasks to work on, the agent has no appropriate outcome to select—it must either falsely claim completion, report being blocked (inaccurate), or use the catch-all `:other` which exits with a generic reason.

### Goals
1. Add a `:no-tasks` outcome to the `:implement` step
2. Exit the recipe gracefully with a clear reason when no tasks are available
3. Classify this exit as a normal completion (not an error or guardrail)

### Non-goals
- Changing the beads (`bd`) tool behavior
- Auto-detecting tasks before starting the recipe
- Adding task queue management to the orchestration system

## Background & Context

### Current State
The `:implement` step definition:

```clojure
:implement
{:prompt "Implement the current task from beads.

## Prerequisites
1. Run `bd ready` to see the task details
..."
 :outcomes #{:complete :blocked :other}
 :on-outcome
 {:complete {:next-step :code-review}
  :blocked {:action :exit :reason "implementation-blocked"}
  :other {:action :exit :reason "user-provided-other"}}}
```

When `bd ready` returns no tasks, the agent must choose:
- `:complete` — incorrect, no work was done
- `:blocked` — semantically wrong, not blocked by a dependency
- `:other` — forces agent to provide a description, exits with generic reason

### Why Now
During initial recipe testing, this gap was identified. The recipe should handle this common scenario explicitly rather than relying on the catch-all `:other` outcome.

### Related Work
- @docs/design/recipe-exit-reason-classification.md — exit reason classification system (dependency)
- @backend/src/voice_code/recipes.clj — recipe definitions

### Dependencies
This design depends on @docs/design/recipe-exit-reason-classification.md being implemented first. That design introduces `classify-exit-reason` and `exit-reason->message` functions which this feature extends. If implementing this feature before exit reason classification, the core recipe change (adding `:no-tasks` outcome) can proceed independently—the exit reason will simply pass through as-is until classification is added.

## Detailed Design

### Data Model

#### New Outcome
Add `:no-tasks` to the `:implement` step's outcomes set.

#### New Exit Reason
Add `"no-tasks-available"` as an exit reason, classified as `:completed` (not an error).

#### Recipe Change

Before:
```clojure
:implement
{:prompt "..."
 :outcomes #{:complete :blocked :other}
 :on-outcome
 {:complete {:next-step :code-review}
  :blocked {:action :exit :reason "implementation-blocked"}
  :other {:action :exit :reason "user-provided-other"}}}
```

After:
```clojure
:implement
{:prompt "..."
 :outcomes #{:complete :no-tasks :blocked :other}
 :on-outcome
 {:complete {:next-step :code-review}
  :no-tasks {:action :exit :reason "no-tasks-available"}
  :blocked {:action :exit :reason "implementation-blocked"}
  :other {:action :exit :reason "user-provided-other"}}}
```

### API Design

#### Exit Reason Classification

In @backend/src/voice_code/orchestration.clj, the `"no-tasks-available"` reason should be classified as `:completed`:

```clojure
;; In exit-reason->message
:completed
(case reason
  ;; ... existing cases ...
  "no-tasks-available" "No tasks available to implement"
  ;; ... default ...
  )
```

This is correct because:
- The agent successfully checked for work
- Finding no work is a valid terminal state
- The user should see this as informational, not a warning or error

#### WebSocket Message

When recipe exits with this reason:
```json
{
  "type": "recipe_exited",
  "session_id": "abc123",
  "reason": "no-tasks-available",
  "category": "completed",
  "message": "No tasks available to implement"
}
```

### Code Examples

#### Updated Recipe Definition

```clojure
(defn implement-and-review-recipe
  []
  {:id :implement-and-review
   :label "Implement & Review"
   :description "Implement task, review code, fix issues, and commit"
   :initial-step :implement
   :steps
   {:implement
    {:prompt "Implement the current task from beads.

## Prerequisites
1. Run `bd ready` to see the task details
2. Read the design document referenced in the task
3. Review relevant code standards (@STANDARDS.md, @CLAUDE.md)
4. Familiarize yourself with the codebase context

## No Tasks Available
If `bd ready` indicates there are no tasks ready for implementation, select the `no-tasks` outcome. This is a normal situation—the recipe will exit gracefully.

## Implementation Requirements
- Follow the technical approach specified in the task
- Implement all requirements listed in the task
- Write tests alongside implementation (not after)
- Run tests to verify they pass

## Verification Checklist
Before marking complete:
- [ ] All task requirements implemented
- [ ] Unit tests written and passing
- [ ] Integration tests written (if specified in task)
- [ ] Code follows project conventions
- [ ] No unrelated changes included"
     :outcomes #{:complete :no-tasks :blocked :other}
     :on-outcome
     {:complete {:next-step :code-review}
      :no-tasks {:action :exit :reason "no-tasks-available"}
      :blocked {:action :exit :reason "implementation-blocked"}
      :other {:action :exit :reason "user-provided-other"}}}
    ;; ... remaining steps unchanged ...
    }})
```

#### Updated Exit Reason Message

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
      "no-tasks-available" "No tasks available to implement"
      "user-provided-other" "Recipe exited by user choice"
      (str "Completed: " reason))
    ;; ... other categories ...
    ))
```

### Component Interactions

```
User starts implement-and-review recipe
    ↓
Agent receives :implement step prompt
    ↓
Agent runs `bd ready`
    ├─ Tasks exist → Agent implements, selects :complete
    │                    ↓
    │                Recipe continues to :code-review
    │
    └─ No tasks → Agent selects :no-tasks
                     ↓
                 Recipe exits with reason "no-tasks-available"
                     ↓
                 classify-exit-reason → :completed
                     ↓
                 iOS shows success indicator with message
```

## Verification Strategy

### Testing Approach

#### Unit Tests (Core - No Dependencies)
1. Recipe validation passes with new outcome
2. Recipe structure includes `:no-tasks` in outcomes and on-outcome map
3. `determine-next-action` returns correct exit action for `:no-tasks`

#### Unit Tests (After Exit Reason Classification)
4. `classify-exit-reason` returns `:completed` for `"no-tasks-available"`
5. `exit-reason->message` returns appropriate message

#### Integration Tests
1. Mock agent returning `{"outcome": "no-tasks"}` → recipe exits cleanly
2. WebSocket message includes reason `"no-tasks-available"`

### Test Examples

```clojure
(ns voice-code.recipes-test
  (:require [clojure.test :refer :all]
            [voice-code.recipes :as recipes]
            [voice-code.orchestration :as orch]))

;; Core tests - can run immediately after recipe change
(deftest implement-step-no-tasks-outcome-test
  (testing "no-tasks outcome is valid in implement step"
    (let [recipe (recipes/implement-and-review-recipe)
          implement-step (get-in recipe [:steps :implement])]
      (is (contains? (:outcomes implement-step) :no-tasks))
      (is (= {:action :exit :reason "no-tasks-available"}
             (get-in implement-step [:on-outcome :no-tasks]))))))

(deftest implement-step-no-tasks-transition-test
  (testing "no-tasks outcome produces exit action"
    (let [recipe (recipes/implement-and-review-recipe)
          implement-step (get-in recipe [:steps :implement])
          action (orch/determine-next-action implement-step :no-tasks)]
      (is (= :exit (:action action)))
      (is (= "no-tasks-available" (:reason action))))))

(deftest recipe-validates-with-no-tasks-outcome-test
  (testing "recipe validation passes with no-tasks outcome"
    (let [recipe (recipes/implement-and-review-recipe)]
      (is (nil? (recipes/validate-recipe recipe))))))

;; Tests requiring exit reason classification feature
;; Add these after @docs/design/recipe-exit-reason-classification.md is implemented
#_(deftest no-tasks-available-classification-test
    (testing "no-tasks-available is classified as completed"
      (is (= :completed (orch/classify-exit-reason "no-tasks-available")))))

#_(deftest no-tasks-available-message-test
    (testing "no-tasks-available has descriptive message"
      (let [msg (orch/exit-reason->message "no-tasks-available" :completed)]
        (is (str/includes? msg "No tasks")))))
```

### Acceptance Criteria

1. `:implement` step includes `:no-tasks` in its outcomes set
2. Selecting `:no-tasks` exits recipe with reason `"no-tasks-available"`
3. Exit reason is classified as `:completed` (not `:error` or `:guardrail`)
4. iOS receives `category: "completed"` in the exit message
5. Human-readable message clearly states no tasks were available
6. All existing tests continue to pass

## Alternatives Considered

### Alternative 1: Use `:blocked` outcome
Repurpose the existing `:blocked` outcome for "no tasks" scenario.

**Rejected because**: Semantically incorrect. "Blocked" implies an impediment preventing work on an existing task. Having no tasks is different from being blocked.

### Alternative 2: Use `:complete` outcome
Agent selects `:complete` when there's nothing to do.

**Rejected because**: Misleading. "Complete" implies work was done. This could cause confusion in logs and user-facing messages.

### Alternative 3: Classify as `:guardrail` category
Treat "no tasks" as a guardrail condition.

**Rejected because**: Guardrails indicate safety limits being triggered. Finding no tasks is a normal workflow state, not a safety concern.

## Risks & Mitigations

### Risk: Agent doesn't recognize when to use `:no-tasks`
Agent might still use `:other` when `bd ready` returns empty.

**Mitigation**: Update the step prompt to explicitly mention the `:no-tasks` outcome and when to use it. Add guidance like: "If `bd ready` shows no tasks available, select the `no-tasks` outcome."

### Risk: Breaking existing behavior
Adding a new outcome could affect existing orchestration logic.

**Mitigation**: The change is additive. Existing outcomes and transitions are unchanged. Recipe validation will catch any structural issues.

## Quality Checklist
- [x] All code examples are syntactically correct
- [x] Examples match the codebase's style and conventions
- [x] Verification steps are specific and actionable
- [x] Cross-references to related files use @filename.md format
- [x] No placeholder text remains
