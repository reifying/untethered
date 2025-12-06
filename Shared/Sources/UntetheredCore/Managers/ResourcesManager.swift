import Foundation
import Combine

/// Manages file resources uploaded via Share Extension and synced with backend
@MainActor
public class ResourcesManager: ObservableObject {
    private let appGroupIdentifier = "group.com.910labs.untethered.resources"
    private let voiceCodeClient: VoiceCodeClient
    private let appSettings: AppSettings

    @Published public var isProcessing = false
    @Published public var pendingUploadCount = 0
    @Published public var resources: [Resource] = []
    @Published public var isLoadingResources = false

    private var processTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var pendingAcknowledgments: [String: (Bool) -> Void] = [:] // uploadId -> completion handler

    public init(voiceCodeClient: VoiceCodeClient, appSettings: AppSettings = AppSettings()) {
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
                print("[ResourcesManager] " + "Resources list updated: \(resourcesList.count) resources")
            }
            .store(in: &cancellables)
    }

    // MARK: - Public Interface

    /// Request list of resources from backend
    public func listResources() {
        guard voiceCodeClient.isConnected else {
            print("⚠️ [ResourcesManager] Not connected, cannot list resources")
            print("[ResourcesManager] " + "Not connected, cannot list resources")
            return
        }

        isLoadingResources = true
        print("[ResourcesManager] " + "Requesting resources list")
        voiceCodeClient.listResources(storageLocation: appSettings.resourceStorageLocation)
    }

    /// Delete a resource from backend
    public func deleteResource(_ resource: Resource) {
        guard voiceCodeClient.isConnected else {
            print("⚠️ [ResourcesManager] Not connected, cannot delete resource")
            print("[ResourcesManager] " + "Not connected, cannot delete resource")
            return
        }

        print("[ResourcesManager] " + "Deleting resource: \(resource.filename)")
        voiceCodeClient.deleteResource(filename: resource.filename, storageLocation: appSettings.resourceStorageLocation)
    }

    /// Process all pending uploads from the App Group container
    public func processPendingUploads() {
        guard !isProcessing else {
            print("⏭️ [ResourcesManager] Already processing uploads, skipping")
            print("[ResourcesManager] " + "Already processing uploads, skipping")
            return
        }

        guard voiceCodeClient.isConnected else {
            print("⚠️ [ResourcesManager] Not connected, deferring upload processing")
            print("[ResourcesManager] " + "Not connected, deferring upload processing")
            return
        }

        print("[ResourcesManager] " + "Starting upload processing")
        Task {
            await processUploadsAsync()
        }
    }

    /// Get count of pending uploads without processing them
    public func updatePendingCount() {
        guard let pendingUploadsURL = getPendingUploadsDirectory() else {
            print("[ResourcesManager] " + "Failed to get pending uploads directory")
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

            print("[ResourcesManager] " + "Updated pending count: \(metadataFiles.count)")
            DispatchQueue.main.async {
                self.pendingUploadCount = metadataFiles.count
            }
        } catch {
            print("⚠️ [ResourcesManager] Failed to count pending uploads: \(error)")
            print("[ResourcesManager] " + "Failed to count pending uploads: \(error)")
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
        print("[ResourcesManager] " + "Set isProcessing = true")

        defer {
            Task { @MainActor in
                self.isProcessing = false
                print("[ResourcesManager] " + "Set isProcessing = false")
            }
        }

        guard let pendingUploadsURL = getPendingUploadsDirectory() else {
            print("❌ [ResourcesManager] Failed to access App Group container")
            print("[ResourcesManager] " + "Failed to access App Group container")
            return
        }

        print("📂 [ResourcesManager] Checking for pending uploads at: \(pendingUploadsURL.path)")
        print("[ResourcesManager] " + "Checking for pending uploads at: \(pendingUploadsURL.path)")

        // Find all metadata files
        let metadataFiles: [URL]
        do {
            metadataFiles = try FileManager.default.contentsOfDirectory(
                at: pendingUploadsURL,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }
        } catch {
            print("❌ [ResourcesManager] Failed to list pending uploads: \(error)")
            print("[ResourcesManager] " + "Failed to list pending uploads: \(error)")
            return
        }

        guard !metadataFiles.isEmpty else {
            print("✅ [ResourcesManager] No pending uploads found")
            print("[ResourcesManager] " + "No pending uploads found")
            await MainActor.run {
                self.pendingUploadCount = 0
            }
            return
        }

        print("📤 [ResourcesManager] Found \(metadataFiles.count) pending upload(s)")
        print("[ResourcesManager] " + "Found \(metadataFiles.count) pending upload(s)")
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
        print("[ResourcesManager] " + "Processing upload: \(uploadId)")

        // Read metadata
        let metadata: [String: Any]
        do {
            let metadataData = try Data(contentsOf: metadataURL)
            guard let json = try JSONSerialization.jsonObject(with: metadataData) as? [String: Any] else {
                print("❌ [ResourcesManager] Invalid metadata format for upload: \(uploadId)")
                print("[ResourcesManager] " + "Invalid metadata format for upload: \(uploadId)")
                try? FileManager.default.removeItem(at: metadataURL)
                return
            }
            metadata = json
        } catch {
            print("❌ [ResourcesManager] Failed to read metadata for upload \(uploadId): \(error)")
            print("[ResourcesManager] " + "Failed to read metadata for upload \(uploadId): \(error)")
            try? FileManager.default.removeItem(at: metadataURL)
            return
        }

        guard let filename = metadata["filename"] as? String else {
            print("❌ [ResourcesManager] Missing filename in metadata for upload: \(uploadId)")
            print("[ResourcesManager] " + "Missing filename in metadata for upload: \(uploadId)")
            try? FileManager.default.removeItem(at: metadataURL)
            return
        }

        print("[ResourcesManager] " + "Read metadata for file: \(filename)")

        // Read file data
        let dataURL = pendingUploadsURL.appendingPathComponent("\(uploadId).data")
        let fileData: Data
        do {
            fileData = try Data(contentsOf: dataURL)
        } catch {
            print("❌ [ResourcesManager] Failed to read data file for upload \(uploadId): \(error)")
            print("[ResourcesManager] " + "Failed to read data file for upload \(uploadId): \(error)")
            // Clean up metadata if data file is missing
            try? FileManager.default.removeItem(at: metadataURL)
            return
        }

        // Base64 encode
        let base64Content = fileData.base64EncodedString()

        print("📤 [ResourcesManager] Uploading file: \(filename) (\(fileData.count) bytes)")
        print("[ResourcesManager] " + "Uploading file: \(filename) (\(fileData.count) bytes)")

        // Send upload_file message
        let success = await sendUploadMessage(filename: filename, content: base64Content)

        if success {
            // Delete both files on success
            do {
                try FileManager.default.removeItem(at: metadataURL)
                try FileManager.default.removeItem(at: dataURL)
                print("✅ [ResourcesManager] Upload successful, cleaned up: \(uploadId)")
                print("[ResourcesManager] " + "Upload successful, cleaned up: \(uploadId)")
            } catch {
                print("⚠️ [ResourcesManager] Upload successful but failed to clean up files: \(error)")
                print("[ResourcesManager] " + "Upload successful but failed to clean up files: \(error)")
            }
        } else {
            print("⚠️ [ResourcesManager] Upload failed, will retry later: \(uploadId)")
            print("[ResourcesManager] " + "Upload failed, will retry later: \(uploadId)")
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
            print("[ResourcesManager] " + "Sending upload_file message for: \(filename) to: \(appSettings.resourceStorageLocation)")

            // Store continuation to be called when acknowledgment received
            pendingAcknowledgments[filename] = { success in
                print("[ResourcesManager] " + "Received acknowledgment for \(filename): success=\(success)")
                continuation.resume(returning: success)
            }

            self.voiceCodeClient.sendMessage(message)

            // Timeout after 30 seconds if no response
            DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) { [weak self] in
                guard let self = self else { return }
                if self.pendingAcknowledgments[filename] != nil {
                    print("⚠️ [ResourcesManager] Upload timeout for: \(filename)")
                    print("[ResourcesManager] " + "Upload timeout for: \(filename)")
                    self.pendingAcknowledgments.removeValue(forKey: filename)
                    continuation.resume(returning: false)
                }
            }
        }
    }

    // MARK: - Response Handling

    /// Call this when file-uploaded or error response received from backend
    func handleUploadResponse(filename: String, success: Bool) {
        print("[ResourcesManager] " + "handleUploadResponse called for \(filename): success=\(success)")

        // Backend may return a different filename if there was a conflict (e.g., "file-20251111123456.txt")
        // Since uploads are processed sequentially, match against the original filename or just take the first pending
        if let completion = pendingAcknowledgments[filename] {
            // Exact match
            print("[ResourcesManager] " + "Found exact match for \(filename), calling completion handler")
            pendingAcknowledgments.removeValue(forKey: filename)
            completion(success)
        } else if let (originalFilename, completion) = pendingAcknowledgments.first {
            // Filename changed due to conflict, complete the first pending upload
            print("⚠️ [ResourcesManager] Filename mismatch: sent '\(originalFilename)', received '\(filename)'. Completing first pending upload.")
            print("[ResourcesManager] " + "Filename mismatch: sent '\(originalFilename)', received '\(filename)'. Completing first pending upload.")
            pendingAcknowledgments.removeValue(forKey: originalFilename)
            completion(success)
        } else {
            print("[ResourcesManager] " + "No pending acknowledgment found for \(filename)")
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
