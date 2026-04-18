# Recipe Provider Selection Design

## 1. Overview

### Problem Statement

Recipes always run under the Claude provider because the iOS frontend never sends a `provider` field in the `start_recipe` WebSocket message. Users who prefer Copilot (or have it set as their default) cannot use their preferred provider for recipe execution. This breaks the expectation set by the existing provider picker on regular new sessions.

### Goals

1. Allow users to select a provider (Claude or Copilot) when launching a recipe
2. Default the recipe provider picker to the user's configured default provider (from Settings)
3. Ensure the entire recipe — including `restart-new-session` loops in `implement-and-review-all` — runs under the same provider

### Non-Goals

- Per-recipe provider defaults (all recipes share the same picker)
- Changing provider mid-recipe
- Backend changes (the backend already fully supports provider in `start_recipe`)
- Cursor provider support

## 2. Background & Context

### Current State

The multi-provider session creation work (@docs/plans/2025-01-31-multi-provider-session-creation-design.md) is complete:
- `ConversationView` shows a segmented Claude/Copilot picker for new sessions
- `AppSettings.defaultProvider` stores the user's preferred provider
- Backend `start_recipe` handler extracts `provider` from the message and stores it in orchestration state
- `execute-recipe-step` reads provider from orchestration state and passes it to `invoke-provider-async`
- `restart-new-session` (used by `implement-and-review-all`) inherits provider from the old orchestration state

The only gap is the iOS `RecipeMenuView` → `VoiceCodeClient.startRecipe()` path, which never sends `provider`.

### Why Now

This is the next phase of the `extend-providers` feature branch. Backend plumbing is done; the frontend needs to catch up.

### Related Work

- @docs/plans/2025-01-31-multi-provider-session-creation-design.md — Multi-provider session creation (completed)
- @backend/test/voice_code/orchestration_server_test.clj — Backend tests for recipe provider support (already passing)

## 3. Detailed Design

### Data Model

No data model changes. All required fields already exist:
- `AppSettings.defaultProvider: String` — user's default provider preference
- Backend orchestration state `:provider` field — already stored per-recipe-session
- `start_recipe` WebSocket message already supports `provider` field

### API Design

No protocol changes. The `start_recipe` message already accepts an optional `provider` field (backend handler at server.clj:1869-1879 and tested in @backend/test/voice_code/orchestration_server_test.clj):

```json
{
  "type": "start_recipe",
  "session_id": "<uuid>",
  "recipe_id": "<recipe-id>",
  "working_directory": "<path>",
  "provider": "copilot"
}
```

The backend handler (server.clj:1869-1940) already extracts and uses this field. This design only adds the iOS code to send it.

### Code Examples

#### VoiceCodeClient — Add `provider` parameter

Current signature:

```swift
func startRecipe(sessionId: String, recipeId: String, workingDirectory: String)
```

New signature:

```swift
func startRecipe(sessionId: String, recipeId: String, workingDirectory: String, provider: String)
```

Implementation:

```swift
func startRecipe(sessionId: String, recipeId: String, workingDirectory: String, provider: String) {
    print("📤 [VoiceCodeClient] Starting recipe \(recipeId) for session \(sessionId) in \(workingDirectory) with provider \(provider)")
    let message: [String: Any] = [
        "type": "start_recipe",
        "session_id": sessionId,
        "recipe_id": recipeId,
        "working_directory": workingDirectory,
        "provider": provider
    ]
    sendMessage(message)
}
```

#### RecipeMenuView — Add provider picker and settings dependency

Add `settings` parameter and provider picker state:

```swift
struct RecipeMenuView: View {
    @ObservedObject var client: VoiceCodeClient
    let sessionId: String
    let workingDirectory: String
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var isLoading = false
    @State private var hasRequestedRecipes = false
    @State private var errorMessage: String?
    @State private var cancellables = Set<AnyCancellable>()
    @State private var useNewSession = false
    @State private var showingNewSessionConfirmation = false
    @State private var selectedProvider: String = "claude"  // NEW
```

Add segmented picker in the toggle section:

```swift
Section {
    Toggle("Start in new session", isOn: $useNewSession)

    Picker("Provider", selection: $selectedProvider) {
        Text("Claude").tag("claude")
        Text("Copilot").tag("copilot")
    }
    .pickerStyle(.segmented)
} footer: {
    Text("Select the AI provider and whether to use a new session for this recipe.")
}
```

Initialize from settings on appear:

