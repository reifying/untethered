// RecipeMenuView.swift
// Recipe selection menu for orchestration

import SwiftUI

struct RecipeMenuView: View {
    @ObservedObject var client: VoiceCodeClient
    let sessionId: String
    @Environment(\.dismiss) private var dismiss

    @State private var isLoading = false

    var body: some View {
        let _ = RenderTracker.count(Self.self)
        NavigationView {
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
        .onAppear {
            if client.availableRecipes.isEmpty {
                isLoading = true
                client.getAvailableRecipes()

                // Timeout if recipes don't arrive
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    isLoading = false
                }
            }
        }
    }

    private func selectRecipe(recipeId: String) {
        print("📤 [RecipeMenuView] Selected recipe: \(recipeId) for session \(sessionId)")
        client.startRecipe(sessionId: sessionId, recipeId: recipeId)
        dismiss()
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
            sessionId: "test-session-123"
        )
    }
}
