# Analyze

Analyze the design document to understand the implementation scope.

## Prerequisites
1. Run `bd quickstart` to understand beads workflow if unfamiliar
2. Locate the design document for this feature
3. Read the design document thoroughly

## Analysis Steps
1. Identify all components that need to be created or modified
2. Map acceptance criteria to concrete implementation work
3. Identify dependencies between pieces of work
4. Note any verification steps from the design

Report your analysis including:
- Key components to implement
- Dependency graph (what must be done before what)
- Estimated number of tasks needed
- Any ambiguities or gaps in the design

**Outcomes:** complete, design-missing, needs-input, other

**Transitions:**
- `complete` → **Create Epic**
- `design-missing` → **exit** (no-design-document-found)
- `needs-input` → **exit** (clarification-needed)
- `other` → **exit** (user-provided-other)