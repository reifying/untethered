# Commit

Commit and push the changes.

## Update Beads First
If this work was driven by a beads task:
- Fully done: `br close <task-id>`
- Partially done: `br update <task-id> --status in_progress --notes <what remains>`
- Then `br sync --flush-only` and stage the export: `git add .beads/issues.jsonl`

## Commit
- Stage the intended changes. Check `git status` for strays first — do not
  blanket-add files unrelated to this work.
- Write a commit message that says what changed and why, and include the beads
  task ID when there is one.
- Never force-push, and never amend or rewrite commits that are already pushed.

## Push
Push to the remote after committing. If the push is rejected because the remote
is ahead, run `git pull --rebase` and push again.

## Choosing Your Outcome
- `committed` — commit created and pushed
- `nothing-to-commit` — `git status` shows nothing to commit
- `other` — commit or push failed in a way you cannot resolve; explain in otherDescription

**Outcomes:** committed, nothing-to-commit, other

**Transitions:**
- `committed` → **exit** (changes-committed)
- `nothing-to-commit` → **exit** (no-changes-to-commit)
- `other` → **exit** (user-provided-other)