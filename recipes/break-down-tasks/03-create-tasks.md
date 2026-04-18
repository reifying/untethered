# Create Tasks

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