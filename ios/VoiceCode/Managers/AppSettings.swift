// AppSettings.swift
// Server configuration and app settings

import Foundation
import Combine
import AVFoundation

class AppSettings: ObservableObject {
    @Published var serverURL: String {
        didSet {
            UserDefaults.standard.set(serverURL, forKey: "serverURL")
        }
    }

    @Published var serverPort: String {
        didSet {
            UserDefaults.standard.set(serverPort, forKey: "serverPort")
        }
    }

    @Published var selectedVoiceIdentifier: String? {
        didSet {
            if let identifier = selectedVoiceIdentifier {
                UserDefaults.standard.set(identifier, forKey: "selectedVoiceIdentifier")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedVoiceIdentifier")
            }
        }
    }

    var fullServerURL: String {
        let cleanURL = serverURL.trimmingCharacters(in: .whitespaces)
        let cleanPort = serverPort.trimmingCharacters(in: .whitespaces)
        return "ws://\(cleanURL):\(cleanPort)"
    }

    // Get available voices sorted by quality (premium first)
    static var availableVoices: [(identifier: String, name: String, quality: String, language: String)] {
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

        return voices
    }

    init() {
        self.serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        self.serverPort = UserDefaults.standard.string(forKey: "serverPort") ?? "8080"
        self.selectedVoiceIdentifier = UserDefaults.standard.string(forKey: "selectedVoiceIdentifier")
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
