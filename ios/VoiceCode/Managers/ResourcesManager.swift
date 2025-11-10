import Foundation
import Combine

/// Manages file resources uploaded via Share Extension and synced with backend
class ResourcesManager: ObservableObject {
    private let appGroupIdentifier = "group.com.travisbrown.untethered"
    private let voiceCodeClient: VoiceCodeClient
    private let appSettings: AppSettings

    @Published var isProcessing = false
    @Published var pendingUploadCount = 0

    private var processTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(voiceCodeClient: VoiceCodeClient, appSettings: AppSettings = AppSettings()) {
        self.voiceCodeClient = voiceCodeClient
        self.appSettings = appSettings

        // Monitor connection state to process uploads when connected
        voiceCodeClient.$isConnected
            .sink { [weak self] isConnected in
                if isConnected {
                    self?.processPendingUploads()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Public Interface

    /// Process all pending uploads from the App Group container
    func processPendingUploads() {
        guard !isProcessing else {
            print("⏭️ [ResourcesManager] Already processing uploads, skipping")
            return
        }

        guard voiceCodeClient.isConnected else {
            print("⚠️ [ResourcesManager] Not connected, deferring upload processing")
            return
        }

        Task {
            await processUploadsAsync()
        }
    }

    /// Get count of pending uploads without processing them
    func updatePendingCount() {
        guard let pendingUploadsURL = getPendingUploadsDirectory() else {
            DispatchQueue.main.async {
                self.pendingUploadCount = 0
            }
            return
        }

        do {
            let metadataFiles = try FileManager.default.contentsOfDirectory(
                at: pendingUploadsURL,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }

            DispatchQueue.main.async {
                self.pendingUploadCount = metadataFiles.count
            }
        } catch {
            print("⚠️ [ResourcesManager] Failed to count pending uploads: \(error)")
            DispatchQueue.main.async {
                self.pendingUploadCount = 0
            }
        }
    }

    // MARK: - Internal Processing

    private func processUploadsAsync() async {
        await MainActor.run {
            self.isProcessing = true
        }

        defer {
            Task { @MainActor in
                self.isProcessing = false
            }
        }

        guard let pendingUploadsURL = getPendingUploadsDirectory() else {
            print("❌ [ResourcesManager] Failed to access App Group container")
            return
        }

        print("📂 [ResourcesManager] Checking for pending uploads at: \(pendingUploadsURL.path)")

        // Find all metadata files
        let metadataFiles: [URL]
        do {
            metadataFiles = try FileManager.default.contentsOfDirectory(
                at: pendingUploadsURL,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }
        } catch {
            print("❌ [ResourcesManager] Failed to list pending uploads: \(error)")
            return
        }

        guard !metadataFiles.isEmpty else {
            print("✅ [ResourcesManager] No pending uploads found")
            await MainActor.run {
                self.pendingUploadCount = 0
            }
            return
        }

        print("📤 [ResourcesManager] Found \(metadataFiles.count) pending upload(s)")
        await MainActor.run {
            self.pendingUploadCount = metadataFiles.count
        }

        // Process each upload
        for metadataURL in metadataFiles {
            await processUpload(metadataURL: metadataURL, pendingUploadsURL: pendingUploadsURL)
        }

        // Update final count
        updatePendingCount()
    }

    private func processUpload(metadataURL: URL, pendingUploadsURL: URL) async {
        let uploadId = metadataURL.deletingPathExtension().lastPathComponent

        print("📄 [ResourcesManager] Processing upload: \(uploadId)")

        // Read metadata
        let metadata: [String: Any]
        do {
            let metadataData = try Data(contentsOf: metadataURL)
            guard let json = try JSONSerialization.jsonObject(with: metadataData) as? [String: Any] else {
                print("❌ [ResourcesManager] Invalid metadata format for upload: \(uploadId)")
                try? FileManager.default.removeItem(at: metadataURL)
                return
            }
            metadata = json
        } catch {
            print("❌ [ResourcesManager] Failed to read metadata for upload \(uploadId): \(error)")
            try? FileManager.default.removeItem(at: metadataURL)
            return
        }

        guard let filename = metadata["filename"] as? String else {
            print("❌ [ResourcesManager] Missing filename in metadata for upload: \(uploadId)")
            try? FileManager.default.removeItem(at: metadataURL)
            return
        }

        // Read file data
        let dataURL = pendingUploadsURL.appendingPathComponent("\(uploadId).data")
        let fileData: Data
        do {
            fileData = try Data(contentsOf: dataURL)
        } catch {
            print("❌ [ResourcesManager] Failed to read data file for upload \(uploadId): \(error)")
            // Clean up metadata if data file is missing
            try? FileManager.default.removeItem(at: metadataURL)
            return
        }

        // Base64 encode
        let base64Content = fileData.base64EncodedString()

        print("📤 [ResourcesManager] Uploading file: \(filename) (\(fileData.count) bytes)")

        // Send upload_file message
        let success = await sendUploadMessage(filename: filename, content: base64Content)

        if success {
            // Delete both files on success
            do {
                try FileManager.default.removeItem(at: metadataURL)
                try FileManager.default.removeItem(at: dataURL)
                print("✅ [ResourcesManager] Upload successful, cleaned up: \(uploadId)")
            } catch {
                print("⚠️ [ResourcesManager] Upload successful but failed to clean up files: \(error)")
            }
        } else {
            print("⚠️ [ResourcesManager] Upload failed, will retry later: \(uploadId)")
        }
    }

    private func sendUploadMessage(filename: String, content: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            let message: [String: Any] = [
                "type": "upload_file",
                "filename": filename,
                "content": content,
                "storage_location": appSettings.resourceStorageLocation
            ]

            print("📨 [ResourcesManager] Sending upload_file message for: \(filename) to: \(appSettings.resourceStorageLocation)")
            voiceCodeClient.sendMessage(message)

            // For MVP, assume success after sending
            // TODO: Implement proper acknowledgment tracking in future
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                continuation.resume(returning: true)
            }
        }
    }

    // MARK: - Helpers

    private func getPendingUploadsDirectory() -> URL? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            print("❌ [ResourcesManager] Failed to access App Group container: \(appGroupIdentifier)")
            return nil
        }

        return containerURL.appendingPathComponent("pending-uploads", isDirectory: true)
    }
}
