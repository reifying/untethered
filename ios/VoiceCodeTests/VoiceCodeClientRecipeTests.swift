// VoiceCodeClientRecipeTests.swift
// Tests for recipe orchestration message handling in VoiceCodeClient

import XCTest
@testable import VoiceCode

class VoiceCodeClientRecipeTests: XCTestCase {
    var client: VoiceCodeClient!

    override func setUp() {
        super.setUp()
        client = VoiceCodeClient(
            serverURL: "ws://localhost:3000",
            setupObservers: false
        )
    }

    override func tearDown() {
        client.disconnect()
        client = nil
        super.tearDown()
    }

    // MARK: - Available Recipes Tests

    func testHandleAvailableRecipesMessage() throws {
        let expectation = XCTestExpectation(description: "Available recipes received")

        let cancellable = client.$availableRecipes
            .dropFirst()
            .sink { recipes in
                XCTAssertEqual(recipes.count, 1, "Should have 1 recipe")
                XCTAssertEqual(recipes.first?.id, "implement-and-review")
                XCTAssertEqual(recipes.first?.label, "Implement & Review")
                XCTAssertTrue(recipes.first?.description.contains("code") ?? false)
                expectation.fulfill()
            }

        let json = """
        {
            "type": "available_recipes",
            "recipes": [
                {
                    "id": "implement-and-review",
                    "label": "Implement & Review",
                    "description": "Implement task, review code, and fix issues in a loop"
                }
            ]
        }
        """

        client.handleMessage(json)

        // Wait for debounced update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(self.client.availableRecipes.count, 1)
        }

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()
    }

    func testHandleMultipleAvailableRecipes() throws {
        let expectation = XCTestExpectation(description: "Multiple recipes received")

        let cancellable = client.$availableRecipes
            .dropFirst()
            .sink { recipes in
                XCTAssertEqual(recipes.count, 2, "Should have 2 recipes")
                expectation.fulfill()
            }

        let json = """
        {
            "type": "available_recipes",
            "recipes": [
                {
                    "id": "recipe-1",
                    "label": "Recipe One",
                    "description": "First recipe"
                },
                {
                    "id": "recipe-2",
                    "label": "Recipe Two",
                    "description": "Second recipe"
                }
            ]
        }
        """

        client.handleMessage(json)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(self.client.availableRecipes.count, 2)
        }

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()
    }

    func testHandleEmptyAvailableRecipes() throws {
        let expectation = XCTestExpectation(description: "Empty recipes handled")

        let cancellable = client.$availableRecipes
            .dropFirst()
            .sink { recipes in
                XCTAssertEqual(recipes.count, 0, "Should have no recipes")
                expectation.fulfill()
            }

        let json = """
        {
            "type": "available_recipes",
            "recipes": []
        }
        """

        client.handleMessage(json)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(self.client.availableRecipes.count, 0)
        }

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()
    }

    // MARK: - Recipe Started Tests

    func testHandleRecipeStartedMessage() throws {
        let expectation = XCTestExpectation(description: "Recipe started")

        let cancellable = client.$activeRecipes
            .dropFirst()
            .sink { recipes in
                XCTAssertEqual(recipes.count, 1, "Should have 1 active recipe")
                let sessionId = "test-session-123"
                if let active = recipes[sessionId] {
                    XCTAssertEqual(active.recipeId, "implement-and-review")
                    XCTAssertEqual(active.recipeLabel, "Implement & Review")
                    XCTAssertEqual(active.currentStep, "implement")
                    XCTAssertEqual(active.iterationCount, 1)
                    expectation.fulfill()
                } else {
                    XCTFail("Recipe not found in active recipes")
                }
            }

        let json = """
        {
            "type": "recipe_started",
            "session_id": "test-session-123",
            "recipe_id": "implement-and-review",
            "recipe_label": "Implement & Review",
            "current_step": "implement",
            "iteration_count": 1
        }
        """

        client.handleMessage(json)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertNotNil(self.client.activeRecipes["test-session-123"])
        }

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()
    }

    func testHandleMultipleRecipesStarted() throws {
        let expectation = XCTestExpectation(description: "Multiple recipes started")
        var updateCount = 0

        let cancellable = client.$activeRecipes
            .dropFirst()
            .sink { recipes in
                updateCount += 1
                if updateCount == 2 {
                    XCTAssertEqual(recipes.count, 2, "Should have 2 active recipes")
                    XCTAssertNotNil(recipes["session-1"])
                    XCTAssertNotNil(recipes["session-2"])
                    expectation.fulfill()
                }
            }

        // Start first recipe
        let json1 = """
        {
            "type": "recipe_started",
            "session_id": "session-1",
            "recipe_id": "implement-and-review",
            "recipe_label": "Implement & Review",
            "current_step": "implement",
            "iteration_count": 1
        }
        """

        client.handleMessage(json1)

        // Start second recipe after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let json2 = """
            {
                "type": "recipe_started",
                "session_id": "session-2",
                "recipe_id": "implement-and-review",
                "recipe_label": "Implement & Review",
                "current_step": "code-review",
                "iteration_count": 2
            }
            """
            self.client.handleMessage(json2)
        }

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()
    }

    // MARK: - Recipe Exited Tests

    func testHandleRecipeExitedMessage() throws {
        let expectation = XCTestExpectation(description: "Recipe exited")

        // First, start a recipe
        let startJson = """
        {
            "type": "recipe_started",
            "session_id": "test-session-456",
            "recipe_id": "implement-and-review",
            "recipe_label": "Implement & Review",
            "current_step": "implement",
            "iteration_count": 1
        }
        """

        client.handleMessage(startJson)

        // Wait for it to be added
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // Now exit the recipe
            let exitJson = """
            {
                "type": "recipe_exited",
                "session_id": "test-session-456",
                "reason": "user-requested"
            }
            """

            let cancellable = self.client.$activeRecipes
                .dropFirst()
                .sink { recipes in
                    XCTAssertEqual(recipes.count, 0, "Should have no active recipes")
                    expectation.fulfill()
                }

            self.client.handleMessage(exitJson)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                XCTAssertNil(self.client.activeRecipes["test-session-456"])
            }

            wait(for: [expectation], timeout: 1.0)
            cancellable.cancel()
        }
    }

    func testHandleRecipeExitedAfterMultipleRecipes() throws {
        let expectation = XCTestExpectation(description: "Recipe exited with multiple active")
        var updateCount = 0

        let cancellable = client.$activeRecipes
            .dropFirst()
            .sink { recipes in
                updateCount += 1
                // After exit, should have 1 recipe remaining
                if updateCount == 3 {
                    XCTAssertEqual(recipes.count, 1, "Should have 1 remaining recipe")
                    XCTAssertNotNil(recipes["session-1"])
                    XCTAssertNil(recipes["session-2"])
                    expectation.fulfill()
                }
            }

        // Start two recipes
        client.handleMessage("""
            {
                "type": "recipe_started",
                "session_id": "session-1",
                "recipe_id": "implement-and-review",
                "recipe_label": "Implement & Review",
                "current_step": "implement",
                "iteration_count": 1
            }
            """)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.client.handleMessage("""
                {
                    "type": "recipe_started",
                    "session_id": "session-2",
                    "recipe_id": "implement-and-review",
                    "recipe_label": "Implement & Review",
                    "current_step": "code-review",
                    "iteration_count": 1
                }
                """)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // Exit session-2
            self.client.handleMessage("""
                {
                    "type": "recipe_exited",
                    "session_id": "session-2",
                    "reason": "max-iterations"
                }
                """)
        }

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()
    }

    // MARK: - Invalid Message Tests

    func testHandleRecipeStartedWithMissingFields() throws {
        let expectation = XCTestExpectation(description: "Missing fields handled")

        var updateReceived = false
        let cancellable = client.$activeRecipes
            .dropFirst()
            .sink { _ in
                updateReceived = true
            }

        // Message missing required fields
        let json = """
        {
            "type": "recipe_started",
            "session_id": "test-session"
        }
        """

        client.handleMessage(json)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // Should not have received any update
            XCTAssertFalse(updateReceived, "Should not update with incomplete data")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()
    }

    func testHandleRecipeExitedWithMissingFields() throws {
        let expectation = XCTestExpectation(description: "Recipe exit with missing fields handled")

        var updateReceived = false
        let cancellable = client.$activeRecipes
            .dropFirst()
            .sink { _ in
                updateReceived = true
            }

        // Message missing required fields
        let json = """
        {
            "type": "recipe_exited",
            "session_id": "test-session"
        }
        """

        client.handleMessage(json)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // Should not have received any update (missing reason)
            XCTAssertFalse(updateReceived, "Should not update with incomplete data")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()
    }

    // MARK: - Public Method Tests

    func testGetAvailableRecipesMethod() throws {
        // This test verifies the method doesn't crash
        XCTAssertNoThrow(client.getAvailableRecipes())
    }

    func testStartRecipeMethod() throws {
        // This test verifies the method doesn't crash
        XCTAssertNoThrow(client.startRecipe(sessionId: "test-123", recipeId: "implement-and-review"))
    }

    func testExitRecipeMethod() throws {
        // This test verifies the method doesn't crash
        XCTAssertNoThrow(client.exitRecipe(sessionId: "test-123"))
    }
}

// Helper to assert no throw
extension XCTestCase {
    func XCTAssertNoThrow<T>(_ expression: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try expression()
        } catch {
            XCTFail(message() + " threw error: \(error)", file: file, line: line)
        }
    }
}
