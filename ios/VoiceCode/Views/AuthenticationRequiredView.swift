// AuthenticationRequiredView.swift
// View shown when app launches without API key or when authentication fails

import SwiftUI

/// View displayed when API key authentication is required.
/// Provides clear instructions and navigation to QR scanning or manual entry.
struct AuthenticationRequiredView: View {
    @ObservedObject var client: VoiceCodeClient

    @State private var showingScanner = false
    @State private var showingManualEntry = false
    @State private var manualKeyInput = ""
    @State private var validationError: String?
    @State private var isRetrying = false

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                Spacer()

                // Lock icon
                Image(systemName: "key.slash")
                    .font(.system(size: 60))
                    .foregroundColor(.orange)

                // Title
                Text("Authentication Required")
                    .font(.title2)
                    .fontWeight(.semibold)

                // Error message or instructions
                if let error = client.authenticationError {
                    Text(error)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                } else {
                    Text("Connect your app to the voice-code backend by scanning the API key QR code displayed in your terminal.")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()

                // Primary action: Scan QR Code
                Button(action: {
                    showingScanner = true
                }) {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 24)

                // Secondary action: Manual Entry
                Button(action: {
                    showingManualEntry = true
                }) {
                    Label("Enter Manually", systemImage: "keyboard")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.systemGray5))
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 24)

                // Retry button (only shown if there was an error)
                if client.authenticationError != nil {
                    Button(action: retryConnection) {
                        HStack {
                            if isRetrying {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                            Text("Retry Connection")
                        }
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
                    .disabled(isRetrying)
                }

                Spacer()

                // Help text
                Text("Run `make show-key-qr` in your terminal to display the QR code")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showingScanner) {
            QRScannerView(
                onCodeScanned: { scannedKey in
                    showingScanner = false
                    saveAndConnect(key: scannedKey)
                },
                onCancel: {
                    showingScanner = false
                }
            )
        }
        .sheet(isPresented: $showingManualEntry) {
            ManualKeyEntrySheet(
                keyInput: $manualKeyInput,
                validationError: $validationError,
                onSave: {
                    showingManualEntry = false
                    saveAndConnect(key: manualKeyInput)
                    manualKeyInput = ""
                },
                onCancel: {
                    showingManualEntry = false
                    manualKeyInput = ""
                    validationError = nil
                }
            )
        }
    }

    private func saveAndConnect(key: String) {
        validationError = nil

        // Validate key format
        guard KeychainManager.shared.isValidAPIKeyFormat(key) else {
            validationError = "Invalid API key format. Must start with 'voice-code-' and be 43 characters."
            showingManualEntry = true
            manualKeyInput = key
            return
        }

        // Save to keychain
        do {
            try KeychainManager.shared.saveAPIKey(key)

            // Reconnect with new key
            client.disconnect()
            client.connect()
        } catch {
            validationError = "Failed to save API key: \(error.localizedDescription)"
            showingManualEntry = true
            manualKeyInput = key
        }
    }

    private func retryConnection() {
        isRetrying = true
        client.disconnect()
        client.connect()

        // Reset retry state after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            isRetrying = false
        }
    }
}

/// Sheet for manual API key entry
private struct ManualKeyEntrySheet: View {
    @Binding var keyInput: String
    @Binding var validationError: String?
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("API Key", text: $keyInput)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))

                    if let error = validationError {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                } header: {
                    Text("Enter API Key")
                } footer: {
                    Text("Paste the API key from your terminal. It starts with 'voice-code-' and is 43 characters long.")
                }
            }
            .navigationTitle("Manual Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        // Validate before calling onSave
                        if KeychainManager.shared.isValidAPIKeyFormat(keyInput) {
                            validationError = nil
                            onSave()
                        } else {
                            validationError = "Invalid format. Must start with 'voice-code-' and be 43 characters."
                        }
                    }
                    .disabled(keyInput.isEmpty)
                }
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct AuthenticationRequiredView_Previews: PreviewProvider {
    static var previews: some View {
        // Preview with no error
        AuthenticationRequiredView(
            client: PreviewVoiceCodeClient.withNoError()
        )
        .previewDisplayName("Initial State")

        // Preview with auth error
        AuthenticationRequiredView(
            client: PreviewVoiceCodeClient.withAuthError()
        )
        .previewDisplayName("With Error")
    }
}

/// Mock VoiceCodeClient for previews
private class PreviewVoiceCodeClient {
    static func withNoError() -> VoiceCodeClient {
        let client = VoiceCodeClient(
            serverURL: "ws://localhost:8080",
            setupObservers: false
        )
        client.requiresReauthentication = true
        return client
    }

    static func withAuthError() -> VoiceCodeClient {
        let client = VoiceCodeClient(
            serverURL: "ws://localhost:8080",
            setupObservers: false
        )
        client.requiresReauthentication = true
        client.authenticationError = "Authentication failed. Please re-scan the API key QR code."
        return client
    }
}
#endif
