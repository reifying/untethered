// AppSettings.swift
// Server configuration and app settings for macOS

import Foundation
import Combine
import AVFoundation

/// macOS-specific app settings
/// Note: This is a minimal implementation. iOS-specific features like
/// respectSilentMode and continuePlaybackWhenLocked are not needed on macOS.
class AppSettings: ObservableObject {
    /// Special identifier for "All Premium Voices" rotation mode
    static let allPremiumVoicesIdentifier = "com.voicecode.all-premium-voices"

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

    // MARK: - Voice Selection

    // Cache for voices to avoid repeated enumeration
    private static var cachedAvailableVoices: [(identifier: String, name: String, quality: String, language: String)]?
    private static var cachedPremiumVoices: [(identifier: String, name: String, quality: String, language: String)]?

    /// Pre-load voices asynchronously to avoid blocking the main thread later
    static func preloadVoices() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Self.availableVoices
            _ = Self.premiumVoices
        }
    }

    /// Get available voices sorted by quality (premium first)
    static var availableVoices: [(identifier: String, name: String, quality: String, language: String)] {
        if let cached = cachedAvailableVoices {
            return cached
        }

        let allVoices = AVSpeechSynthesisVoice.speechVoices()

        let voices = allVoices
            .filter {
                let lang = $0.language.lowercased()
                return lang.hasPrefix("en-") || lang == "en"
            }
            .filter { $0.quality != .default }
            .sorted { voice1, voice2 in
                let quality1 = voice1.quality.sortOrder
                let quality2 = voice2.quality.sortOrder
                if quality1 != quality2 {
                    return quality1 < quality2
                }
                return voice1.name < voice2.name
            }
            .map { voice in
                let qualityName = voice.quality.displayName
                let displayName: String
                if voice.name.lowercased().contains(qualityName.lowercased()) {
                    displayName = voice.name
                } else {
                    displayName = "\(voice.name) (\(qualityName))"
                }
                return (voice.identifier, displayName, qualityName, voice.language)
            }

        cachedAvailableVoices = voices
        return voices
    }

    /// Get only premium quality voices (for "All Premium Voices" rotation)
    static var premiumVoices: [(identifier: String, name: String, quality: String, language: String)] {
        if let cached = cachedPremiumVoices {
            return cached
        }

        let allVoices = AVSpeechSynthesisVoice.speechVoices()

        let voices = allVoices
            .filter {
                let lang = $0.language.lowercased()
                return lang.hasPrefix("en-") || lang == "en"
            }
            .filter { $0.quality == .premium }
            .sorted { $0.name < $1.name }
            .map { voice in
                (voice.identifier, voice.name, "Premium", voice.language)
            }

        cachedPremiumVoices = voices
        return voices
    }

    /// Compute a stable hash for a string that remains consistent across app launches
    private func stableHash(_ string: String) -> Int {
        var hash = 0
        for char in string.unicodeScalars {
            hash = hash &* 31 &+ Int(char.value)
        }
        return abs(hash)
    }

    /// Resolve the actual voice identifier to use for speech
    /// - Parameter workingDirectory: Optional working directory for deterministic voice rotation
    /// - Returns: Voice identifier to use, or nil for system default
    func resolveVoiceIdentifier(forWorkingDirectory workingDirectory: String? = nil) -> String? {
        guard let selected = selectedVoiceIdentifier else {
            return nil
        }

        // If not using "All Premium Voices" mode, return the selected voice directly
        guard selected == Self.allPremiumVoicesIdentifier else {
            return selected
        }

        // Get available premium voices
        let premiumVoices = Self.premiumVoices

        // No premium voices available - fall back to first available voice or nil
        guard !premiumVoices.isEmpty else {
            return Self.availableVoices.first?.identifier
        }

        // Only one premium voice - use it
        guard premiumVoices.count > 1 else {
            return premiumVoices.first?.identifier
        }

        // Multiple premium voices - rotate based on working directory hash
        guard let workingDirectory = workingDirectory else {
            return premiumVoices.first?.identifier
        }

        // Use stable hash of working directory to select voice
        let hashValue = stableHash(workingDirectory)
        let index = hashValue % premiumVoices.count
        return premiumVoices[index].identifier
    }
}

// MARK: - AVSpeechSynthesisVoiceQuality Extensions

extension AVSpeechSynthesisVoiceQuality {
    var displayName: String {
        switch self {
        case .default:
            return "Default"
        case .enhanced:
            return "Enhanced"
        case .premium:
            return "Premium"
        @unknown default:
            return "Unknown"
        }
    }

    var sortOrder: Int {
        switch self {
        case .premium:
            return 0
        case .enhanced:
            return 1
        case .default:
            return 2
        @unknown default:
            return 3
        }
    }
}
