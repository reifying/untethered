// ConversationRecipeTests.swift
// Tests for recipe toolbar button in ConversationView

import XCTest
import SwiftUI
import CoreData
@testable import VoiceCode

class ConversationRecipeTests: XCTestCase {
    var persistenceController: PersistenceController!
    var viewContext: NSManagedObjectContext!
    var client: VoiceCodeClient!

    override func setUp() {
        super.setUp()
        persistenceController = PersistenceController(inMemory: true)
        viewContext = persistenceController.container.viewContext
        client = VoiceCodeClient(serverURL: "ws://localhost:3000", setupObservers: false)
    }

    override func tearDown() {
        client.disconnect()
        client = nil
        viewContext = nil
        persistenceController = nil
        super.tearDown()
    }

    // MARK: - Helper Methods

    func createTestSession(workingDirectory: String = "/Users/test/project") -> CDBackendSession {
        let session = CDBackendSession(context: viewContext)
        session.id = UUID()
        session.workingDirectory = workingDirectory
        session.lastModified = Date()
        session.messageCount = 0
        try? viewContext.save()
        return session
    }

    // MARK: - Active Recipe State Tests

    func testActiveRecipeNilWhenNoRecipeStarted() {
        let session = createTestSession()
        let sessionId = session.id.uuidString.lowercased()

        // No active recipe for this session
        XCTAssertNil(client.activeRecipes[sessionId])
    }

    func testActiveRecipeFoundAfterRecipeStarted() {
        let session = createTestSession()
        let sessionId = session.id.uuidString.lowercased()
        let expectation = XCTestExpectation(description: "Recipe started")

        let cancellable = client.$activeRecipes
            .dropFirst()
            .sink { recipes in
                if recipes[sessionId] != nil {
                    expectation.fulfill()
                }
            }

        // Simulate recipe_started message from backend
        let json = """
        {
            "type": "recipe_started",
            "session_id": "\(sessionId)",
            "recipe_id": "implement-and-review",
            "recipe_label": "Implement & Review",
            "current_step": "implement",
            "step_count": 1
        }
        """

        client.handleMessage(json)

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()

        // Verify active recipe is set
        let activeRecipe = client.activeRecipes[sessionId]
        XCTAssertNotNil(activeRecipe)
        XCTAssertEqual(activeRecipe?.recipeId, "implement-and-review")
        XCTAssertEqual(activeRecipe?.recipeLabel, "Implement & Review")
        XCTAssertEqual(activeRecipe?.currentStep, "implement")
        XCTAssertEqual(activeRecipe?.stepCount, 1)
    }

    func testActiveRecipeUpdatesOnStepChange() {
        let session = createTestSession()
        let sessionId = session.id.uuidString.lowercased()
        var updateCount = 0
        let expectation = XCTestExpectation(description: "Recipe updated twice")

        let cancellable = client.$activeRecipes
            .dropFirst()
            .sink { recipes in
                updateCount += 1
                if updateCount == 2 {
                    expectation.fulfill()
                }
            }

        // Start recipe
        client.handleMessage("""
        {
            "type": "recipe_started",
            "session_id": "\(sessionId)",
            "recipe_id": "implement-and-review",
            "recipe_label": "Implement & Review",
            "current_step": "implement",
            "step_count": 1
        }
        """)

        // Transition to next step
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.client.handleMessage("""
            {
                "type": "recipe_started",
                "session_id": "\(sessionId)",
                "recipe_id": "implement-and-review",
                "recipe_label": "Implement & Review",
                "current_step": "code-review",
                "step_count": 2
            }
            """)
        }

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()

