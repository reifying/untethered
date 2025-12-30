// ResourcesManager.swift
// Manages file resources upload and listing for macOS
// Adapted from iOS ResourcesManager per Section 11.4

import Foundation
import Combine
import OSLog
import VoiceCodeShared

private let logger = Logger(subsystem: "dev.910labs.voice-code-desktop", category: "ResourcesManager")

/// Upload progress state
public struct UploadProgress: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let filename: String
    public var bytesUploaded: Int64
    public let totalBytes: Int64
    public var status: UploadStatus

    public enum UploadStatus: Equatable, Sendable {
        case pending
        case uploading
        case completed
        case failed(String)
    }

    public var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesUploaded) / Double(totalBytes)
    }

    public var isComplete: Bool {
        if case .completed = status { return true }
        return false
    }

    public var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }
}

/// Manages file resources uploaded to the backend
/// macOS version: Direct file access, no App Group needed
@MainActor
final class ResourcesManager: ObservableObject {
    private let client: VoiceCodeClient
    private let appSettings: AppSettings

    @Published var isProcessing = false
    @Published var resources: [Resource] = []
    @Published var isLoadingResources = false
    @Published var uploadProgress: [UploadProgress] = []
    @Published var lastError: String?

    private var cancellables = Set<AnyCancellable>()
    private var pendingAcknowledgments: [String: (Bool) -> Void] = [:]

    /// Maximum file size for uploads (100MB per spec)
    static let maxFileSize: Int64 = 100 * 1024 * 1024

    init(client: VoiceCodeClient, appSettings: AppSettings) {
        self.client = client
        self.appSettings = appSettings

        setupSubscriptions()
    }

    private func setupSubscriptions() {
        // Monitor connection state
        client.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                if isConnected {
                    self?.refreshResources()
                }
            }
            .store(in: &cancellables)

