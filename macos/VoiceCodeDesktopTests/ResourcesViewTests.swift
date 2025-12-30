//
//  ResourcesViewTests.swift
//  VoiceCodeDesktopTests
//
//  Tests for ResourcesView and ResourcesManager per Section 11.4 of macos-desktop-design.md:
//  - Resources panel functionality
//  - File upload via drag-and-drop and file dialogs
//  - Upload progress tracking
//  - Resource list management
//

import XCTest
import SwiftUI
import Combine
@testable import VoiceCodeDesktop
@testable import VoiceCodeShared

@MainActor
final class ResourcesViewTests: XCTestCase {
    var settings: AppSettings!
    var client: VoiceCodeClient!
    var resourcesManager: ResourcesManager!
    var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        settings = AppSettings()
        client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        resourcesManager = ResourcesManager(client: client, appSettings: settings)
        cancellables = Set<AnyCancellable>()
    }

    override func tearDown() {
        cancellables = nil
        resourcesManager = nil
        client = nil
        settings = nil
        super.tearDown()
    }

    // MARK: - ResourcesManager Tests

    func testResourcesManagerInitialization() {
        XCTAssertNotNil(resourcesManager)
        XCTAssertFalse(resourcesManager.isProcessing)
        XCTAssertFalse(resourcesManager.isLoadingResources)
        XCTAssertTrue(resourcesManager.resources.isEmpty)
        XCTAssertTrue(resourcesManager.uploadProgress.isEmpty)
        XCTAssertNil(resourcesManager.lastError)
    }

    func testEffectiveStorageLocationWithConfigured() {
        settings.resourceStorageLocation = "/Users/test/uploads"
        XCTAssertEqual(resourcesManager.effectiveStorageLocation, "/Users/test/uploads")
    }

    func testEffectiveStorageLocationWithEmpty() {
        settings.resourceStorageLocation = ""
        // Should default to Downloads folder
        XCTAssertTrue(resourcesManager.effectiveStorageLocation.contains("Downloads"))
    }

    func testMaxFileSizeConstant() {
        // 100MB per spec
        XCTAssertEqual(ResourcesManager.maxFileSize, 100 * 1024 * 1024)
    }

    func testSupportedContentTypes() {
        let types = ResourcesManager.supportedContentTypes
        XCTAssertTrue(types.contains("public.item"))
        XCTAssertTrue(types.contains("public.folder"))
    }

    func testIsFileTypeSupported() {
        // Should accept all files
        let pdfURL = URL(fileURLWithPath: "/test/file.pdf")
        XCTAssertTrue(ResourcesManager.isFileTypeSupported(pdfURL))

        let swiftURL = URL(fileURLWithPath: "/test/file.swift")
        XCTAssertTrue(ResourcesManager.isFileTypeSupported(swiftURL))

        let unknownURL = URL(fileURLWithPath: "/test/file.xyz")
        XCTAssertTrue(ResourcesManager.isFileTypeSupported(unknownURL))
    }

    func testClearCompletedUploads() {
        // This would require setting up uploadProgress with completed items
        // Since uploadProgress is managed internally, we test the method exists
        resourcesManager.clearCompletedUploads()
        XCTAssertTrue(resourcesManager.uploadProgress.isEmpty)
    }

    func testClearFailedUploads() {
        resourcesManager.clearFailedUploads()
        XCTAssertTrue(resourcesManager.uploadProgress.isEmpty)
    }

    // MARK: - UploadProgress Tests

    func testUploadProgressInitialization() {
        let progress = UploadProgress(
            id: UUID(),
            filename: "test.pdf",
            bytesUploaded: 0,
            totalBytes: 1000,
            status: .pending
        )

        XCTAssertEqual(progress.filename, "test.pdf")
        XCTAssertEqual(progress.bytesUploaded, 0)
        XCTAssertEqual(progress.totalBytes, 1000)
        XCTAssertEqual(progress.progress, 0)
        XCTAssertFalse(progress.isComplete)
        XCTAssertFalse(progress.isFailed)
    }

    func testUploadProgressCalculation() {
        let progress = UploadProgress(
            id: UUID(),
            filename: "test.pdf",
            bytesUploaded: 500,
            totalBytes: 1000,
            status: .uploading
        )

        XCTAssertEqual(progress.progress, 0.5)
    }

    func testUploadProgressZeroTotalBytes() {
        let progress = UploadProgress(
            id: UUID(),
            filename: "test.pdf",
            bytesUploaded: 0,
            totalBytes: 0,
            status: .pending
        )

        XCTAssertEqual(progress.progress, 0)
    }

    func testUploadProgressCompleted() {
        let progress = UploadProgress(
            id: UUID(),
            filename: "test.pdf",
            bytesUploaded: 1000,
            totalBytes: 1000,
            status: .completed
        )

        XCTAssertTrue(progress.isComplete)
        XCTAssertFalse(progress.isFailed)
    }

    func testUploadProgressFailed() {
        let progress = UploadProgress(
            id: UUID(),
            filename: "test.pdf",
            bytesUploaded: 500,
            totalBytes: 1000,
            status: .failed("Connection lost")
        )

        XCTAssertFalse(progress.isComplete)
        XCTAssertTrue(progress.isFailed)
    }

    func testUploadStatusEquality() {
        let pending1: UploadProgress.UploadStatus = .pending
        let pending2: UploadProgress.UploadStatus = .pending
        XCTAssertEqual(pending1, pending2)

        let uploading1: UploadProgress.UploadStatus = .uploading
        let uploading2: UploadProgress.UploadStatus = .uploading
        XCTAssertEqual(uploading1, uploading2)

        let completed1: UploadProgress.UploadStatus = .completed
        let completed2: UploadProgress.UploadStatus = .completed
        XCTAssertEqual(completed1, completed2)

        let failed1: UploadProgress.UploadStatus = .failed("error")
        let failed2: UploadProgress.UploadStatus = .failed("error")
        XCTAssertEqual(failed1, failed2)

        let failed3: UploadProgress.UploadStatus = .failed("different error")
        XCTAssertNotEqual(failed1, failed3)
    }

    // MARK: - ResourcesView Tests

    func testResourcesViewInitialization() {
        let view = ResourcesView(resourcesManager: resourcesManager, settings: settings)
        XCTAssertNotNil(view)
    }

    func testResourceSortOrderCases() {
        let cases = ResourcesView.ResourceSortOrder.allCases
        XCTAssertEqual(cases.count, 6)
        XCTAssertTrue(cases.contains(.dateDescending))
        XCTAssertTrue(cases.contains(.dateAscending))
        XCTAssertTrue(cases.contains(.nameAscending))
        XCTAssertTrue(cases.contains(.nameDescending))
        XCTAssertTrue(cases.contains(.sizeDescending))
        XCTAssertTrue(cases.contains(.sizeAscending))
    }

    func testResourceSortOrderRawValues() {
        XCTAssertEqual(ResourcesView.ResourceSortOrder.dateDescending.rawValue, "Newest First")
        XCTAssertEqual(ResourcesView.ResourceSortOrder.dateAscending.rawValue, "Oldest First")
        XCTAssertEqual(ResourcesView.ResourceSortOrder.nameAscending.rawValue, "Name A-Z")
        XCTAssertEqual(ResourcesView.ResourceSortOrder.nameDescending.rawValue, "Name Z-A")
        XCTAssertEqual(ResourcesView.ResourceSortOrder.sizeDescending.rawValue, "Largest First")
        XCTAssertEqual(ResourcesView.ResourceSortOrder.sizeAscending.rawValue, "Smallest First")
    }

    // MARK: - ResourcesToolbar Tests

    func testResourcesToolbarInitialization() {
        var sortOrder = ResourcesView.ResourceSortOrder.dateDescending
        let toolbar = ResourcesToolbar(
            sortOrder: Binding(get: { sortOrder }, set: { sortOrder = $0 }),
            onRefresh: {},
            onAddFiles: {},
            isLoading: false
        )
        XCTAssertNotNil(toolbar)
    }

    func testResourcesToolbarLoadingState() {
        var sortOrder = ResourcesView.ResourceSortOrder.dateDescending
        let toolbarLoading = ResourcesToolbar(
            sortOrder: Binding(get: { sortOrder }, set: { sortOrder = $0 }),
            onRefresh: {},
            onAddFiles: {},
            isLoading: true
        )
        XCTAssertNotNil(toolbarLoading)
    }

    // MARK: - EmptyResourcesView Tests

    func testEmptyResourcesViewNotDragOver() {
        let view = EmptyResourcesView(isDragOver: false, onAddFiles: {})
        XCTAssertNotNil(view)
    }

    func testEmptyResourcesViewDragOver() {
        let view = EmptyResourcesView(isDragOver: true, onAddFiles: {})
        XCTAssertNotNil(view)
    }

    // MARK: - ResourceRowView Tests

    func testResourceRowViewWithPDF() {
        let resource = Resource(
            filename: "document.pdf",
            path: ".untethered/resources/document.pdf",
            size: 1024,
            timestamp: Date()
        )
        let view = ResourceRowView(resource: resource)
        XCTAssertNotNil(view)
    }

    func testResourceRowViewWithImage() {
        let resource = Resource(
            filename: "photo.jpg",
            path: ".untethered/resources/photo.jpg",
            size: 2048,
            timestamp: Date()
        )
        let view = ResourceRowView(resource: resource)
        XCTAssertNotNil(view)
    }

    func testResourceRowViewWithCode() {
        let resource = Resource(
            filename: "app.swift",
            path: ".untethered/resources/app.swift",
            size: 512,
            timestamp: Date()
        )
        let view = ResourceRowView(resource: resource)
        XCTAssertNotNil(view)
    }

    func testResourceRowViewWithArchive() {
        let resource = Resource(
            filename: "archive.zip",
            path: ".untethered/resources/archive.zip",
            size: 4096,
            timestamp: Date()
        )
        let view = ResourceRowView(resource: resource)
        XCTAssertNotNil(view)
    }

    func testResourceRowViewWithUnknown() {
        let resource = Resource(
            filename: "file.xyz",
            path: ".untethered/resources/file.xyz",
            size: 256,
            timestamp: Date()
        )
        let view = ResourceRowView(resource: resource)
        XCTAssertNotNil(view)
    }

    // MARK: - UploadProgressRowView Tests

    func testUploadProgressRowViewPending() {
        let progress = UploadProgress(
            id: UUID(),
            filename: "test.pdf",
            bytesUploaded: 0,
            totalBytes: 1000,
            status: .pending
        )
        let view = UploadProgressRowView(upload: progress)
        XCTAssertNotNil(view)
    }

    func testUploadProgressRowViewUploading() {
        let progress = UploadProgress(
            id: UUID(),
            filename: "test.pdf",
            bytesUploaded: 500,
            totalBytes: 1000,
            status: .uploading
        )
        let view = UploadProgressRowView(upload: progress)
        XCTAssertNotNil(view)
    }

    func testUploadProgressRowViewCompleted() {
        let progress = UploadProgress(
            id: UUID(),
            filename: "test.pdf",
            bytesUploaded: 1000,
            totalBytes: 1000,
            status: .completed
        )
        let view = UploadProgressRowView(upload: progress)
        XCTAssertNotNil(view)
    }

    func testUploadProgressRowViewFailed() {
        let progress = UploadProgress(
            id: UUID(),
            filename: "test.pdf",
            bytesUploaded: 500,
            totalBytes: 1000,
            status: .failed("Network error")
        )
        let view = UploadProgressRowView(upload: progress)
        XCTAssertNotNil(view)
    }

    // MARK: - DragOverlayView Tests

    func testDragOverlayViewInitialization() {
        let view = DragOverlayView()
        XCTAssertNotNil(view)
    }

    // MARK: - ResourcesListView Tests

    func testResourcesListViewEmpty() {
        let view = ResourcesListView(
            resources: [],
            uploadProgress: [],
            onDelete: { _ in },
            onClearCompleted: {}
        )
        XCTAssertNotNil(view)
    }

    func testResourcesListViewWithResources() {
        let resources = [
            Resource(filename: "file1.pdf", path: "path1", size: 1000, timestamp: Date()),
            Resource(filename: "file2.txt", path: "path2", size: 500, timestamp: Date())
        ]
        let view = ResourcesListView(
            resources: resources,
            uploadProgress: [],
            onDelete: { _ in },
            onClearCompleted: {}
        )
        XCTAssertNotNil(view)
    }

    func testResourcesListViewWithUploads() {
        let uploads = [
            UploadProgress(id: UUID(), filename: "upload1.pdf", bytesUploaded: 500, totalBytes: 1000, status: .uploading),
            UploadProgress(id: UUID(), filename: "upload2.pdf", bytesUploaded: 1000, totalBytes: 1000, status: .completed)
        ]
        let view = ResourcesListView(
            resources: [],
            uploadProgress: uploads,
            onDelete: { _ in },
            onClearCompleted: {}
        )
        XCTAssertNotNil(view)
    }

    // MARK: - Resource Model Tests

    func testResourceFormattedSize() {
        let smallResource = Resource(filename: "small.txt", path: "path", size: 100, timestamp: Date())
        XCTAssertFalse(smallResource.formattedSize.isEmpty)

        let largeResource = Resource(filename: "large.zip", path: "path", size: 1_000_000, timestamp: Date())
        XCTAssertFalse(largeResource.formattedSize.isEmpty)
    }

    func testResourceRelativeTimestamp() {
        let resource = Resource(filename: "test.pdf", path: "path", size: 1000, timestamp: Date())
        XCTAssertFalse(resource.relativeTimestamp.isEmpty)
    }

    func testResourceInitFromJSON() {
        let json: [String: Any] = [
            "filename": "test.pdf",
            "path": ".untethered/resources/test.pdf",
            "size": Int64(1024),
            "timestamp": "2025-01-15T10:30:00Z"
        ]

        let resource = Resource(json: json)
        XCTAssertNotNil(resource)
        XCTAssertEqual(resource?.filename, "test.pdf")
        XCTAssertEqual(resource?.path, ".untethered/resources/test.pdf")
        XCTAssertEqual(resource?.size, 1024)
    }

    func testResourceInitFromJSONMissingFields() {
        let json: [String: Any] = [
            "filename": "test.pdf"
            // Missing path and size
        ]

        let resource = Resource(json: json)
        XCTAssertNil(resource)
    }

    // MARK: - Integration Tests

    func testUploadFilesWithoutConnection() {
        // Client is not connected, so upload should fail gracefully
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try? "test content".write(to: tempFile, atomically: true, encoding: .utf8)

        resourcesManager.uploadFiles([tempFile])

        // Should set an error since not connected
        XCTAssertNotNil(resourcesManager.lastError)

        // Cleanup
        try? FileManager.default.removeItem(at: tempFile)
    }

    func testRefreshResourcesWithoutConnection() {
        // Should not crash when called without connection
        resourcesManager.refreshResources()
        XCTAssertFalse(resourcesManager.isLoadingResources)
    }

    func testDeleteResourceWithoutConnection() {
        let resource = Resource(filename: "test.pdf", path: "path", size: 1000, timestamp: Date())

        // Should not crash when called without connection
        resourcesManager.deleteResource(resource)
    }
}
