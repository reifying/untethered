# Fix

Fix the blocking issues from the code review.

- Address every issue the review listed — and nothing more. No opportunistic
  refactoring or unrelated cleanup; that widens the diff the re-review has to verify.
- Update or add tests where a fix changes behavior.
- Run the relevant tests and confirm they pass before finishing.

**Do not commit.** The changes will be re-reviewed first.

## Choosing Your Outcome
- `complete` — every listed issue is addressed and tests pass
- `other` — an issue cannot be fixed as described; explain what is blocking in otherDescription

**Outcomes:** complete, other

**Transitions:**
- `complete` → **Code Review**
- `other` → **exit** (user-provided-other)