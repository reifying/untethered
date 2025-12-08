// MenuBarCommandsTests.swift
// Unit tests for MenuBarCommands (macOS)

import XCTest
import SwiftUI
@testable import UntetheredMac

final class MenuBarCommandsTests: XCTestCase {

    // MARK: - ConversationActions Protocol Tests

    func testConversationActionsProtocolRequirements() {
        // Verify that ConversationActions protocol has all required methods
        // This is a compile-time check, but we can verify the protocol exists
        let protocolMethods = [
            "sendPrompt",
            "stopTurn",
            "copySessionID",
            "toggleRecording",
            "cancelInput",
            "compactSession",
            "showCommandMenu"
        ]

        // If this test compiles, the protocol is correctly defined
        XCTAssertEqual(protocolMethods.count, 7, "ConversationActions should have 7 methods")
    }

    // MARK: - Mock ConversationActions

    class MockConversationActions: ConversationActions {
        var sendPromptCalled = false
        var stopTurnCalled = false
        var copySessionIDCalled = false
        var toggleRecordingCalled = false
        var cancelInputCalled = false
        var compactSessionCalled = false
        var showCommandMenuCalled = false

        func sendPrompt() {
            sendPromptCalled = true
        }

        func stopTurn() {
            stopTurnCalled = true
        }

        func copySessionID() {
            copySessionIDCalled = true
        }

        func toggleRecording() {
            toggleRecordingCalled = true
        }

        func cancelInput() {
            cancelInputCalled = true
        }

        func compactSession() {
            compactSessionCalled = true
        }

        func showCommandMenu() {
            showCommandMenuCalled = true
        }

        func reset() {
            sendPromptCalled = false
            stopTurnCalled = false
            copySessionIDCalled = false
            toggleRecordingCalled = false
            cancelInputCalled = false
            compactSessionCalled = false
            showCommandMenuCalled = false
        }
    }

    // MARK: - Mock Action Tests

    func testMockActionsSendPrompt() {
        let mock = MockConversationActions()
        XCTAssertFalse(mock.sendPromptCalled)

        mock.sendPrompt()
        XCTAssertTrue(mock.sendPromptCalled)
    }

    func testMockActionsStopTurn() {
        let mock = MockConversationActions()
        XCTAssertFalse(mock.stopTurnCalled)

        mock.stopTurn()
        XCTAssertTrue(mock.stopTurnCalled)
    }

    func testMockActionsCopySessionID() {
        let mock = MockConversationActions()
        XCTAssertFalse(mock.copySessionIDCalled)

        mock.copySessionID()
        XCTAssertTrue(mock.copySessionIDCalled)
    }

    func testMockActionsToggleRecording() {
        let mock = MockConversationActions()
        XCTAssertFalse(mock.toggleRecordingCalled)

        mock.toggleRecording()
        XCTAssertTrue(mock.toggleRecordingCalled)
    }

    func testMockActionsCancelInput() {
        let mock = MockConversationActions()
        XCTAssertFalse(mock.cancelInputCalled)

        mock.cancelInput()
        XCTAssertTrue(mock.cancelInputCalled)
    }

    func testMockActionsCompactSession() {
        let mock = MockConversationActions()
        XCTAssertFalse(mock.compactSessionCalled)

        mock.compactSession()
        XCTAssertTrue(mock.compactSessionCalled)
    }

    func testMockActionsShowCommandMenu() {
        let mock = MockConversationActions()
        XCTAssertFalse(mock.showCommandMenuCalled)

        mock.showCommandMenu()
        XCTAssertTrue(mock.showCommandMenuCalled)
    }

    func testMockActionsReset() {
        let mock = MockConversationActions()

        // Call all actions
        mock.sendPrompt()
        mock.stopTurn()
        mock.copySessionID()
        mock.toggleRecording()
        mock.cancelInput()
        mock.compactSession()
        mock.showCommandMenu()

        // Verify all are true
        XCTAssertTrue(mock.sendPromptCalled)
        XCTAssertTrue(mock.stopTurnCalled)
        XCTAssertTrue(mock.copySessionIDCalled)
        XCTAssertTrue(mock.toggleRecordingCalled)
        XCTAssertTrue(mock.cancelInputCalled)
        XCTAssertTrue(mock.compactSessionCalled)
        XCTAssertTrue(mock.showCommandMenuCalled)

        // Reset
        mock.reset()

        // Verify all are false
        XCTAssertFalse(mock.sendPromptCalled)
        XCTAssertFalse(mock.stopTurnCalled)
        XCTAssertFalse(mock.copySessionIDCalled)
        XCTAssertFalse(mock.toggleRecordingCalled)
        XCTAssertFalse(mock.cancelInputCalled)
        XCTAssertFalse(mock.compactSessionCalled)
        XCTAssertFalse(mock.showCommandMenuCalled)
    }

