# Rebase

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