import UIKit
import Social
import UniformTypeIdentifiers
import MobileCoreServices

/// Share Extension view controller for handling file shares from other apps.
/// Saves shared files to App Group container for main app to process and upload.
class ShareViewController: UIViewController {

    // MARK: - Constants

    private let appGroupIdentifier = "group.com.travisbrown.untethered"

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        processSharedContent()
    }

    // MARK: - Content Processing

    private func processSharedContent() {
        guard let extensionContext = extensionContext,
              let inputItems = extensionContext.inputItems as? [NSExtensionItem] else {
            completeRequest(success: false, error: "No input items found")
            return
        }

        // Process first item with attachments
        for item in inputItems {
            guard let attachments = item.attachments else { continue }

            for provider in attachments {
                // Check if provider has file URL
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    handleFileURLProvider(provider)
                    return
                }
                // Check if provider has content (fallback for some apps)
                else if provider.hasItemConformingToTypeIdentifier(UTType.item.identifier) {
                    handleItemProvider(provider)
                    return
                }
            }
        }

        completeRequest(success: false, error: "No supported file attachments found")
    }

    private func handleFileURLProvider(_ provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] (item, error) in
            guard let self = self else { return }

            if let error = error {
                self.completeRequest(success: false, error: "Failed to load file: \(error.localizedDescription)")
                return
            }

            guard let url = item as? URL else {
                self.completeRequest(success: false, error: "Invalid file URL")
                return
            }

            self.saveFileToAppGroup(url: url, originalFilename: url.lastPathComponent)
        }
    }

    private func handleItemProvider(_ provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.item.identifier, options: nil) { [weak self] (item, error) in
            guard let self = self else { return }

            if let error = error {
                self.completeRequest(success: false, error: "Failed to load item: \(error.localizedDescription)")
                return
            }

            if let url = item as? URL {
                self.saveFileToAppGroup(url: url, originalFilename: url.lastPathComponent)
            } else {
                self.completeRequest(success: false, error: "Unsupported item type")
            }
        }
    }

    private func saveFileToAppGroup(url: URL, originalFilename: String) {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            completeRequest(success: false, error: "Failed to access App Group container")
            return
        }

        let pendingUploadsURL = containerURL.appendingPathComponent("pending-uploads", isDirectory: true)

        // Create pending-uploads directory if needed
        do {
            try FileManager.default.createDirectory(at: pendingUploadsURL, withIntermediateDirectories: true)
        } catch {
            completeRequest(success: false, error: "Failed to create pending-uploads directory: \(error.localizedDescription)")
            return
        }

        // Generate unique ID for this upload
        let uploadId = UUID().uuidString.lowercased()

        // Read file data
        let fileData: Data
        do {
            fileData = try Data(contentsOf: url)
        } catch {
            completeRequest(success: false, error: "Failed to read file: \(error.localizedDescription)")
            return
        }

        // Save file data
        let dataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).data")
        do {
            try fileData.write(to: dataFileURL)
        } catch {
            completeRequest(success: false, error: "Failed to write file data: \(error.localizedDescription)")
            return
        }

        // Save metadata
        let metadata: [String: Any] = [
            "id": uploadId,
            "filename": originalFilename,
            "size": fileData.count,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

        let metadataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).json")
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted)
            try jsonData.write(to: metadataFileURL)
        } catch {
            completeRequest(success: false, error: "Failed to write metadata: \(error.localizedDescription)")
            return
        }

        completeRequest(success: true, error: nil)
    }

    // MARK: - Completion

    private func completeRequest(success: Bool, error: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if let error = error {
                let alert = UIAlertController(
                    title: success ? "File Saved" : "Error",
                    message: success ? "File will be uploaded when you open the app" : error,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                    self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
                })
                self.present(alert, animated: true)
            } else {
                self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            }
        }
    }
}
