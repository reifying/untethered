# Review Polish

Final readability pass on the design document.

Look for what would trip up a reader: ambiguous statements, unexplained
acronyms, leftover placeholder text or TODOs, broken formatting (unlabeled code
fences, mangled tables, chaotic heading levels), typos that change meaning.

Good enough is good enough — flag what affects understanding, not what you would
merely phrase differently. On a re-review, confirm the previous findings were
fixed.

Review only — change nothing yet.

## Choosing Your Outcome
- `no-issues` — reads cleanly
- `issues-found` — specific readability problems, listed
- `other` — explain in otherDescription

**Outcomes:** issues-found, no-issues, other

**Transitions:**
- `issues-found` → **Fix Polish**
- `no-issues` → **Final Review**
- `other` → **exit** (user-provided-other)