# Review

Review the design document you just wrote, as if you were the engineer who has to implement from it.

Check, against the actual codebase:
- Would the implementer be blocked or misled anywhere? Are decisions justified, or merely asserted?
- Do the code examples match the project's real APIs, names, and conventions? Do the referenced files exist?
- Are the acceptance criteria concrete enough to test?
- Is anything substantive missing — or, equally, over-specified beyond what this change needs?

Report only gaps that would actually hurt implementation. A short document that
fully covers a small change is correct, not incomplete. If this is a re-review
after fixes, verify the previous findings were addressed rather than raising a
fresh wishlist.

Do not make changes in this step.

## Choosing Your Outcome
- `no-issues` — an implementer could work from this document as-is
- `issues-found` — substantive gaps or errors, listed in your report
- `other` — the review cannot be performed; explain in otherDescription

**Outcomes:** issues-found, no-issues, other

**Transitions:**
- `issues-found` → **Fix**
- `no-issues` → **Commit**
- `other` → **exit** (user-provided-other)