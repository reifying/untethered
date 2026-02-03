# Refine Design

Iteratively improve an existing design document through focused review passes

**Recipe ID:** `refine-design`
**Initial Step:** `locate-design`

---

### Commit

**Prompt:**

Commit the refined design document.

Use a commit message that summarizes the refinements made.
Example: 'Refine user authentication design: add error handling, simplify token flow'

**Model:** `haiku`

**Outcomes:** committed, nothing-to-commit, other

**Transitions:**
- `committed` → **exit** (design-refined-and-committed)
- `nothing-to-commit` → **exit** (no-changes-made)
- `other` → **exit** (user-provided-other)

### Final Review

**Prompt:**

Perform a **final sanity check** on the refined design.

## Final Review
Read through the entire design one more time looking for anything that slipped through:

- [ ] Does the design actually solve the stated problem?
- [ ] Is there anything obviously wrong or missing?
- [ ] Would you be comfortable implementing from this design?
- [ ] Are there any remaining concerns?

## Summary
Provide a brief summary of the refinements made:
- What was added for completeness
- What was expanded for breadth
- What was simplified
- What was fixed for consistency
- What was polished

If any issues remain, report them. Otherwise, confirm the design is ready to commit.

**Outcomes:** issues-found, no-issues, other

**Transitions:**
- `issues-found` → **Fix Final**
- `no-issues` → **Commit**
- `other` → **exit** (user-provided-other)

### Fix Breadth

**Prompt:**

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

### Fix Completeness

**Prompt:**

Address the completeness and depth issues identified in the review.

## Guidelines
- Add missing sections or details identified in the review
- Ensure code examples are correct and follow project conventions
- Keep additions focused - add what's needed, nothing more
- Avoid scope creep: if something wasn't in the original design intent, don't add it

## Simplicity Reminder
When adding depth, prefer:
- Concrete examples over abstract descriptions
- Simple solutions over clever ones
- Fewer moving parts over comprehensive frameworks
- Direct approaches over indirection

After making changes, the design will be re-reviewed for completeness.

**Outcomes:** complete, other

**Transitions:**
- `complete` → **Review Completeness**
- `other` → **exit** (user-provided-other)

### Fix Consistency

**Prompt:**

Address the consistency issues identified in the review.

## Guidelines
- Standardize terminology throughout the document
- Align code examples with the codebase style
- Resolve contradictions (pick one approach, update all references)
- Fix broken references and links

After making changes, the design will be re-reviewed for consistency.

**Outcomes:** complete, other

**Transitions:**
- `complete` → **Review Consistency**
- `other` → **exit** (user-provided-other)

### Fix Final

**Prompt:**

Address the final issues identified.

Fix the remaining issues, then the design will have one more final review.

**Outcomes:** complete, other

**Transitions:**
- `complete` → **Final Review**
- `other` → **exit** (user-provided-other)

### Fix Polish

**Prompt:**

Apply the polish fixes identified in the review.

## Guidelines
- Fix typos and grammar
- Improve clarity of confusing passages
- Clean up formatting issues
- Remove placeholder text

Keep changes minimal - this is polish, not rewriting.

After making changes, the design will be re-reviewed for polish.

**Outcomes:** complete, other

**Transitions:**
- `complete` → **Review Polish**
- `other` → **exit** (user-provided-other)

### Fix Simplicity

**Prompt:**

Simplify the over-engineered parts identified in the review.

## Guidelines
- Remove unnecessary abstractions
- Inline things that don't need to be separate
- Replace generic with specific
- Delete speculative features

## Simplification Principles
- Delete code/design that isn't needed NOW
- Prefer duplication over the wrong abstraction
- Make it work, make it right, make it fast - in that order
- The best code is no code at all

After making changes, the design will be re-reviewed for simplicity.

**Outcomes:** complete, other

**Transitions:**
- `complete` → **Review Simplicity**
- `other` → **exit** (user-provided-other)

### Locate Design

**Prompt:**

Locate and read the design document to be refined.

## Instructions
1. Identify the design document (user should have specified which one, or it may be the most recent)
2. Read the entire document thoroughly
3. Note the current structure and content

Report what you found and confirm you're ready to begin the refinement process.

**Model:** `haiku`

**Outcomes:** found, not-found, other

**Transitions:**
- `found` → **Review Completeness**
- `not-found` → **exit** (design-document-not-found)
- `other` → **exit** (user-provided-other)

### Review Breadth

**Prompt:**

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

### Review Completeness

**Prompt:**

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

### Review Consistency

**Prompt:**

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

### Review Polish

**Prompt:**

Review the design document for **clarity, formatting, and polish**.

## Review Focus
This is the final pass - focus on readability and presentation.

## Clarity Checklist
- [ ] Writing is concise and direct
- [ ] Technical concepts explained at appropriate level
- [ ] No ambiguous statements
- [ ] Acronyms defined on first use
- [ ] Complex ideas have examples

## Formatting Checklist
- [ ] Headers create logical hierarchy
- [ ] Code blocks properly formatted with language tags
- [ ] Lists used appropriately
- [ ] Tables readable and aligned
- [ ] Consistent formatting throughout

## Polish Checklist
- [ ] No typos or grammatical errors
- [ ] No placeholder text remaining
- [ ] No TODO comments left unaddressed
- [ ] No commented-out content
- [ ] Professional tone throughout

## Important Constraints
- **Do not make changes yet** - this is review only
- Focus on issues that affect understanding
- Don't over-polish - good enough is good enough

Report specific polish issues found. If the document is polished, report no issues.

**Outcomes:** issues-found, no-issues, other

**Transitions:**
- `issues-found` → **Fix Polish**
- `no-issues` → **Final Review**
- `other` → **exit** (user-provided-other)

### Review Simplicity

**Prompt:**

Review the design document for **over-engineering and unnecessary complexity**.

## Review Focus
This pass looks for ways to SIMPLIFY the design. Simpler is better.

## Over-Engineering Red Flags
- [ ] Abstractions without multiple concrete uses
- [ ] Configuration options that could be hardcoded
- [ ] Extensibility points for hypothetical future needs
- [ ] Generic solutions where specific ones would suffice
- [ ] Multiple indirection layers
- [ ] Complex state machines where simple conditionals work
- [ ] Framework-like patterns in application code

## Simplification Opportunities
- [ ] Can any component be eliminated entirely?
- [ ] Can two similar things be merged into one?
- [ ] Can a complex flow be linearized?
- [ ] Can configuration be replaced with convention?
- [ ] Can an abstraction be inlined?
- [ ] Can error handling be simplified?

## YAGNI Check (You Aren't Gonna Need It)
- [ ] Is anything being built "for future use"?
- [ ] Are there features no one asked for?
- [ ] Is there flexibility that isn't required?

## Important Constraints
- **Do not make changes yet** - this is review only
- Challenge every abstraction: does it earn its complexity?
- The best design is often the most boring one
- Clever is the enemy of maintainable

Report specific over-engineering found. If the design is appropriately simple, report no issues.

**Outcomes:** issues-found, no-issues, other

**Transitions:**
- `issues-found` → **Fix Simplicity**
- `no-issues` → **Review Consistency**
- `other` → **exit** (user-provided-other)

## Guardrails

- Max visits per step: 5
- Max total steps: 150
- Exit on other: true