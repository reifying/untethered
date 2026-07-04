# Code Review

Review the uncommitted changes in this repository and decide whether they are ready to commit.

## Establish Context
- Run `git status` and `git diff` (plus `git diff --staged`) to see exactly what changed
- Skim recent `git log`, and any beads task (`br show <task-id>`) or design document the work references, to understand what the changes are supposed to accomplish
- Read the modified files wherever the diff alone is ambiguous — judge changes in context, not in isolation

## What to Look For, in Priority Order
1. **Correctness** — logic errors, unhandled edge cases, broken invariants, regressions in surrounding code
2. **Tests** — new behavior is covered, and the tests pass. Actually run the relevant test suite; do not take passing tests on faith.
3. **Security** — hardcoded secrets or credentials, injection risks, unvalidated external input
4. **Scope** — the diff matches the task's intent; no unrelated edits, debug output, or stray files

## Severity Bar
Report only issues that should block this commit. Style preferences, hypothetical
future concerns, and minor naming quibbles are not blockers. Finding nothing is a
common and correct result — do not invent findings to have something to report.

If this is a re-review after fixes: first verify each previously reported issue is
actually resolved, then check the fixes themselves for new problems. Do not raise
new nitpicks you did not consider blocking the first time.

## Report
State which files you read and what you checked in each — the review is only as
good as its evidence. For each blocking issue give the file and line, what is
wrong, why it blocks the commit, and a suggested fix.

Do not make any changes in this step.

## Choosing Your Outcome
- `no-issues` — nothing blocks the commit (tests pass, no blocking findings)
- `issues-found` — one or more blocking issues, listed in your report
- `other` — you cannot perform the review (e.g. there are no changes to review); explain in otherDescription

**Outcomes:** issues-found, no-issues, other

**Transitions:**
- `issues-found` → **Fix**
- `no-issues` → **Commit**
- `other` → **exit** (user-provided-other)