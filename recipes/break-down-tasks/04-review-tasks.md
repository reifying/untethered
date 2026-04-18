# Review Tasks

Review the task breakdown for completeness and quality.

## Review Checklist

### Coverage
- [ ] All acceptance criteria from design are addressed by at least one task
- [ ] All components from design have corresponding tasks
- [ ] Verification strategy from design is reflected in task verification sections

### Task Quality
- [ ] Each task has a design document reference
- [ ] Each task has clear requirements
- [ ] Each task has verification steps
- [ ] No task is too large (should be completable in one session)
- [ ] No task is too vague (specific files and changes identified)

### Dependencies
- [ ] Task dependencies are explicitly stated in descriptions
- [ ] No circular dependencies exist
- [ ] Foundation tasks come before dependent tasks
- [ ] Parallelizable tasks are marked

### Dependency Links (Critical)
Run these commands to verify dependency links are properly set up:

1. **Check blocked tasks:** `bd blocked`
   - Tasks with prerequisites should appear here
   - If nothing is blocked but tasks have dependencies, links are missing

2. **Check epic dependencies:** `bd show <epic-id>`
   - Epic should show "Depends on" section listing ALL child tasks
   - If missing, epic will show as "ready" before children complete

3. **Check ready tasks:** `bd ready`
   - Only foundation tasks (no prerequisites) should appear
   - If all tasks appear, dependency links are missing

### Traceability
- [ ] Epic references the design document
- [ ] Each task references the relevant design section
- [ ] Acceptance criteria map back to design

Run `bd list` to see the created structure.

Report any issues found.

**Outcomes:** issues-found, no-issues, other

**Transitions:**
- `issues-found` → **Fix Tasks**
- `no-issues` → **Commit**
- `other` → **exit** (user-provided-other)