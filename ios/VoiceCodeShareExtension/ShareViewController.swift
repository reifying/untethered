import UIKit
import UniformTypeIdentifiers
import MobileCoreServices
import Security

/// Share Extension view controller for handling file shares from other apps.
/// Uploads files immediately to backend server via HTTP POST with Bearer token authentication.
class ShareViewController: UIViewController {

    // MARK: - Constants

    private let appGroupIdentifier = "group.com.910labs.untethered.resources"
    private let uploadTimeout: TimeInterval = 60.0 // 60 second timeout for uploads

    // MARK: - Keychain Configuration

    /// Keychain service identifier (matches main app's KeychainManager)
    private let keychainService = "dev.910labs.voice-code"
    /// Keychain account identifier (matches main app's KeychainManager)
    private let keychainAccount = "api-key"

    // MARK: - Debug UI

    private var debugLabel: UILabel!
    private var debugTextView: UITextView!
    private var debugLog: [String] = []

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupDebugUI()
        logDebug("viewDidLoad called")
        processSharedContent()
    }

    private func setupDebugUI() {
        view.backgroundColor = .systemBackground

        // Title label
        debugLabel = UILabel()
        debugLabel.text = "Share Extension Debug"
        debugLabel.font = .boldSystemFont(ofSize: 18)
        debugLabel.textAlignment = .center
        debugLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(debugLabel)

        // Debug text view
        debugTextView = UITextView()
        debugTextView.isEditable = false
        debugTextView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        debugTextView.backgroundColor = .secondarySystemBackground
        debugTextView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(debugTextView)

        NSLayoutConstraint.activate([
            debugLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            debugLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            debugLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            debugTextView.topAnchor.constraint(equalTo: debugLabel.bottomAnchor, constant: 20),
            debugTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            debugTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            debugTextView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20)
        ])
    }

    private func logDebug(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logEntry = "[\(timestamp)] \(message)"
        debugLog.append(logEntry)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.debugTextView.text = self.debugLog.joined(separator: "\n")

            // Auto-scroll to bottom
            let bottom = NSRange(location: self.debugTextView.text.count, length: 0)
            self.debugTextView.scrollRangeToVisible(bottom)
        }

        // Also log to console
        print("[ShareExtension] \(logEntry)")
    }

    // MARK: - Keychain Access

    /// Retrieve API key from Keychain.
    /// Uses the same service/account as the main app's KeychainManager.
    /// - Returns: The API key if found, nil otherwise
    private func retrieveAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }

        return key
    }

    // MARK: - Content Processing

    private func processSharedContent() {
        logDebug("processSharedContent called")

        guard let extensionContext = extensionContext else {
            logDebug("ERROR: No extensionContext")
            completeRequest(success: false, error: "No extension context", serverPath: nil)
            return
        }

        guard let inputItems = extensionContext.inputItems as? [NSExtensionItem] else {
            logDebug("ERROR: No input items or wrong type")
            completeRequest(success: false, error: "No input items found", serverPath: nil)
            return
        }

        logDebug("Found \(inputItems.count) input items")

        // Process first item with attachments
        for (itemIndex, item) in inputItems.enumerated() {
            logDebug("Processing item \(itemIndex + 1)")

            guard let attachments = item.attachments else {
                logDebug("Item \(itemIndex + 1) has no attachments")
                continue
            }

            logDebug("Item \(itemIndex + 1) has \(attachments.count) attachments")

            for (providerIndex, provider) in attachments.enumerated() {
                logDebug("Checking provider \(providerIndex + 1)")
                logDebug("Provider registered types: \(provider.registeredTypeIdentifiers.joined(separator: ", "))")

                // Check if provider has file URL
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    logDebug("Provider \(providerIndex + 1) matches fileURL")
                    handleFileURLProvider(provider)
                    return
                }
                // Check for plain text (crash logs, diagnostics)
                else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    logDebug("Provider \(providerIndex + 1) matches plainText")
                    handleTextProvider(provider)
                    return
                }
                // Check for data
                else if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
                    logDebug("Provider \(providerIndex + 1) matches data")
                    handleDataProvider(provider)
                    return
                }
                // Check if provider has content (fallback for some apps)
                else if provider.hasItemConformingToTypeIdentifier(UTType.item.identifier) {
                    logDebug("Provider \(providerIndex + 1) matches item")
                    handleItemProvider(provider)
                    return
                }
            }
        }

        logDebug("ERROR: No supported content found")
        completeRequest(success: false, error: "No supported content found", serverPath: nil)
    }

    private func handleFileURLProvider(_ provider: NSItemProvider) {
        logDebug("handleFileURLProvider: Loading file URL...")
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] (item, error) in
            guard let self = self else { return }

            if let error = error {
                self.logDebug("ERROR: Failed to load file: \(error.localizedDescription)")
                self.completeRequest(success: false, error: "Failed to load file: \(error.localizedDescription)", serverPath: nil)
                return
            }

            guard let url = item as? URL else {
                self.logDebug("ERROR: Item is not a URL, type: \(type(of: item))")
                self.completeRequest(success: false, error: "Invalid file URL", serverPath: nil)
                return
            }

            self.logDebug("File URL loaded: \(url.path)")
            self.uploadFile(url: url, originalFilename: url.lastPathComponent)
        }
    }

    private func handleTextProvider(_ provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] (item, error) in
            guard let self = self else { return }

            if let error = error {
                self.completeRequest(success: false, error: "Failed to load text: \(error.localizedDescription)", serverPath: nil)
                return
            }

            guard let text = item as? String else {
                self.completeRequest(success: false, error: "Invalid text content", serverPath: nil)
                return
            }

            // Save text as a .txt file
            guard let data = text.data(using: .utf8) else {
                self.completeRequest(success: false, error: "Failed to encode text", serverPath: nil)
                return
            }

            self.uploadData(data: data, filename: "crash-report.txt")
        }
    }

    private func handleDataProvider(_ provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.data.identifier, options: nil) { [weak self] (item, error) in
            guard let self = self else { return }

            if let error = error {
                self.completeRequest(success: false, error: "Failed to load data: \(error.localizedDescription)", serverPath: nil)
                return
            }

            if let data = item as? Data {
                self.uploadData(data: data, filename: "shared-content.dat")
            } else if let url = item as? URL {
                self.uploadFile(url: url, originalFilename: url.lastPathComponent)
            } else {
                self.completeRequest(success: false, error: "Unsupported data type", serverPath: nil)
            }
        }
    }

    private func handleItemProvider(_ provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.item.identifier, options: nil) { [weak self] (item, error) in
            guard let self = self else { return }

            if let error = error {
                self.completeRequest(success: false, error: "Failed to load item: \(error.localizedDescription)", serverPath: nil)
                return
            }

            if let url = item as? URL {
                self.uploadFile(url: url, originalFilename: url.lastPathComponent)
            } else {
                self.completeRequest(success: false, error: "Unsupported item type", serverPath: nil)
            }
        }
    }

    // MARK: - HTTP Upload

    private func uploadFile(url: URL, originalFilename: String) {
        logDebug("uploadFile: Reading file at \(url.path)")
        logDebug("File size: \(url.fileSize() ?? "unknown")")

        // Read file data
        let fileData: Data
        do {
            fileData = try Data(contentsOf: url)
            logDebug("File read successfully: \(fileData.count) bytes")
        } catch {
            logDebug("ERROR: Failed to read file: \(error.localizedDescription)")
            completeRequest(success: false, error: "Failed to read file: \(error.localizedDescription)", serverPath: nil)
            return
        }

        uploadData(data: fileData, filename: originalFilename)
    }

    private func uploadData(data: Data, filename: String) {
        logDebug("uploadData: Starting upload for \(filename) (\(data.count) bytes)")

        // Retrieve API key from Keychain for authentication
        guard let apiKey = retrieveAPIKey() else {
            logDebug("ERROR: API key not found in Keychain")
            completeRequest(
                success: false,
                error: "API key not configured. Please open the main app and set up authentication in Settings.",
                serverPath: nil
            )
            return
        }
        logDebug("API key retrieved from Keychain")

        // Get server settings from UserDefaults (shared via App Group)
        let sharedDefaults = UserDefaults(suiteName: appGroupIdentifier)
        logDebug("App Group identifier: \(appGroupIdentifier)")

        let serverURL = sharedDefaults?.string(forKey: "serverURL")
        let serverPort = sharedDefaults?.string(forKey: "serverPort")
        let resourceStorageLocation = sharedDefaults?.string(forKey: "resourceStorageLocation") ?? "~/Downloads"

        logDebug("Server URL from defaults: \(serverURL ?? "nil")")
        logDebug("Server Port from defaults: \(serverPort ?? "nil")")
        logDebug("Storage location from defaults: \(resourceStorageLocation)")

        guard let serverURL = serverURL,
              let serverPort = serverPort,
              !serverURL.isEmpty,
              !serverPort.isEmpty else {
            logDebug("ERROR: Server not configured")
            completeRequest(success: false, error: "Server not configured. Please open the main app and configure server settings.", serverPath: nil)
            return
        }

        // Construct HTTP upload URL
        let uploadURLString = "http://\(serverURL):\(serverPort)/upload"
        logDebug("Upload URL: \(uploadURLString)")

        guard let uploadURL = URL(string: uploadURLString) else {
            logDebug("ERROR: Invalid server URL")
            completeRequest(success: false, error: "Invalid server URL", serverPath: nil)
            return
        }

        // Prepare JSON payload
        logDebug("Encoding file as base64...")
        let base64Content = data.base64EncodedString()
        logDebug("Base64 encoded: \(base64Content.count) characters")

        let payload: [String: Any] = [
            "filename": filename,
            "content": base64Content,
            "storage_location": resourceStorageLocation
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            logDebug("ERROR: Failed to encode JSON payload")
            completeRequest(success: false, error: "Failed to encode upload request", serverPath: nil)
            return
        }

        logDebug("JSON payload size: \(jsonData.count) bytes")

        // Create HTTP POST request with Bearer token authentication
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = jsonData
        request.timeoutInterval = uploadTimeout

        logDebug("Sending HTTP POST request with Bearer authentication...")

        // Perform upload
        let task = URLSession.shared.dataTask(with: request) { [weak self] (data, response, error) in
            guard let self = self else { return }

            if let error = error {
                self.logDebug("ERROR: Upload failed: \(error.localizedDescription)")
                self.completeRequest(success: false, error: "Upload failed: \(error.localizedDescription)", serverPath: nil)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                self.logDebug("ERROR: Response is not HTTPURLResponse")
                self.completeRequest(success: false, error: "Invalid server response", serverPath: nil)
                return
            }

            self.logDebug("HTTP response status: \(httpResponse.statusCode)")

            // Handle 401 Unauthorized specifically
            if httpResponse.statusCode == 401 {
                self.logDebug("ERROR: Authentication failed (401 Unauthorized)")
                self.completeRequest(
                    success: false,
                    error: "Authentication failed. Please verify your API key in the main app Settings.",
                    serverPath: nil
                )
                return
            }

            guard let data = data else {
                self.logDebug("ERROR: No response data")
                self.completeRequest(success: false, error: "No response data", serverPath: nil)
                return
            }

            self.logDebug("Response data: \(data.count) bytes")

            // Try to log raw response for debugging
            if let responseString = String(data: data, encoding: .utf8) {
                self.logDebug("Response body: \(responseString)")
            }

            // Parse response
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.logDebug("ERROR: Failed to parse JSON response")
                self.completeRequest(success: false, error: "Invalid response format", serverPath: nil)
                return
            }

            self.logDebug("JSON parsed successfully")

            if httpResponse.statusCode == 200, let success = json["success"] as? Bool, success {
                // Success - extract server path
                let serverPath = json["path"] as? String ?? "Unknown location"
                self.logDebug("SUCCESS: File uploaded to \(serverPath)")
                self.completeRequest(success: true, error: nil, serverPath: serverPath)
            } else {
                // Error response
                let errorMessage = json["error"] as? String ?? "Unknown error"
                self.logDebug("ERROR: Server returned error: \(errorMessage)")
                self.completeRequest(success: false, error: errorMessage, serverPath: nil)
            }
        }

        task.resume()
        logDebug("Upload task started")
    }

    // MARK: - Completion

    private func completeRequest(success: Bool, error: String?, serverPath: String?) {
        logDebug("completeRequest called - success: \(success)")
        if let error = error {
            logDebug("Error message: \(error)")
        }
        if let path = serverPath {
            logDebug("Server path: \(path)")
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            let message: String
            if success, let path = serverPath {
                message = "File location:\n\(path)\n\nTap to copy path"
            } else {
                message = error ?? "Unknown error"
            }

            let alert = UIAlertController(
                title: success ? "Upload Complete" : "Upload Failed",
                message: message,
                preferredStyle: .alert
            )

            if success, let path = serverPath {
                // Add copy button for successful uploads
                alert.addAction(UIAlertAction(title: "Copy Path", style: .default) { _ in
                    self.logDebug("Copy Path tapped")
                    UIPasteboard.general.string = path
                    // Show brief confirmation, then close
                    let confirmAlert = UIAlertController(title: "Copied!", message: nil, preferredStyle: .alert)
                    self.present(confirmAlert, animated: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        confirmAlert.dismiss(animated: true) {
                            self.logDebug("Extension completing")
                            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
                        }
                    }
                })
            } else {
                // Add copy button for error messages
                alert.addAction(UIAlertAction(title: "Copy Error", style: .default) { _ in
                    self.logDebug("Copy Error tapped")
                    UIPasteboard.general.string = message
                    self.showCopiedConfirmation(message: "Error copied to clipboard")
                })
            }

            // Add copy debug logs button
            alert.addAction(UIAlertAction(title: "Copy Debug Logs", style: .default) { _ in
                self.logDebug("Copy Debug Logs tapped")
                let fullLog = self.debugLog.joined(separator: "\n")
                UIPasteboard.general.string = fullLog
                self.showCopiedConfirmation(message: "Debug logs copied to clipboard")
            })

            alert.addAction(UIAlertAction(title: "Done", style: success ? .cancel : .default) { _ in
                self.logDebug("Done tapped - extension completing")
                self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            })

            self.logDebug("Presenting completion alert")
            self.present(alert, animated: true)
        }
    }

    private func showCopiedConfirmation(message: String) {
        let confirmAlert = UIAlertController(title: "Copied!", message: message, preferredStyle: .alert)
        self.present(confirmAlert, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            confirmAlert.dismiss(animated: true)
        }
    }
}

// MARK: - URL Extension for File Size

extension URL {
    func fileSize() -> String? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            if let size = attributes[.size] as? Int64 {
                return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            }
        } catch {
            return nil
        }
        return nil
    }
}
