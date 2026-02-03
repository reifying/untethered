# Code Review

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