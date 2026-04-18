# Commit

Commit and push the changes.

## Pre-Commit Steps
If working on a beads task, update its status first:
- Run `bd close <task-id>` to mark the task as complete
- If partially complete, use `bd update <task-id> --status in-progress` with notes

## Commit and Push
- Write a clear commit message describing what was implemented
- If working on a beads task, include the task ID in the commit message
- Push to the remote repository after committing

**Outcomes:** committed, nothing-to-commit, other

**Transitions:**
- `committed` → **exit** (changes-committed)
- `nothing-to-commit` → **exit** (no-changes-to-commit)
- `other` → **exit** (user-provided-other)

**Model:** `haiku`