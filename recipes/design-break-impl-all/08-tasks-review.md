# Tasks Review

Review the task breakdown as if you were a fresh agent about to execute it.

## The Critical Checks
1. **Cold-start executability** — pick two or three tasks and read each
   description as a stranger would: does it name the actual files, reference the
   design section, and define verification? Any task you could not start from
   cold needs fixing.
2. **Coverage** — every acceptance criterion and component in the design maps to
   at least one task, and no task invents work the design does not call for.
3. **Dependency links** — run the commands; do not assume:
   - `br blocked` — tasks with prerequisites must appear here; nothing blocked means links are missing
   - `br ready` — only genuinely startable foundation tasks should appear; if every task shows as ready, links are missing
   - `br show <epic-id>` — the epic must depend on all children, or it will look ready before they are done
4. **Sizing** — no task so large it spans many concerns, none so vague it names no files

Run `br list` to see the full structure.

Report only problems that would cause an executing agent to stall, duplicate
work, or build the wrong thing. A lean, well-linked breakdown needs no findings.
On a re-review after fixes, verify the previous findings were addressed rather
than raising new ones.

## Choosing Your Outcome
- `no-issues` — the breakdown is executable as-is
- `issues-found` — problems found, listed in your report
- `other` — explain in otherDescription

**Outcomes:** issues-found, no-issues, other

**Transitions:**
- `issues-found` → **Tasks Fix**
- `no-issues` → **Tasks Commit**
- `other` → **exit** (user-provided-other)