# Implement & Review All

Implement all tasks, restarting in new sessions after each commit

**Recipe ID:** `implement-and-review-all`
**Initial Step:** `implement`

---

### Code Review

**Prompt:**

Perform a thorough code review on the changes.

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

Report any issues found. Do not make changes yet.

**Outcomes:** issues-found, no-issues, other

**Transitions:**
- `issues-found` → **Fix**
- `no-issues` → **Commit**
- `other` → **exit** (user-provided-other)

### Commit

**Prompt:**

Commit and push the changes.

## Pre-Commit Steps
If working on a beads task, update its status first:
- Run `bd close <task-id>` to mark the task as complete
- If partially complete, use `bd update <task-id> --status in-progress` with notes

## Commit and Push
- Write a clear commit message describing what was implemented
- If working on a beads task, include the task ID in the commit message
- Push to the remote repository after committing

**Model:** `haiku`

**Outcomes:** committed, nothing-to-commit, other

**Transitions:**
- `committed` → **restart-new-session** ()
- `nothing-to-commit` → **exit** (no-changes-to-commit)
- `other` → **exit** (user-provided-other)

### Fix

**Prompt:**

Address the issues found in the code review.

After fixing:
- Run tests to ensure they still pass
- Verify the fix doesn't introduce new issues

**Outcomes:** complete, other

**Transitions:**
- `complete` → **Code Review**
- `other` → **exit** (user-provided-other)

### Implement

**Prompt:**

Implement the current task from beads.

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

**Only one task.** Only implement the one task. Do not start on a second beads task.
**Do not commit yet.** Code review happens next.

**Outcomes:** blocked, complete, no-tasks, other

**Transitions:**
- `blocked` → **exit** (implementation-blocked)
- `complete` → **Code Review**
- `no-tasks` → **exit** (no-tasks-available)
- `other` → **exit** (user-provided-other)

## Guardrails

- Max visits per step: 3
- Max total steps: 100
- Exit on other: true