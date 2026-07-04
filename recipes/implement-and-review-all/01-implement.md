# Implement

Implement one ready task from beads.

## Pick Up the Task
1. Run `br ready --limit 1 --type task --type bug --type feature --type chore --type docs --type question`
2. Claim it so no other agent picks it up: `br update <task-id> --claim`
3. Run `br show <task-id>` and read everything it references — the design document, the files named in the technical approach, and @STANDARDS.md / @CLAUDE.md if present

## No Tasks Available
If `br ready --limit 1 --type task --type bug --type feature --type chore --type docs --type question` returns nothing, choose the `no-tasks` outcome. This is a normal result — the recipe exits gracefully.

## Implement
- Follow the task's requirements and technical approach. If the codebase has
  drifted from the approach (files moved, APIs changed), implement the task's
  intent against the current code and note the deviation in your report.
- Write tests alongside the implementation. The task is not done until new
  behavior is covered and the relevant test suite passes — run the tests, do
  not assume.
- Keep the diff scoped to this task: no drive-by refactors, no unrelated fixes.

**One task only.** Do not start a second beads task.
**Do not commit.** Code review happens next.

Work autonomously — nobody is watching this session, so never stop to ask a
question. If the task cannot proceed (missing dependency, contradictory
requirements, broken environment), choose `blocked` and say why.

## Choosing Your Outcome
- `complete` — all requirements implemented, tests written and passing
- `no-tasks` — nothing ready to implement
- `blocked` — you cannot make progress; explain the blocker
- `other` — anything else; explain in otherDescription

**Outcomes:** blocked, complete, no-tasks, other

**Transitions:**
- `blocked` → **exit** (implementation-blocked)
- `complete` → **Code Review**
- `no-tasks` → **exit** (no-tasks-available)
- `other` → **exit** (user-provided-other)