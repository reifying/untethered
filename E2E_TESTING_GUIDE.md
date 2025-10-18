# End-to-End Testing Guide
**Session Replication Architecture (voice-code-97 through 101)**

Last Updated: 2025-10-17

---

## Overview

This guide covers the comprehensive end-to-end testing strategy for the voice-code session replication architecture. Tests validate the Swift-Clojure backend interactions using **REAL data** with **minimal mocking**.

### Test Philosophy

- **Real Backend**: Tests connect to actual localhost:8080 backend
- **Real Sessions**: Uses ~700 existing .jsonl files from ~/.claude/projects
- **Real Claude CLI**: Creates real sessions (costs money via Claude API)
- **Real CoreData**: Tests actual persistence layer
- **Minimal Mocking**: Only mock voice output and hard-to-trigger errors

---

## Prerequisites

### 1. Backend Running

```bash
cd backend
lein run
```

**Expected output:**
```
Starting voice-code backend...
Loading session index...
Loaded index with 700+ sessions
Server started on port 8080
Watching ~/.claude/projects for changes...
```

### 2. Claude CLI Installed

```bash
# Verify installation
claude --version

# Verify authentication
claude "test" -p
```

**Expected:** Claude CLI should respond without errors.

### 3. Test Environment

```bash
# Create test working directory
mkdir -p /tmp/voice-code-e2e-tests
```

---

## Test Files

### Swift Tests (ios/VoiceCodeTests/)

| File | Task | Tests | Costs Money? |
|------|------|-------|--------------|
| **E2ETerminalToIOSSyncTests.swift** | voice-code-97 | Terminal sessions appearing on iOS | Yes (creates sessions) |
| **E2EIOSToIOSSyncTests.swift** | voice-code-98 | iOS-to-iOS session syncing | Yes (creates sessions) |
| **E2ESessionForkingTests.swift** | voice-code-99 | Concurrent resume creating forks | Yes (creates forks) |
| **E2EDeletionWorkflowTests.swift** | voice-code-100 | Deletion stops replication | Yes (minimal) |
| **E2EPerformanceTests.swift** | voice-code-101 | Performance with 700+ sessions | No (read-only) |

### Clojure Tests (backend/manual_test/voice_code/)

| File | Description | Costs Money? |
|------|-------------|--------------|
| **test_10_real_data_validation.clj** | Backend validation with real 700+ sessions | No |

---

## Running Tests

### Swift Tests

#### Run All E2E Tests

```bash
cd ios

xcodebuild test \
  -scheme VoiceCode \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:VoiceCodeTests/E2ETerminalToIOSSyncTests \
  -only-testing:VoiceCodeTests/E2EIOSToIOSSyncTests \
  -only-testing:VoiceCodeTests/E2ESessionForkingTests \
  -only-testing:VoiceCodeTests/E2EDeletionWorkflowTests \
  -only-testing:VoiceCodeTests/E2EPerformanceTests
```

#### Run Individual Test Files

**Terminal to iOS Sync (voice-code-97):**
```bash
xcodebuild test \
  -scheme VoiceCode \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:VoiceCodeTests/E2ETerminalToIOSSyncTests
```

**iOS to iOS Sync (voice-code-98):**
```bash
xcodebuild test \
  -scheme VoiceCode \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:VoiceCodeTests/E2EIOSToIOSSyncTests
```

**Session Forking (voice-code-99):**
```bash
xcodebuild test \
  -scheme VoiceCode \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:VoiceCodeTests/E2ESessionForkingTests
```

**Deletion Workflow (voice-code-100):**
```bash
xcodebuild test \
  -scheme VoiceCode \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:VoiceCodeTests/E2EDeletionWorkflowTests
```

**Performance Testing (voice-code-101):**
```bash
xcodebuild test \
  -scheme VoiceCode \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:VoiceCodeTests/E2EPerformanceTests
```

#### Run Individual Test Methods

```bash
xcodebuild test \
  -scheme VoiceCode \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:VoiceCodeTests/E2EPerformanceTests/testSessionListReceivePerformance
```

### Clojure Tests

```bash
cd backend

# Run real data validation tests
lein test :only voice-code.test-10-real-data-validation

# Run specific test
lein test :only voice-code.test-10-real-data-validation/test-real-index-building
```

---

## Test Scenarios

### Terminal to iOS Sync (voice-code-97)

**What's Tested:**
- Backend serving 700+ real sessions via session_list
- Creating new Claude session from terminal
- iOS receiving session_created broadcast
- Session appearing in CoreData with correct metadata
- Subscribing to existing real sessions
- Terminal prompt appearing on iOS via session_updated
- Session naming conventions

**Key Tests:**
- `testReceiveRealSessionList()` - Loads all 700+ sessions
- `testSubscribeToExistingRealSession()` - Loads real session history
- `testCreateNewTerminalSession()` - Creates real Claude session (💰)
- `testTerminalPromptAppearsOnIOS()` - End-to-end message sync (💰)