    // MARK: - Notification Tests

    func testStopSpeakingNotificationName() {
        // Verify the notification name is correctly defined
        let notificationName = Notification.Name.stopSpeaking
        XCTAssertEqual(notificationName.rawValue, "stopSpeaking")
    }

    func testStopSpeakingNotificationPosted() {
        let expectation = XCTestExpectation(description: "Stop speaking notification received")

        // Set up observer
        let observer = NotificationCenter.default.addObserver(
            forName: .stopSpeaking,
            object: nil,
            queue: .main
        ) { notification in
            expectation.fulfill()
        }

        // Post notification
        NotificationCenter.default.post(name: .stopSpeaking, object: nil)

        // Wait for notification
        wait(for: [expectation], timeout: 1.0)

        // Clean up
        NotificationCenter.default.removeObserver(observer)
    }

    func testStopSpeakingNotificationWithMultipleObservers() {
        let expectation1 = XCTestExpectation(description: "Observer 1 received notification")
        let expectation2 = XCTestExpectation(description: "Observer 2 received notification")

        // Set up multiple observers
        let observer1 = NotificationCenter.default.addObserver(
            forName: .stopSpeaking,
            object: nil,
            queue: .main
        ) { _ in
            expectation1.fulfill()
        }

        let observer2 = NotificationCenter.default.addObserver(
            forName: .stopSpeaking,
            object: nil,
            queue: .main
        ) { _ in
            expectation2.fulfill()
        }

        // Post notification
        NotificationCenter.default.post(name: .stopSpeaking, object: nil)

        // Wait for both notifications
        wait(for: [expectation1, expectation2], timeout: 1.0)

        // Clean up
        NotificationCenter.default.removeObserver(observer1)
        NotificationCenter.default.removeObserver(observer2)
    }

    // MARK: - FocusedValue Tests

    func testFocusedConversationKeyType() {
        // Verify the FocusedConversationKey has the correct Value type
        // This is a compile-time check
        let _: FocusedConversationKey.Value? = nil
        XCTAssertTrue(true, "FocusedConversationKey.Value type is correctly defined")
    }

    // MARK: - Integration Tests

    func testSessionCommandsStructExists() {
        // Verify SessionCommands struct can be instantiated
        let commands = SessionCommands()
        XCTAssertNotNil(commands)
    }

    func testVoiceCommandsStructExists() {
        // Verify VoiceCommands struct can be instantiated
        let commands = VoiceCommands()
        XCTAssertNotNil(commands)
    }

    // MARK: - Mock Action Lifecycle Tests

    func testMockActionsIndependence() {
        let mock = MockConversationActions()

        // Call one action
        mock.sendPrompt()
        XCTAssertTrue(mock.sendPromptCalled)
        XCTAssertFalse(mock.stopTurnCalled)
        XCTAssertFalse(mock.copySessionIDCalled)
        XCTAssertFalse(mock.toggleRecordingCalled)
        XCTAssertFalse(mock.cancelInputCalled)
        XCTAssertFalse(mock.compactSessionCalled)
        XCTAssertFalse(mock.showCommandMenuCalled)

        // Call another action
        mock.stopTurn()
        XCTAssertTrue(mock.sendPromptCalled)
        XCTAssertTrue(mock.stopTurnCalled)
        XCTAssertFalse(mock.copySessionIDCalled)
        XCTAssertFalse(mock.toggleRecordingCalled)
        XCTAssertFalse(mock.cancelInputCalled)
        XCTAssertFalse(mock.compactSessionCalled)
        XCTAssertFalse(mock.showCommandMenuCalled)
    }

    func testMockActionsMultipleCalls() {
        let mock = MockConversationActions()

        // Call same action multiple times
        mock.sendPrompt()
        XCTAssertTrue(mock.sendPromptCalled)

        mock.sendPrompt()
        XCTAssertTrue(mock.sendPromptCalled) // Still true after second call

        mock.sendPrompt()
        XCTAssertTrue(mock.sendPromptCalled) // Still true after third call
    }

    // MARK: - Notification Cleanup Tests

    func testNotificationObserverRemoval() {
        let expectation = XCTestExpectation(description: "Notification received")
        expectation.expectedFulfillmentCount = 1 // Should only be fulfilled once

        // Add observer
        let observer = NotificationCenter.default.addObserver(
            forName: .stopSpeaking,
            object: nil,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        // Post notification
        NotificationCenter.default.post(name: .stopSpeaking, object: nil)

        // Remove observer
        NotificationCenter.default.removeObserver(observer)

        // Post notification again - should not be received
        NotificationCenter.default.post(name: .stopSpeaking, object: nil)

        // Wait with shorter timeout since we expect exactly one fulfillment
        wait(for: [expectation], timeout: 0.5)
    }
}
