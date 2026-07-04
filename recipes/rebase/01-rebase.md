# Rebase

Rebase the current branch onto the **local** `main` branch. Local main is the target — do not fetch, and do not rebase onto origin/main.

## Before Starting
- `git status` must be clean, with no rebase or merge already in progress. If
  the tree is dirty or a rebase is mid-flight, choose `other` and describe the
  state instead of plowing ahead.
- Note the current branch, and record `git log --oneline main..HEAD` so you know
  which commits are being replayed.

## Execute
Run `git rebase main` and resolve any conflicts.

Every resolution must preserve the intent of both branches: your commits should
still accomplish what they set out to do, and main's changes must remain intact
and functional.

- Read both sides of each conflict and understand WHY each changed, not just what
- If main refactored code your branch touches, re-express your change in the new structure
- Never resolve by wholesale taking one side without reading the other
- After the rebase completes, run the test suite

## If You Cannot Resolve Cleanly
Do not leave the repository mid-rebase. Run `git rebase --abort` to restore the
branch, then exit through the matching outcome below. Asking is better than
guessing and burying a bug in a conflict resolution.

## Choosing Your Outcome
- `complete` — rebase finished, conflicts resolved, tests pass
- `ask-questions` — aborted the rebase; a resolution depends on a judgment call the user should make (state the specific question)
- `conflicts-unresolvable` — aborted the rebase; the branches' changes genuinely cannot be reconciled without human intervention
- `other` — anything else (dirty tree, rebase already in progress, tests failing before you started); explain in otherDescription

**Outcomes:** ask-questions, complete, conflicts-unresolvable, other

**Transitions:**
- `ask-questions` → **exit** (clarification-needed)
- `complete` → **Review**
- `conflicts-unresolvable` → **exit** (conflicts-require-human-intervention)
- `other` → **exit** (user-provided-other)