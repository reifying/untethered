# Fix

Fix the defects the rebase review found.

- Defect in the tip commit: amend it (`git commit --amend`).
- Defect in an earlier commit: `git commit --fixup=<sha>`, then
  `GIT_SEQUENCE_EDITOR=true git rebase -i --autosquash main` — the env var makes
  it non-interactive. Never run a bare `git rebase -i`; there is no interactive
  editor in this environment.
- Re-run the tests after fixing.

## Choosing Your Outcome
- `complete` — defects fixed, tests pass
- `other` — a defect cannot be fixed; explain in otherDescription

**Outcomes:** complete, other

**Transitions:**
- `complete` → **Review**
- `other` → **exit** (user-provided-other)