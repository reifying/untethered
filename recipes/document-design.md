# Document Design

Create a detailed design document with examples and verification

**Recipe ID:** `document-design`
**Initial Step:** `document`

---

### Commit

**Prompt:**

Commit and push the design document. Use a descriptive commit message that summarizes what is being designed.

**Model:** `haiku`

**Outcomes:** committed, nothing-to-commit, other

**Transitions:**
- `committed` → **exit** (design-committed)
- `nothing-to-commit` → **exit** (no-changes-to-commit)
- `other` → **exit** (user-provided-other)

### Document

**Prompt:**

Create a detailed design document for the requested feature or change. Store as a markdown file following the repository's conventions for location and naming.

## Document Structure

Include the following sections:

### 1. Overview
- Problem statement: What problem does this solve?
- Goals: What are we trying to achieve?
- Non-goals: What is explicitly out of scope?

### 2. Background & Context
- Current state: How does the system work today?
- Why now: What triggered this work?
- Related work: Links to relevant documents, issues, or prior art

### 3. Detailed Design

#### Data Model
- New or modified data structures
- Schema changes with before/after examples
- Migration strategy if applicable

#### API Design
- Endpoint signatures with request/response examples
- Error cases and status codes
- Breaking changes and deprecation plan

#### Code Examples
Provide concrete implementation examples:

```clojure
;; Example: Show the key function signatures
(defn process-request
  "Process incoming request with validation."
  [request]
  ;; Implementation approach...
  )
```

Include examples for:
- Happy path usage
- Error handling patterns
- Edge cases

#### Component Interactions
- Sequence diagrams or flow descriptions
- Integration points with existing systems
- Dependency relationships

### 4. Verification Strategy

#### Testing Approach
- Unit tests: What functions need direct testing?
- Integration tests: What component interactions need verification?
- End-to-end tests: What user workflows should be validated?

#### Test Examples
```clojure
(deftest process-request-test
  (testing "validates required fields"
    (is (thrown? ExceptionInfo (process-request {}))))
  (testing "returns processed result"
    (is (= expected-result (process-request valid-input)))))
```

#### Acceptance Criteria
- Numbered list of verifiable requirements
- Each criterion should be testable

### 5. Alternatives Considered
- What other approaches were evaluated?
- Why was this approach chosen?
- Trade-offs of the chosen approach

### 6. Risks & Mitigations
- What could go wrong?
- How will we detect problems?
- Rollback strategy

## Quality Checklist
Before marking complete, verify:
- [ ] All code examples are syntactically correct
- [ ] Examples match the codebase's style and conventions
- [ ] Verification steps are specific and actionable
- [ ] Cross-references to related files use @filename.md format
- [ ] No placeholder text remains

**Outcomes:** complete, needs-input, other

**Transitions:**
- `complete` → **Review**
- `needs-input` → **exit** (clarification-needed)
- `other` → **exit** (user-provided-other)

### Fix

**Prompt:**

Address the issues found in the design document review.

**Outcomes:** complete, other

**Transitions:**
- `complete` → **Review**
- `other` → **exit** (user-provided-other)

### Review

**Prompt:**

Review the design document you created. Check for:
- Completeness: Are all sections filled in with substantive content?
- Correctness: Do code examples compile/parse correctly?
- Clarity: Would another developer understand the design?
- Consistency: Does it align with existing patterns in the codebase?
- Actionability: Are verification steps specific enough to execute?

Report any gaps or issues found. Do not make changes yet.

**Outcomes:** issues-found, no-issues, other

**Transitions:**
- `issues-found` → **Fix**
- `no-issues` → **Commit**
- `other` → **exit** (user-provided-other)

## Guardrails

- Max visits per step: 3
- Max total steps: 100
- Exit on other: true