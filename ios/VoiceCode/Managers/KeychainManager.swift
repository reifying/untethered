// KeychainManager.swift
// Secure API key storage using iOS Keychain

import Foundation
import Security

enum KeychainError: Error, Equatable {
    case duplicateItem
    case itemNotFound
    case unexpectedStatus(OSStatus)
    case invalidData

    var localizedDescription: String {
        switch self {
        case .duplicateItem:
            return "Item already exists in Keychain"
        case .itemNotFound:
            return "Item not found in Keychain"
        case .unexpectedStatus(let status):
            return "Keychain error: \(status)"
        case .invalidData:
            return "Invalid data format"
        }
    }
}

/// Manages secure storage of API keys in the iOS Keychain
/// with support for sharing between app and Share Extension via access group.
class KeychainManager {
    static let shared = KeychainManager()

    private let service = "dev.910labs.voice-code"
    private let account = "api-key"

    /// Access group for sharing keychain items with app extensions.
    /// This allows the Share Extension to access the same API key.
    /// Note: The AppIdentifierPrefix is configured in the entitlements file.
    /// When using keychain-access-groups entitlement, items are automatically
    /// accessible to all apps/extensions with the same group in their entitlements.
    private let accessGroup: String? = nil

    private init() {}

    // MARK: - API Key Validation

    /// Validate API key format before saving.
    /// Key must start with "voice-code-", be exactly 43 characters,
    /// and contain only lowercase hex characters after the prefix.
    func isValidAPIKeyFormat(_ key: String) -> Bool {
        // Must start with "voice-code-" prefix
        guard key.hasPrefix("voice-code-") else {
            return false
        }

        // Must be exactly 43 characters (11 prefix + 32 hex)
        guard key.count == 43 else {
            return false
        }

        // Characters after prefix must be lowercase hex (0-9, a-f)
        let hexPart = key.dropFirst(11)  // Remove "voice-code-" prefix
        let hexCharacterSet = CharacterSet(charactersIn: "0123456789abcdef")
        return hexPart.unicodeScalars.allSatisfy { hexCharacterSet.contains($0) }
    }

    // MARK: - Keychain Operations

    /// Save API key to Keychain
    /// - Parameter key: The API key to save
    /// - Throws: KeychainError if save fails
    func saveAPIKey(_ key: String) throws {
        guard let data = key.data(using: .utf8) else {
            throw KeychainError.invalidData
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        // Try to add, if exists then update
        var status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            // Item exists, update it
            var searchQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]

            if let accessGroup = accessGroup {
                searchQuery[kSecAttrAccessGroup as String] = accessGroup
            }

            let updateAttributes: [String: Any] = [
                kSecValueData as String: data
            ]

            status = SecItemUpdate(searchQuery as CFDictionary, updateAttributes as CFDictionary)
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Retrieve API key from Keychain
    /// - Returns: The API key if found, nil otherwise
    func retrieveAPIKey() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }

        return key
    }

    /// Delete API key from Keychain
    /// - Throws: KeychainError if delete fails (except for itemNotFound which is ignored)
    func deleteAPIKey() throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemDelete(query as CFDictionary)

        // Success or item not found are both acceptable
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Check if API key exists in Keychain
    /// - Returns: true if key exists, false otherwise
    func hasAPIKey() -> Bool {
        return retrieveAPIKey() != nil
    }
}
