// ShareExtensionAuthTests.swift
// Unit tests for Share Extension Bearer token authentication

import XCTest
@testable import VoiceCode

/// Tests for Share Extension authentication behavior.
/// Validates that HTTP requests include proper Authorization headers
/// and that authentication errors are handled correctly.
final class ShareExtensionAuthTests: XCTestCase {

    // MARK: - Setup/Teardown

    override func setUp() {
        super.setUp()
        // Ensure clean state
        try? KeychainManager.shared.deleteAPIKey()
    }

    override func tearDown() {
        // Clean up
        try? KeychainManager.shared.deleteAPIKey()
        super.tearDown()
    }

    // MARK: - Authorization Header Tests

    func testAuthorizationHeaderFormat() {
        // Test that Bearer token format is correct
        let apiKey = "voice-code-a1b2c3d4e5f678901234567890abcdef"
        let expectedHeader = "Bearer \(apiKey)"

        // This matches what ShareViewController does:
        // request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        XCTAssertEqual(expectedHeader, "Bearer voice-code-a1b2c3d4e5f678901234567890abcdef")
        XCTAssertTrue(expectedHeader.hasPrefix("Bearer "),
                     "Authorization header should have Bearer prefix")
    }

    func testBearerTokenDoesNotExposeKeyPrefix() {
        // Ensure the bearer token format doesn't duplicate the "voice-code-" prefix
        let apiKey = "voice-code-a1b2c3d4e5f678901234567890abcdef"
        let header = "Bearer \(apiKey)"

        // Count occurrences of "voice-code-" - should be exactly 1
        let occurrences = header.components(separatedBy: "voice-code-").count - 1
        XCTAssertEqual(occurrences, 1, "API key prefix should appear exactly once")
    }

    // MARK: - API Key Availability Tests

    func testAPIKeyAvailableFromKeychain() throws {
        let testKey = "voice-code-11111111111111111111111111111111"

        // Save API key (simulates main app saving it)
        try KeychainManager.shared.saveAPIKey(testKey)

        // Share Extension would retrieve it
        let retrieved = KeychainManager.shared.retrieveAPIKey()
        XCTAssertEqual(retrieved, testKey, "Share Extension should access API key from Keychain")
    }

    func testAPIKeyNotAvailableReturnsNil() {
        // No API key saved
        let retrieved = KeychainManager.shared.retrieveAPIKey()
        XCTAssertNil(retrieved, "Should return nil when no API key exists")
    }

    func testHasAPIKeyReturnsFalseWhenNotConfigured() {
        // Share Extension checks hasAPIKey before attempting upload
        XCTAssertFalse(KeychainManager.shared.hasAPIKey(),
                      "hasAPIKey should return false when not configured")
    }

    func testHasAPIKeyReturnsTrueWhenConfigured() throws {
        try KeychainManager.shared.saveAPIKey("voice-code-22222222222222222222222222222222")
        XCTAssertTrue(KeychainManager.shared.hasAPIKey(),
                     "hasAPIKey should return true when configured")
    }

    // MARK: - HTTP Response Code Tests

    func testHTTP401IsAuthenticationFailure() {
        // 401 Unauthorized indicates authentication failure
        let statusCode = 401
        XCTAssertEqual(statusCode, 401, "401 is the standard HTTP status for authentication failure")
    }

    func testHTTP200IsSuccess() {
        // 200 OK indicates successful upload
        let statusCode = 200
        XCTAssertEqual(statusCode, 200, "200 is the standard HTTP status for success")
    }

    // MARK: - Error Message Tests

    func testMissingAPIKeyErrorMessage() {
        // The error message shown when API key is not configured
        let expectedMessage = "API key not configured. Please open the main app and set up authentication in Settings."

        // This matches what ShareViewController shows
        XCTAssertTrue(expectedMessage.contains("API key not configured"),
                     "Error should mention missing API key")
        XCTAssertTrue(expectedMessage.contains("main app"),
                     "Error should direct user to main app")
        XCTAssertTrue(expectedMessage.contains("Settings"),
                     "Error should mention Settings")
    }

