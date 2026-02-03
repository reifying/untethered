# Fix

Address the issues found in the rebase review.

After fixing:
- Amend the relevant commits if needed (`git commit --amend` or `git rebase -i`)
- Run tests to ensure they pass
- Verify the fix doesn't introduce new issues

**Outcomes:** complete, other

**Transitions:**
- `complete` → **Review**
- `other` → **exit** (user-provided-other)