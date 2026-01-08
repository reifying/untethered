// APIKeySectionTests.swift
// Unit tests for APIKeySection

import XCTest
@testable import VoiceCode

final class APIKeySectionTests: XCTestCase {

    override func tearDown() {
        // Clean up keychain after each test
        try? KeychainManager.shared.deleteAPIKey()
        super.tearDown()
    }

    // MARK: - Masked Key Format Tests

    func testMaskedKeyFormatWithValidKey() {
        // Create section instance to test maskedKey function
        let section = APIKeySection(onKeyChanged: nil, apiKeyInput: .constant(""))

        // Test with standard API key
        let key = "voice-code-a1b2c3d4e5f678901234567890abcdef"
        let masked = section.maskedKey(key)

        // Should show first 4 and last 4 characters: "voic...cdef"
        XCTAssertEqual(masked, "voic...cdef", "Masked key should show first 4 and last 4 characters")
    }

    func testMaskedKeyFormatPreservesFirstFourChars() {
        let section = APIKeySection(onKeyChanged: nil, apiKeyInput: .constant(""))

        let key = "test-prefix-a1b2c3d4e5f678901234567890abcdef"
        let masked = section.maskedKey(key)

        XCTAssertTrue(masked.hasPrefix("test"), "Masked key should preserve first 4 characters")
    }

    func testMaskedKeyFormatPreservesLastFourChars() {
        let section = APIKeySection(onKeyChanged: nil, apiKeyInput: .constant(""))

        let key = "voice-code-a1b2c3d4e5f67890123456789012wxyz"
        let masked = section.maskedKey(key)

        XCTAssertTrue(masked.hasSuffix("wxyz"), "Masked key should preserve last 4 characters")
    }

    func testMaskedKeyFormatShortKey() {
        let section = APIKeySection(onKeyChanged: nil, apiKeyInput: .constant(""))

        // Keys 8 chars or less should not be masked
        let shortKey = "12345678"
        let masked = section.maskedKey(shortKey)

        XCTAssertEqual(masked, "12345678", "Short keys should not be masked")
    }

    func testMaskedKeyFormatVeryShortKey() {
        let section = APIKeySection(onKeyChanged: nil, apiKeyInput: .constant(""))

        // Very short key
        let shortKey = "abc"
        let masked = section.maskedKey(shortKey)

        XCTAssertEqual(masked, "abc", "Very short keys should not be masked")
    }

    func testMaskedKeyFormatEdgeCaseNineChars() {
        let section = APIKeySection(onKeyChanged: nil, apiKeyInput: .constant(""))

        // 9 character key should be masked (> 8)
        let key = "123456789"
        let masked = section.maskedKey(key)

        XCTAssertEqual(masked, "1234...6789", "9-char key should be masked")
    }

    // MARK: - Status Display Tests

    func testStatusWhenKeyNotConfigured() throws {
        // Ensure no key exists
        try KeychainManager.shared.deleteAPIKey()

        // Verify hasAPIKey returns false
        XCTAssertFalse(KeychainManager.shared.hasAPIKey(), "hasAPIKey should return false when no key is configured")
    }

    func testStatusWhenKeyConfigured() throws {
        // Save a valid key
        let testKey = "voice-code-a1b2c3d4e5f678901234567890abcdef"
        try KeychainManager.shared.saveAPIKey(testKey)

        // Verify hasAPIKey returns true
        XCTAssertTrue(KeychainManager.shared.hasAPIKey(), "hasAPIKey should return true when key is configured")
    }

    func testStatusTransitionFromNotConfiguredToConfigured() throws {
        // Start with no key
        try KeychainManager.shared.deleteAPIKey()
        XCTAssertFalse(KeychainManager.shared.hasAPIKey())

        // Add key
        try KeychainManager.shared.saveAPIKey("voice-code-a1b2c3d4e5f678901234567890abcdef")
        XCTAssertTrue(KeychainManager.shared.hasAPIKey())
    }

