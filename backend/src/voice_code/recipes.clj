(ns voice-code.recipes
  (:require [clojure.spec.alpha :as s]))

(def valid-models
  "Valid model values for recipe steps"
  #{"haiku" "sonnet" "opus"})

(def review-commit-steps
  "Shared steps for the review → fix → commit loop.
   Used by both review-and-commit and implement-and-review recipes."
  {:code-review
   {:prompt "Perform a thorough code review on the changes.

## Review Process

1. Run `git diff` to see exactly what changed
2. Read each modified file to understand the changes in context
3. Evaluate against the checklist below
4. Report your findings

**Important:** List the files you read and summarize what you checked in each.

## Review Checklist

### Correctness
- [ ] Logic correctly implements the requirements
- [ ] Edge cases are handled
- [ ] Error handling is appropriate
- [ ] No regressions introduced

### Code Quality
- [ ] Follows project naming conventions
- [ ] Functions are appropriately sized
- [ ] No code duplication
- [ ] Comments explain 'why' not 'what' (where needed)

### Testing
- [ ] Tests cover happy path
- [ ] Tests cover error cases
- [ ] Tests are readable and maintainable
- [ ] All tests pass

### Security & Performance
- [ ] No hardcoded secrets or credentials
- [ ] No obvious performance issues
- [ ] Input validation where needed

### Design Alignment
- [ ] Implementation matches requirements
- [ ] No scope creep beyond task requirements

Report any issues found. Do not make changes yet."
    :outcomes #{:no-issues :issues-found :other}
    :on-outcome
    {:no-issues {:next-step :commit}
     :issues-found {:next-step :fix}
     :other {:action :exit :reason "user-provided-other"}}}

   :fix
   {:prompt "Address the issues found in the code review.

After fixing:
- Run tests to ensure they still pass
- Verify the fix doesn't introduce new issues"
    :outcomes #{:complete :other}
    :on-outcome
    {:complete {:next-step :code-review}
     :other {:action :exit :reason "user-provided-other"}}}

   :commit
   {:prompt "Commit and push the changes.

## Pre-Commit Steps
If working on a beads task, update its status first:
- Run `bd close <task-id>` to mark the task as complete
- If partially complete, use `bd update <task-id> --status in-progress` with notes

## Commit and Push
- Write a clear commit message describing what was implemented
- If working on a beads task, include the task ID in the commit message
- Push to the remote repository after committing"
    :model "haiku"
    :outcomes #{:committed :nothing-to-commit :other}
    :on-outcome
    {:committed {:action :exit :reason "changes-committed"}
     :nothing-to-commit {:action :exit :reason "no-changes-to-commit"}
     :other {:action :exit :reason "user-provided-other"}}}})

(def default-guardrails
  "Default guardrails for recipes"
  {:max-step-visits 3
   :max-total-steps 100
   :exit-on-other true})

(defn review-and-commit-recipe
  "Returns the review-and-commit recipe definition.
   This recipe reviews existing changes, fixes issues, and commits."
  []
  {:id :review-and-commit
   :label "Review & Commit"
   :description "Review existing changes, fix issues, and commit"
   :initial-step :code-review
   :steps review-commit-steps
   :guardrails default-guardrails})

(defn document-design-recipe
  "Returns the document-design recipe definition.
   This recipe creates a detailed design document with code examples and verification steps."
  []
  {:id :document-design
   :label "Document Design"
   :description "Create a detailed design document with examples and verification"
   :initial-step :document
   :steps
   {:document
    {:prompt "Create a detailed design document for the requested feature or change. Store as a markdown file following the repository's conventions for location and naming.

## Document Structure

Include the following sections:

### 1. Overview
- Problem statement: What problem does this solve?
- Goals: What are we trying to achieve?
- Non-goals: What is explicitly out of scope?

### 2. Background & Context
- Current state: How does the system work today?
- Why now: What triggered this work?
- Related work: Links to relevant documents, issues, or prior art

### 3. Detailed Design

#### Data Model
- New or modified data structures
- Schema changes with before/after examples
- Migration strategy if applicable

#### API Design
- Endpoint signatures with request/response examples
- Error cases and status codes
- Breaking changes and deprecation plan

#### Code Examples
Provide concrete implementation examples:

```clojure
;; Example: Show the key function signatures
(defn process-request
  \"Process incoming request with validation.\"
  [request]
  ;; Implementation approach...
  )
```

Include examples for:
- Happy path usage
- Error handling patterns
- Edge cases

#### Component Interactions
- Sequence diagrams or flow descriptions
- Integration points with existing systems
- Dependency relationships

### 4. Verification Strategy

#### Testing Approach
- Unit tests: What functions need direct testing?
- Integration tests: What component interactions need verification?
- End-to-end tests: What user workflows should be validated?

#### Test Examples
```clojure
(deftest process-request-test
  (testing \"validates required fields\"
    (is (thrown? ExceptionInfo (process-request {}))))
  (testing \"returns processed result\"
    (is (= expected-result (process-request valid-input)))))
```

#### Acceptance Criteria
- Numbered list of verifiable requirements
- Each criterion should be testable

### 5. Alternatives Considered
- What other approaches were evaluated?
- Why was this approach chosen?
- Trade-offs of the chosen approach

### 6. Risks & Mitigations
- What could go wrong?
- How will we detect problems?
- Rollback strategy

## Quality Checklist
Before marking complete, verify:
- [ ] All code examples are syntactically correct
- [ ] Examples match the codebase's style and conventions
- [ ] Verification steps are specific and actionable
- [ ] Cross-references to related files use @filename.md format
- [ ] No placeholder text remains"
     :outcomes #{:complete :needs-input :other}
     :on-outcome
     {:complete {:next-step :review}
      :needs-input {:action :exit :reason "clarification-needed"}
      :other {:action :exit :reason "user-provided-other"}}}

    :review
    {:prompt "Review the design document you created. Check for:
- Completeness: Are all sections filled in with substantive content?
- Correctness: Do code examples compile/parse correctly?
- Clarity: Would another developer understand the design?
- Consistency: Does it align with existing patterns in the codebase?
- Actionability: Are verification steps specific enough to execute?

Report any gaps or issues found. Do not make changes yet."
     :outcomes #{:no-issues :issues-found :other}
     :on-outcome
     {:no-issues {:next-step :commit}
      :issues-found {:next-step :fix}
      :other {:action :exit :reason "user-provided-other"}}}

    :fix
    {:prompt "Address the issues found in the design document review."
     :outcomes #{:complete :other}
     :on-outcome
     {:complete {:next-step :review}
      :other {:action :exit :reason "user-provided-other"}}}

    :commit
    {:prompt "Commit and push the design document. Use a descriptive commit message that summarizes what is being designed."
     :model "haiku"
     :outcomes #{:committed :nothing-to-commit :other}
     :on-outcome
     {:committed {:action :exit :reason "design-committed"}
      :nothing-to-commit {:action :exit :reason "no-changes-to-commit"}
      :other {:action :exit :reason "user-provided-other"}}}}

   :guardrails
   {:max-step-visits 3
    :max-total-steps 100
    :exit-on-other true}})

(defn break-down-tasks-recipe
  "Returns the break-down-tasks recipe definition.
   This recipe creates implementation tasks from a design document using beads."
  []
  {:id :break-down-tasks
   :label "Break Down Tasks"
   :description "Create implementation tasks from design document using beads"
   :initial-step :analyze
   :steps
   {:analyze
    {:prompt "Analyze the design document to understand the implementation scope.

## Prerequisites
1. Run `bd quickstart` to understand beads workflow if unfamiliar
2. Locate the design document for this feature
3. Read the design document thoroughly

## Analysis Steps
1. Identify all components that need to be created or modified
2. Map acceptance criteria to concrete implementation work
3. Identify dependencies between pieces of work
4. Note any verification steps from the design

Report your analysis including:
- Key components to implement
- Dependency graph (what must be done before what)
- Estimated number of tasks needed
- Any ambiguities or gaps in the design"
     :outcomes #{:complete :design-missing :needs-input :other}
     :on-outcome
     {:complete {:next-step :create-epic}
      :design-missing {:action :exit :reason "no-design-document-found"}
      :needs-input {:action :exit :reason "clarification-needed"}
      :other {:action :exit :reason "user-provided-other"}}}

    :create-epic
    {:prompt "Create the parent epic for this implementation work.

## Epic Creation
Run `bd add` to create an epic with:
- **Title**: Clear, concise name for the feature/change
- **Description**: Reference the design document using @path/to/design.md
- **Type**: epic

The epic description should include:
```
## Design Document
@path/to/design-document.md

## Overview
[Brief summary of what this epic delivers]

## Acceptance Criteria
[Copy or reference the acceptance criteria from the design]
```"
     :outcomes #{:complete :other}
     :on-outcome
     {:complete {:next-step :create-tasks}
      :other {:action :exit :reason "user-provided-other"}}}

    :create-tasks
    {:prompt "Create individual implementation tasks as children of the epic.

## Task Creation Guidelines

For each task, run `bd add` with:
- **Parent**: The epic you just created
- **Title**: Action-oriented (e.g., 'Add validation to user input handler')
- **Type**: task

### Task Granularity
Each task should be:
- **Atomic**: Completes one logical unit of work
- **Testable**: Has clear verification criteria
- **Independent**: Can be worked on without blocking others (where possible)
- **Small**: Completable in a single focused session

### Required Task Sections

Each task description must include:

```
## Design Reference
@path/to/design-document.md#relevant-section

## Context
[Why this task exists and how it fits into the larger feature]

## Requirements
- [ ] Specific requirement 1
- [ ] Specific requirement 2

## Technical Approach
[Key implementation details from the design document]
- Files to modify: [list specific files]
- New files to create: [if any]
- Dependencies: [other tasks that must complete first]

## Verification
- [ ] Unit tests for [specific functionality]
- [ ] Integration test for [specific interaction]
- [ ] Manual verification: [specific steps]

## Acceptance Criteria
[Subset of epic criteria this task addresses]
```

### Task Ordering
Create tasks in dependency order:
1. Foundation tasks (data models, schemas, migrations)
2. Core logic tasks (business logic, algorithms)
3. Integration tasks (API endpoints, event handlers)
4. UI tasks (if applicable)
5. Documentation tasks (if needed beyond design doc)

### Parallelization
Mark tasks that can be worked in parallel with a note:
```
## Parallelization
Can be worked alongside: [list task titles]
```"
     :outcomes #{:complete :other}
     :on-outcome
     {:complete {:next-step :review-tasks}
      :other {:action :exit :reason "user-provided-other"}}}

    :review-tasks
    {:prompt "Review the task breakdown for completeness and quality.

## Review Checklist

### Coverage
- [ ] All acceptance criteria from design are addressed by at least one task
- [ ] All components from design have corresponding tasks
- [ ] Verification strategy from design is reflected in task verification sections

### Task Quality
- [ ] Each task has a design document reference
- [ ] Each task has clear requirements
- [ ] Each task has verification steps
- [ ] No task is too large (should be completable in one session)
- [ ] No task is too vague (specific files and changes identified)

### Dependencies
- [ ] Task dependencies are explicitly stated
- [ ] No circular dependencies exist
- [ ] Foundation tasks come before dependent tasks
- [ ] Parallelizable tasks are marked

### Traceability
- [ ] Epic references the design document
- [ ] Each task references the relevant design section
- [ ] Acceptance criteria map back to design

Run `bd list` to see the created structure.

Report any issues found."
     :outcomes #{:no-issues :issues-found :other}
     :on-outcome
     {:no-issues {:next-step :commit}
      :issues-found {:next-step :fix-tasks}
      :other {:action :exit :reason "user-provided-other"}}}

    :fix-tasks
    {:prompt "Address the issues found in the task review.

Use `bd edit <task-id>` to update task descriptions.
Use `bd add` to create missing tasks.
Use `bd delete <task-id>` to remove duplicate or unnecessary tasks."
     :outcomes #{:complete :other}
     :on-outcome
     {:complete {:next-step :review-tasks}
      :other {:action :exit :reason "user-provided-other"}}}

    :commit
    {:prompt "Commit and push the beads changes.

## Commit Requirements
- Include all files in `beads/` directory
- Use the epic ID in the commit message
- Write a clear commit message

Example: 'Add implementation tasks for user authentication (epic-abc123)'"
     :model "haiku"
     :outcomes #{:committed :nothing-to-commit :other}
     :on-outcome
     {:committed {:action :exit :reason "tasks-committed"}
      :nothing-to-commit {:action :exit :reason "no-changes-to-commit"}
      :other {:action :exit :reason "user-provided-other"}}}}

   :guardrails
   {:max-step-visits 3
    :max-total-steps 100
    :exit-on-other true}})

(def implement-step
  "The implement step for implement-and-review recipe."
  {:prompt "Implement the current task from beads.

## Prerequisites
1. Run `bd ready --limit 1` to see the task details
2. Read the design document referenced in the task
3. Review relevant code standards (@STANDARDS.md, @CLAUDE.md)
4. Familiarize yourself with the codebase context

## No Tasks Available
If `bd ready --limit 1` indicates there are no tasks ready for implementation, select the `no-tasks` outcome. This is a normal situation—the recipe will exit gracefully.

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
- [ ] No unrelated changes included

**Do not commit yet.** Code review happens next."
   :outcomes #{:complete :no-tasks :blocked :other}
   :on-outcome
   {:complete {:next-step :code-review}
    :no-tasks {:action :exit :reason "no-tasks-available"}
    :blocked {:action :exit :reason "implementation-blocked"}
    :other {:action :exit :reason "user-provided-other"}}})

(defn implement-and-review-recipe
  "Returns the implement-and-review recipe definition.
   This recipe implements a task, reviews the code, iteratively fixes issues, and commits."
  []
  {:id :implement-and-review
   :label "Implement & Review"
   :description "Implement task, review code, fix issues, and commit"
   :initial-step :implement
   :steps (assoc review-commit-steps :implement implement-step)
   :guardrails default-guardrails})

(def all-recipes
  "Registry of all available recipes"
  {:document-design (document-design-recipe)
   :break-down-tasks (break-down-tasks-recipe)
   :review-and-commit (review-and-commit-recipe)
   :implement-and-review (implement-and-review-recipe)})

(defn get-recipe
  "Get a recipe by ID. Returns nil if not found."
  [recipe-id]
  (get all-recipes recipe-id))

(defn validate-recipe
  "Validate recipe structure. Returns validation result or nil if valid."
  [recipe]
  (let [step-names (set (keys (:steps recipe)))
        initial-step (:initial-step recipe)
        recipe-model (:model recipe)]
    (cond
      (nil? initial-step)
      {:error "Recipe must have :initial-step"}

      (not (contains? step-names initial-step))
      {:error (str "Initial step not found in steps: " initial-step)}

      (and recipe-model (not (contains? valid-models recipe-model)))
      {:error (str "Invalid recipe-level model '" recipe-model "'. Valid models: " valid-models)}

      :else
      (let [validation-errors
            (mapcat
             (fn [[step-name step-def]]
               (let [step-outcomes (:outcomes step-def)
                     on-outcome (:on-outcome step-def)
                     step-model (:model step-def)]
                 (concat
                  ;; Validate step-level model
                  (when (and step-model (not (contains? valid-models step-model)))
                    [{:error (str "Invalid model '" step-model "' at step " step-name ". Valid models: " valid-models)}])
                  ;; Validate transitions
                  (mapcat
                   (fn [[outcome transition]]
                     (cond
                       (not (contains? step-outcomes outcome))
                       [{:error (str "Outcome " outcome " at step " step-name " not in :outcomes")}]

                       (and (= outcome :other) (not (:reason transition)))
                       [{:error (str "Transition for 'other' outcome must have :reason")}]

                       (and (= (:action transition) :exit) (not (:reason transition)))
                       [{:error (str "Exit action must have :reason")}]

                       (and (:next-step transition)
                            (not (contains? step-names (:next-step transition))))
                       [{:error (str "Next step " (:next-step transition) " not found in steps")}]

                       :else []))
                   on-outcome))))
             (:steps recipe))]
        (if (empty? validation-errors)
          nil
          validation-errors)))))

(s/def ::outcome keyword?)
(s/def ::action keyword?)
(s/def ::next-step keyword?)
(s/def ::reason string?)
(s/def ::outcomes (s/coll-of keyword? :kind set?))

(s/def ::transition
  (s/or :next-step (s/keys :req-un [::next-step])
        :exit (s/keys :req-un [::action ::reason])))

(s/def ::on-outcome
  (s/map-of keyword? ::transition))

(s/def ::model valid-models)

(s/def ::step-def
  (s/keys :req-un [::prompt ::outcomes ::on-outcome]
          :opt-un [::model]))

(s/def ::steps
  (s/map-of keyword? ::step-def))

(s/def ::guardrail
  (s/keys :req-un [::max-iterations]))

(s/def ::recipe
  (s/keys :req-un [::id ::description ::initial-step ::steps]
          :opt-un [::guardrails ::model]))
