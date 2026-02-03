# Rebase

Rebase current branch on local main with conflict resolution

**Recipe ID:** `rebase`
**Initial Step:** `rebase`

---

### Complete

**Prompt:**

The rebase has been reviewed and is ready.

## Summary
Provide a brief summary of:
- Number of commits rebased
- Any conflicts that were resolved
- Key changes from main that were incorporated

The branch is now rebased on main and ready for further work or pushing.

**Model:** `haiku`

**Outcomes:** done, other

**Transitions:**
- `done` → **exit** (rebase-complete)
- `other` → **exit** (user-provided-other)

### Fix

**Prompt:**

Address the issues found in the rebase review.

After fixing:
- Amend the relevant commits if needed (`git commit --amend` or `git rebase -i`)
- Run tests to ensure they pass
- Verify the fix doesn't introduce new issues

**Outcomes:** complete, other

**Transitions:**
- `complete` → **Review**
- `other` → **exit** (user-provided-other)

### Rebase

**Prompt:**

Rebase on the local (not remote) main branch.

## Before Starting
1. Ensure working directory is clean (`git status`)
2. Fetch latest changes (`git fetch origin`)
3. Check current branch name

## Rebase Best Practices

### Preserve Intent of Both Branches
- The goal is to replay your commits on top of main while preserving the intent of BOTH branches
- Your branch's changes should achieve their original purpose
- Main's changes should remain intact and functional
- The combined result should honor both sets of changes

### Conflict Resolution Guidelines
- Read both versions carefully before making changes
- Understand WHY each change was made, not just WHAT changed
- If main refactored code your branch modifies, apply your changes to the new structure
- If both branches modified the same logic, combine the intents thoughtfully
- Test after resolving conflicts to ensure nothing is broken

### When in Doubt
- If the correct resolution is unclear, select the `ask-questions` outcome
- It's better to ask than to guess and introduce bugs
- Provide context about what's unclear when asking

## Execution
Run: `git rebase main`

Handle any conflicts that arise following the guidelines above.

**Outcomes:** ask-questions, complete, conflicts-unresolvable, other

**Transitions:**
- `ask-questions` → **exit** (clarification-needed)
- `complete` → **Review**
- `conflicts-unresolvable` → **exit** (conflicts-require-human-intervention)
- `other` → **exit** (user-provided-other)

### Review

**Prompt:**

Ask a subagent to perform a review on the rebase with special attention to any files that had merge conflicts.

## Review Instructions for Subagent
Use the Task tool to launch a subagent with these instructions:

1. Identify all files that had merge conflicts during the rebase
2. For each conflicted file:
   - Verify the resolution preserves intent from both branches
   - Check for accidentally deleted code
   - Check for duplicated code
   - Ensure the combined logic is coherent
3. Run tests to verify nothing is broken
4. Report any issues found

Wait for the subagent to complete and report its findings.

**Outcomes:** issues-found, no-issues, other

**Transitions:**
- `issues-found` → **Fix**
- `no-issues` → **Complete**
- `other` → **exit** (user-provided-other)

## Guardrails

- Max visits per step: 3
- Max total steps: 100
- Exit on other: true