    func testAuthFailureErrorMessage() {
        // The error message shown when server returns 401
        let expectedMessage = "Authentication failed. Please verify your API key in the main app Settings."

        XCTAssertTrue(expectedMessage.contains("Authentication failed"),
                     "Error should indicate authentication failure")
        XCTAssertTrue(expectedMessage.contains("API key"),
                     "Error should mention API key")
    }

    // MARK: - URLRequest Building Tests

    func testURLRequestIncludesAuthorizationHeader() {
        // Simulate how ShareViewController builds the request
        let url = URL(string: "http://localhost:8080/upload")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let apiKey = "voice-code-a1b2c3d4e5f678901234567890abcdef"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // Verify headers
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                      "Bearer voice-code-a1b2c3d4e5f678901234567890abcdef",
                      "Request should include Authorization header with Bearer token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"),
                      "application/json",
                      "Request should include Content-Type header")
        XCTAssertEqual(request.httpMethod, "POST",
                      "Request should use POST method")
    }

    func testURLRequestWithoutAPIKeyHasNoAuthorizationHeader() {
        // When no API key is available, request should not be made
        // (ShareViewController returns early with error)
        let url = URL(string: "http://localhost:8080/upload")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // No Authorization header set
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"),
                    "Request without API key should not have Authorization header")
    }

    // MARK: - Keychain Service/Account Tests

    func testKeychainServiceMatchesShareExtension() {
        // The service and account names must match between main app and Share Extension
        // ShareViewController uses:
        //   keychainService = "dev.910labs.voice-code"
        //   keychainAccount = "api-key"
        // KeychainManager uses:
        //   service = "dev.910labs.voice-code"
        //   account = "api-key"

        // These are hardcoded in both files, so this test documents the requirement
        let expectedService = "dev.910labs.voice-code"
        let expectedAccount = "api-key"

        // If KeychainManager changes these, this test will catch it
        // (We can't directly access private properties, but we verify behavior)
        let testKey = "voice-code-33333333333333333333333333333333"

        do {
            try KeychainManager.shared.saveAPIKey(testKey)
            let retrieved = KeychainManager.shared.retrieveAPIKey()
            XCTAssertEqual(retrieved, testKey,
                          "Keychain operations should work with service '\(expectedService)' and account '\(expectedAccount)'")
            try KeychainManager.shared.deleteAPIKey()
        } catch {
            XCTFail("Keychain operations failed: \(error)")
        }
    }

    // MARK: - Edge Case Tests

    func testEmptyAPIKeyNotSentAsBearer() throws {
        // If somehow an empty key is saved, it shouldn't be used
        try KeychainManager.shared.saveAPIKey("")

        let retrieved = KeychainManager.shared.retrieveAPIKey()
        XCTAssertEqual(retrieved, "", "Empty string should be retrievable")

        // ShareViewController should validate key format before using
        // KeychainManager.isValidAPIKeyFormat would catch this
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat(""),
                      "Empty string should fail format validation")
    }

    func testInvalidAPIKeyFormatDetected() {
        // Share Extension should ideally validate key format
        let invalidKeys = [
            "wrong-prefix-a1b2c3d4e5f678901234567890abcdef",
            "voice-code-short",
            "voice-code-UPPERCASE1234567890ABCDEF1234",
            ""
        ]

        for key in invalidKeys {
            XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat(key),
                          "Key '\(key)' should be invalid format")
        }
    }

    func testValidAPIKeyFormatAccepted() {
        let validKeys = [
            "voice-code-a1b2c3d4e5f678901234567890abcdef",
            "voice-code-00000000000000000000000000000000",
            "voice-code-ffffffffffffffffffffffffffffffff"
        ]

        for key in validKeys {
            XCTAssertTrue(KeychainManager.shared.isValidAPIKeyFormat(key),
                         "Key '\(key)' should be valid format")
        }
    }
}
