// RecoverableErrorViewTests.swift
// Tests for RecoverableErrorView per Appendix Z.3

import XCTest
import SwiftUI
import VoiceCodeShared
@testable import VoiceCodeDesktop

/// Tests for RecoverableErrorView rendering and interaction
@MainActor
final class RecoverableErrorViewTests: XCTestCase {

    // MARK: - Rendering Tests

    func testRecoverableErrorViewWithRecoveryAction() {
        // Given: An error with a recovery action
        let error = UserRecoverableError(
            title: "Connection Lost",
            message: "Unable to connect to the server.",
            recoveryAction: UserRecoveryAction(label: "Retry") { }
        )

        var retryCount = 0
        var dismissCount = 0

        // When: Creating the view
        let view = RecoverableErrorView(
            error: error,
            onRetry: { retryCount += 1 },
            onDismiss: { dismissCount += 1 }
        )

        // Then: View should be creatable without errors
        XCTAssertNotNil(view)

        // Verify the error properties are accessible
        XCTAssertEqual(error.title, "Connection Lost")
        XCTAssertEqual(error.message, "Unable to connect to the server.")
        XCTAssertEqual(error.recoveryAction?.label, "Retry")
    }

    func testRecoverableErrorViewWithoutRecoveryAction() {
        // Given: An error without a recovery action (like session busy)
        let error = UserRecoverableError(
            title: "Session Busy",
            message: "This session is processing another request.",
            recoveryAction: nil
        )

        // When: Creating the view
        let view = RecoverableErrorView(
            error: error,
            onRetry: { },
            onDismiss: { }
        )

        // Then: View should be creatable without errors
        XCTAssertNotNil(view)

        // Verify no recovery action
        XCTAssertNil(error.recoveryAction)
    }

    // MARK: - VoiceCodeClient Integration Tests

    func testVoiceCodeClientCurrentRecoverableError() {
        // Given: A VoiceCodeClient
        let client = VoiceCodeClient(
            serverURL: "ws://localhost:8080",
            setupObservers: false
        )

        // When: Initially created
        // Then: No recoverable error should be set
        XCTAssertNil(client.currentRecoverableError)
    }

    func testVoiceCodeClientShowRecoverableError() {
        // Given: A VoiceCodeClient
        let client = VoiceCodeClient(
            serverURL: "ws://localhost:8080",
            setupObservers: false
        )

        // When: Showing a recoverable error
        let error = URLError(.notConnectedToInternet)
        client.showRecoverableError(from: error)

        // Then: currentRecoverableError should be set
        XCTAssertNotNil(client.currentRecoverableError)
        XCTAssertEqual(client.currentRecoverableError?.title, "No Internet Connection")
    }

    func testVoiceCodeClientClearRecoverableError() {
        // Given: A VoiceCodeClient with a recoverable error
        let client = VoiceCodeClient(
            serverURL: "ws://localhost:8080",
            setupObservers: false
        )
        client.showRecoverableError(from: URLError(.notConnectedToInternet))
        XCTAssertNotNil(client.currentRecoverableError)

        // When: Clearing the error
        client.clearRecoverableError()

        // Then: currentRecoverableError should be nil
        XCTAssertNil(client.currentRecoverableError)
    }

    func testVoiceCodeClientShowNonRecoverableError() {
        // Given: A VoiceCodeClient
        let client = VoiceCodeClient(
            serverURL: "ws://localhost:8080",
            setupObservers: false
        )

        // When: Showing a non-recoverable error
        struct CustomError: Error {}
        client.showRecoverableError(from: CustomError())

        // Then: currentRecoverableError should be nil (unknown errors are not recoverable)
        XCTAssertNil(client.currentRecoverableError)
    }

    func testVoiceCodeClientRecoverableErrorFromCannotFindHost() {
        // Given: A VoiceCodeClient with app settings
        let appSettings = AppSettings()
        appSettings.serverURL = "test-server"
        appSettings.serverPort = "3000"

        let client = VoiceCodeClient(
            serverURL: appSettings.fullServerURL,
            appSettings: appSettings,
            setupObservers: false
        )

        // When: Showing a cannotFindHost error
        client.showRecoverableError(from: URLError(.cannotFindHost))

        // Then: Should show "Server Not Found" error with server info
        XCTAssertNotNil(client.currentRecoverableError)
        XCTAssertEqual(client.currentRecoverableError?.title, "Server Not Found")
        XCTAssertTrue(client.currentRecoverableError?.message.contains("test-server:3000") ?? false)
        XCTAssertEqual(client.currentRecoverableError?.recoveryAction?.label, "Open Settings")
    }

    func testVoiceCodeClientRecoverableErrorFromTimeout() {
        // Given: A VoiceCodeClient
        let client = VoiceCodeClient(
            serverURL: "ws://localhost:8080",
            setupObservers: false
        )

        // When: Showing a timeout error
        client.showRecoverableError(from: URLError(.timedOut))

        // Then: Should show "Connection Timed Out" error
        XCTAssertNotNil(client.currentRecoverableError)
        XCTAssertEqual(client.currentRecoverableError?.title, "Connection Timed Out")
        XCTAssertEqual(client.currentRecoverableError?.recoveryAction?.label, "Retry")
    }

    func testVoiceCodeClientRecoverableErrorFromSessionLock() {
        // Given: A VoiceCodeClient
        let client = VoiceCodeClient(
            serverURL: "ws://localhost:8080",
            setupObservers: false
        )

        // When: Showing a session lock error
        client.showRecoverableError(from: SessionLockError(sessionId: "test-session"))

        // Then: Should show "Session Busy" error without recovery action
        XCTAssertNotNil(client.currentRecoverableError)
        XCTAssertEqual(client.currentRecoverableError?.title, "Session Busy")
        XCTAssertNil(client.currentRecoverableError?.recoveryAction)
    }

    func testVoiceCodeClientRecoverableErrorFromConnectionRefused() {
        // Given: A VoiceCodeClient with app settings
        let appSettings = AppSettings()
        appSettings.serverURL = "localhost"
        appSettings.serverPort = "9999"

        let client = VoiceCodeClient(
            serverURL: appSettings.fullServerURL,
            appSettings: appSettings,
            setupObservers: false
        )

        // When: Showing a cannotConnectToHost error
        client.showRecoverableError(from: URLError(.cannotConnectToHost))

        // Then: Should show "Connection Refused" error
        XCTAssertNotNil(client.currentRecoverableError)
        XCTAssertEqual(client.currentRecoverableError?.title, "Connection Refused")
        XCTAssertEqual(client.currentRecoverableError?.recoveryAction?.label, "Retry")
    }
}
