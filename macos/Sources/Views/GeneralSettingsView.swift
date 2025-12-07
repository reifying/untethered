// GeneralSettingsView.swift
// General settings tab for server configuration

import SwiftUI
import UntetheredCore

struct GeneralSettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var showingDirectoryPicker = false
    @State private var defaultWorkingDirectory: String = ""

    var body: some View {
        Form {
            Section(header: Text("Server Configuration")) {
                HStack {
                    Text("Server Address:")
                        .frame(width: 120, alignment: .trailing)
                    TextField("localhost", text: $settings.serverURL)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text("Port:")
                        .frame(width: 120, alignment: .trailing)
                    TextField("8080", text: $settings.serverPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }

                HStack {
                    Spacer().frame(width: 120)
                    Text("ws://\(settings.serverURL):\(settings.serverPort)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section(header: Text("Defaults")) {
                HStack {
                    Text("Working Directory:")
                        .frame(width: 120, alignment: .trailing)
                    TextField("~/", text: $defaultWorkingDirectory)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                    Button("Choose...") {
                        showDirectoryPicker()
                    }
                }
                HStack {
                    Spacer().frame(width: 120)
                    Text("Default directory for new sessions")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .onAppear {
            // Load default working directory
            defaultWorkingDirectory = UserDefaults.standard.string(forKey: "defaultWorkingDirectory") ?? NSHomeDirectory()
        }
    }

    private func showDirectoryPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: defaultWorkingDirectory)

        panel.begin { response in
            if response == .OK, let url = panel.url {
                defaultWorkingDirectory = url.path
                UserDefaults.standard.set(url.path, forKey: "defaultWorkingDirectory")
            }
        }
    }
}
