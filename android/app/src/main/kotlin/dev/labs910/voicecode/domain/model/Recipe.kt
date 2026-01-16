package dev.labs910.voicecode.domain.model

/**
 * Domain model for a recipe (orchestration) definition from the backend.
 * Corresponds to iOS Recipe.swift model.
 *
 * Recipes are pre-defined workflows that can be executed via the backend,
 * like automated code review, test generation, etc.
 */
data class Recipe(
    /** Unique identifier for this recipe */
    val id: String,

    /** Human-readable label for display */
    val label: String,

    /** Description of what this recipe does */
    val description: String
)

/**
 * Active recipe state for a session (in-memory, not persisted).
 * Tracks the current execution state of a recipe.
 */
data class ActiveRecipe(
    /** Recipe ID being executed */
    val recipeId: String,

    /** Human-readable recipe label */
    val recipeLabel: String,

    /** Current step being executed */
    val currentStep: String,

    /** Total number of steps in the recipe */
    val stepCount: Int
) {
    /**
     * Progress as a fraction (0.0 to 1.0).
     * Returns 0.0 if stepCount is 0 to avoid division by zero.
     */
    val progress: Float
        get() = if (stepCount > 0) {
            // Extract step number from currentStep if it follows "Step N: ..." format
            val stepMatch = Regex("^Step (\\d+)").find(currentStep)
            val currentStepNum = stepMatch?.groupValues?.get(1)?.toIntOrNull() ?: 0
            currentStepNum.toFloat() / stepCount
        } else {
            0f
        }

    /**
     * Display text showing progress.
     */
    val progressText: String
        get() = "$recipeLabel: $currentStep"
}
