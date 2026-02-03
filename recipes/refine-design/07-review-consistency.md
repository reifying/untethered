# Review Consistency

Review the design document for **internal consistency and alignment**.

## Review Focus
This pass checks that the design is coherent and aligned with the codebase.

## Internal Consistency
- [ ] Terminology used consistently throughout
- [ ] Code examples match the described approach
- [ ] Data models in different sections agree
- [ ] No contradictions between sections
- [ ] Level of detail consistent across sections

## Codebase Alignment
- [ ] Naming follows project conventions
- [ ] Patterns match existing codebase patterns
- [ ] Code examples follow project style
- [ ] Referenced files/modules exist
- [ ] Integration points match actual codebase structure

## Cross-Reference Check
- [ ] All referenced designs/docs exist
- [ ] Links are valid
- [ ] Dependencies are actually available

## Important Constraints
- **Do not make changes yet** - this is review only
- Focus on inconsistencies, not preferences
- Align with existing patterns, don't introduce new ones unnecessarily

Report specific inconsistencies found. If the design is consistent, report no issues.

**Outcomes:** issues-found, no-issues, other

**Transitions:**
- `issues-found` → **Fix Consistency**
- `no-issues` → **Review Polish**
- `other` → **exit** (user-provided-other)