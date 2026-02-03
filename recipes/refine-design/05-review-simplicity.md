# Review Simplicity

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