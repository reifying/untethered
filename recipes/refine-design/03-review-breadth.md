# Review Breadth

Review the design document for **breadth and coverage**.

## Review Focus
This pass examines whether the design considers the full picture - not just the happy path.

## Breadth Checklist
- [ ] Failure modes identified (what can go wrong?)
- [ ] Recovery strategies documented
- [ ] Backward compatibility addressed (if modifying existing system)
- [ ] Migration path clear (if data/schema changes)
- [ ] Performance implications considered
- [ ] Security implications addressed
- [ ] Observability needs identified (logging, metrics, alerts)
- [ ] Dependencies and their failure modes noted

## Integration Checklist
- [ ] Upstream dependencies documented
- [ ] Downstream consumers identified
- [ ] Cross-cutting concerns addressed (auth, logging, etc.)
- [ ] Deployment considerations noted

## Important Constraints
- **Do not make changes yet** - this is review only
- Only flag items that are genuinely missing and needed
- Not every design needs every item above - use judgment
- Avoid adding complexity for hypothetical scenarios
- If the design is intentionally narrow in scope, that's acceptable

Report specific gaps in coverage. If breadth is adequate, report no issues.

**Outcomes:** issues-found, no-issues, other

**Transitions:**
- `issues-found` → **Fix Breadth**
- `no-issues` → **Review Simplicity**
- `other` → **exit** (user-provided-other)