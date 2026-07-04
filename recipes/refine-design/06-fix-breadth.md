# Fix Breadth

Address the coverage gaps the review identified — those and nothing else.

Keep additions proportional to real risk. Where the right answer is to not
handle something, say so in the document — we considered X and are not handling
it because Y — instead of designing machinery for it.

## Choosing Your Outcome
- `complete` — every gap addressed
- `other` — explain in otherDescription

**Outcomes:** complete, other

**Transitions:**
- `complete` → **Review Breadth**
- `other` → **exit** (user-provided-other)