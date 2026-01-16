package dev.labs910.voicecode.domain

import dev.labs910.voicecode.domain.model.*
import org.junit.Assert.*
import org.junit.Test

/**
 * Tests for Recipe domain model.
 */
class RecipeTest {

    @Test
    fun `Recipe holds id, label, and description`() {
        val recipe = Recipe(
            id = "code-review",
            label = "Code Review",
            description = "Performs an automated code review of staged changes"
        )

        assertEquals("code-review", recipe.id)
        assertEquals("Code Review", recipe.label)
        assertEquals("Performs an automated code review of staged changes", recipe.description)
    }

    @Test
    fun `Recipe data class supports equality`() {
        val recipe1 = Recipe("test", "Test Recipe", "Test description")
        val recipe2 = Recipe("test", "Test Recipe", "Test description")
        val recipe3 = Recipe("other", "Other Recipe", "Other description")

        assertEquals(recipe1, recipe2)
        assertNotEquals(recipe1, recipe3)
    }

    // ==========================================================================
    // MARK: - ActiveRecipe Tests
    // ==========================================================================

    @Test
    fun `ActiveRecipe holds execution state`() {
        val active = ActiveRecipe(
            recipeId = "code-review",
            recipeLabel = "Code Review",
            currentStep = "Step 2: Analyzing code",
            stepCount = 5
        )

        assertEquals("code-review", active.recipeId)
        assertEquals("Code Review", active.recipeLabel)
        assertEquals("Step 2: Analyzing code", active.currentStep)
        assertEquals(5, active.stepCount)
    }

    @Test
    fun `ActiveRecipe progress calculates fraction from step number`() {
        val active = ActiveRecipe(
            recipeId = "test",
            recipeLabel = "Test",
            currentStep = "Step 2: Processing",
            stepCount = 4
        )

        // Step 2 of 4 = 0.5
        assertEquals(0.5f, active.progress, 0.01f)
    }

    @Test
    fun `ActiveRecipe progress is zero when stepCount is zero`() {
        val active = ActiveRecipe(
            recipeId = "test",
            recipeLabel = "Test",
            currentStep = "Starting...",
            stepCount = 0
        )

        assertEquals(0f, active.progress, 0.01f)
    }

    @Test
    fun `ActiveRecipe progress is zero when step number cannot be parsed`() {
        val active = ActiveRecipe(
            recipeId = "test",
            recipeLabel = "Test",
            currentStep = "Initializing recipe...",
            stepCount = 5
        )

        // No "Step N" prefix found
        assertEquals(0f, active.progress, 0.01f)
    }

    @Test
    fun `ActiveRecipe progressText combines label and step`() {
        val active = ActiveRecipe(
            recipeId = "code-review",
            recipeLabel = "Code Review",
            currentStep = "Step 3: Generating report",
            stepCount = 5
        )

        assertEquals("Code Review: Step 3: Generating report", active.progressText)
    }

    @Test
    fun `ActiveRecipe progress at completion`() {
        val active = ActiveRecipe(
            recipeId = "test",
            recipeLabel = "Test",
            currentStep = "Step 5: Done",
            stepCount = 5
        )

        // Step 5 of 5 = 1.0
        assertEquals(1.0f, active.progress, 0.01f)
    }

    @Test
    fun `ActiveRecipe progress at first step`() {
        val active = ActiveRecipe(
            recipeId = "test",
            recipeLabel = "Test",
            currentStep = "Step 1: Starting",
            stepCount = 10
        )

        // Step 1 of 10 = 0.1
        assertEquals(0.1f, active.progress, 0.01f)
    }
}
