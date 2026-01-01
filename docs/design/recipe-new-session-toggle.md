# Recipe New Session Toggle

## Overview

### Problem Statement
When a user starts a recipe from an existing session, the recipe executes within that session's conversation context. This means the recipe inherits all prior conversation history, which may be undesirable when:
- The session has accumulated significant context that's irrelevant to the new task
- The user wants a clean slate for the recipe execution
- The recipe's task is unrelated to previous work in the session

Currently, users must manually create a new session first, navigate to it, and then start the recipe—a cumbersome workflow.

### Goals
1. Allow users to start a recipe in a fresh session with a single toggle
2. Keep the implementation simple by leveraging existing backend new-session support
3. Provide clear feedback when a recipe starts in a new session
4. Minimize changes to existing components

### Non-goals
- Auto-navigating to the new session after recipe start
- Custom naming of recipe-spawned sessions
- Per-recipe toggle state (e.g., remembering preferences per recipe)
- Persisting the toggle state across app sessions

## Background & Context

### Current State

The recipe selection flow:

1. User opens `RecipeMenuView` from `ConversationView` toolbar or `SessionInfoView`
2. `RecipeMenuView` receives:
   - `sessionId`: Current session's Claude session ID (lowercase UUID)
   - `workingDirectory`: Current session's working directory
   - `client`: `VoiceCodeClient` instance
3. User selects a recipe
4. `selectRecipe()` calls `client.startRecipe(sessionId:recipeId:workingDirectory:)`
5. Recipe executes in the current session

The backend already supports starting recipes on new sessions (see @recipe-new-session-support.md):
- Detects new sessions via `session-exists?` check
- Uses `--session-id` flag for first Claude invocation (creates session)
- Transitions to `--resume` for subsequent invocations
- Requires `working_directory` for new sessions

### Why Now
Users have reported wanting to start recipes without polluting existing sessions. The backend support is already in place; this feature exposes that capability in the iOS UI.

### Related Work
- @recipe-new-session-support.md - Backend support for new session recipes
- @STANDARDS.md - WebSocket protocol and session ID conventions
- @ios/VoiceCode/Views/RecipeMenuView.swift - Current recipe selection UI

## Detailed Design

### Data Model

#### iOS State Changes

Add local state to `RecipeMenuView`:

```swift
@State private var useNewSession = false
```

No persistence required—defaults to `false` on each sheet presentation.

#### Session Creation Flow

When `useNewSession` is `true`:
1. Generate new UUID: `UUID().uuidString.lowercased()`
2. Send `start_recipe` with new UUID as `session_id`
3. Backend creates session on first Claude invocation
4. `SessionSyncManager` receives session via existing replication

No iOS-side `CDBackendSession` creation needed—backend creates the session and it replicates automatically.

### API Design

#### WebSocket Protocol

No changes to the protocol. The existing `start_recipe` message already supports new sessions:

```json
{
  "type": "start_recipe",
  "session_id": "<new-uuid>",
  "recipe_id": "implement-and-review",
  "working_directory": "/path/to/project"
}
```

The backend detects this is a new session (no existing `.jsonl` file) and handles it appropriately.

### Code Examples

#### RecipeMenuView.swift Changes

The following shows the complete modified file with changes marked. Key modifications:
1. Add two new `@State` properties
2. Add toggle section to the List
3. Modify `selectRecipe()` to handle new session flow
4. Add confirmation alert

