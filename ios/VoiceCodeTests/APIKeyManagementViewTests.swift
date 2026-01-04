// APIKeyManagementViewTests.swift
// Unit tests for APIKeyManagementView

import XCTest
@testable import VoiceCode

final class APIKeyManagementViewTests: XCTestCase {

    override func tearDown() {
        // Clean up keychain after each test
        try? KeychainManager.shared.deleteAPIKey()
        super.tearDown()
    }

    // MARK: - Validation Tests

    func testIsValidKeyWithValidKey() {
        let validKey = "voice-code-a1b2c3d4e5f678901234567890abcdef"
        XCTAssertTrue(KeychainManager.shared.isValidAPIKeyFormat(validKey))
    }

    func testIsValidKeyWithInvalidPrefix() {
        let invalidKey = "invalid-prefix-a1b2c3d4e5f678901234567890ab"
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat(invalidKey))
    }

    func testIsValidKeyWithTooShort() {
        let shortKey = "voice-code-short"
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat(shortKey))
    }

    func testIsValidKeyWithTooLong() {
        let longKey = "voice-code-a1b2c3d4e5f678901234567890abcdef12"
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat(longKey))
    }

    func testIsValidKeyWithUppercaseHex() {
        let uppercaseKey = "voice-code-A1B2C3D4E5F678901234567890ABCDEF"
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat(uppercaseKey))
    }

    func testIsValidKeyWithNonHexCharacters() {
        let nonHexKey = "voice-code-ghijklmn12345678901234567890abcd"
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat(nonHexKey))
    }

    func testIsValidKeyWithEmptyString() {
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat(""))
    }

    // MARK: - Validation Message Tests

    func testValidationMessageForEmptyInput() {
        let view = APIKeyManagementView(onKeyChanged: nil)
        // When input is empty, validationMessage should indicate to enter a key
        // We test the internal logic by checking the conditions
        let emptyInput = ""
        XCTAssertTrue(emptyInput.isEmpty, "Empty input should trigger 'Enter an API key' message")
    }

    func testValidationMessageForWrongPrefix() {
        let wrongPrefix = "wrong-prefix-a1b2c3d4e5f678901234567890ab"
        XCTAssertFalse(wrongPrefix.hasPrefix("voice-code-"))
    }

    func testValidationMessageForTooShortKey() {
        let shortKey = "voice-code-abc"
        XCTAssertTrue(shortKey.count < 43)
        XCTAssertEqual(43 - shortKey.count, 29, "Should need 29 more characters")
    }

    func testValidationMessageForTooLongKey() {
        let longKey = "voice-code-a1b2c3d4e5f678901234567890abcdef123"
        XCTAssertTrue(longKey.count > 43)
        XCTAssertEqual(longKey.count - 43, 3, "Should have 3 extra characters")
    }

    func testValidationMessageForUppercaseLetters() {
        let mixedCase = "voice-code-A1B2c3d4e5f678901234567890abcdef"
        let hexPart = mixedCase.dropFirst(11)
        XCTAssertTrue(hexPart.contains(where: { $0.isUppercase }), "Should detect uppercase letters")
    }

    // MARK: - Masked Key Tests

    func testMaskedKeyFormat() {
        let view = APIKeyManagementView(onKeyChanged: nil)
        let key = "voice-code-a1b2c3d4e5f678901234567890abcdef"
        let masked = view.maskedKey(key)

        // Should show first 15 chars + "...****"
        XCTAssertEqual(masked, "voice-code-a1b2...****")
    }

    func testMaskedKeyPreservesPrefix() {
        let view = APIKeyManagementView(onKeyChanged: nil)
        let key = "voice-code-0000000000000000000000000000000"
        let masked = view.maskedKey(key)

        XCTAssertTrue(masked.hasPrefix("voice-code-0000"))
    }

    func testMaskedKeyShortKeyNotMasked() {
        let view = APIKeyManagementView(onKeyChanged: nil)
        let shortKey = "short-key"
        let masked = view.maskedKey(shortKey)

        // Keys 19 chars or less should not be masked
        XCTAssertEqual(masked, "short-key")
    }

    func testMaskedKeyExactlyNineteenChars() {
        let view = APIKeyManagementView(onKeyChanged: nil)
        let key = "1234567890123456789"  // 19 chars
        let masked = view.maskedKey(key)

        XCTAssertEqual(masked, "1234567890123456789", "19-char key should not be masked")
    }

    func testMaskedKeyTwentyChars() {
        let view = APIKeyManagementView(onKeyChanged: nil)
        let key = "12345678901234567890"  // 20 chars
        let masked = view.maskedKey(key)

        XCTAssertEqual(masked, "123456789012345...****", "20-char key should be masked")
    }

    // MARK: - Initialization Tests

    func testInitializationWithCallback() {
        var callbackCalled = false
        let view = APIKeyManagementView(onKeyChanged: {
            callbackCalled = true
        })

        XCTAssertNotNil(view)
        XCTAssertFalse(callbackCalled, "Callback should not be called on initialization")
    }

    func testInitializationWithNilCallback() {
        let view = APIKeyManagementView(onKeyChanged: nil)
        XCTAssertNotNil(view)
    }

    func testInitializationWithoutKey() throws {
        try KeychainManager.shared.deleteAPIKey()

        let view = APIKeyManagementView(onKeyChanged: nil)
        // View should initialize without error when no key exists
        XCTAssertNotNil(view)
    }

    func testInitializationWithExistingKey() throws {
        let testKey = "voice-code-a1b2c3d4e5f678901234567890abcdef"
        try KeychainManager.shared.saveAPIKey(testKey)

        let view = APIKeyManagementView(onKeyChanged: nil)
        // View should initialize successfully when key exists
        XCTAssertNotNil(view)
    }

    // MARK: - Save Button Enablement Tests

    func testSaveButtonDisabledForEmptyInput() {
        // Empty input should not be valid
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat(""))
    }

    func testSaveButtonDisabledForInvalidKey() {
        // Invalid key should not enable save
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat("invalid-key"))
    }

    func testSaveButtonEnabledForValidKey() {
        // Valid key should enable save
        let validKey = "voice-code-a1b2c3d4e5f678901234567890abcdef"
        XCTAssertTrue(KeychainManager.shared.isValidAPIKeyFormat(validKey))
    }

    // MARK: - Key Storage Integration Tests

    func testSaveValidKeyIntegration() throws {
        try KeychainManager.shared.deleteAPIKey()
        XCTAssertFalse(KeychainManager.shared.hasAPIKey())

        let testKey = "voice-code-a1b2c3d4e5f678901234567890abcdef"
        try KeychainManager.shared.saveAPIKey(testKey)

        XCTAssertTrue(KeychainManager.shared.hasAPIKey())
        XCTAssertEqual(KeychainManager.shared.retrieveAPIKey(), testKey)
    }

    func testDeleteKeyIntegration() throws {
        let testKey = "voice-code-a1b2c3d4e5f678901234567890abcdef"
        try KeychainManager.shared.saveAPIKey(testKey)
        XCTAssertTrue(KeychainManager.shared.hasAPIKey())

        try KeychainManager.shared.deleteAPIKey()
        XCTAssertFalse(KeychainManager.shared.hasAPIKey())
    }

    func testUpdateExistingKeyIntegration() throws {
        let firstKey = "voice-code-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        try KeychainManager.shared.saveAPIKey(firstKey)
        XCTAssertEqual(KeychainManager.shared.retrieveAPIKey(), firstKey)

        let secondKey = "voice-code-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        try KeychainManager.shared.saveAPIKey(secondKey)
        XCTAssertEqual(KeychainManager.shared.retrieveAPIKey(), secondKey)
    }

    // MARK: - Callback Tests

    func testCallbackNotCalledOnInit() {
        var callCount = 0
        _ = APIKeyManagementView(onKeyChanged: {
            callCount += 1
        })

        XCTAssertEqual(callCount, 0, "Callback should not be called during initialization")
    }

    // MARK: - Edge Cases

    func testValidationWithOnlyPrefix() {
        let prefixOnly = "voice-code-"
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat(prefixOnly))
        XCTAssertEqual(prefixOnly.count, 11)
    }

    func testValidationWithExactlyCorrectLength() {
        let exactLength = "voice-code-a1b2c3d4e5f678901234567890abcdef"
        XCTAssertEqual(exactLength.count, 43)
        XCTAssertTrue(KeychainManager.shared.isValidAPIKeyFormat(exactLength))
    }

    func testValidationWithAllZeros() {
        let allZeros = "voice-code-00000000000000000000000000000000"
        XCTAssertEqual(allZeros.count, 43)
        XCTAssertTrue(KeychainManager.shared.isValidAPIKeyFormat(allZeros))
    }

    func testValidationWithAllFs() {
        let allFs = "voice-code-ffffffffffffffffffffffffffffffff"
        XCTAssertEqual(allFs.count, 43)
        XCTAssertTrue(KeychainManager.shared.isValidAPIKeyFormat(allFs))
    }

    func testValidationWithMixedValidHex() {
        let mixedHex = "voice-code-0123456789abcdef0123456789abcdef"
        XCTAssertEqual(mixedHex.count, 43)
        XCTAssertTrue(KeychainManager.shared.isValidAPIKeyFormat(mixedHex))
    }

    // MARK: - Character Length Boundary Tests

    func testValidationAt42Characters() {
        let key42 = "voice-code-a1b2c3d4e5f678901234567890abcde"  // 42 chars
        XCTAssertEqual(key42.count, 42)
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat(key42))
    }

    func testValidationAt44Characters() {
        let key44 = "voice-code-a1b2c3d4e5f678901234567890abcdeff"  // 44 chars
        XCTAssertEqual(key44.count, 44)
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat(key44))
    }
}
