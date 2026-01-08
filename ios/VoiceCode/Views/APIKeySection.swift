// APIKeySection.swift
// Settings section for API key management

import SwiftUI

/// Settings section showing API key status and providing key management actions.
struct APIKeySection: View {
    @State private var showingScanner = false
    @State private var showingDeleteConfirmation = false
    @State private var validationError: String?
    /// Tracks whether a key exists - used to trigger view refresh after save/delete
    @State private var hasKey: Bool = KeychainManager.shared.hasAPIKey()

    /// Callback when API key changes (for triggering reconnection)
    let onKeyChanged: (() -> Void)?

    /// Binding for API key input - allows parent to access pending input for save
    @Binding var apiKeyInput: String

    var body: some View {
        Section(header: Text("Authentication")) {
            if hasKey {
                configuredKeyView
            } else {
                notConfiguredKeyView
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showingScanner) {
            QRScannerView(
                onCodeScanned: { scannedKey in
                    // Populate the field; key will be saved when user clicks Save
                    // This ensures the server URL is also updated before reconnecting
                    apiKeyInput = scannedKey
                    showingScanner = false
                },
                onCancel: {
                    showingScanner = false
                }
            )
            .ignoresSafeArea()
        }
        #endif
        .alert("Delete API Key?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteAPIKey()
            }
        } message: {
            Text("You will need to re-scan the QR code to connect to the backend.")
        }
    }

    // MARK: - Key Configured View

    private var configuredKeyView: some View {
        Group {
            // Status row
            HStack {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundColor(.green)
                Text("API Key Configured")
                Spacer()
                if let key = KeychainManager.shared.retrieveAPIKey() {
                    Text(maskedKey(key))
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            #if os(iOS)
            // Update key button (iOS only - requires camera for QR scanning)
            Button(action: { showingScanner = true }) {
                HStack {
                    Text("Update Key")
                    Spacer()
                    Image(systemName: "qrcode.viewfinder")
                        .foregroundColor(.accentColor)
                }
            }
            #endif

            // Delete key button
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                HStack {
                    Text("Delete Key")
                    Spacer()
                    Image(systemName: "trash")
                }
            }

            // Show error if delete failed
            if let error = validationError {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }
        }
    }

    // MARK: - Key Not Configured View

    private var notConfiguredKeyView: some View {
        Group {
            // Warning status
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("API Key Required")
            }

            #if os(iOS)
            // Scan QR button (iOS only - requires camera)
            Button(action: { showingScanner = true }) {
                HStack {
                    Text("Scan QR Code")
                    Spacer()
                    Image(systemName: "qrcode.viewfinder")
                        .foregroundColor(.accentColor)
                }
            }
            #endif

            // Manual entry field
            TextField("Paste API key", text: $apiKeyInput)
                .textContentType(.password)
                #if os(iOS)
                .autocapitalization(.none)
                #endif
                .autocorrectionDisabled()
                .font(.system(size: 14, design: .monospaced))

            if let error = validationError {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            // Help text
            Text("Run 'make show-key-qr' on your server to display the QR code")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Key Masking

    /// Mask API key showing first 4 and last 4 characters
    /// Format: "voic...89ab"
    func maskedKey(_ key: String) -> String {
        guard key.count > 8 else { return key }

        let prefix = String(key.prefix(4))
        let suffix = String(key.suffix(4))
        return "\(prefix)...\(suffix)"
    }

    // MARK: - Actions

    /// Save API key from input field. Returns true if saved successfully or nothing to save.
    /// Returns false if validation failed.
    @discardableResult
    func saveAPIKey() -> Bool {
        validationError = nil

        // Nothing to save
        guard !apiKeyInput.isEmpty else {
            return true
        }

        // Validate format
        guard KeychainManager.shared.isValidAPIKeyFormat(apiKeyInput) else {
            validationError = "Invalid format. Must start with 'voice-code-' and be 43 characters."
            return false
        }

        do {
            try KeychainManager.shared.saveAPIKey(apiKeyInput)
            apiKeyInput = ""
            hasKey = true  // Update state to refresh view
            onKeyChanged?()
            return true
        } catch {
            validationError = "Failed to save: \(error.localizedDescription)"
            return false
        }
    }

    private func deleteAPIKey() {
        validationError = nil

        do {
            try KeychainManager.shared.deleteAPIKey()
            hasKey = false  // Update state to refresh view
            onKeyChanged?()
        } catch {
            validationError = "Failed to delete: \(error.localizedDescription)"
        }
    }
}

// MARK: - Preview

#if DEBUG
struct APIKeySection_Previews: PreviewProvider {
    static var previews: some View {
        Form {
            APIKeySection(onKeyChanged: nil, apiKeyInput: .constant(""))
        }
    }
}
#endif
