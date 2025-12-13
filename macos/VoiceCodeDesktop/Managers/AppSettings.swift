// AppSettings.swift
// Server configuration and app settings for macOS

import Foundation
import Combine

/// macOS-specific app settings
/// Note: This is a minimal implementation. iOS-specific features like
/// respectSilentMode and continuePlaybackWhenLocked are not needed on macOS.
class AppSettings: ObservableObject {
    private var cancellables = Set<AnyCancellable>()

    @Published var serverURL: String
    @Published var serverPort: String

    @Published var selectedVoiceIdentifier: String? {
        didSet {
            if let identifier = selectedVoiceIdentifier {
                UserDefaults.standard.set(identifier, forKey: "selectedVoiceIdentifier")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedVoiceIdentifier")
            }
        }
    }

    @Published var recentSessionsLimit: Int {
        didSet {
            UserDefaults.standard.set(recentSessionsLimit, forKey: "recentSessionsLimit")
        }
    }

    @Published var notifyOnResponse: Bool {
        didSet {
            UserDefaults.standard.set(notifyOnResponse, forKey: "notifyOnResponse")
        }
    }

    @Published var resourceStorageLocation: String {
        didSet {
            UserDefaults.standard.set(resourceStorageLocation, forKey: "resourceStorageLocation")
        }
    }

    @Published var queueEnabled: Bool {
        didSet {
            UserDefaults.standard.set(queueEnabled, forKey: "queueEnabled")
        }
    }

    @Published var priorityQueueEnabled: Bool {
        didSet {
            UserDefaults.standard.set(priorityQueueEnabled, forKey: "priorityQueueEnabled")
        }
    }

    @Published var systemPrompt: String

    var fullServerURL: String {
        let cleanURL = serverURL.trimmingCharacters(in: .whitespaces)
        let cleanPort = serverPort.trimmingCharacters(in: .whitespaces)
        return "ws://\(cleanURL):\(cleanPort)"
    }

    /// Returns true if the server has been configured (non-empty address)
    var isServerConfigured: Bool {
        !serverURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    init() {
        // Load from UserDefaults with defaults
        serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        serverPort = UserDefaults.standard.string(forKey: "serverPort") ?? "8080"
        selectedVoiceIdentifier = UserDefaults.standard.string(forKey: "selectedVoiceIdentifier")
        recentSessionsLimit = UserDefaults.standard.object(forKey: "recentSessionsLimit") as? Int ?? 10
        notifyOnResponse = UserDefaults.standard.object(forKey: "notifyOnResponse") as? Bool ?? true
        resourceStorageLocation = UserDefaults.standard.string(forKey: "resourceStorageLocation") ?? ""
        queueEnabled = UserDefaults.standard.object(forKey: "queueEnabled") as? Bool ?? false
        priorityQueueEnabled = UserDefaults.standard.object(forKey: "priorityQueueEnabled") as? Bool ?? false
        systemPrompt = UserDefaults.standard.string(forKey: "systemPrompt") ?? ""

        // Set up observers to persist changes
        setupPersistence()
    }

    private func setupPersistence() {
        $serverURL
            .dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: "serverURL") }
            .store(in: &cancellables)

        $serverPort
            .dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: "serverPort") }
            .store(in: &cancellables)

        $systemPrompt
            .dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: "systemPrompt") }
            .store(in: &cancellables)
    }
}
