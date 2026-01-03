// KeychainManagerTests.swift
// Unit tests for KeychainManager

import XCTest
@testable import VoiceCode

final class KeychainManagerTests: XCTestCase {

    override func tearDown() {
        // Clean up after each test
        try? KeychainManager.shared.deleteAPIKey()
        super.tearDown()
    }

    // MARK: - Save and Retrieve Tests

    func testSaveAndRetrieveAPIKey() throws {
        // 43 chars total: "voice-code-" (11) + 32 hex chars
        let testKey = "voice-code-a1b2c3d4e5f678901234567890abcdef"

        try KeychainManager.shared.saveAPIKey(testKey)

        let retrieved = KeychainManager.shared.retrieveAPIKey()
        XCTAssertEqual(retrieved, testKey)
    }

    func testRetrieveReturnsNilWhenEmpty() {
        // Ensure no key exists
        try? KeychainManager.shared.deleteAPIKey()

        let retrieved = KeychainManager.shared.retrieveAPIKey()
        XCTAssertNil(retrieved)
    }

    func testUpdateExistingKey() throws {
        let firstKey = "voice-code-11111111111111111111111111111111"
        let secondKey = "voice-code-22222222222222222222222222222222"

        try KeychainManager.shared.saveAPIKey(firstKey)
        try KeychainManager.shared.saveAPIKey(secondKey)

        let retrieved = KeychainManager.shared.retrieveAPIKey()
        XCTAssertEqual(retrieved, secondKey)
    }

    // MARK: - hasAPIKey Tests

    func testHasAPIKeyReturnsFalseWhenEmpty() {
        // Ensure no key exists
        try? KeychainManager.shared.deleteAPIKey()

        XCTAssertFalse(KeychainManager.shared.hasAPIKey())
    }

    func testHasAPIKeyReturnsTrueWhenSet() throws {
        try KeychainManager.shared.saveAPIKey("voice-code-a1b2c3d4e5f678901234567890abcdef")
        XCTAssertTrue(KeychainManager.shared.hasAPIKey())
    }

    // MARK: - Delete Tests

    func testDeleteAPIKey() throws {
        let testKey = "voice-code-a1b2c3d4e5f678901234567890abcdef"
        try KeychainManager.shared.saveAPIKey(testKey)

        try KeychainManager.shared.deleteAPIKey()

        XCTAssertNil(KeychainManager.shared.retrieveAPIKey())
        XCTAssertFalse(KeychainManager.shared.hasAPIKey())
    }

    func testDeleteNonExistentKeyDoesNotThrow() {
        // Ensure no key exists
        try? KeychainManager.shared.deleteAPIKey()

        // Should not throw when deleting non-existent key
        XCTAssertNoThrow(try KeychainManager.shared.deleteAPIKey())
    }

    // MARK: - isValidAPIKeyFormat Tests

    func testValidAPIKeyFormat() {
        // Valid keys
        XCTAssertTrue(KeychainManager.shared.isValidAPIKeyFormat("voice-code-a1b2c3d4e5f678901234567890abcdef"))
        XCTAssertTrue(KeychainManager.shared.isValidAPIKeyFormat("voice-code-00000000000000000000000000000000"))
        XCTAssertTrue(KeychainManager.shared.isValidAPIKeyFormat("voice-code-ffffffffffffffffffffffffffffffff"))
        XCTAssertTrue(KeychainManager.shared.isValidAPIKeyFormat("voice-code-0123456789abcdef0123456789abcdef"))
    }

