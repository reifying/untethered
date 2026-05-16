# Update

Locate the existing draft design document and update it so it conforms to the full structure below. An agent (or human) already started this doc — your job is to bring it up to standard, fill in missing sections, and ensure every section has substantive content. Do NOT create a new file; edit the existing one in place.

## Instructions

1. Identify the design document being updated. The user should have specified which one; if not, use the most recently modified design doc under `docs/design/` (or the repo's design-doc location).
2. Read the entire document. Note which sections already exist and which are missing, thin, or stale.
3. Update the document so it matches the required structure below. Preserve existing content that is correct; rewrite or expand content that is incomplete; add any missing sections. Do not delete substantive prior work without an explicit reason.

## Required Document Structure

The finished document must contain all of the following sections.

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

## Update Guidelines

- **Preserve correct prior content.** If a section is already substantive and accurate, leave it alone or refine lightly.
- **Fill genuine gaps.** Missing sections must be written with real content drawn from the codebase, not placeholders.
- **Flag unknowns explicitly.** If you cannot answer a section without input from the user, write an explicit `> TODO(input-needed): <question>` block in that section rather than inventing an answer.
- **Match the codebase.** Code examples must use real namespaces, function signatures, and conventions from this repo — not generic Clojure.
- **Cross-reference real files.** Use `@path/to/file.ext` form for references.

## Quality Checklist

Before marking complete, verify:
- [ ] Every required section above is present and substantive
- [ ] All code examples are syntactically correct
- [ ] Examples match the codebase's style and conventions
- [ ] Verification steps are specific and actionable
- [ ] Cross-references to related files use @filename format
- [ ] No placeholder text remains (except explicit `TODO(input-needed)` blocks)
- [ ] Pre-existing correct content was preserved

**Outcomes:** complete, not-found, needs-input, other

**Transitions:**
- `complete` → **Review**
- `not-found` → **exit** (design-document-not-found)
- `needs-input` → **exit** (clarification-needed)
- `other` → **exit** (user-provided-other)
