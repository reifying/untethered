// Recipe.swift
// Recipe models for orchestration feature

import Foundation

/// Recipe definition from backend
struct Recipe: Identifiable, Codable, Equatable {
    let id: String
    let label: String
    let description: String

    private enum CodingKeys: String, CodingKey {
        case id, label, description
    }
}

/// Response wrapper for available recipes from backend
struct AvailableRecipes: Codable {
    let recipes: [Recipe]
}

/// Active recipe state for a session (in-memory, not persisted)
struct ActiveRecipe: Equatable {
    let recipeId: String
    let recipeLabel: String
    let currentStep: String
    let iterationCount: Int

    init(recipeId: String, recipeLabel: String, currentStep: String, iterationCount: Int) {
        self.recipeId = recipeId
        self.recipeLabel = recipeLabel
        self.currentStep = currentStep
        self.iterationCount = iterationCount
    }
}