**Expected Results:**
- Session count ≥ 500
- All sessions have proper metadata (name, working_directory, etc.)
- Terminal sessions named "Terminal: <dir> - <timestamp>"
- Messages sync within seconds

---

### iOS to iOS Sync (voice-code-98)

**What's Tested:**
- Two iOS clients connecting simultaneously
- iOS-originated sessions creating backend .jsonl files
- session_created broadcast to all clients
- Messages syncing between clients via session_updated
- Optimistic UI reconciliation
- Voice: prefix for iOS sessions

**Key Tests:**
- `testTwoClientsConnectAndReceiveSessionList()` - Multi-client connection
- `testIOSSessionCreationSyncsToOtherClient()` - End-to-end sync (💰)
- `testIOSSessionUpdatesSyncToOtherClient()` - Incremental updates (💰)
- `testOptimisticUIWithRealBackend()` - No message duplication (💰)

**Expected Results:**
- Both clients receive same session list
- Session created on one client appears on other
- Messages sync correctly
- No duplicate messages from optimistic UI

---

### Session Forking (voice-code-99)

**What's Tested:**
- Concurrent resume creating fork files
- Fork file detection by filesystem watcher
- iOS receiving session_created for forks
- Fork naming: "(fork)" or "(compacted)"
- Multiple forks from same parent
- Fork metadata inheritance

**Key Tests:**
- `testConcurrentResumeCreatesFork()` - Basic fork creation (💰)
- `testForkNamingConvention()` - Verify "(fork)" suffix (💰)
- `testMultipleConcurrentResumesCreateMultipleForks()` - Multiple forks (💰)
- `testForkMetadataInheritance()` - Working directory inheritance (💰)

**Expected Results:**
- Fork files detected within 5 seconds
- Fork names include "(fork)" or "(compacted)"
- Forks inherit parent's working directory
- iOS auto-subscribes to forks (optional behavior)

---

### Deletion Workflow (voice-code-100)

**What's Tested:**
- session_deleted message stops updates for that client
- Other clients continue receiving updates
- Backend .jsonl file persists after client deletion
- markedDeleted filtering in CoreData queries
- Deletion state persists across reconnections
- Multiple clients have independent deletion states

**Key Tests:**
- `testDeletionStopsReplicationForClient()` - Per-client filtering (💰)
- `testBackendFileRemainsAfterClientDeletion()` - File persistence (💰)
- `testDeletedSessionNotVisibleInUIQueries()` - CoreData filtering
- `testMultipleClientsDeletionIndependence()` - Independent states (💰)

**Expected Results:**
- Client 1 marks deleted, stops receiving updates
- Client 2 still receives updates
- Backend file still exists
- Deleted sessions filtered from UI queries

---

### Performance Testing (voice-code-101)

**What's Tested:**
- Session list load time with 700+ sessions
- Per-session load latency
- Large session (100+ messages) load time
- CoreData query performance
- Paginated fetches (20 sessions/page)
- Memory usage with many sessions
- Incremental update latency (terminal → iOS)

**Key Tests:**
- `testSessionListReceivePerformance()` - Session list latency
- `testPerSessionLoadPerformance()` - Individual session load
- `testCoreDataQueryPerformance()` - Query speed with 700+ sessions
- `testMemoryUsageWith700Sessions()` - Memory footprint
- `testIncrementalUpdateLatency()` - End-to-end update speed (💰)

**Performance Targets:**
- Session list: < 3 seconds
- Per-session load: < 5 seconds
- CoreData query: < 100ms
- Memory: Reasonable for 700+ sessions
- Update latency: < 20 seconds end-to-end

---

## Backend Validation (test_10_real_data_validation.clj)

**What's Tested:**
- Index building with 700+ real .jsonl files
- Session metadata extraction accuracy
- Message count validation
- Session naming patterns
- Index persistence (.edn file)
- Performance of get-all-sessions
- JSONL parsing performance

**Key Tests:**
- `test-real-index-building` - Index build time < 60s
- `test-real-session-metadata` - All sessions have required fields
- `test-message-count-accuracy` - Counts match file contents
- `test-two-real-ios-clients` - Multi-client broadcast
- `test-performance-get-all-sessions` - < 100ms average

**Expected Results:**
- Index builds in < 60 seconds
- All sessions have valid metadata
- Message counts accurate (within ±2)
- get-all-sessions averages < 100ms

---

## Cleanup

### After Each Test Run

```bash
# Find and remove test sessions
find ~/.claude/projects -name "*e2e-test*.jsonl" -delete
find ~/.claude/projects -name "*E2E*.jsonl" -delete

# Or inspect before deleting
find ~/.claude/projects -name "*e2e-test*.jsonl"
```

### Manual Cleanup

```bash
# List test sessions
ls -lh ~/.claude/projects/**/*e2e*.jsonl

# Remove specific test session
rm ~/.claude/projects/some-project/<test-session-id>.jsonl
```

