// RecipeMenuView.swift
// Recipe selection menu for orchestration

import SwiftUI
import Combine

struct RecipeMenuView: View {
    @ObservedObject var client: VoiceCodeClient
    let sessionId: String
    let workingDirectory: String
    @Environment(\.dismiss) private var dismiss

    @State private var isLoading = false
    @State private var hasRequestedRecipes = false
    @State private var errorMessage: String?
    @State private var cancellables = Set<AnyCancellable>()
    @State private var useNewSession = false
    @State private var showingNewSessionConfirmation = false

    var body: some View {
        let _ = RenderTracker.count(Self.self)
        NavigationController(minWidth: 450, minHeight: 400) {
            recipeMenuContent
        }
        #if os(macOS)
        .swipeToBack()
        #endif
    }

    private var recipeMenuContent: some View {
        ZStack {
            Group {
                if isLoading {
                    // Loading state
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Loading recipes...")
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = errorMessage {
                    // Error state
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 64))
                            .foregroundColor(.red)
                        Text("Recipe Error")
                            .font(.title2)
                            .foregroundColor(.primary)
                        Text(error)
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button(action: { errorMessage = nil }) {
                            Text("Dismiss")
                                .font(.body)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(6)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if client.availableRecipes.isEmpty {
                    // Empty state
                    VStack(spacing: 16) {
                        Image(systemName: "list.bullet.clipboard")
                            .font(.system(size: 64))
                            .foregroundColor(.secondary)
                        Text("No recipes available")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        Text("Recipes will appear when your backend is configured.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Recipe list
                    List {
                        // Toggle section at top
                        Section {
                            Toggle("Start in new session", isOn: $useNewSession)
                        } footer: {
                            Text("Creates a fresh session for this recipe instead of using the current session.")
                        }

                        // Recipe list section
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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarBuilder.cancelButton { dismiss() }
        }
        .onAppear {
            if client.availableRecipes.isEmpty && !hasRequestedRecipes {
                hasRequestedRecipes = true
                isLoading = true
                client.getAvailableRecipes()

                // Timeout if recipes don't arrive (10 second timeout)
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    // Capture self normally - SwiftUI manages the lifecycle
                    self.handleRecipeLoadTimeout()
                }
            }
        }
        .onReceive(client.$availableRecipes) { recipes in
            // Stop loading when recipes arrive
            if !recipes.isEmpty && isLoading {
                isLoading = false
            }
        }
        .alert("Recipe Started", isPresented: $showingNewSessionConfirmation) {
            Button("OK") {
                dismiss()
            }
        } message: {
            Text("Recipe is running in a new session. Go to Sessions to view it.")
        }
    }

    private func handleRecipeLoadTimeout() {
        if isLoading {
            isLoading = false
            hasRequestedRecipes = false  // Reset so user can retry
            errorMessage = "Failed to load recipes. Please try again."
        }
    }

    private func selectRecipe(recipeId: String) {
        // Determine which session ID to use
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
        // Capture bindings for use in closure
        let dismissAction = self.dismiss
        let isLoadingBinding = $isLoading
        let errorMessageBinding = $errorMessage
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
                        // Show confirmation instead of auto-dismiss
                        self.showingNewSessionConfirmation = true
                    } else {
                        dismissAction()
                    }
                }
            )
            .store(in: &cancellables)
    }
}

// MARK: - Recipe Row View

struct RecipeRowView: View {
    let recipe: Recipe
    let onSelect: (String) -> Void

    var body: some View {
        Button(action: {
            onSelect(recipe.id)
        }) {
            VStack(alignment: .leading, spacing: 4) {
                Text(recipe.label)
                    .font(.body)
                    .foregroundColor(.primary)
                Text(recipe.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

struct RecipeMenuView_Previews: PreviewProvider {
    static var previews: some View {
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)

        // Mock available recipes
        let mockRecipes = [
            Recipe(id: "implement-and-review", label: "Implement & Review", description: "Implement task, review code, and fix issues in a loop")
        ]
        client.availableRecipes = mockRecipes

        return RecipeMenuView(
            client: client,
            sessionId: "test-session-123",
            workingDirectory: "/Users/test/project"
        )
    }
}
