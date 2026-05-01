# Review

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