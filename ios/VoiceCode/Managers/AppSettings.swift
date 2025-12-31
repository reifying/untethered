// AppSettings.swift
// Server configuration and app settings

import Foundation
import Combine
import AVFoundation

class AppSettings: ObservableObject {
    /// Special identifier for "All Premium Voices" rotation mode
    static let allPremiumVoicesIdentifier = "com.voicecode.all-premium-voices"

    private let appGroupID = "group.com.910labs.untethered.resources"
    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }
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

    @Published var continuePlaybackWhenLocked: Bool {
        didSet {
            UserDefaults.standard.set(continuePlaybackWhenLocked, forKey: "continuePlaybackWhenLocked")
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
            sharedDefaults?.set(resourceStorageLocation, forKey: "resourceStorageLocation")
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

    @Published var respectSilentMode: Bool {
        didSet {
            UserDefaults.standard.set(respectSilentMode, forKey: "respectSilentMode")
        }
    }

    @Published var systemPrompt: String

    @Published var maxMessageSizeKB: Int {
        didSet {
            UserDefaults.standard.set(maxMessageSizeKB, forKey: "maxMessageSizeKB")
        }
    }

    var fullServerURL: String {
        let cleanURL = serverURL.trimmingCharacters(in: .whitespaces)
        let cleanPort = serverPort.trimmingCharacters(in: .whitespaces)
        return "ws://\(cleanURL):\(cleanPort)"
    }

    /// Returns true if the server has been configured (non-empty address)
    var isServerConfigured: Bool {
        !serverURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // Cache for voices to avoid blocking main thread
    private static var cachedAvailableVoices: [(identifier: String, name: String, quality: String, language: String)]?
    private static var cachedPremiumVoices: [(identifier: String, name: String, quality: String, language: String)]?

    /// Pre-load voices asynchronously to avoid blocking the main thread later
    static func preloadVoices() {
        DispatchQueue.global(qos: .userInitiated).async {
            // Trigger voice loading and caching
            _ = Self.availableVoices
            _ = Self.premiumVoices
            print("🎙️ Voices pre-loaded and cached")
        }
    }

    // Get available voices sorted by quality (premium first)
    static var availableVoices: [(identifier: String, name: String, quality: String, language: String)] {
        // Return cached value if available
        if let cached = cachedAvailableVoices {
            return cached
        }

        let allVoices = AVSpeechSynthesisVoice.speechVoices()

        // Debug: Print all available voices
        print("🎙️ Total voices available: \(allVoices.count)")
        for voice in allVoices.prefix(5) {
            print("  - \(voice.name) (\(voice.quality.displayName)) [\(voice.language)] - \(voice.identifier)")
        }

        let voices = allVoices
            // More flexible English filter - include en-US, en-GB, en-AU, etc.
            .filter {
                let lang = $0.language.lowercased()
                return lang.hasPrefix("en-") || lang == "en"
            }
            // Only show Premium and Enhanced voices (exclude default quality)
            .filter { $0.quality != .default }
            .sorted { voice1, voice2 in
                // Sort by quality: premium > enhanced > default
                let quality1 = voice1.quality.sortOrder
                let quality2 = voice2.quality.sortOrder
                if quality1 != quality2 {
                    return quality1 < quality2
                }
                // Then by name
                return voice1.name < voice2.name
            }
            .map { voice in
                let qualityName = voice.quality.displayName
                // Check if voice name already includes quality descriptor
                let displayName: String
                if voice.name.lowercased().contains(qualityName.lowercased()) {
                    // Name already has quality, don't duplicate
                    displayName = voice.name
                } else {
                    // Add quality descriptor
                    displayName = "\(voice.name) (\(qualityName))"
                }
                return (voice.identifier, displayName, qualityName, voice.language)
            }

        print("🎙️ Filtered English voices: \(voices.count)")
        for voice in voices.prefix(5) {
            print("  - \(voice.1)")
        }

        // Cache the result
        cachedAvailableVoices = voices
        return voices
    }

    /// Get only premium quality voices (for "All Premium Voices" rotation)
    static var premiumVoices: [(identifier: String, name: String, quality: String, language: String)] {
        // Return cached value if available
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

        // Cache the result
        cachedPremiumVoices = voices
        return voices
    }

    /// Compute a stable hash for a string that remains consistent across app launches
    /// - Parameter string: The string to hash
    /// - Returns: A non-negative integer hash value
    private func stableHash(_ string: String) -> Int {
        var hash = 0
        for char in string.unicodeScalars {
            hash = hash &* 31 &+ Int(char.value)
        }
        return abs(hash)
    }

    /// Resolve the actual voice identifier to use for speech
    /// - Parameters:
    ///   - workingDirectory: Optional working directory for deterministic voice rotation
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
            // No working directory provided - use first premium voice
            return premiumVoices.first?.identifier
        }

        // Use stable hash of working directory to select voice
        let hashValue = stableHash(workingDirectory)
        let index = hashValue % premiumVoices.count
        let selectedVoice = premiumVoices[index]
        print("🎙️ Voice rotation: project \(workingDirectory.split(separator: "/").last ?? "unknown") → \(selectedVoice.name) (index \(index) of \(premiumVoices.count))")
        return selectedVoice.identifier
    }

    init() {
        // Load initial values BEFORE setting up publishers to avoid triggering writes on launch
        self.serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        self.serverPort = UserDefaults.standard.string(forKey: "serverPort") ?? "8080"

        // On first launch, default to the first available premium voice
        if let savedVoice = UserDefaults.standard.string(forKey: "selectedVoiceIdentifier") {
            self.selectedVoiceIdentifier = savedVoice
        } else if let firstPremiumVoice = Self.availableVoices.first {
            self.selectedVoiceIdentifier = firstPremiumVoice.identifier
            UserDefaults.standard.set(firstPremiumVoice.identifier, forKey: "selectedVoiceIdentifier")
        } else {
            self.selectedVoiceIdentifier = nil
        }

        self.continuePlaybackWhenLocked = UserDefaults.standard.object(forKey: "continuePlaybackWhenLocked") as? Bool ?? true
        self.recentSessionsLimit = UserDefaults.standard.object(forKey: "recentSessionsLimit") as? Int ?? 5
        self.notifyOnResponse = UserDefaults.standard.object(forKey: "notifyOnResponse") as? Bool ?? true
        self.resourceStorageLocation = UserDefaults.standard.string(forKey: "resourceStorageLocation") ?? "~/Downloads"
        self.queueEnabled = UserDefaults.standard.object(forKey: "queueEnabled") as? Bool ?? false
        self.priorityQueueEnabled = UserDefaults.standard.object(forKey: "priorityQueueEnabled") as? Bool ?? false
        self.respectSilentMode = UserDefaults.standard.object(forKey: "respectSilentMode") as? Bool ?? true
        self.systemPrompt = UserDefaults.standard.string(forKey: "systemPrompt") ?? ""
        self.maxMessageSizeKB = UserDefaults.standard.object(forKey: "maxMessageSizeKB") as? Int ?? 200

        // Set up debounced publishers for text fields (serverURL and serverPort)
        // dropFirst() skips the initial value to avoid writing on init
        // Only save to UserDefaults after user stops typing for 0.5 seconds
        $serverURL
            .dropFirst()
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self = self else { return }
                UserDefaults.standard.set(value, forKey: "serverURL")
                self.sharedDefaults?.set(value, forKey: "serverURL")
            }
            .store(in: &cancellables)

        $serverPort
            .dropFirst()
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self = self else { return }
                UserDefaults.standard.set(value, forKey: "serverPort")
                self.sharedDefaults?.set(value, forKey: "serverPort")
            }
            .store(in: &cancellables)

        $systemPrompt
            .dropFirst()
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self = self else { return }
                UserDefaults.standard.set(value, forKey: "systemPrompt")
            }
            .store(in: &cancellables)

        // Sync settings to shared UserDefaults for share extension access
        syncToSharedDefaults()
    }

    /// Sync current settings to shared UserDefaults so share extension can access them
    private func syncToSharedDefaults() {
        sharedDefaults?.set(serverURL, forKey: "serverURL")
        sharedDefaults?.set(serverPort, forKey: "serverPort")
        sharedDefaults?.set(resourceStorageLocation, forKey: "resourceStorageLocation")
    }

    func testConnection(completion: @escaping (Bool, String) -> Void) {
        // Basic validation
        guard !serverURL.isEmpty else {
            completion(false, "Server address is required")
            return
        }

        guard !serverPort.isEmpty, let _ = Int(serverPort) else {
            completion(false, "Valid port number is required")
            return
        }

        // Attempt to connect to the WebSocket
        guard let url = URL(string: fullServerURL) else {
            completion(false, "Invalid URL format")
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        let task = URLSession.shared.webSocketTask(with: request)

        task.receive { result in
            switch result {
            case .success:
                task.cancel(with: .goingAway, reason: nil)
                DispatchQueue.main.async {
                    completion(true, "Connection successful!")
                }
            case .failure(let error):
                DispatchQueue.main.async {
                    completion(false, "Connection failed: \(error.localizedDescription)")
                }
            }
        }

        task.resume()

        // Set a timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            task.cancel(with: .goingAway, reason: nil)
            completion(false, "Connection timeout")
        }
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