```swift
struct RecipeMenuView: View {
    @ObservedObject var client: VoiceCodeClient
    let sessionId: String
    let workingDirectory: String
    @Environment(\.dismiss) private var dismiss

    @State private var isLoading = false
    @State private var hasRequestedRecipes = false
    @State private var errorMessage: String?
    @State private var cancellables = Set<AnyCancellable>()
    @State private var useNewSession = false  // NEW
    @State private var showingNewSessionConfirmation = false  // NEW

    var body: some View {
        let _ = RenderTracker.count(Self.self)
        NavigationView {
            ZStack {
                Group {
                    if isLoading {
                        // ... existing loading state ...
                    } else if let error = errorMessage {
                        // ... existing error state ...
                    } else if client.availableRecipes.isEmpty {
                        // ... existing empty state ...
                    } else {
                        // Recipe list - MODIFIED to add toggle section
                        List {
                            // NEW: Toggle section at top
                            Section {
                                Toggle("Start in new session", isOn: $useNewSession)
                            } footer: {
                                Text("Creates a fresh session for this recipe instead of using the current session.")
                            }

                            // Existing recipe list wrapped in section
                            Section("Recipes") {
                                ForEach(client.availableRecipes) { recipe in
                                    RecipeRowView(
                                        recipe: recipe,
                                        onSelect: { recipeId in
                                            selectRecipe(recipeId: recipeId)
                                        }
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        // NEW: Confirmation alert for new session
        .alert("Recipe Started", isPresented: $showingNewSessionConfirmation) {
            Button("OK") {
                dismiss()
            }
        } message: {
            Text("Recipe is running in a new session. Go to Sessions to view it.")
        }
        .onAppear {
            // ... existing onAppear logic ...
        }
        .onReceive(client.$availableRecipes) { recipes in
            // ... existing onReceive logic ...
        }
    }

    private func selectRecipe(recipeId: String) {
        // NEW: Determine which session ID to use
        let targetSessionId: String
        if useNewSession {
            targetSessionId = UUID().uuidString.lowercased()
            print("📤 [RecipeMenuView] Starting recipe in NEW session: \(targetSessionId)")
        } else {
            targetSessionId = sessionId
        }

        print("📤 [RecipeMenuView] Selected recipe: \(recipeId) for session \(targetSessionId) in \(workingDirectory)")
        isLoading = true
        errorMessage = nil

        client.startRecipe(sessionId: targetSessionId, recipeId: recipeId, workingDirectory: workingDirectory)

        // Wait for recipe_started confirmation (15 second timeout)
        // Capture bindings for use in closure (existing pattern in codebase)
        let dismissAction = self.dismiss
        var isLoadingBinding = $isLoading
        var errorMessageBinding = $errorMessage
        let shouldShowConfirmation = useNewSession  // Capture current value

        client.$activeRecipes
            .first { $0[targetSessionId] != nil }
            .timeout(.seconds(15), scheduler: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    if case .failure = completion {
                        isLoadingBinding.wrappedValue = false
                        errorMessageBinding.wrappedValue = "Recipe start timeout. Please check your connection and try again."
                    }
                },
                receiveValue: { [self] _ in
                    isLoadingBinding.wrappedValue = false
                    if shouldShowConfirmation {
                        // NEW: Show confirmation instead of auto-dismiss
                        self.showingNewSessionConfirmation = true
                    } else {
                        dismissAction()
                    }
                }
            )
            .store(in: &cancellables)
    }
}
```

#### VoiceCodeClient.swift

No changes needed. The existing `startRecipe` method accepts any session ID:

```swift
func startRecipe(sessionId: String, recipeId: String, workingDirectory: String) {
    print("📤 [VoiceCodeClient] Starting recipe \(recipeId) for session \(sessionId) in \(workingDirectory)")
    let message: [String: Any] = [
        "type": "start_recipe",
        "session_id": sessionId,
        "recipe_id": recipeId,
        "working_directory": workingDirectory
    ]
    sendMessage(message)
}
```

### Component Interactions

#### Sequence Diagram: Recipe Start in New Session

```
User                RecipeMenuView              VoiceCodeClient              Backend
  |                      |                            |                         |
  |--Enable toggle------>|                            |                         |
  |  useNewSession=true  |                            |                         |
  |                      |                            |                         |
  |--Select recipe------>|                            |                         |
  |                      |                            |                         |
  |                      |--Generate new UUID         |                         |
  |                      |  "abc123..."               |                         |
  |                      |                            |                         |
  |                      |--startRecipe-------------->|                         |
  |                      |  sessionId: "abc123..."    |                         |
  |                      |  recipeId: "impl..."       |                         |
  |                      |  workingDir: "/proj"       |                         |
  |                      |                            |                         |
  |                      |                            |--start_recipe---------->|
  |                      |                            |                         |
  |                      |                            |<--recipe_started--------|
  |                      |                            |                         |
  |                      |<--activeRecipes updated----|                         |
  |                      |                            |                         |
  |<--Show confirmation--|                            |                         |
  |  "Recipe Started"    |                            |                         |
  |  in new session      |                            |                         |
  |                      |                            |                         |
  |--Tap OK------------->|                            |                         |
  |                      |--dismiss()                 |                         |
  |                      |                            |                         |
  |                      |                            |  (session replicates    |
  |                      |                            |   via SessionSyncManager)|
```

#### Session Replication Flow

After the recipe starts:
1. Backend invokes Claude CLI with `--session-id <new-uuid>`
2. Claude creates `~/.claude/projects/<project>/<new-uuid>.jsonl`
3. Backend's file watcher detects new file
4. Backend broadcasts `session_created` to connected clients
5. `SessionSyncManager` receives and creates `CDBackendSession`
6. Session appears in iOS Sessions view

This is the existing replication mechanism—no changes needed.

## Verification Strategy

### Testing Approach

#### Unit Tests

Due to SwiftUI's `@State` being private, direct unit testing of toggle behavior is limited. The key testable logic is in the `selectRecipe` function's session ID selection.

#### Integration Tests (Manual Test Script)

**Prerequisites:**
- iOS app connected to backend
- At least one recipe available (e.g., "implement-and-review")
- Existing session with a working directory set