        // Monitor file upload responses
        client.$fileUploadResponse
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] response in
                self?.handleUploadResponse(filename: response.filename, success: response.success)
            }
            .store(in: &cancellables)

        // Monitor resources list updates
        client.$resourcesList
            .receive(on: DispatchQueue.main)
            .sink { [weak self] resourcesList in
                self?.resources = resourcesList
                self?.isLoadingResources = false
                logger.info("📚 Resources list updated: \(resourcesList.count) resources")
            }
            .store(in: &cancellables)
    }

    // MARK: - Public Interface

    /// Refresh resources list from backend
    func refreshResources() {
        guard client.isConnected else {
            logger.warning("⚠️ Not connected, cannot list resources")
            return
        }

        let storageLocation = effectiveStorageLocation
        guard !storageLocation.isEmpty else {
            logger.warning("⚠️ No storage location configured")
            return
        }

        isLoadingResources = true
        logger.info("📋 Requesting resources list from: \(storageLocation)")
        client.listResources(storageLocation: storageLocation)
    }

    /// Delete a resource from backend
    func deleteResource(_ resource: Resource) {
        guard client.isConnected else {
            logger.warning("⚠️ Not connected, cannot delete resource: \(resource.filename)")
            return
        }

        let storageLocation = effectiveStorageLocation
        logger.info("🗑️ Deleting resource: \(resource.filename) from: \(storageLocation)")
        client.deleteResource(filename: resource.filename, storageLocation: storageLocation)
    }

    /// Upload files from URLs (drag-and-drop or file picker)
    /// - Parameter urls: Array of file URLs to upload
    func uploadFiles(_ urls: [URL]) {
        guard client.isConnected else {
            lastError = "Not connected to server"
            logger.warning("⚠️ Not connected, cannot upload files")
            return
        }

        let storageLocation = effectiveStorageLocation
        guard !storageLocation.isEmpty else {
            lastError = "No storage location configured"
            logger.warning("⚠️ No storage location configured")
            return
        }

        for url in urls {
            uploadFile(url, storageLocation: storageLocation)
        }
    }

    /// Upload a single file
    private func uploadFile(_ url: URL, storageLocation: String) {
        let uploadId = UUID()
        let filename = url.lastPathComponent

        // Check if file exists and get size
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.error("❌ File does not exist: \(url.path)")
            let progress = UploadProgress(
                id: uploadId,
                filename: filename,
                bytesUploaded: 0,
                totalBytes: 0,
                status: .failed("File not found")
            )
            uploadProgress.append(progress)
            return
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = (attributes[.size] as? Int64) ?? 0

            // Check file size limit
            guard fileSize <= Self.maxFileSize else {
                logger.error("❌ File too large: \(fileSize) bytes (max: \(Self.maxFileSize))")
                let progress = UploadProgress(
                    id: uploadId,
                    filename: filename,
                    bytesUploaded: 0,
                    totalBytes: fileSize,
                    status: .failed("File too large (max 100MB)")
                )
                uploadProgress.append(progress)
                return
            }

            // Create progress entry
            let progress = UploadProgress(
                id: uploadId,
                filename: filename,
                bytesUploaded: 0,
                totalBytes: fileSize,
                status: .pending
            )
            uploadProgress.append(progress)

            // Read file and upload asynchronously
            Task {
                await performUpload(url: url, uploadId: uploadId, storageLocation: storageLocation)
            }

        } catch {
            logger.error("❌ Failed to get file attributes: \(error.localizedDescription)")
            let progress = UploadProgress(
                id: uploadId,
                filename: filename,
                bytesUploaded: 0,
                totalBytes: 0,
                status: .failed(error.localizedDescription)
            )
            uploadProgress.append(progress)
        }
    }

    private func performUpload(url: URL, uploadId: UUID, storageLocation: String) async {
        let filename = url.lastPathComponent

        // Update status to uploading
        updateUploadStatus(uploadId: uploadId, status: .uploading)

        do {
            // Start accessing security-scoped resource if needed
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            // Read file data
            let fileData = try Data(contentsOf: url)
            let base64Content = fileData.base64EncodedString()

            // Update progress to show bytes read
            updateUploadProgress(uploadId: uploadId, bytesUploaded: Int64(fileData.count))

            logger.info("📤 Uploading file: \(filename) (\(fileData.count) bytes)")

            // Send upload message and wait for acknowledgment
            let success = await sendUploadMessage(filename: filename, content: base64Content, storageLocation: storageLocation)

            if success {
                updateUploadStatus(uploadId: uploadId, status: .completed)
                logger.info("✅ Upload successful: \(filename)")

                // Refresh resources list
                refreshResources()

                // Remove completed upload after delay
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                    await MainActor.run {
                        self.uploadProgress.removeAll { $0.id == uploadId }
                    }
                }
            } else {
                updateUploadStatus(uploadId: uploadId, status: .failed("Upload failed"))
                logger.error("❌ Upload failed: \(filename)")
            }

        } catch {
            logger.error("❌ Failed to read file: \(error.localizedDescription)")
            updateUploadStatus(uploadId: uploadId, status: .failed(error.localizedDescription))
        }
    }

    private func sendUploadMessage(filename: String, content: String, storageLocation: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            let message: [String: Any] = [
                "type": "upload_file",
                "filename": filename,
                "content": content,
                "storage_location": storageLocation
            ]

            logger.info("📨 Sending upload_file message for: \(filename) to: \(storageLocation)")

            // Track whether continuation has been resumed to prevent double-resume
            var hasResumed = false

            // Store continuation to be called when acknowledgment received
            pendingAcknowledgments[filename] = { success in
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(returning: success)
            }

            client.sendMessage(message)

            // Timeout after 30 seconds
            Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await MainActor.run {
                    // Remove and call in single operation to prevent race
                    if let completion = self.pendingAcknowledgments.removeValue(forKey: filename) {
                        logger.warning("⚠️ Upload timeout for: \(filename)")
                        completion(false)
                    }
                }
            }
        }
    }

    private func handleUploadResponse(filename: String, success: Bool) {
        logger.info("📬 Upload response for \(filename): success=\(success)")

        // Use atomic removeValue to prevent race with timeout task
        if let completion = pendingAcknowledgments.removeValue(forKey: filename) {
            completion(success)
        } else if let (originalFilename, completion) = pendingAcknowledgments.first {
            // Filename changed due to conflict - also use atomic removal
            logger.info("⚠️ Filename mismatch: sent '\(originalFilename)', received '\(filename)'")
            if pendingAcknowledgments.removeValue(forKey: originalFilename) != nil {
                completion(success)
            }
        }
    }

    // MARK: - Progress Updates

    private func updateUploadStatus(uploadId: UUID, status: UploadProgress.UploadStatus) {
        if let index = uploadProgress.firstIndex(where: { $0.id == uploadId }) {
            uploadProgress[index].status = status
        }
    }

    private func updateUploadProgress(uploadId: UUID, bytesUploaded: Int64) {
        if let index = uploadProgress.firstIndex(where: { $0.id == uploadId }) {
            uploadProgress[index].bytesUploaded = bytesUploaded
        }
    }

    /// Clear completed uploads from progress list
    func clearCompletedUploads() {
        uploadProgress.removeAll { $0.isComplete }
    }

    /// Clear failed uploads from progress list
    func clearFailedUploads() {
        uploadProgress.removeAll { $0.isFailed }
    }

    // MARK: - Storage Location

    /// Effective storage location for uploads
    /// Uses session's working directory if resourceStorageLocation is empty
    var effectiveStorageLocation: String {
        let configured = appSettings.resourceStorageLocation
        if configured.isEmpty {
            // Default to user's Downloads folder
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
                .first?.path ?? "~/Downloads"
        }
        return configured
    }
}

// MARK: - Supported File Types

extension ResourcesManager {
    /// Check if a file type is supported for upload
    static func isFileTypeSupported(_ url: URL) -> Bool {
        // Accept all files - backend handles validation
        return true
    }

    /// Get supported UTTypes for drag-and-drop
    static var supportedContentTypes: [String] {
        // Accept files and folders
        return ["public.item", "public.folder"]
    }
}
