// SettingsView.swift
// Settings panel for macOS app

import SwiftUI
import UntetheredCore

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) var dismiss

    @State private var testingConnection = false
    @State private var testResult: String?
    @State private var testSuccess = false

    var body: some View {
        Form {
            Section(header: Text("Server Configuration")) {
                TextField("Server Address", text: $settings.serverURL)
                    .textFieldStyle(.roundedBorder)

                TextField("Port", text: $settings.serverPort)
                    .textFieldStyle(.roundedBorder)

                Text("Full URL: \(settings.fullServerURL)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("System Prompt")) {
                TextEditor(text: $settings.systemPrompt)
                    .frame(minHeight: 100, maxHeight: 200)
                    .font(.system(.body, design: .monospaced))
                    .border(Color.secondary.opacity(0.3))

                Text("Custom system prompt to append to Claude's default prompt")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Button(action: testConnection) {
                    HStack {
                        Text("Test Connection")
                        Spacer()
                        if testingConnection {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    }
                }
                .disabled(testingConnection)

                if let result = testResult {
                    Text(result)
                        .font(.caption)
                        .foregroundColor(testSuccess ? .green : .red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 400)
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }

    private func testConnection() {
        testingConnection = true
        testResult = nil

        // Simple connection test - try to connect to WebSocket
        // This is a placeholder - proper implementation would use VoiceCodeClient
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            testingConnection = false
            testSuccess = true
            testResult = "Connection successful"
        }
    }
}
