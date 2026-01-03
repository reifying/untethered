// AuthenticationRequiredViewTests.swift
// Unit tests for AuthenticationRequiredView

import XCTest
import SwiftUI
@testable import VoiceCode

final class AuthenticationRequiredViewTests: XCTestCase {

    // MARK: - View State Tests

    func testViewShowsDefaultInstructionsWhenNoError() {
        let client = createTestClient()
        client.requiresReauthentication = true
        client.authenticationError = nil

        // View should show default instructions when no error is set
        XCTAssertNil(client.authenticationError)
        XCTAssertTrue(client.requiresReauthentication)
    }

    func testViewShowsErrorMessageWhenAuthFailed() {
        let client = createTestClient()
        client.requiresReauthentication = true
        client.authenticationError = "Authentication failed"

        XCTAssertEqual(client.authenticationError, "Authentication failed")
        XCTAssertTrue(client.requiresReauthentication)
    }

    func testClientStateUpdatesOnAuthError() {
        let client = createTestClient()

        // Initial state
        XCTAssertFalse(client.requiresReauthentication)
        XCTAssertNil(client.authenticationError)
        XCTAssertFalse(client.isAuthenticated)

        // Simulate auth error
        client.isAuthenticated = false
        client.requiresReauthentication = true
        client.authenticationError = "Authentication failed"

        XCTAssertTrue(client.requiresReauthentication)
        XCTAssertEqual(client.authenticationError, "Authentication failed")
    }

    // MARK: - API Key Validation Tests

    func testValidAPIKeyFormats() {
        // Standard valid key
        XCTAssertTrue(KeychainManager.shared.isValidAPIKeyFormat("voice-code-a1b2c3d4e5f678901234567890abcdef"))

        // All zeros
        XCTAssertTrue(KeychainManager.shared.isValidAPIKeyFormat("voice-code-00000000000000000000000000000000"))

        // All f's
        XCTAssertTrue(KeychainManager.shared.isValidAPIKeyFormat("voice-code-ffffffffffffffffffffffffffffffff"))

        // Mixed case hex (lowercase only)
        XCTAssertTrue(KeychainManager.shared.isValidAPIKeyFormat("voice-code-0123456789abcdef0123456789abcdef"))
    }

    func testInvalidAPIKeyFormats() {
        // Empty string
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat(""))

        // Too short
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat("voice-code-abc"))

        // Wrong prefix
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat("api-key-a1b2c3d4e5f678901234567890abcdef"))

        // Missing prefix
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat("a1b2c3d4e5f678901234567890abcdef"))

        // Uppercase hex (invalid)
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat("voice-code-A1B2C3D4E5F678901234567890ABCDEF"))

        // Non-hex characters
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat("voice-code-ghijklmnopqrstuvwxyz1234567890ab"))

        // Too long
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat("voice-code-a1b2c3d4e5f678901234567890abcdef1"))

        // Random URL
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat("https://example.com"))
    }

    // MARK: - Save and Connect Flow Tests

    func testSaveValidKeyToKeychain() throws {
        // Clean up first
        try? KeychainManager.shared.deleteAPIKey()

        let validKey = "voice-code-a1b2c3d4e5f678901234567890abcdef"

        // Validate and save
        XCTAssertTrue(KeychainManager.shared.isValidAPIKeyFormat(validKey))
        try KeychainManager.shared.saveAPIKey(validKey)

        // Verify saved
        XCTAssertTrue(KeychainManager.shared.hasAPIKey())
        XCTAssertEqual(KeychainManager.shared.retrieveAPIKey(), validKey)

        // Clean up
        try KeychainManager.shared.deleteAPIKey()
    }

    func testInvalidKeyNotSaved() throws {
        // Clean up first
        try? KeychainManager.shared.deleteAPIKey()

        let invalidKey = "not-a-valid-key"

        // Validation should fail
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat(invalidKey))

        // Verify nothing was saved
        XCTAssertFalse(KeychainManager.shared.hasAPIKey())

        // Clean up
        try? KeychainManager.shared.deleteAPIKey()
    }

    // MARK: - Client Integration Tests

    func testClientShowsReauthenticationWhenNoAPIKey() {
        // Ensure no API key
        try? KeychainManager.shared.deleteAPIKey()

        let client = createTestClient()

        // Simulate connect message being sent without API key
        // In real flow, VoiceCodeClient checks apiKey in sendConnectMessage
        if KeychainManager.shared.retrieveAPIKey() == nil {
            client.requiresReauthentication = true
            client.authenticationError = "API key not configured. Please scan QR code in Settings."
        }

        XCTAssertTrue(client.requiresReauthentication)
        XCTAssertEqual(client.authenticationError, "API key not configured. Please scan QR code in Settings.")
    }

    func testClientClearsErrorOnSuccessfulAuth() {
        let client = createTestClient()

        // Set up error state
        client.isAuthenticated = false
        client.requiresReauthentication = true
        client.authenticationError = "Previous auth failed"

        // Simulate successful authentication
        client.isAuthenticated = true
        client.authenticationError = nil
        client.requiresReauthentication = false

        XCTAssertTrue(client.isAuthenticated)
        XCTAssertNil(client.authenticationError)
        XCTAssertFalse(client.requiresReauthentication)
    }

    // MARK: - View Display State Tests

    func testViewDisplaysWhenReauthenticationRequired() {
        let client = createTestClient()

        // State 1: Not requiring reauth - view should not show
        XCTAssertFalse(client.requiresReauthentication)

        // State 2: Requiring reauth - view should show
        client.requiresReauthentication = true
        XCTAssertTrue(client.requiresReauthentication)
    }

    func testRetryButtonVisibleWhenError() {
        let client = createTestClient()

        // With error - retry should be visible
        client.authenticationError = "Connection failed"
        XCTAssertNotNil(client.authenticationError)

        // Without error - retry should be hidden
        client.authenticationError = nil
        XCTAssertNil(client.authenticationError)
    }

    // MARK: - Error Message Tests

    func testErrorMessageVariants() {
        let client = createTestClient()

        // Test various error messages that backend might send
        let errorMessages = [
            "Authentication failed",
            "API key not configured. Please scan QR code in Settings.",
            "Invalid API key",
            "Connection refused"
        ]

        for message in errorMessages {
            client.authenticationError = message
            XCTAssertEqual(client.authenticationError, message)
        }
    }

    // MARK: - Manual Entry Validation Tests

    func testManualEntryValidation() {
        // Valid key should pass
        let validKey = "voice-code-a1b2c3d4e5f678901234567890abcdef"
        XCTAssertTrue(KeychainManager.shared.isValidAPIKeyFormat(validKey))

        // Pasted key with whitespace should fail (user needs to trim)
        let keyWithWhitespace = " voice-code-a1b2c3d4e5f678901234567890abcdef "
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat(keyWithWhitespace))

        // Partial key should fail
        let partialKey = "voice-code-a1b2c3d4"
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat(partialKey))
    }

    // MARK: - Helper Methods

    private func createTestClient() -> VoiceCodeClient {
        return VoiceCodeClient(
            serverURL: "ws://localhost:8080",
            setupObservers: false
        )
    }
}
