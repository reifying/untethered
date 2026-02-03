# Review & Commit

Review existing changes, fix issues, and commit

**Recipe ID:** `review-and-commit`
**Initial Step:** `code-review`

---

### Code Review

**Prompt:**

Perform a thorough code review on the changes.

## Review Process

1. Run `git diff` to see exactly what changed
2. Read each modified file to understand the changes in context
3. Evaluate against the checklist below
4. Report your findings

**Important:** List the files you read and summarize what you checked in each.

## Review Checklist

### Correctness
- [ ] Logic correctly implements the requirements
- [ ] Edge cases are handled
- [ ] Error handling is appropriate
- [ ] No regressions introduced

### Code Quality
- [ ] Follows project naming conventions
- [ ] Functions are appropriately sized
- [ ] No code duplication
- [ ] Comments explain 'why' not 'what' (where needed)

### Testing
- [ ] Tests cover happy path
- [ ] Tests cover error cases
- [ ] Tests are readable and maintainable
- [ ] All tests pass

### Security & Performance
- [ ] No hardcoded secrets or credentials
- [ ] No obvious performance issues
- [ ] Input validation where needed

### Design Alignment
- [ ] Implementation matches requirements
- [ ] No scope creep beyond task requirements

Report any issues found. Do not make changes yet.

**Outcomes:** issues-found, no-issues, other

**Transitions:**
- `issues-found` → **Fix**
- `no-issues` → **Commit**
- `other` → **exit** (user-provided-other)

### Commit

**Prompt:**

Commit and push the changes.

## Pre-Commit Steps
If working on a beads task, update its status first:
- Run `bd close <task-id>` to mark the task as complete
- If partially complete, use `bd update <task-id> --status in-progress` with notes

## Commit and Push
- Write a clear commit message describing what was implemented
- If working on a beads task, include the task ID in the commit message
- Push to the remote repository after committing

**Model:** `haiku`

**Outcomes:** committed, nothing-to-commit, other

**Transitions:**
- `committed` → **exit** (changes-committed)
- `nothing-to-commit` → **exit** (no-changes-to-commit)
- `other` → **exit** (user-provided-other)

### Fix

**Prompt:**

Address the issues found in the code review.

After fixing:
- Run tests to ensure they still pass
- Verify the fix doesn't introduce new issues

**Outcomes:** complete, other

**Transitions:**
- `complete` → **Code Review**
- `other` → **exit** (user-provided-other)

## Guardrails

- Max visits per step: 3
- Max total steps: 100
- Exit on other: true