---

## Cost Estimation

### Tests That Cost Money (Claude API Calls)

| Test File | Approximate API Calls | Estimated Cost |
|-----------|----------------------|----------------|
| E2ETerminalToIOSSyncTests | 3-5 | $0.10 - $0.30 |
| E2EIOSToIOSSyncTests | 5-10 | $0.30 - $0.60 |
| E2ESessionForkingTests | 8-12 | $0.50 - $0.80 |
| E2EDeletionWorkflowTests | 4-6 | $0.20 - $0.40 |
| E2EPerformanceTests | 1-2 | $0.05 - $0.15 |
| **Total per full run** | **21-35** | **$1.15 - $2.25** |

### Cost-Free Tests

- E2EPerformanceTests (most tests - read-only)
- test_10_real_data_validation.clj (all tests)
- Backend manual tests (test_03 through test_09, except test_05, test_06, test_07)

---

## Troubleshooting

### Backend Not Running

**Symptom:** Tests timeout waiting for connection

**Solution:**
```bash
cd backend
lein run
# Verify: "Server started on port 8080"
```

### Claude CLI Not Found

**Symptom:** `executableURL` error or "file not found"

**Solution:**
```bash
# Check installation
which claude
# Should return: /usr/local/bin/claude

# If not found, install Claude CLI
# Or update test to use correct path
```

### Session List Empty

**Symptom:** Tests fail because no sessions loaded

**Solution:**
```bash
# Verify sessions exist
ls -l ~/.claude/projects/**/*.jsonl | wc -l
# Should show 700+

# Check backend logs for errors
# Restart backend to rebuild index
```

### Tests Taking Too Long

**Symptom:** Tests timeout or take minutes

**Cause:** Claude API calls are slow, or backend is processing many files

**Solution:**
- Increase timeout values in tests
- Run performance tests separately (no Claude calls)
- Use faster network connection
- Reduce number of test iterations

### Cleanup Issues

**Symptom:** Old test sessions accumulating

**Solution:**
```bash
# Clean up before running tests
find ~/.claude/projects -name "*e2e-test*.jsonl" -delete
find ~/.claude/projects -name "*E2E*.jsonl" -delete
```

### Fork Tests Failing

**Symptom:** Fork files not detected

**Cause:** Claude CLI may not always create forks (depends on timing)

**Solution:**
- Increase delays between parent and fork creation
- Some tests may be flaky - retry
- Verify fork files manually: `ls ~/.claude/projects/**/*fork*.jsonl`

---

## Test Results Interpretation

### Success Criteria

**voice-code-97: Terminal to iOS Sync**
- ✅ Receives 500+ sessions
- ✅ All sessions have valid metadata
- ✅ New terminal session appears on iOS
- ✅ Terminal prompts sync to iOS

**voice-code-98: iOS to iOS Sync**
- ✅ Two clients receive same session list
- ✅ iOS session creation syncs to other client
- ✅ Optimistic UI reconciles without duplicates
- ✅ Updates sync between clients

**voice-code-99: Session Forking**
- ✅ Concurrent resume creates fork
- ✅ Fork names include "(fork)" or "(compacted)"
- ✅ iOS receives session_created for forks
- ✅ Fork metadata inherits from parent

**voice-code-100: Deletion Workflow**
- ✅ Deleted session stops receiving updates on deleting client
- ✅ Other clients continue receiving updates
- ✅ Backend file persists
- ✅ Deleted sessions filtered from UI queries

**voice-code-101: Performance**
- ✅ Session list loads in < 3 seconds
- ✅ Per-session load < 5 seconds
- ✅ CoreData queries < 100ms
- ✅ Memory usage reasonable

**Backend Validation**
- ✅ Index builds in < 60 seconds
- ✅ All metadata fields present
- ✅ Message counts accurate
- ✅ Performance targets met

---

## Next Steps

After running these tests successfully:

1. **Document Results:** Record performance metrics for baseline
2. **Update Beads:** Close tasks voice-code-97 through voice-code-101
3. **Production Deployment:** Tests validate production readiness
4. **Monitoring:** Set up alerts for performance regressions
5. **Continuous Testing:** Integrate into CI/CD (with cost limits)

---

## Notes

- **Real Data Testing:** These tests prove the system works with production-scale data
- **Flaky Tests:** Some tests may be flaky due to network latency or Claude API variability
- **Cost Control:** Run full suite sparingly; use performance tests for frequent validation
- **Manual Inspection:** Always inspect test sessions before cleanup to verify correctness
- **Backend Logs:** Check backend logs for detailed session replication activity

---

## References

- [REPLICATION_ARCHITECTURE.md](backend/REPLICATION_ARCHITECTURE.md) - Architecture specification
- [STANDARDS.md](STANDARDS.md) - WebSocket protocol and naming conventions
- [test_assessment.md](test_assessment.md) - Swift test quality assessment
