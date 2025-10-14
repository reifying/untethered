// AppSettings.swift
// Server configuration and app settings

import Foundation
import Combine

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

    var fullServerURL: String {
        let cleanURL = serverURL.trimmingCharacters(in: .whitespaces)
        let cleanPort = serverPort.trimmingCharacters(in: .whitespaces)
        return "ws://\(cleanURL):\(cleanPort)"
    }

    init() {
        self.serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        self.serverPort = UserDefaults.standard.string(forKey: "serverPort") ?? "8080"
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