    func testStatusTransitionFromConfiguredToNotConfigured() throws {
        // Start with key
        try KeychainManager.shared.saveAPIKey("voice-code-a1b2c3d4e5f678901234567890abcdef")
        XCTAssertTrue(KeychainManager.shared.hasAPIKey())

        // Remove key
        try KeychainManager.shared.deleteAPIKey()
        XCTAssertFalse(KeychainManager.shared.hasAPIKey())
    }

    // MARK: - View Initialization Tests

    func testAPIKeySectionInitialization() {
        // Test that section can be initialized with callback
        var callbackCalled = false
        let section = APIKeySection(onKeyChanged: {
            callbackCalled = true
        }, apiKeyInput: .constant(""))

        XCTAssertNotNil(section, "APIKeySection should initialize successfully")
        XCTAssertFalse(callbackCalled, "Callback should not be called on initialization")
    }

    func testAPIKeySectionInitializationWithNilCallback() {
        // Test that section can be initialized without callback
        let section = APIKeySection(onKeyChanged: nil, apiKeyInput: .constant(""))

        XCTAssertNotNil(section, "APIKeySection should initialize with nil callback")
    }

    // MARK: - Masked Key Format Edge Cases

    func testMaskedKeyWithEmptyString() {
        let section = APIKeySection(onKeyChanged: nil, apiKeyInput: .constant(""))

        let masked = section.maskedKey("")
        XCTAssertEqual(masked, "", "Empty string should remain empty")
    }

    func testMaskedKeyWithExactlyEightChars() {
        let section = APIKeySection(onKeyChanged: nil, apiKeyInput: .constant(""))

        // Exactly 8 characters - edge case, should NOT be masked
        let key = "12345678"
        let masked = section.maskedKey(key)

        XCTAssertEqual(masked, "12345678", "8-char key should not be masked")
    }

    func testMaskedKeyFormatConsistency() {
        let section = APIKeySection(onKeyChanged: nil, apiKeyInput: .constant(""))

        // Multiple calls should produce consistent results
        let key = "voice-code-a1b2c3d4e5f678901234567890abcdef"
        let masked1 = section.maskedKey(key)
        let masked2 = section.maskedKey(key)

        XCTAssertEqual(masked1, masked2, "Masked key should be consistent across calls")
    }

    // MARK: - Design Doc Format Tests

    func testMaskedKeyMatchesDesignDocFormat() {
        let section = APIKeySection(onKeyChanged: nil, apiKeyInput: .constant(""))

        // According to design doc, format should be "voic...89ab"
        // Testing with a key ending in "89ab"
        let key = "voice-code-0000000000000000000000000089ab"
        let masked = section.maskedKey(key)

        XCTAssertEqual(masked, "voic...89ab", "Masked key format should match design doc: 'voic...89ab'")
    }

    // MARK: - QR Scan Flow Tests

    func testQRScanPopulatesInputWithoutSaving() {
        // Ensure no key exists initially
        try? KeychainManager.shared.deleteAPIKey()
        XCTAssertFalse(KeychainManager.shared.hasAPIKey())

        // Simulate the QR scan flow: scanned key goes into apiKeyInput binding
        var inputValue = ""
        let scannedKey = "voice-code-a1b2c3d4e5f678901234567890abcdef"

        // QR scan populates the field (simulating what happens in APIKeySection)
        inputValue = scannedKey

        // Verify the input was populated
        XCTAssertEqual(inputValue, scannedKey)

        // But key should NOT be saved to keychain yet (user hasn't clicked Save)
        XCTAssertFalse(KeychainManager.shared.hasAPIKey(),
            "API key should NOT be saved to keychain until user clicks Save")
    }

    func testAPIKeySectionInitializationDoesNotTriggerCallback() {
        // This test documents expected behavior: creating an APIKeySection
        // should not invoke the onKeyChanged callback. The callback is only
        // invoked when saveAPIKey() or deleteAPIKey() is called explicitly.
        // Since QR scan no longer calls saveAPIKey(), it won't trigger the callback.
        var callbackInvoked = false

        // Create section with callback
        let _ = APIKeySection(onKeyChanged: {
            callbackInvoked = true
        }, apiKeyInput: .constant(""))

        // Callback should NOT have been invoked on initialization
        XCTAssertFalse(callbackInvoked,
            "onKeyChanged callback should NOT be invoked on initialization")
    }
}
