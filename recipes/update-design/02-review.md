# Review

Review the updated design document. Check for:
- Completeness: Are all required sections present and filled in with substantive content?
- Correctness: Do code examples compile/parse correctly? Do referenced symbols actually exist in the codebase?
- Clarity: Would another developer understand the design?
- Consistency: Does it align with existing patterns in the codebase?
- Actionability: Are verification steps specific enough to execute?
- Preservation: Was pre-existing correct content kept intact, not silently rewritten or dropped?

Report any gaps or issues found. Do not make changes yet.

**Outcomes:** issues-found, no-issues, other

**Transitions:**
- `issues-found` → **Fix**
- `no-issues` → **Commit**
- `other` → **exit** (user-provided-other)
