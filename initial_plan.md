# Initial Plan: Fix voice-code-120 through voice-code-125

**Date**: 2025-10-18
**Context**: Follow-up work from REPLICATION_ARCHITECTURE.md implementation

## Overview

Six issues need to be investigated and fixed, all related to the session replication architecture. I'll use parallel subagents to investigate each issue while maintaining oversight for quality, testing, and standards compliance.

## Issues Summary

### voice-code-120: Backend sends session_updated with 0 messages after filtering warmup
- **Type**: Bug
- **Priority**: P2
- **Location**: `backend/src/voice_code/replication.clj` - `handle-file-modified` function
- **Issue**: Empty message check happens BEFORE filtering sidechain messages
- **Fix**: Move `(when (seq new-messages))` check to AFTER `filter-sidechain-messages`
- **Confidence**: HIGH - Clear fix identified

### voice-code-121: Backend re-sends all messages instead of just new ones
- **Type**: Bug
- **Priority**: P2
- **Location**: `backend/src/voice_code/replication.clj` - `handle-file-created` function
- **Issue**: `file-positions` atom not initialized when new session created
- **Fix**: Initialize file-positions in handle-file-created
- **Confidence**: HIGH - Root cause identified in logs

### voice-code-122: Backend includes non-UUID .jsonl files in session list
- **Type**: Bug
- **Priority**: P2
- **Location**: `backend/src/voice_code/replication.clj` - `extract-session-id-from-path` function
- **Issue**: No UUID validation for .jsonl filenames
- **Fix**: Add UUID validation and filter invalid sessions
- **Confidence**: HIGH - Clear validation needed

### voice-code-123: iOS subscribes twice when creating new session
- **Type**: Bug
- **Priority**: P2
- **Locations**:
  - `ios/VoiceCode/Views/SessionsView.swift:125`
  - `ios/VoiceCode/Views/ConversationView.swift:151`
- **Issue**: Duplicate subscription calls
- **Fix**: Remove one subscribe call (likely from SessionsView)
- **Confidence**: MEDIUM - Need to verify which call to remove

### voice-code-124: Existing sessions not loading
- **Type**: Bug
- **Priority**: P2
- **Issue**: Sessions from filesystem not appearing in iOS session list
- **Investigation needed**:
  - Is backend sending session_list?
  - Is iOS receiving and processing it?
  - Are sessions being filtered incorrectly?
- **Confidence**: LOW - Root cause not yet identified

### voice-code-125: Session list interaction not intuitive
- **Type**: Bug (UX)
- **Priority**: P2
- **Location**: `ios/VoiceCode/Views/SessionsView.swift`
- **Issue**: Tap shows checkbox, long-press should open but is unclear
- **Fix**: Implement single-tap to open (remove checkbox)
- **Confidence**: MEDIUM - Design decision needed

## Execution Strategy

### Phase 1: Parallel Investigation (Current)
1. Launch 6 subagents in parallel, one per issue
2. Each subagent will:
   - Read relevant code files
   - Understand the issue deeply
   - Propose a fix with code changes
   - Write tests for the fix
   - Run tests to verify
   - Document their findings

### Phase 2: Review & Quality Assurance
1. Review each subagent's solution for:
   - Code quality and adherence to STANDARDS.md
   - Test coverage and test quality
   - Proper snake_case/kebab-case conversions
   - Alignment with REPLICATION_ARCHITECTURE.md design
   - Edge cases handled
2. Request revisions if needed
3. Ensure all tests pass

### Phase 3: Integration & Validation
1. Verify fixes work together (no conflicts)
2. Run full test suite
3. Manual testing if needed
4. Update Beads issues to resolved

### Phase 4: Documentation
1. Create final_update.md with:
   - Summary of all fixes
   - Test results
   - Any design decisions made
   - Known limitations or follow-up work

## Standards to Enforce

From STANDARDS.md:
- JSON keys: snake_case
- Clojure keywords: kebab-case
- Swift properties: camelCase
- Proper coercion at boundaries
- All code changes must have tests
- All tests must pass before marking complete

## Success Criteria

- All 6 issues fixed and tested
- All existing tests still pass
- New tests added for all bug fixes
- Code adheres to standards
- Changes align with REPLICATION_ARCHITECTURE.md
- Beads issues updated
- final_update.md completed

## Estimated Effort

Using subagents to keep context clean. Prepared for up to 1000 tool calls if needed for thoroughness. Each issue should be relatively straightforward except voice-code-124 which needs investigation.
