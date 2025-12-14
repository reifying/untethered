# Orchestration MVP Requirements

## Overview

Implement automated recipe-driven workflow orchestration for Claude Code agents. MVP focuses on a single "Implement & Review" recipe that loops through implementation, review, and issue fixing until all issues are resolved.

## Feature Scope

### User Interface (iOS Frontend)

- **Settings Toggle:** Enable/disable orchestration mid-session
- **Recipe Selection:** User can select "Implement next task" recipe from a menu
- **Session Continuity:** Same session can toggle between orchestration and normal chat

### Backend Orchestration

- **Recipe Definition:** Define workflow as state machine in Clojure code with tests
- **Recipe State Tracking:** Maintain current recipe and iteration count per session
- **Prompt Construction:** Append JSON outcome requirements to user prompt
- **Response Parsing:** Extract and validate JSON outcome from agent response
- **Automatic Transitions:** Determine next prompt/action based on outcome

## MVP Recipe: "Implement & Review Loop"

### Workflow

1. **Implement Task**
   - Prompt: `"Run bd ready and implement the task."`
   - Expected outcomes: `complete`, `other`
   - On `complete` → proceed to Code Review
   - On `other` → exit recipe (user intervenes)

2. **Code Review**
   - Prompt: `"Perform a code review on the task that you just completed."`
   - Expected outcomes: `no-issues`, `issues-found`, `other`
   - On `no-issues` → return to step 1 (Implement Task)
   - On `issues-found` → proceed to Fix Issues
   - On `other` → exit recipe

3. **Fix Issues** (loop until clean)
   - Prompt: `"Address the issues found."`
   - Expected outcomes: `complete`, `other`
   - On `complete` → proceed to Code Review (re-review)
   - On `other` → exit recipe

4. **Re-Review After Fix**
   - Same as Code Review (step 2)
   - Loop continues until `no-issues`

### Exit Conditions

Any `other` outcome at any step exits the recipe and returns to normal chat.

## JSON Response Format

### Standard Structure

```json
{
  "outcome": "enum-value",
  "otherDescription": "description string (optional, only when outcome is 'other')"
}
```

### Examples

```json
{"outcome": "complete"}
{"outcome": "no-issues"}
{"outcome": "issues-found"}
{"outcome": "other", "otherDescription": "Waiting for external API response"}
```

## Prompt Integration

### Constraint

System prompt cannot change mid-session. JSON format requirement must be appended to user prompt each turn.

### Prompt Appending Strategy

For each orchestrated turn, append to user prompt:
```
{outcome_format_requirement}
Your possible outcomes: {outcome1}, {outcome2}, ...
Please end your response with a JSON block: {"outcome": "..."}
```

### Invalid JSON Handling

If agent does not provide valid JSON:
1. Extract any text response (for context)
2. Send back: `"Please respond again with JSON per the instructions. {outcome_format_requirement}"`
3. Loop continues until valid JSON received

## Deferred Features

- Prompt templates with variable interpolation (`{{task-description}}`, etc.)
- Context tracking and automatic compaction
- User-configurable recipe parameters
- Additional recipes (beyond MVP)

## Implementation Requirements

### Testing

- All recipe logic must have unit test coverage
- JSON parsing edge cases tested (invalid JSON, missing fields, unexpected outcomes)
- Recipe state transitions tested
- Integration tests for orchestration loop

### Code Organization

- Recipe definitions in Clojure with spec validation
- Separate orchestration module for state machine logic
- Response parser module for JSON extraction and validation
- Clear separation between normal chat and orchestrated prompts
