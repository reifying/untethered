// AppSettings.swift
// Server configuration and app settings for macOS

import Foundation
import Combine
import AVFoundation
import Carbon.HIToolbox

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

    // MARK: - General Settings
    @Published var autoConnectOnLaunch: Bool {
        didSet {
            UserDefaults.standard.set(autoConnectOnLaunch, forKey: "autoConnectOnLaunch")
        }
    }

    @Published var showInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showInMenuBar, forKey: "showInMenuBar")
        }
    }

    // MARK: - Voice Settings
    @Published var speechRate: Float {
        didSet {
            UserDefaults.standard.set(speechRate, forKey: "speechRate")
        }
    }

    @Published var pushToTalkHotkey: String {
        didSet {
            UserDefaults.standard.set(pushToTalkHotkey, forKey: "pushToTalkHotkey")
        }
    }

    /// Hotkey key code (virtual key code from Carbon)
    @Published var hotkeyKeyCode: UInt32 {
        didSet {
            UserDefaults.standard.set(hotkeyKeyCode, forKey: "hotkeyKeyCode")
            updatePushToTalkHotkeyDescription()
        }
    }

    /// Hotkey modifiers (Carbon modifier flags: controlKey, optionKey, shiftKey, cmdKey)
    @Published var hotkeyModifiers: UInt32 {
        didSet {
            UserDefaults.standard.set(hotkeyModifiers, forKey: "hotkeyModifiers")
            updatePushToTalkHotkeyDescription()
        }
    }

    // MARK: - Session Settings
    @Published var defaultWorkingDirectory: String {
        didSet {
            UserDefaults.standard.set(defaultWorkingDirectory, forKey: "defaultWorkingDirectory")
        }
    }

    @Published var autoAddToQueue: Bool {
        didSet {
            UserDefaults.standard.set(autoAddToQueue, forKey: "autoAddToQueue")
        }
    }

    @Published var sessionRetentionDays: Int {
        didSet {
            UserDefaults.standard.set(sessionRetentionDays, forKey: "sessionRetentionDays")
        }
    }

    // MARK: - Advanced Settings
    @Published var debugLoggingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(debugLoggingEnabled, forKey: "debugLoggingEnabled")
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

        // General settings
        autoConnectOnLaunch = UserDefaults.standard.object(forKey: "autoConnectOnLaunch") as? Bool ?? true
        showInMenuBar = UserDefaults.standard.object(forKey: "showInMenuBar") as? Bool ?? true

        // Voice settings
        speechRate = UserDefaults.standard.object(forKey: "speechRate") as? Float ?? 0.5
        pushToTalkHotkey = UserDefaults.standard.string(forKey: "pushToTalkHotkey") ?? "⌃⌥V"

        // Hotkey settings - default: ⌃⌥V (Control + Option + V)
        hotkeyKeyCode = UserDefaults.standard.object(forKey: "hotkeyKeyCode") as? UInt32 ?? UInt32(kVK_ANSI_V)
        hotkeyModifiers = UserDefaults.standard.object(forKey: "hotkeyModifiers") as? UInt32 ?? UInt32(controlKey | optionKey)

        // Session settings
        defaultWorkingDirectory = UserDefaults.standard.string(forKey: "defaultWorkingDirectory") ?? ""
        autoAddToQueue = UserDefaults.standard.object(forKey: "autoAddToQueue") as? Bool ?? false
        sessionRetentionDays = UserDefaults.standard.object(forKey: "sessionRetentionDays") as? Int ?? 30

        // Advanced settings
        debugLoggingEnabled = UserDefaults.standard.object(forKey: "debugLoggingEnabled") as? Bool ?? false

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

        $defaultWorkingDirectory
            .dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: "defaultWorkingDirectory") }
            .store(in: &cancellables)

        $pushToTalkHotkey
            .dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: "pushToTalkHotkey") }
            .store(in: &cancellables)
    }

    // MARK: - Cache Management

    /// Log file location (read-only)
    var logFileLocation: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs")
            .appendingPathComponent("VoiceCode")
    }

    /// Clear cached data (voice caches, etc.)
    func clearCache() {
        Self.cachedAvailableVoices = nil
        Self.cachedPremiumVoices = nil
    }

    /// Reset all settings to their default values
    func resetToDefaults() {
        serverURL = ""
        serverPort = "8080"
        selectedVoiceIdentifier = nil
        recentSessionsLimit = 10
        notifyOnResponse = true
        resourceStorageLocation = ""
        queueEnabled = false
        priorityQueueEnabled = false
        systemPrompt = ""
        autoConnectOnLaunch = true
        showInMenuBar = true
        speechRate = 0.5
        pushToTalkHotkey = "⌃⌥V"
        hotkeyKeyCode = UInt32(kVK_ANSI_V)
        hotkeyModifiers = UInt32(controlKey | optionKey)
        defaultWorkingDirectory = ""
        autoAddToQueue = false
        sessionRetentionDays = 30
        debugLoggingEnabled = false
    }

    // MARK: - Hotkey Management

    /// Update the hotkey with a new key code and modifiers.
    /// This updates both the stored values and the display string.
    /// - Parameters:
    ///   - keyCode: The virtual key code (e.g., kVK_ANSI_V)
    ///   - modifiers: Carbon modifier flags (e.g., controlKey | optionKey)
    func updateHotkey(keyCode: UInt32, modifiers: UInt32) {
        hotkeyKeyCode = keyCode
        hotkeyModifiers = modifiers
        // Note: pushToTalkHotkey is updated automatically via updatePushToTalkHotkeyDescription()
    }

    /// Update the pushToTalkHotkey string based on current keyCode and modifiers
    private func updatePushToTalkHotkeyDescription() {
        var parts: [String] = []

        // Add modifiers in standard macOS order: ⌃⌥⇧⌘
        if hotkeyModifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if hotkeyModifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if hotkeyModifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if hotkeyModifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }

        parts.append(keyCodeToDisplayString(hotkeyKeyCode))
        pushToTalkHotkey = parts.joined()
    }

    /// Convert a virtual key code to a display string
    private func keyCodeToDisplayString(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Escape: return "Escape"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return "Key(\(keyCode))"
        }
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
