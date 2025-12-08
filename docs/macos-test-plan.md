# macOS Test Plan - Test Pyramid

This document outlines the automated testing strategy for the macOS Untethered app, following the traditional test pyramid approach.

## Test Pyramid Structure

```
        /\
       /UI\ ← Few tests (E2E critical user flows)
      /────\
     /Integ\ ← More tests (component interaction)
    /──────\
   /  Unit  \ ← Most tests (individual functions/classes)
  /──────────\
```

## Layer 1: Unit Tests (Foundation) - P0

**Target: 50-70% of total tests | Est: ~80 test methods**

Unit tests verify individual components in isolation. These should be fast (<100ms each) and require no external dependencies.

### 1. AppSettings Tests (`voice-code-desktop-ptv`)
**File:** `macos/Tests/Settings/AppSettingsTests.swift`
**Pattern:** Follow `ios/VoiceCodeTests/AppSettingsTests.swift`

Test coverage:
- ✅ Default values initialization
- ✅ UserDefaults persistence with 0.5s debouncing
- ✅ Voice settings: `selectedVoiceIdentifier`, `autoPlayResponses`, speech rate
- ✅ System prompt persistence
- ✅ Server URL/port validation
- ✅ `fullServerURL` computed property
- ✅ Shared UserDefaults syncing

**Est:** ~15 test methods

### 2. MenuBarCommands Tests (`voice-code-desktop-5au`)
**File:** `macos/Tests/Commands/MenuBarCommandsTests.swift`

Test coverage:
- ✅ ConversationActions protocol conformance
- ✅ FocusedValue key registration
- ✅ Command enabled/disabled states
- ✅ Keyboard shortcut definitions
- ✅ Menu item labels

**Est:** ~8 test methods

### 3. CommandMenu Filtering Tests (`voice-code-desktop-rbu`)
**File:** `macos/Tests/Views/CommandMenuSheetTests.swift`
**Pattern:** Follow `ios/VoiceCodeTests/CommandMenuTests.swift`

Test coverage:
- ✅ Search/filter by command label
- ✅ Search/filter by command description
- ✅ Hierarchical filtering (groups with matching children)
- ✅ Empty search results
- ✅ Case-insensitive matching
- ✅ Command execution flow

**Est:** ~12 test methods

### 4. Voice Integration Tests (`voice-code-desktop-adz`)
**File:** `macos/Tests/Voice/VoiceIntegrationTests.swift`
**Pattern:** Follow `ios/VoiceCodeTests/VoiceOutputManagerTests.swift`

Test coverage:
- ✅ VoiceInputManager state management
- ✅ VoiceOutputManager playback lifecycle
- ✅ Permission authorization states
- ✅ Auto-play logic (settings.autoPlayResponses)
- ✅ Stop speaking notification handling
- ✅ Transcribed text → input field flow

**Est:** ~15 test methods

### 5. Session CoreData Tests (`voice-code-desktop-ul6`)
**File:** `macos/Tests/Models/SessionManagementTests.swift`

Test coverage:
- ✅ CDBackendSession CRUD operations
- ✅ Session display name generation
- ✅ Working directory persistence
- ✅ Session ID lowercase enforcement
- ✅ Relationship with CDMessage
- ✅ Fetch request predicates

**Est:** ~12 test methods

### 6. Message CoreData Tests (`voice-code-desktop-py3`)
**File:** `macos/Tests/Models/MessageManagementTests.swift`

Test coverage:
- ✅ CDMessage creation with status
- ✅ Message status transitions (sending → confirmed)
- ✅ Message ordering by timestamp
- ✅ Message deletion cascade
- ✅ Role validation (user/assistant)
- ✅ displayText computed property

**Est:** ~10 test methods

---

## Layer 2: Integration Tests (Glue Code) - P1

**Target: 25-35% of total tests | Est: ~35 test methods**

Integration tests verify that components work together correctly. These may require mocks or test fixtures.

### 7. Settings Window Integration (`voice-code-desktop-8l6`)
**File:** `macos/Tests/Integration/SettingsWindowTests.swift`

Test coverage:
- ✅ Tab navigation between General/Voice/Advanced
- ✅ Settings persistence across tabs
- ✅ Voice test button triggers TTS
- ✅ Directory picker updates UserDefaults
- ✅ Clear cache deletes CoreData messages
- ✅ Settings window opens with Cmd+,

**Est:** ~10 test methods

### 8. Command Execution Flow (`voice-code-desktop-qqc`)
**File:** `macos/Tests/Integration/CommandExecutionTests.swift`

Test coverage:
- ✅ Command menu sheet presentation
- ✅ Command selection triggers WebSocket message
- ✅ Command output received and stored
- ✅ Command completion updates status
- ✅ Sheet dismisses after execution
- ✅ Error handling for failed commands

**Est:** ~12 test methods

### 9. Session Sync Integration (`voice-code-desktop-8xg`)
**File:** `macos/Tests/Integration/SessionSyncTests.swift`

Test coverage:
- ✅ SessionSyncManager creates/updates sessions
- ✅ Recent sessions WebSocket message handling
- ✅ Session UUID lowercase normalization
- ✅ Backend session → iOS session mapping
- ✅ Message saves to correct session
- ✅ Session list updates trigger UI refresh

**Est:** ~13 test methods

