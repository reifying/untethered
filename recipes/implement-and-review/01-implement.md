# Implement

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