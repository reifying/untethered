# Retrospective

Reflect on the session and identify areas for improvement

**Recipe ID:** `retrospective`
**Initial Step:** `reflect`

---

### Reflect

**Prompt:**

Perform a retrospective on the session that just took place.

## Important Constraints
- Do NOT make any changes to files
- Do NOT run any commands or tests
- This is purely investigative and reflective
- Be concise - bullet points preferred over prose

## Focus Areas (Friction Only)

### Tool Issues
- Which tools didn't work as expected?
- What tool calls failed or produced unexpected results?
- What tools were missing that would have helped?

### Development Friction
- What slowed down the development process?
- Where were requirements unclear or context missing?
- What work had to be repeated or backtracked?

### Testing Friction
- What problems occurred running or writing tests?
- Where did test failures lack clear feedback?
- What was unreliable in the test infrastructure?

### Process Friction
- What workflow inefficiencies occurred?
- What documentation or context was missing?

## Output Format
- List only friction points and potential improvements
- Do NOT include what worked well or positive observations
- Be specific with examples from this session
- Keep it brief and actionable

**Outcomes:** complete, other

**Transitions:**
- `complete` → **exit** (retrospective-complete)
- `other` → **exit** (user-provided-other)

## Guardrails

- Max visits per step: 3
- Max total steps: 100
- Exit on other: true