// AdvancedSettingsView.swift
// Advanced settings tab for system prompt and debugging

import SwiftUI
import UntetheredCore

struct AdvancedSettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var showingClearCacheAlert = false
    @Environment(\.managedObjectContext) private var viewContext

    var body: some View {
        Form {
            Section(header: Text("System Prompt")) {
                VStack(alignment: .leading) {
                    Text("Custom system prompt (appended to Claude's default):")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextEditor(text: $settings.systemPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 120)
                        .border(Color.secondary.opacity(0.2))

                    Text("Leave empty to use default system prompt only")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section(header: Text("Debug")) {
                Toggle("Enable Debug Logging", isOn: .constant(false))
                    .disabled(true)
                Text("Verbose logging (not yet implemented)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Data")) {
                Button("Clear Message Cache") {
                    showingClearCacheAlert = true
                }
                Text("Remove all cached messages from local storage")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("About")) {
                HStack {
                    Text("Version:")
                        .foregroundColor(.secondary)
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
                }

                HStack {
                    Text("Build:")
                        .foregroundColor(.secondary)
                    Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")
                }
            }
        }
        .padding()
        .alert("Clear Message Cache?", isPresented: $showingClearCacheAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                clearMessageCache()
            }
        } message: {
            Text("This will remove all cached messages from local storage. This cannot be undone.")
        }
    }

    private func clearMessageCache() {
        let fetchRequest = CDMessage.fetchRequest()
        fetchRequest.includesPropertyValues = false

        do {
            let messages = try viewContext.fetch(fetchRequest)
            for message in messages {
                viewContext.delete(message)
            }
            try viewContext.save()
            print("Message cache cleared: \(messages.count) messages deleted")
        } catch {
            print("Failed to clear message cache: \(error)")
        }
    }
}