```swift
.onAppear {
    selectedProvider = settings.defaultProvider
    // ... existing onAppear logic
}
```

Pass provider through to `startRecipe`:

```swift
private func selectRecipe(recipeId: String) {
    let targetSessionId: String
    if useNewSession {
        targetSessionId = UUID().uuidString.lowercased()
    } else {
        targetSessionId = sessionId
    }
    client.startRecipe(
        sessionId: targetSessionId,
        recipeId: recipeId,
        workingDirectory: workingDirectory,
        provider: selectedProvider  // NEW
    )
    // ... existing confirmation/timeout logic
}
```

#### ConversationView — Pass settings to RecipeMenuView

Current sheet presentation:

```swift
.sheet(isPresented: $showingRecipeMenu) {
    RecipeMenuView(client: client, sessionId: session.id.uuidString.lowercased(), workingDirectory: session.workingDirectory)
}
```

Updated:

```swift
.sheet(isPresented: $showingRecipeMenu) {
    RecipeMenuView(client: client, sessionId: session.id.uuidString.lowercased(), workingDirectory: session.workingDirectory, settings: settings)
}
```

#### Preview — Update with settings parameter

```swift
struct RecipeMenuView_Previews: PreviewProvider {
    static var previews: some View {
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        client.availableRecipes = [
            Recipe(id: "implement-and-review", label: "Implement & Review", description: "Implement task, review code, and fix issues in a loop")
        ]
        return RecipeMenuView(
            client: client,
            sessionId: "test-session-123",
            workingDirectory: "/Users/test/project",
            settings: AppSettings()
        )
    }
}
```

### Component Interactions

**Recipe launch flow with provider:**

```
User taps recipe button in ConversationView
  → RecipeMenuView presented (receives settings)
  → Provider picker defaults to settings.defaultProvider
  → User optionally changes provider and/or new session toggle
  → User taps recipe row
  → selectRecipe() called
    → VoiceCodeClient.startRecipe(sessionId, recipeId, workingDirectory, provider)
      → WebSocket: {"type": "start_recipe", ..., "provider": "copilot"}
        → Backend: start-recipe-for-session stores provider in orchestration state
        → Backend: execute-recipe-step uses provider for all steps
        → Backend: restart-new-session inherits provider for implement-and-review-all
```

**No changes needed in the backend flow.** The `restart-new-session` path (server.clj:855-909) already reads `(:provider orch-state)` and passes it to `start-recipe-for-session` for the new session.

### Provider Always Sent

Unlike the `prompt` message (where `provider` is only sent for new sessions), the `start_recipe` message always includes `provider`. This is correct because:

1. The backend already handles this — it uses explicit provider > session metadata > default (server.clj:1875-1879)
2. It ensures the user's picker selection is always respected, even for existing sessions
3. It's harmless for existing sessions — the backend simply uses the explicit value

## 4. Verification Strategy

### Testing Approach

**No CLI invocation in tests.** All tests mock provider CLI calls per project convention.

#### Swift Tests

**VoiceCodeClientRecipeTests** — Extend existing test file:

```swift
func testStartRecipeMethodWithProvider() throws {
    XCTAssertNoThrow(
        client.startRecipe(
            sessionId: "test-123",
            recipeId: "implement-and-review",
            workingDirectory: "/Users/test/project",
            provider: "copilot"
        )
    )
}

func testStartRecipeMethodWithClaudeProvider() throws {
    XCTAssertNoThrow(
        client.startRecipe(
            sessionId: "test-456",
            recipeId: "implement-and-review",
            workingDirectory: "/Users/test/project",
            provider: "claude"
        )
    )
}
```

**RecipeNewSessionToggleTests** — Add provider selection tests:

```swift
func testProviderDefaultsFromSettings() throws {
    // Test that the default provider logic matches settings
    let defaultProvider = "copilot"
    let selectedProvider = defaultProvider  // Mimics onAppear initialization
    XCTAssertEqual(selectedProvider, "copilot",
                   "Provider should default from settings")
}

func testProviderSelectionIsIndependentOfNewSessionToggle() throws {
    // Provider and new session toggle are orthogonal controls
    let useNewSession = true
    let selectedProvider = "copilot"
    let targetSessionId = useNewSession ? UUID().uuidString.lowercased() : "existing-session"

    // Both controls are set independently
    XCTAssertTrue(useNewSession)
    XCTAssertEqual(selectedProvider, "copilot")
    XCTAssertNotEqual(targetSessionId, "existing-session")
}
```

