# Tasks Create Tasks

Break the epic into implementation tasks.

**Write every task as a prompt for a fresh agent.** Each task will be executed by
a new session with no memory of this conversation, no access to the design
discussion, and nothing but the task description and the repository. If the
description does not carry enough context to implement from cold, the task will
fail — put the context in.

## Creating Tasks
For each task run `br create --type task --parent <epic-id>` with an
action-oriented title (e.g. 'Add validation to user input handler') and a
description containing:

```
## Design Reference
@path/to/design-document.md#relevant-section

## Context
[Why this task exists and how it fits the larger feature]

## Requirements
- [ ] Specific, verifiable requirement

## Technical Approach
[The relevant implementation details from the design — files to modify,
new files to create, key functions and data structures involved]

## Verification
[What tests prove this works — unit, integration, and/or manual steps]
```

## Sizing
Each task should be one coherent unit of work — independently implementable and
testable, small enough for a single focused agent session. If a task needs
another task's output, that is a dependency between two tasks, not one giant task.

Create tasks roughly foundation-first: data models and schemas, then core logic,
then integration points (APIs, handlers), then UI, then docs.

## Dependency Links
`br ready` only works if the links exist. After creating all tasks:

1. The epic depends on every child, so it cannot close or look ready while
   children are open:
   `br dep add <epic-id> <child-task-id>` — repeat for each child
2. Each task depends on its prerequisites:
   `br dep add <blocked-task> <blocking-task>` — the first argument depends on
   the second (e.g. the write-tests task depends on the implement-handler task)

Sanity-check with `br blocked`: tasks with prerequisites should be listed there.
If nothing is blocked but you created ordered work, the links are missing.

## Choosing Your Outcome
- `complete` — all tasks created with dependencies linked
- `other` — explain in otherDescription

**Outcomes:** complete, other

**Transitions:**
- `complete` → **Tasks Review**
- `other` → **exit** (user-provided-other)