---

## Layer 3: UI Tests (Critical Flows) - P1

**Target: 10-15% of total tests | Est: ~15 test methods**

UI tests verify end-to-end user workflows. These are slowest and most brittle, so we test only critical flows.

### 10. Keyboard Shortcuts E2E (`voice-code-desktop-qpr`)
**File:** `macos/UITests/KeyboardShortcutsTests.swift`

Test coverage:
- ✅ Cmd+, opens settings window
- ✅ Cmd+K opens command menu sheet
- ✅ Cmd+Enter sends prompt
- ✅ Cmd+Shift+C copies session ID to pasteboard
- ✅ Cmd+Shift+S stops speaking
- ✅ Escape cancels input/recording

**Est:** ~6 test methods

### 11. Voice Workflow E2E (`voice-code-desktop-dks`)
**File:** `macos/UITests/VoiceWorkflowTests.swift`

Test coverage:
- ✅ Microphone button requests permission
- ✅ Start recording → mic button turns red
- ✅ Stop recording → text appears in input field
- ✅ Send prompt → auto-play speaks response
- ✅ Stop speaking button visible during playback
- ✅ Play button on assistant messages

**Est:** ~5 test methods

### 12. Session Navigation E2E (`voice-code-desktop-tnu`)
**File:** `macos/UITests/SessionNavigationTests.swift`

Test coverage:
- ✅ Select session from sidebar → messages load
- ✅ Create new session → empty conversation
- ✅ Switch between sessions → state preserved
- ✅ Locked session shows "Processing..."

**Est:** ~4 test methods

---

## Infrastructure Tasks

### 13. Add macOS Test Makefile Targets (`voice-code-desktop-h2b`)

Add to `Makefile`:
```makefile
# macOS Testing
macos-test:
	cd macos && xcodebuild test \
		-scheme UntetheredMac \
		-destination 'platform=macOS'

macos-test-unit:
	cd macos && xcodebuild test \
		-scheme UntetheredMac \
		-only-testing:UntetheredMacTests

macos-test-ui:
	cd macos && xcodebuild test \
		-scheme UntetheredMac \
		-only-testing:UntetheredMacUITests

macos-test-coverage:
	cd macos && xcodebuild test \
		-scheme UntetheredMac \
		-destination 'platform=macOS' \
		-enableCodeCoverage YES \
		-resultBundlePath TestResults
```

### 14. Setup Test Coverage Reporting (`voice-code-desktop-a5h`)

**Tools:**
- Xcode's built-in code coverage (`.xcresult` bundles)
- `xcov` gem for reports: `gem install xcov`

**Target:** 70% code coverage minimum

**Exclude from coverage:**
- UI/SwiftUI views (test via UI tests)
- AppDelegate/SceneDelegate boilerplate
- Generated CoreData classes

---

## Test Execution Strategy

### Development Workflow
```bash
# Fast feedback loop (unit tests only)
make macos-test-unit     # ~10 seconds

# Full test suite
make macos-test          # ~60 seconds

# Before PR/commit
make macos-test-coverage # ~75 seconds, generates report
```

### CI/CD Pipeline
1. Run unit tests on every commit
2. Run integration tests on PR
3. Run UI tests nightly or pre-release
4. Fail build if coverage drops below 70%

---

## Test Naming Conventions

Follow iOS test patterns:

```swift
// Unit tests: test + WhatIsBeingTested
func testDefaultServerURL()
func testAutoPlayResponsesPersistence()

// Integration tests: test + Feature + Scenario
func testSettingsWindow_TabNavigation_UpdatesView()
func testCommandExecution_ValidCommand_SendsWebSocketMessage()

// UI tests: test + UserAction + ExpectedOutcome
func testKeyboardShortcut_CmdComma_OpensSettings()
func testVoiceButton_Tap_StartsRecording()
```

---

## Test Data & Fixtures

### Mock Data Location
- `macos/Tests/Fixtures/` - JSON files, test sessions
- `macos/Tests/Mocks/` - Mock WebSocket client, mock VoiceCodeClient

### CoreData Test Stack
```swift
class PersistenceControllerPreview {
    static let shared: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        // Preload test data
        return controller
    }()
}
```

---

## Success Criteria

✅ **Before merging Phase 6:**
- All P0 unit tests (6 suites) written and passing
- macOS test Makefile targets working
- Code coverage ≥ 60%

✅ **Before production release:**
- All P1 integration tests (3 suites) written and passing
- All P1 UI tests (3 suites) written and passing
- Code coverage ≥ 70%
- All tests run in <90 seconds total

---

## Notes

- **Don't over-test SwiftUI views:** Views are declarative - test via UI tests, not unit tests
- **Test business logic, not framework code:** Don't test that CoreData saves - test that your logic calls save correctly
- **Mock external dependencies:** WebSocket, file system, user defaults
- **Use XCTestExpectation for async:** VoiceCodeClient operations, debounced saves
- **Leverage iOS tests:** Many UntetheredCore tests already exist in `ios/VoiceCodeTests/`

---

## Related Documentation

- iOS Test Suite: `ios/VoiceCodeTests/` (19 test files, ~150 tests)
- Backend Tests: `backend/test/` (Clojure tests)
- WebSocket Protocol: `STANDARDS.md` (WebSocket Protocol section)
