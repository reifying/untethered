import Foundation
import Combine

/// Manages file resources uploaded via Share Extension and synced with backend
class ResourcesManager: ObservableObject {
    private let appGroupIdentifier = "group.com.910labs.untethered.resources"
    private let voiceCodeClient: VoiceCodeClient
    private let appSettings: AppSettings

    @Published var isProcessing = false
    @Published var pendingUploadCount = 0
    @Published var resources: [Resource] = []
    @Published var isLoadingResources = false

    private var processTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var pendingAcknowledgments: [String: (Bool) -> Void] = [:] // uploadId -> completion handler

    init(voiceCodeClient: VoiceCodeClient, appSettings: AppSettings = AppSettings()) {
        self.voiceCodeClient = voiceCodeClient
        self.appSettings = appSettings

        // Monitor connection state to process uploads when connected
        voiceCodeClient.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                if isConnected {
                    self?.processPendingUploads()
                }
            }
            .store(in: &cancellables)

        // Monitor file upload responses
        voiceCodeClient.$fileUploadResponse
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] response in
                self?.handleUploadResponse(filename: response.filename, success: response.success)
            }
            .store(in: &cancellables)

        // Monitor resources list updates
        voiceCodeClient.$resourcesList
            .receive(on: DispatchQueue.main)
            .sink { [weak self] resourcesList in
                self?.resources = resourcesList
                self?.isLoadingResources = false
                LogManager.shared.log("Resources list updated: \(resourcesList.count) resources", category: "ResourcesManager")
            }
            .store(in: &cancellables)
    }

    // MARK: - Public Interface

    /// Request list of resources from backend
    func listResources() {
        guard voiceCodeClient.isConnected else {
            print("⚠️ [ResourcesManager] Not connected, cannot list resources")
            LogManager.shared.log("Not connected, cannot list resources", category: "ResourcesManager")
            return
        }

        isLoadingResources = true
        LogManager.shared.log("Requesting resources list", category: "ResourcesManager")
        voiceCodeClient.listResources(storageLocation: appSettings.resourceStorageLocation)
    }

    /// Delete a resource from backend
    func deleteResource(_ resource: Resource) {
        guard voiceCodeClient.isConnected else {
            print("⚠️ [ResourcesManager] Not connected, cannot delete resource")
            LogManager.shared.log("Not connected, cannot delete resource", category: "ResourcesManager")
            return
        }

        LogManager.shared.log("Deleting resource: \(resource.filename)", category: "ResourcesManager")
        voiceCodeClient.deleteResource(filename: resource.filename, storageLocation: appSettings.resourceStorageLocation)
    }

    /// Process all pending uploads from the App Group container
    func processPendingUploads() {
        guard !isProcessing else {
            print("⏭️ [ResourcesManager] Already processing uploads, skipping")
            LogManager.shared.log("Already processing uploads, skipping", category: "ResourcesManager")
            return
        }

        guard voiceCodeClient.isConnected else {
            print("⚠️ [ResourcesManager] Not connected, deferring upload processing")
            LogManager.shared.log("Not connected, deferring upload processing", category: "ResourcesManager")
            return
        }

        LogManager.shared.log("Starting upload processing", category: "ResourcesManager")
        Task {
            await processUploadsAsync()
        }
    }

    /// Get count of pending uploads without processing them
    func updatePendingCount() {
        guard let pendingUploadsURL = getPendingUploadsDirectory() else {
            LogManager.shared.log("Failed to get pending uploads directory", category: "ResourcesManager")
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

            LogManager.shared.log("Updated pending count: \(metadataFiles.count)", category: "ResourcesManager")
            DispatchQueue.main.async {
                self.pendingUploadCount = metadataFiles.count
            }
        } catch {
            print("⚠️ [ResourcesManager] Failed to count pending uploads: \(error)")
            LogManager.shared.log("Failed to count pending uploads: \(error)", category: "ResourcesManager")
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
        LogManager.shared.log("Set isProcessing = true", category: "ResourcesManager")

        defer {
            Task { @MainActor in
                self.isProcessing = false
                LogManager.shared.log("Set isProcessing = false", category: "ResourcesManager")
            }
        }

        guard let pendingUploadsURL = getPendingUploadsDirectory() else {
            print("❌ [ResourcesManager] Failed to access App Group container")
            LogManager.shared.log("Failed to access App Group container", category: "ResourcesManager")
            return
        }

        print("📂 [ResourcesManager] Checking for pending uploads at: \(pendingUploadsURL.path)")
        LogManager.shared.log("Checking for pending uploads at: \(pendingUploadsURL.path)", category: "ResourcesManager")

        // Find all metadata files
        let metadataFiles: [URL]
        do {
            metadataFiles = try FileManager.default.contentsOfDirectory(
                at: pendingUploadsURL,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }
        } catch {
            print("❌ [ResourcesManager] Failed to list pending uploads: \(error)")
            LogManager.shared.log("Failed to list pending uploads: \(error)", category: "ResourcesManager")
            return
        }

        guard !metadataFiles.isEmpty else {
            print("✅ [ResourcesManager] No pending uploads found")
            LogManager.shared.log("No pending uploads found", category: "ResourcesManager")
            await MainActor.run {
                self.pendingUploadCount = 0
            }
            return
        }

        print("📤 [ResourcesManager] Found \(metadataFiles.count) pending upload(s)")
        LogManager.shared.log("Found \(metadataFiles.count) pending upload(s)", category: "ResourcesManager")
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
        LogManager.shared.log("Processing upload: \(uploadId)", category: "ResourcesManager")

        // Read metadata
        let metadata: [String: Any]
        do {
            let metadataData = try Data(contentsOf: metadataURL)
            guard let json = try JSONSerialization.jsonObject(with: metadataData) as? [String: Any] else {
                print("❌ [ResourcesManager] Invalid metadata format for upload: \(uploadId)")
                LogManager.shared.log("Invalid metadata format for upload: \(uploadId)", category: "ResourcesManager")
                try? FileManager.default.removeItem(at: metadataURL)
                return
            }
            metadata = json
        } catch {
            print("❌ [ResourcesManager] Failed to read metadata for upload \(uploadId): \(error)")
            LogManager.shared.log("Failed to read metadata for upload \(uploadId): \(error)", category: "ResourcesManager")
            try? FileManager.default.removeItem(at: metadataURL)
            return
        }

        guard let filename = metadata["filename"] as? String else {
            print("❌ [ResourcesManager] Missing filename in metadata for upload: \(uploadId)")
            LogManager.shared.log("Missing filename in metadata for upload: \(uploadId)", category: "ResourcesManager")
            try? FileManager.default.removeItem(at: metadataURL)
            return
        }

        LogManager.shared.log("Read metadata for file: \(filename)", category: "ResourcesManager")

        // Read file data
        let dataURL = pendingUploadsURL.appendingPathComponent("\(uploadId).data")
        let fileData: Data
        do {
            fileData = try Data(contentsOf: dataURL)
        } catch {
            print("❌ [ResourcesManager] Failed to read data file for upload \(uploadId): \(error)")
            LogManager.shared.log("Failed to read data file for upload \(uploadId): \(error)", category: "ResourcesManager")
            // Clean up metadata if data file is missing
            try? FileManager.default.removeItem(at: metadataURL)
            return
        }

        // Base64 encode
        let base64Content = fileData.base64EncodedString()

        print("📤 [ResourcesManager] Uploading file: \(filename) (\(fileData.count) bytes)")
        LogManager.shared.log("Uploading file: \(filename) (\(fileData.count) bytes)", category: "ResourcesManager")

        // Send upload_file message
        let success = await sendUploadMessage(filename: filename, content: base64Content)

        if success {
            // Delete both files on success
            do {
                try FileManager.default.removeItem(at: metadataURL)
                try FileManager.default.removeItem(at: dataURL)
                print("✅ [ResourcesManager] Upload successful, cleaned up: \(uploadId)")
                LogManager.shared.log("Upload successful, cleaned up: \(uploadId)", category: "ResourcesManager")
            } catch {
                print("⚠️ [ResourcesManager] Upload successful but failed to clean up files: \(error)")
                LogManager.shared.log("Upload successful but failed to clean up files: \(error)", category: "ResourcesManager")
            }
        } else {
            print("⚠️ [ResourcesManager] Upload failed, will retry later: \(uploadId)")
            LogManager.shared.log("Upload failed, will retry later: \(uploadId)", category: "ResourcesManager")
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
            LogManager.shared.log("Sending upload_file message for: \(filename) to: \(appSettings.resourceStorageLocation)", category: "ResourcesManager")

            // Store continuation to be called when acknowledgment received
            pendingAcknowledgments[filename] = { success in
                LogManager.shared.log("Received acknowledgment for \(filename): success=\(success)", category: "ResourcesManager")
                continuation.resume(returning: success)
            }

            voiceCodeClient.sendMessage(message)

            // Timeout after 30 seconds if no response
            DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) { [weak self] in
                guard let self = self else { return }
                if self.pendingAcknowledgments[filename] != nil {
                    print("⚠️ [ResourcesManager] Upload timeout for: \(filename)")
                    LogManager.shared.log("Upload timeout for: \(filename)", category: "ResourcesManager")
                    self.pendingAcknowledgments.removeValue(forKey: filename)
                    continuation.resume(returning: false)
                }
            }
        }
    }

    // MARK: - Response Handling

    /// Call this when file-uploaded or error response received from backend
    func handleUploadResponse(filename: String, success: Bool) {
        LogManager.shared.log("handleUploadResponse called for \(filename): success=\(success)", category: "ResourcesManager")

        // Backend may return a different filename if there was a conflict (e.g., "file-20251111123456.txt")
        // Since uploads are processed sequentially, match against the original filename or just take the first pending
        if let completion = pendingAcknowledgments[filename] {
            // Exact match
            LogManager.shared.log("Found exact match for \(filename), calling completion handler", category: "ResourcesManager")
            pendingAcknowledgments.removeValue(forKey: filename)
            completion(success)
        } else if let (originalFilename, completion) = pendingAcknowledgments.first {
            // Filename changed due to conflict, complete the first pending upload
            print("⚠️ [ResourcesManager] Filename mismatch: sent '\(originalFilename)', received '\(filename)'. Completing first pending upload.")
            LogManager.shared.log("Filename mismatch: sent '\(originalFilename)', received '\(filename)'. Completing first pending upload.", category: "ResourcesManager")
            pendingAcknowledgments.removeValue(forKey: originalFilename)
            completion(success)
        } else {
            LogManager.shared.log("No pending acknowledgment found for \(filename)", category: "ResourcesManager")
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
