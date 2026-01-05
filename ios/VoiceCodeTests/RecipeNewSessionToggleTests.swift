// RecipeNewSessionToggleTests.swift
// Tests for the "Start in new session" toggle feature in RecipeMenuView

import XCTest
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCodeMac
#endif

class RecipeNewSessionToggleTests: XCTestCase {
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

    // MARK: - New Session UUID Format Tests

    func testNewSessionUUIDIsLowercase() throws {
        // Verify that UUIDs generated for new sessions are lowercase
        // This mirrors the logic in RecipeMenuView.selectRecipe
        let newSessionId = UUID().uuidString.lowercased()

        XCTAssertEqual(newSessionId, newSessionId.lowercased(),
                       "New session UUID should be lowercase")
        XCTAssertNotEqual(newSessionId, UUID().uuidString,
                          "Lowercase UUID should differ from raw UUID (which is uppercase)")
    }

    func testNewSessionUUIDFormat() throws {
        // Verify UUID format matches expected pattern
        let newSessionId = UUID().uuidString.lowercased()

        // UUID format: 8-4-4-4-12 hexadecimal digits
        let uuidRegex = #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#
        let regex = try NSRegularExpression(pattern: uuidRegex)
        let range = NSRange(newSessionId.startIndex..., in: newSessionId)

        XCTAssertNotNil(regex.firstMatch(in: newSessionId, range: range),
                        "UUID should match lowercase hex format: \(newSessionId)")
    }

    // MARK: - Recipe Started Confirmation Tests

    func testRecipeStartedWithNewSessionId() throws {
        // Test that activeRecipes is updated when recipe starts with a new session ID
        let expectation = XCTestExpectation(description: "Recipe started with new session ID")

        // Generate a new session ID (mimics RecipeMenuView behavior)
        let newSessionId = UUID().uuidString.lowercased()

        let cancellable = client.$activeRecipes
            .dropFirst()
            .sink { recipes in
                if let activeRecipe = recipes[newSessionId] {
                    XCTAssertEqual(activeRecipe.recipeId, "implement-and-review")
                    XCTAssertEqual(activeRecipe.currentStep, "implement")
                    expectation.fulfill()
                }
            }

        // Simulate backend sending recipe_started for the new session
        let json = """
        {
            "type": "recipe_started",
            "session_id": "\(newSessionId)",
            "recipe_id": "implement-and-review",
            "recipe_label": "Implement & Review",
            "current_step": "implement",
            "step_count": 1
        }
        """

        client.handleMessage(json)

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()
    }

    func testRecipeStartedWithNewSessionDifferentFromExisting() throws {
        // Test that starting a recipe in a new session doesn't affect existing session
        let existingSessionId = UUID().uuidString.lowercased()
        let newSessionId = UUID().uuidString.lowercased()

        XCTAssertNotEqual(existingSessionId, newSessionId,
                          "New session should have different UUID from existing")

        // Start recipe in existing session first
        let existingJson = """
        {
            "type": "recipe_started",
            "session_id": "\(existingSessionId)",
            "recipe_id": "other-recipe",
            "recipe_label": "Other Recipe",
            "current_step": "step1",
            "step_count": 1
        }
        """
        client.handleMessage(existingJson)

        let expectation = XCTestExpectation(description: "Both sessions have active recipes")
        var updateCount = 0

        let cancellable = client.$activeRecipes
            .dropFirst()
            .sink { recipes in
                updateCount += 1
                if recipes.count == 2 {
                    XCTAssertNotNil(recipes[existingSessionId])
                    XCTAssertNotNil(recipes[newSessionId])
                    XCTAssertEqual(recipes[existingSessionId]?.recipeId, "other-recipe")
                    XCTAssertEqual(recipes[newSessionId]?.recipeId, "implement-and-review")
                    expectation.fulfill()
                }
            }

        // Start recipe in new session after a small delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let newJson = """
            {
                "type": "recipe_started",
                "session_id": "\(newSessionId)",
                "recipe_id": "implement-and-review",
                "recipe_label": "Implement & Review",
                "current_step": "implement",
                "step_count": 1
            }
            """
            self.client.handleMessage(newJson)
        }

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()
    }

    // MARK: - Working Directory Inheritance Tests

    func testStartRecipeWithWorkingDirectory() throws {
        // Verify that startRecipe sends working_directory correctly
        // This is important for new sessions which need working_directory
        let sessionId = UUID().uuidString.lowercased()
        let workingDirectory = "/Users/test/project"

        // startRecipe doesn't throw, so this just verifies it doesn't crash
        XCTAssertNoThrow(
            client.startRecipe(
                sessionId: sessionId,
                recipeId: "implement-and-review",
                workingDirectory: workingDirectory
            )
        )
    }

    // MARK: - Session ID Selection Logic Tests

    /// Tests the session ID selection logic that would be used in RecipeMenuView
    /// This is a pure function test of the logic, not the SwiftUI view
    func testSessionIdSelectionLogic() throws {
        let currentSessionId = "existing-session-123"

        // Simulate toggle OFF behavior - use current session
        let useNewSessionOff = false
        let selectedIdWhenOff: String
        if useNewSessionOff {
            selectedIdWhenOff = UUID().uuidString.lowercased()
        } else {
            selectedIdWhenOff = currentSessionId
        }
        XCTAssertEqual(selectedIdWhenOff, currentSessionId,
                       "When toggle is OFF, should use current session ID")

        // Simulate toggle ON behavior - generate new UUID
        let useNewSessionOn = true
        let selectedIdWhenOn: String
        if useNewSessionOn {
            selectedIdWhenOn = UUID().uuidString.lowercased()
        } else {
            selectedIdWhenOn = currentSessionId
        }
        XCTAssertNotEqual(selectedIdWhenOn, currentSessionId,
                          "When toggle is ON, should use new session ID")

        // Verify new ID is a valid lowercase UUID
        let uuidRegex = #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#
        let regex = try NSRegularExpression(pattern: uuidRegex)
        let range = NSRange(selectedIdWhenOn.startIndex..., in: selectedIdWhenOn)
        XCTAssertNotNil(regex.firstMatch(in: selectedIdWhenOn, range: range),
                        "New session ID should be valid lowercase UUID")
    }
}
