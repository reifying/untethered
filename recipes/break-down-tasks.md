# Break Down Tasks

Create implementation tasks from design document using beads

**Recipe ID:** `break-down-tasks`
**Initial Step:** `analyze`

---

### Analyze

**Prompt:**

Analyze the design document to understand the implementation scope.

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
- Any ambiguities or gaps in the design

**Outcomes:** complete, design-missing, needs-input, other

**Transitions:**
- `complete` → **Create Epic**
- `design-missing` → **exit** (no-design-document-found)
- `needs-input` → **exit** (clarification-needed)
- `other` → **exit** (user-provided-other)

### Commit

**Prompt:**

Commit and push the beads changes.

## Commit Requirements
- Include all files in `beads/` directory
- Use the epic ID in the commit message
- Write a clear commit message

Example: 'Add implementation tasks for user authentication (epic-abc123)'

**Model:** `haiku`

**Outcomes:** committed, nothing-to-commit, other

**Transitions:**
- `committed` → **exit** (tasks-committed)
- `nothing-to-commit` → **exit** (no-changes-to-commit)
- `other` → **exit** (user-provided-other)

### Create Epic

**Prompt:**

Create the parent epic for this implementation work.

## Epic Creation
Run `bd create` to create an epic with:
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
```

**Outcomes:** complete, other

**Transitions:**
- `complete` → **Create Tasks**
- `other` → **exit** (user-provided-other)

### Create Tasks

**Prompt:**

Create individual implementation tasks as children of the epic.

## Task Creation Guidelines

For each task, run `bd create` with:
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
```

### Setting Up Dependency Links

After creating all tasks, establish dependency links using `bd dep add`.
This ensures `bd ready` only shows tasks that are actually ready to work on.

**Syntax:** `bd dep add <blocked-task> <blocking-task>`
(The blocked-task depends on blocking-task completing first)

**Required dependencies:**
1. Epic depends on ALL child tasks (epic can't close until children complete):
   ```bash
   bd dep add <epic-id> <child-task-1>
   bd dep add <epic-id> <child-task-2>
   # ... repeat for each child
   ```

2. Tasks depend on their prerequisites (tests depend on implementation, etc.):
   ```bash
   # Example: "Write tests" depends on "Implement handler"
   bd dep add <test-task-id> <impl-task-id>
   ```

**Verify with:** `bd blocked` to see dependency relationships

**Outcomes:** complete, other

**Transitions:**
- `complete` → **Review Tasks**
- `other` → **exit** (user-provided-other)

### Fix Tasks

**Prompt:**

Address the issues found in the task review.

Use `bd edit <task-id>` to update task descriptions.
Use `bd create` to create missing tasks.
Use `bd delete <task-id>` to remove duplicate or unnecessary tasks.
Use `bd dep add <blocked> <blocking>` to add missing dependency links.
Use `bd dep rm <blocked> <blocking>` to remove incorrect dependencies.

**Outcomes:** complete, other

**Transitions:**
- `complete` → **Review Tasks**
- `other` → **exit** (user-provided-other)

### Review Tasks

**Prompt:**

Review the task breakdown for completeness and quality.

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
- [ ] Task dependencies are explicitly stated in descriptions
- [ ] No circular dependencies exist
- [ ] Foundation tasks come before dependent tasks
- [ ] Parallelizable tasks are marked

### Dependency Links (Critical)
Run these commands to verify dependency links are properly set up:

1. **Check blocked tasks:** `bd blocked`
   - Tasks with prerequisites should appear here
   - If nothing is blocked but tasks have dependencies, links are missing

2. **Check epic dependencies:** `bd show <epic-id>`
   - Epic should show "Depends on" section listing ALL child tasks
   - If missing, epic will show as "ready" before children complete

3. **Check ready tasks:** `bd ready`
   - Only foundation tasks (no prerequisites) should appear
   - If all tasks appear, dependency links are missing

### Traceability
- [ ] Epic references the design document
- [ ] Each task references the relevant design section
- [ ] Acceptance criteria map back to design

Run `bd list` to see the created structure.

Report any issues found.

**Outcomes:** issues-found, no-issues, other

**Transitions:**
- `issues-found` → **Fix Tasks**
- `no-issues` → **Commit**
- `other` → **exit** (user-provided-other)

## Guardrails

- Max visits per step: 3
- Max total steps: 100
- Exit on other: true