**Test 1: New Session Recipe Start**
1. Open an existing session in ConversationView
2. Tap the recipe button in the toolbar
3. Verify the "Start in new session" toggle appears at the top of the list
4. Verify the toggle is OFF by default
5. Enable the toggle (switch to ON)
6. Select any recipe (e.g., "Implement & Review")
7. Wait for recipe to start (loading indicator)
8. Verify an alert appears with title "Recipe Started"
9. Verify alert message says "Recipe is running in a new session. Go to Sessions to view it."
10. Tap "OK" to dismiss
11. Navigate back to Sessions list
12. Verify a new session appears with the same working directory
13. Open the new session and verify the recipe is active (green recipe icon)

**Test 2: Existing Session Recipe Start (Toggle Off)**
1. Open an existing session in ConversationView
2. Tap the recipe button in the toolbar
3. Verify the toggle is OFF (default state)
4. Do NOT enable the toggle
5. Select any recipe
6. Verify the sheet dismisses automatically (no confirmation alert)
7. Verify the recipe is running in the CURRENT session (not a new one)
8. Verify no new session was created in Sessions list

**Test 3: Working Directory Inheritance**
1. Create or open a session with working directory `/path/to/project`
2. Start a recipe with "Start in new session" enabled
3. After recipe starts, navigate to the new session
4. Verify the new session's working directory is `/path/to/project` (same as parent)

**Test 4: Toggle State Reset**
1. Open recipe menu, enable the toggle
2. Cancel (dismiss without selecting)
3. Re-open recipe menu
4. Verify the toggle is OFF (state should not persist)

### Acceptance Criteria

1. Toggle labeled "Start in new session" appears in RecipeMenuView above the recipe list
2. Toggle defaults to OFF (disabled) each time the sheet opens
3. When toggle is ON and recipe selected:
   - New lowercase UUID is generated
   - `start_recipe` WebSocket message contains the new UUID as `session_id`
   - Confirmation alert appears with title "Recipe Started"
   - Alert message indicates recipe is in a new session
   - User must tap OK to dismiss the sheet
4. When toggle is OFF and recipe selected:
   - Current session ID is used in `start_recipe` message
   - Sheet dismisses automatically after `recipe_started` confirmation (existing behavior)
5. New session appears in Sessions list within a few seconds via existing replication
6. New session has the same working directory as the session where the recipe was initiated
7. Toggle state does not persist between sheet presentations

## Alternatives Considered

### Alternative 1: Auto-navigate to New Session

**Approach**: After recipe starts in new session, automatically navigate to that session.

**Pros**:
- User immediately sees the new session and recipe progress

**Cons**:
- Requires passing navigation state through RecipeMenuView
- More complex state management
- User might want to stay on current session

**Decision**: Rejected for V1. User can manually navigate to the new session. Can revisit based on feedback.

### Alternative 2: Create CDBackendSession in iOS Before Starting Recipe

**Approach**: Create the session locally in CoreData before sending `start_recipe`.

**Pros**:
- Session immediately visible in UI
- Could enable auto-navigation

**Cons**:
- Duplicates session creation logic
- Requires passing `viewContext` to RecipeMenuView
- Session might differ from what backend creates

**Decision**: Rejected. Backend creates the session, replication handles sync. Simpler and consistent.

### Alternative 3: Per-Recipe Toggle Memory

**Approach**: Remember toggle state per recipe (e.g., always use new session for "implement-and-review").

**Pros**:
- Personalized experience per recipe type

**Cons**:
- Adds complexity (persistence, settings UI)
- Unclear if users want this granularity

**Decision**: Rejected for V1. Start simple with session-scoped toggle. Can add if users request.

### Alternative 4: Add to Recipe Row Instead of Section

**Approach**: Put the toggle inline with each recipe row.

**Pros**:
- Per-recipe decision visible

**Cons**:
- Cluttered UI with many recipes
- Toggle applies to all anyway in current design

**Decision**: Rejected. Single toggle in a section header is cleaner.

## Risks & Mitigations

### Risk 1: Session ID Collision

**Risk**: Generated UUID collides with existing session.

**Mitigation**: UUID collision probability is astronomically low (1 in 2^122). Not a practical concern.

### Risk 2: User Confusion About New Session Location

**Risk**: User enables toggle, recipe starts, but they can't find the new session.

**Mitigation**: Confirmation alert explicitly tells user to check Sessions list. Session has auto-generated name from backend based on working directory.

### Risk 3: Orphaned Sessions

**Risk**: User starts many recipes in new sessions, cluttering session list.

**Mitigation**: Existing session management (delete, hide) applies. Could consider auto-cleanup of empty/inactive sessions in future.

### Risk 4: Toggle State Not Persisted

**Risk**: User expects toggle to remain on but it resets each time sheet opens.

**Mitigation**: Document behavior. Default OFF is conservative—avoids accidental new session creation. Can add persistence later if requested.

## Quality Checklist
- [x] All code examples are syntactically correct
- [x] Examples match the codebase's style and conventions (binding wrapper pattern, RenderTracker, ZStack/Group structure)
- [x] Verification steps are specific and actionable (numbered manual test scripts)
- [x] Cross-references to related files use @filename.md format
- [x] No placeholder text remains