        // Verify step updated
        let activeRecipe = client.activeRecipes[sessionId]
        XCTAssertEqual(activeRecipe?.currentStep, "code-review")
        XCTAssertEqual(activeRecipe?.stepCount, 2)
    }

    // MARK: - Exit Recipe Tests

    func testExitRecipeRemovesActiveRecipe() {
        let session = createTestSession()
        let sessionId = session.id.uuidString.lowercased()
        var updateCount = 0
        let expectation = XCTestExpectation(description: "Recipe exited")

        // Start recipe first
        client.handleMessage("""
        {
            "type": "recipe_started",
            "session_id": "\(sessionId)",
            "recipe_id": "implement-and-review",
            "recipe_label": "Implement & Review",
            "current_step": "implement",
            "step_count": 1
        }
        """)

        // Wait for debounce, then set up listener for exit
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let cancellable = self.client.$activeRecipes
                .dropFirst()
                .sink { recipes in
                    if recipes[sessionId] == nil {
                        expectation.fulfill()
                    }
                }

            // Exit recipe
            self.client.handleMessage("""
            {
                "type": "recipe_exited",
                "session_id": "\(sessionId)",
                "reason": "user-requested"
            }
            """)

            self.wait(for: [expectation], timeout: 1.0)
            cancellable.cancel()
        }

        // Verify recipe removed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertNil(self.client.activeRecipes[sessionId])
        }
    }

    func testExitRecipeMethod() {
        let session = createTestSession()
        let sessionId = session.id.uuidString.lowercased()

        // Verify exitRecipe method doesn't crash
        XCTAssertNoThrow(client.exitRecipe(sessionId: sessionId))
    }

    // MARK: - Multiple Session Tests

    func testDifferentSessionsHaveIndependentRecipeState() {
        let session1 = createTestSession(workingDirectory: "/Users/test/project1")
        let session2 = createTestSession(workingDirectory: "/Users/test/project2")
        let sessionId1 = session1.id.uuidString.lowercased()
        let sessionId2 = session2.id.uuidString.lowercased()
        let expectation = XCTestExpectation(description: "Both recipes started")
        var updateCount = 0

        let cancellable = client.$activeRecipes
            .dropFirst()
            .sink { recipes in
                updateCount += 1
                if recipes.count == 2 {
                    expectation.fulfill()
                }
            }

        // Start recipe on session 1
        client.handleMessage("""
        {
            "type": "recipe_started",
            "session_id": "\(sessionId1)",
            "recipe_id": "implement-and-review",
            "recipe_label": "Implement & Review",
            "current_step": "implement",
            "step_count": 1
        }
        """)

        // Start recipe on session 2
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.client.handleMessage("""
            {
                "type": "recipe_started",
                "session_id": "\(sessionId2)",
                "recipe_id": "implement-and-review",
                "recipe_label": "Implement & Review",
                "current_step": "code-review",
                "step_count": 3
            }
            """)
        }

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()

        // Verify both sessions have independent state
        XCTAssertNotNil(client.activeRecipes[sessionId1])
        XCTAssertNotNil(client.activeRecipes[sessionId2])
        XCTAssertEqual(client.activeRecipes[sessionId1]?.currentStep, "implement")
        XCTAssertEqual(client.activeRecipes[sessionId2]?.currentStep, "code-review")
    }

    func testExitingOneRecipeDoesNotAffectOthers() {
        let session1 = createTestSession(workingDirectory: "/Users/test/project1")
        let session2 = createTestSession(workingDirectory: "/Users/test/project2")
        let sessionId1 = session1.id.uuidString.lowercased()
        let sessionId2 = session2.id.uuidString.lowercased()
        let expectation = XCTestExpectation(description: "Exit completed")
        var updateCount = 0

        // Start both recipes
        client.handleMessage("""
        {
            "type": "recipe_started",
            "session_id": "\(sessionId1)",
            "recipe_id": "implement-and-review",
            "recipe_label": "Implement & Review",
            "current_step": "implement",
            "step_count": 1
        }
        """)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.client.handleMessage("""
            {
                "type": "recipe_started",
                "session_id": "\(sessionId2)",
                "recipe_id": "implement-and-review",
                "recipe_label": "Implement & Review",
                "current_step": "implement",
                "step_count": 1
            }
            """)
        }

        // Wait for both to be active, then exit session 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let cancellable = self.client.$activeRecipes
                .dropFirst()
                .sink { recipes in
                    // After exit, should have 1 remaining
                    if recipes.count == 1 && recipes[sessionId2] != nil {
                        expectation.fulfill()
                    }
                }

            self.client.handleMessage("""
            {
                "type": "recipe_exited",
                "session_id": "\(sessionId1)",
                "reason": "user-requested"
            }
            """)

            self.wait(for: [expectation], timeout: 1.0)
            cancellable.cancel()
        }
    }

    // MARK: - Recipe Menu Tests

    func testGetAvailableRecipesMethod() {
        // Verify method doesn't crash
        XCTAssertNoThrow(client.getAvailableRecipes())
    }

    func testStartRecipeMethod() {
        let session = createTestSession()
        let sessionId = session.id.uuidString.lowercased()

        // Verify method doesn't crash
        XCTAssertNoThrow(client.startRecipe(
            sessionId: sessionId,
            recipeId: "implement-and-review",
            workingDirectory: session.workingDirectory
        ))
    }

    // MARK: - Recipe Display Info Tests

    func testActiveRecipeContainsDisplayInfo() {
        let session = createTestSession()
        let sessionId = session.id.uuidString.lowercased()
        let expectation = XCTestExpectation(description: "Recipe contains display info")

        let cancellable = client.$activeRecipes
            .dropFirst()
            .sink { recipes in
                if let active = recipes[sessionId] {
                    // Verify all display info is present
                    XCTAssertFalse(active.recipeId.isEmpty)
                    XCTAssertFalse(active.recipeLabel.isEmpty)
                    XCTAssertFalse(active.currentStep.isEmpty)
                    XCTAssertGreaterThan(active.stepCount, 0)
                    expectation.fulfill()
                }
            }

        client.handleMessage("""
        {
            "type": "recipe_started",
            "session_id": "\(sessionId)",
            "recipe_id": "implement-and-review",
            "recipe_label": "Implement & Review",
            "current_step": "code-review",
            "step_count": 5
        }
        """)

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()
    }
}