#### Backend Tests

The backend tests in @backend/test/voice_code/orchestration_server_test.clj already cover:
- `start-recipe-for-session-provider-support-test` — provider storage and defaults
- `recipe-provider-extraction-from-message-test` — extracting provider from `start_recipe` message
- `recipe-provider-inheritance-on-restart-test` — provider preserved across `restart-new-session`
- `recipe-execution-with-mocked-providers-test` — recipe step invocation with both providers
- `recipe-copilot-session-id-capture-test` — Copilot session ID capture during recipes

No new backend tests needed.

### Acceptance Criteria

1. RecipeMenuView displays a segmented Claude/Copilot provider picker
2. Provider picker defaults to the user's `defaultProvider` setting
3. User can change the provider before launching a recipe
4. `start_recipe` WebSocket message includes the selected `provider` value
5. Provider selection is independent of the "Start in new session" toggle — both controls work orthogonally
6. `implement-and-review-all` recipe (which uses `restart-new-session`) runs entirely under the selected provider across all new sessions it creates
7. All existing recipe tests continue to pass (updated for new `provider` parameter)
8. All existing provider tests continue to pass

## 5. Alternatives Considered

### A. Derive provider from session metadata only (no picker)

If the recipe targets an existing session, use that session's provider. If new session, use `settings.defaultProvider`.

**Rejected because:** Users should have explicit control at recipe launch time. The default provider may not match what they want for a specific recipe run. A picker is consistent with ConversationView's behavior.

### B. Add provider picker to each recipe row

Show a small provider indicator or toggle per recipe row instead of a section-level picker.

**Rejected because:** Provider applies to the entire recipe, not per-recipe. A single picker at the top is simpler and matches the pattern in ConversationView.

### C. Show picker only when "Start in new session" is enabled

Only show the provider picker when the new session toggle is on, since existing sessions have an established provider.

**Rejected because:** Even for existing sessions, the user may want to explicitly choose a provider. The backend handles explicit provider correctly regardless of session state. Hiding the picker adds conditional logic for no benefit. Additionally, recipes always run in a new session from the backend's perspective (they create their own orchestration state).

## 6. Risks & Mitigations

### Risk: Existing tests break due to signature change

`VoiceCodeClient.startRecipe()` gains a new `provider` parameter, breaking all call sites.

**Mitigation:** There are exactly four call sites:
1. `RecipeMenuView.selectRecipe()` — updated in this change
2. `VoiceCodeClientRecipeTests.testStartRecipeMethod()` — updated in this change
3. `RecipeNewSessionToggleTests.testStartRecipeWithWorkingDirectory()` — updated in this change
4. `ConversationRecipeTests.testStartRecipeMethod()` — updated in this change

### Risk: RecipeMenuView constructor call sites break

Adding `settings` parameter to `RecipeMenuView` breaks all constructor call sites.

**Mitigation:** There are exactly three constructor call sites:
1. `ConversationView.swift` `.sheet` — pass existing `settings` property
2. `SessionInfoView.swift` `.sheet` — pass existing `settings` property (already an `@ObservedObject`)
3. `RecipeMenuView_Previews` — create `AppSettings()` with defaults

### Rollback Strategy

Revert the iOS changes. Backend is unaffected (it already handles missing `provider` by defaulting to Claude). The change is purely additive on the iOS side.

## Files to Modify

| File | Changes |
|------|---------|
| `ios/VoiceCode/Managers/VoiceCodeClient.swift` | Add `provider` parameter to `startRecipe()` |
| `ios/VoiceCode/Views/RecipeMenuView.swift` | Add `settings` parameter, provider picker, pass to `startRecipe` |
| `ios/VoiceCode/Views/ConversationView.swift` | Pass `settings` to `RecipeMenuView` in `.sheet` |
| `ios/VoiceCode/Views/SessionInfoView.swift` | Pass `settings` to `RecipeMenuView` in `.sheet` |
| `ios/VoiceCodeTests/VoiceCodeClientRecipeTests.swift` | Update `testStartRecipeMethod`, add provider test |
| `ios/VoiceCodeTests/RecipeNewSessionToggleTests.swift` | Update `testStartRecipeWithWorkingDirectory`, add provider tests |
| `ios/VoiceCodeTests/ConversationRecipeTests.swift` | Update `testStartRecipeMethod` with `provider` parameter |
