# Review Completeness

Review the design document for **completeness and technical depth**.

## Review Focus
This pass focuses on whether all necessary content exists and has sufficient detail.

## Completeness Checklist
- [ ] Problem statement clearly articulated
- [ ] Goals and non-goals defined
- [ ] All major components/modules described
- [ ] Data models fully specified (fields, types, constraints)
- [ ] API contracts complete (endpoints, request/response, errors)
- [ ] Code examples provided for key patterns
- [ ] Error handling approach documented
- [ ] Testing strategy outlined

## Depth Checklist  
- [ ] Technical decisions are justified (not just stated)
- [ ] Code examples are syntactically correct and idiomatic
- [ ] Edge cases identified and addressed
- [ ] Integration points explicitly documented
- [ ] Data flows clearly described
- [ ] State management explained where applicable

## Important Constraints
- **Do not make changes yet** - this is review only
- Focus on what's MISSING or INSUFFICIENTLY DETAILED
- Avoid suggesting additions that would be over-engineering
- If something is intentionally simple, that's fine

Report specific gaps found. If everything is complete and sufficiently detailed, report no issues.

**Outcomes:** issues-found, no-issues, other

**Transitions:**
- `issues-found` → **Fix Completeness**
- `no-issues` → **Review Breadth**
- `other` → **exit** (user-provided-other)