    func testInvalidAPIKeyFormatWrongPrefix() {
        // Invalid: wrong prefix
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat("wrong-prefix-a1b2c3d4e5f678901234567890ab"))
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat("voicecode-a1b2c3d4e5f6789012345678901234ab"))
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat("voice_code-a1b2c3d4e5f678901234567890abcdef"))
    }

    func testInvalidAPIKeyFormatWrongLength() {
        // Invalid: too short
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat("voice-code-short"))
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat("voice-code-a1b2c3d4e5f678901234567890abcde"))  // 42 chars

        // Invalid: too long
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat("voice-code-a1b2c3d4e5f678901234567890abcdefg"))  // 44 chars
    }

    func testInvalidAPIKeyFormatUppercaseHex() {
        // Invalid: uppercase hex characters
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat("voice-code-A1B2C3D4E5F678901234567890ABCDEF"))
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat("voice-code-a1b2c3d4e5f678901234567890ABCDEF"))
    }

    func testInvalidAPIKeyFormatNonHexCharacters() {
        // Invalid: non-hex characters (g-z)
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat("voice-code-ghijklmn12345678901234567890abcd"))
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat("voice-code-xyz12345678901234567890abcdefgh"))
    }

    func testInvalidAPIKeyFormatEmpty() {
        // Invalid: empty string
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat(""))
    }

    func testInvalidAPIKeyFormatSpecialCharacters() {
        // Invalid: special characters in hex portion
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat("voice-code-a1b2c3d4e5f67890123456789!@#$%^&"))
        XCTAssertFalse(KeychainManager.shared.isValidAPIKeyFormat("voice-code-a1b2-c3d4-e5f6-7890-12345678abcd"))
    }

    // MARK: - Error Enum Tests

    func testKeychainErrorEquatable() {
        XCTAssertEqual(KeychainError.duplicateItem, KeychainError.duplicateItem)
        XCTAssertEqual(KeychainError.itemNotFound, KeychainError.itemNotFound)
        XCTAssertEqual(KeychainError.invalidData, KeychainError.invalidData)
        XCTAssertEqual(KeychainError.unexpectedStatus(-25299), KeychainError.unexpectedStatus(-25299))

        XCTAssertNotEqual(KeychainError.duplicateItem, KeychainError.itemNotFound)
        XCTAssertNotEqual(KeychainError.unexpectedStatus(-25299), KeychainError.unexpectedStatus(-25300))
    }

    func testKeychainErrorLocalizedDescription() {
        XCTAssertEqual(KeychainError.duplicateItem.localizedDescription, "Item already exists in Keychain")
        XCTAssertEqual(KeychainError.itemNotFound.localizedDescription, "Item not found in Keychain")
        XCTAssertEqual(KeychainError.invalidData.localizedDescription, "Invalid data format")
        XCTAssertTrue(KeychainError.unexpectedStatus(-25299).localizedDescription.contains("-25299"))
    }

    // MARK: - Edge Case Tests

    func testSaveEmptyString() throws {
        // Empty string should be saveable (though not a valid API key format)
        try KeychainManager.shared.saveAPIKey("")

        let retrieved = KeychainManager.shared.retrieveAPIKey()
        XCTAssertEqual(retrieved, "")
    }

    func testSaveKeyWithSpecialCharacters() throws {
        // Keys with special characters should be saveable
        let specialKey = "voice-code-test!@#$%^&*()_+-=[]{}|;':\",./<>?"
        try KeychainManager.shared.saveAPIKey(specialKey)

        let retrieved = KeychainManager.shared.retrieveAPIKey()
        XCTAssertEqual(retrieved, specialKey)
    }

    func testSaveKeyWithUnicode() throws {
        // Keys with unicode should be saveable
        let unicodeKey = "voice-code-\u{1F511}\u{1F512}\u{1F513}"  // Key emojis
        try KeychainManager.shared.saveAPIKey(unicodeKey)

        let retrieved = KeychainManager.shared.retrieveAPIKey()
        XCTAssertEqual(retrieved, unicodeKey)
    }

    func testMultipleSavesOverwrite() throws {
        let keys = [
            "voice-code-11111111111111111111111111111111",
            "voice-code-22222222222222222222222222222222",
            "voice-code-33333333333333333333333333333333"
        ]

        for key in keys {
            try KeychainManager.shared.saveAPIKey(key)
        }

        // Only the last key should remain
        let retrieved = KeychainManager.shared.retrieveAPIKey()
        XCTAssertEqual(retrieved, keys.last)
    }

    // MARK: - Integration Tests

    func testFullLifecycle() throws {
        // Start with no key
        try? KeychainManager.shared.deleteAPIKey()
        XCTAssertFalse(KeychainManager.shared.hasAPIKey())
        XCTAssertNil(KeychainManager.shared.retrieveAPIKey())

        // Save a key
        let key1 = "voice-code-a1b2c3d4e5f678901234567890abcdef"
        try KeychainManager.shared.saveAPIKey(key1)
        XCTAssertTrue(KeychainManager.shared.hasAPIKey())
        XCTAssertEqual(KeychainManager.shared.retrieveAPIKey(), key1)

        // Update the key
        let key2 = "voice-code-fedcba9876543210fedcba9876543210"
        try KeychainManager.shared.saveAPIKey(key2)
        XCTAssertTrue(KeychainManager.shared.hasAPIKey())
        XCTAssertEqual(KeychainManager.shared.retrieveAPIKey(), key2)

        // Delete the key
        try KeychainManager.shared.deleteAPIKey()
        XCTAssertFalse(KeychainManager.shared.hasAPIKey())
        XCTAssertNil(KeychainManager.shared.retrieveAPIKey())
    }
}
