# Review

Have a subagent independently review the rebase, focusing on the files that had merge conflicts.

You resolved the conflicts, so you are the wrong reviewer for them. Launch a
subagent (Task tool), tell it which files conflicted and what each branch was
trying to do, and instruct it to:

1. Examine each conflicted file: does the resolution preserve both branches'
   intent? Was any code accidentally dropped or duplicated? Is the merged logic
   coherent?
2. Compare the replayed commits against the originals — `git range-diff ORIG_HEAD...HEAD`
   shows exactly what changed in the replay beyond the base swap
3. Run the test suite
4. Report specific problems with file and line, or a clean bill of health

If subagents are unavailable in this environment, perform the same review
yourself, re-reading each conflicted file from scratch.

Report the findings. Only real defects count — a resolution phrased differently
from how you would have written it is not an issue if the intent survives.

## Choosing Your Outcome
- `no-issues` — the rebase is sound and tests pass
- `issues-found` — defects found, listed in the report
- `other` — explain in otherDescription

**Outcomes:** issues-found, no-issues, other

**Transitions:**
- `issues-found` → **Fix**
- `no-issues` → **Complete**
- `other` → **exit** (user-provided-other)