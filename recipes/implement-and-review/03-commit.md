# Commit

Commit and push the changes.

## Pre-Commit Steps
If working on a beads task, update its status first:
- Run `br close <task-id>` to mark the task as complete
- If partially complete, use `br update <task-id> --status in_progress` with notes

## Commit and Push
- Write a clear commit message describing what was implemented
- If working on a beads task, include the task ID in the commit message
- Run `br sync --flush-only` to ensure issue state is exported
- Stage issue state: `git add .beads/issues.jsonl`
- Push to the remote repository after committing

**Outcomes:** committed, nothing-to-commit, other

**Transitions:**
- `committed` → **exit** (changes-committed)
- `nothing-to-commit` → **exit** (no-changes-to-commit)
- `other` → **exit** (user-provided-other)

**Model:** `haiku`