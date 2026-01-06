// APIKeyManagementView.swift
// Full-screen view for manual API key entry and management

import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Full-screen view for detailed API key management.
/// Provides manual entry alternative to QR scanning with real-time validation.
struct APIKeyManagementView: View {
    @Environment(\.dismiss) var dismiss

    /// Text field input for new API key
    @State private var newKeyInput = ""
    /// Validation error message to display
    @State private var validationError: String?
    /// Whether delete confirmation alert is showing
    @State private var showDeleteConfirmation = false
    /// Whether QR scanner sheet is showing
    @State private var showingScanner = false
    /// Tracks whether a key exists - used to trigger view refresh after save/delete
    @State private var hasKey: Bool

    /// Callback when API key changes (for triggering reconnection)
    let onKeyChanged: (() -> Void)?

    init(onKeyChanged: (() -> Void)? = nil) {
        self.onKeyChanged = onKeyChanged
        self._hasKey = State(initialValue: KeychainManager.shared.hasAPIKey())
    }

    var body: some View {
        NavigationController(minWidth: 500, minHeight: 500) {
            apiKeyForm
        }
        #if os(macOS)
        .swipeToBack()
        #endif
    }

    private var apiKeyForm: some View {
        Form {
            // Current key section
            if hasKey {
                currentKeySection
            }

            // Manual entry section
            manualEntrySection

            // QR scanner alternative
            scannerSection

            // Delete option (only shown when key exists)
            if hasKey {
                deleteSection
            }

            // Help section
            helpSection
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("API Key")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarBuilder.doneButton { dismiss() }
        }
        #if os(iOS)
        .sheet(isPresented: $showingScanner) {
            QRScannerView(
                onCodeScanned: { scannedKey in
                    newKeyInput = scannedKey
                    saveKey()
                    showingScanner = false
                },
                onCancel: {
                    showingScanner = false
                }
            )
            .ignoresSafeArea()
        }
        #endif
        .alert("Delete API Key?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteKey()
            }
        } message: {
            Text("You will need to re-enter the API key to connect to the backend.")
        }
    }

    // MARK: - Current Key Section

    private var currentKeySection: some View {
        Section {
            if let key = KeychainManager.shared.retrieveAPIKey() {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Current Key")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(maskedKey(key))
                            .font(.system(.body, design: .monospaced))
                    }
                    Spacer()
                    Button {
                        ClipboardUtility.copy(key)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
        } header: {
            Text("Stored Key")
        } footer: {
            Text("Key is securely stored in your device's Keychain")
        }
    }

    // MARK: - Manual Entry Section

    private var manualEntrySection: some View {
        Section {
            TextField("Enter API key", text: $newKeyInput)
                .textContentType(.password)
                #if os(iOS)
                .autocapitalization(.none)
                #endif
                .autocorrectionDisabled()
                .font(.system(size: 14, design: .monospaced))
                .accessibilityIdentifier("apiKeyTextField")

            // Real-time validation feedback
            if !newKeyInput.isEmpty {
                validationStatusRow
            }

            if let error = validationError {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Button {
                saveKey()
            } label: {
                HStack {
                    Text(hasKey ? "Update Key" : "Save Key")
                    Spacer()
                    Image(systemName: "checkmark.circle")
                }
            }
            .disabled(!isValidKey)
            .accessibilityIdentifier("saveKeyButton")
        } header: {
            Text("Manual Entry")
        } footer: {
            Text("Format: voice-code-<32 hex characters>\nExample: voice-code-a1b2c3d4e5f678901234567890abcdef")
        }
    }

    // MARK: - Validation Status Row

    private var validationStatusRow: some View {
        HStack {
            if isValidKey {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Valid format")
                    .foregroundColor(.green)
            } else {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                Text(validationMessage)
                    .foregroundColor(.red)
            }
            Spacer()
            Text("\(newKeyInput.count)/43")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .font(.caption)
    }

    // MARK: - Scanner Section

    #if os(iOS)
    private var scannerSection: some View {
        Section {
            Button {
                showingScanner = true
            } label: {
                HStack {
                    Text("Scan QR Code Instead")
                    Spacer()
                    Image(systemName: "qrcode.viewfinder")
                }
            }
            .accessibilityIdentifier("scanQRButton")
        } footer: {
            Text("Run 'make show-key-qr' on your server to display the QR code")
        }
    }
    #else
    private var scannerSection: some View {
        EmptyView()
    }
    #endif

    // MARK: - Delete Section

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                HStack {
                    Text("Delete Key")
                    Spacer()
                    Image(systemName: "trash")
                }
            }
            .accessibilityIdentifier("deleteKeyButton")
        }
    }

    // MARK: - Help Section

    private var helpSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Getting Your API Key", systemImage: "info.circle")
                    .font(.headline)

                Text("1. On your server, run: make show-key")
                Text("2. Copy the API key shown in the terminal")
                Text("3. Paste it in the field above")

                Text("")

                Text("Or use 'make show-key-qr' to display a QR code you can scan.")
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    // MARK: - Validation

    /// Whether the current input is a valid API key format
    var isValidKey: Bool {
        KeychainManager.shared.isValidAPIKeyFormat(newKeyInput)
    }

    /// Validation message describing what's wrong with the input
    var validationMessage: String {
        if newKeyInput.isEmpty {
            return "Enter an API key"
        }

        if !newKeyInput.hasPrefix("voice-code-") {
            return "Must start with 'voice-code-'"
        }

        if newKeyInput.count != 43 {
            if newKeyInput.count < 43 {
                return "Too short (\(43 - newKeyInput.count) more characters needed)"
            } else {
                return "Too long (\(newKeyInput.count - 43) extra characters)"
            }
        }

        // Check hex characters after prefix
        let hexPart = newKeyInput.dropFirst(11)
        let hexCharacterSet = CharacterSet(charactersIn: "0123456789abcdef")
        if !hexPart.unicodeScalars.allSatisfy({ hexCharacterSet.contains($0) }) {
            if hexPart.contains(where: { $0.isUppercase }) {
                return "Must use lowercase letters (a-f), not uppercase"
            }
            return "Characters after prefix must be lowercase hex (0-9, a-f)"
        }

        return "Invalid format"
    }

    // MARK: - Key Masking

    /// Mask API key showing first 15 chars, hiding the rest
    /// Format: "voice-code-a1b2...****"
    func maskedKey(_ key: String) -> String {
        guard key.count > 19 else { return key }

        let prefix = String(key.prefix(15))
        return "\(prefix)...****"
    }

    // MARK: - Actions

    private func saveKey() {
        validationError = nil

        guard isValidKey else {
            validationError = validationMessage
            return
        }

        do {
            try KeychainManager.shared.saveAPIKey(newKeyInput)
            newKeyInput = ""
            hasKey = true
            onKeyChanged?()
        } catch {
            validationError = "Failed to save: \(error.localizedDescription)"
        }
    }

    private func deleteKey() {
        validationError = nil

        do {
            try KeychainManager.shared.deleteAPIKey()
            hasKey = false
            onKeyChanged?()
        } catch {
            validationError = "Failed to delete: \(error.localizedDescription)"
        }
    }
}

// MARK: - Preview

#if DEBUG
struct APIKeyManagementView_Previews: PreviewProvider {
    static var previews: some View {
        APIKeyManagementView(onKeyChanged: nil)
    }
}
#endif
