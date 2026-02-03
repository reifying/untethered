# Fix Breadth

Address the breadth and coverage issues identified in the review.

## Guidelines
- Add coverage for failure modes, integration points, etc. as identified
- Keep additions proportional to the risk/importance
- Document "we considered X and decided not to handle it because Y" where appropriate

## Simplicity Reminder
When expanding coverage:
- Prefer simple error handling over complex retry logic
- Prefer clear failure modes over attempting to handle everything
- It's OK to say "this is out of scope" in the design
- Document tradeoffs rather than trying to solve everything

After making changes, the design will be re-reviewed for breadth.

**Outcomes:** complete, other

**Transitions:**
- `complete` → **Review Breadth**
- `other` → **exit** (user-provided-other)