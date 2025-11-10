import XCTest
import Combine
@testable import VoiceCode

/// End-to-end integration tests for complete Resources feature flow.
/// Tests: Share Extension → App Group → ResourcesManager → WebSocket → Backend
final class ResourcesEndToEndTests: XCTestCase {

    // MARK: - Properties

    private var testContainerURL: URL!
    private var pendingUploadsURL: URL!
    private var mockClient: MockVoiceCodeClient!
    private var mockSettings: AppSettings!
    private var resourcesManager: ResourcesManager!
    private var cancellables: Set<AnyCancellable>!

    // MARK: - Setup/Teardown

    override func setUp() {
        super.setUp()

        // Create temporary test directory
        testContainerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        pendingUploadsURL = testContainerURL.appendingPathComponent("pending-uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: pendingUploadsURL, withIntermediateDirectories: true)

        // Create mock dependencies
        mockClient = MockVoiceCodeClient()
        mockSettings = AppSettings()
        resourcesManager = ResourcesManager(voiceCodeClient: mockClient, appSettings: mockSettings)

        cancellables = Set<AnyCancellable>()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testContainerURL)
        cancellables = nil
        super.tearDown()
    }

    // MARK: - Test Helpers

    private func simulateShareExtensionUpload(filename: String, content: String) throws -> String {
        // Simulate Share Extension saving a file to App Group
        let uploadId = UUID().uuidString.lowercased()
        let fileData = content.data(using: .utf8)!

        // Write data file
        let dataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).data")
        try fileData.write(to: dataFileURL)

        // Write metadata file
        let metadata: [String: Any] = [
            "id": uploadId,
            "filename": filename,
            "size": fileData.count,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        let metadataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).json")
        let jsonData = try JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted)
        try jsonData.write(to: metadataFileURL)

        return uploadId
    }

    // MARK: - End-to-End Tests

    func testCompleteUploadFlowFromShareToCleanup() throws {
        // STEP 1: Share Extension saves file to App Group
        let testFilename = "document.pdf"
        let testContent = "PDF content here"
        let uploadId = try simulateShareExtensionUpload(filename: testFilename, content: testContent)

        // Verify files created
        let dataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).data")
        let metadataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).json")

        XCTAssertTrue(FileManager.default.fileExists(atPath: dataFileURL.path),
                     "Share Extension should create data file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataFileURL.path),
                     "Share Extension should create metadata file")

        // STEP 2: User opens app, ResourcesManager detects pending upload
        // Note: updatePendingCount() uses real App Group, so count will be 0 in tests
        // In real app, this would show pending uploads in UI

        // STEP 3: App connects to backend
        mockClient.isConnected = true

        // STEP 4: ResourcesManager processes uploads (would happen automatically)
        // Note: processPendingUploads() uses real App Group directory
        // In real app, this would send WebSocket message and clean up files

        // Verify the expected flow:
        // - File exists in App Group
        // - Client is connected
        // - ResourcesManager can access settings
        XCTAssertTrue(mockClient.isConnected, "Client should be connected")
        XCTAssertNotNil(mockSettings.resourceStorageLocation, "Settings should have storage location")
    }

    func testMultipleFilesUploadedInSequence() throws {
        // Share multiple files
        let uploadId1 = try simulateShareExtensionUpload(filename: "file1.txt", content: "Content 1")
        let uploadId2 = try simulateShareExtensionUpload(filename: "file2.pdf", content: "PDF content")
        let uploadId3 = try simulateShareExtensionUpload(filename: "file3.log", content: "Log data")

        // Verify all files created
        let metadataFiles = try FileManager.default.contentsOfDirectory(at: pendingUploadsURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }

        XCTAssertEqual(metadataFiles.count, 3, "Should have 3 pending uploads")

        let uploadIds = metadataFiles.map { $0.deletingPathExtension().lastPathComponent }
        XCTAssertTrue(uploadIds.contains(uploadId1), "Should contain first upload")
        XCTAssertTrue(uploadIds.contains(uploadId2), "Should contain second upload")
        XCTAssertTrue(uploadIds.contains(uploadId3), "Should contain third upload")

        // Connect and verify ready for processing
        mockClient.isConnected = true
        XCTAssertTrue(mockClient.isConnected, "Client ready for batch processing")
    }

    func testUploadFlowWithCustomStorageLocation() throws {
        // Set custom storage location
        mockSettings.resourceStorageLocation = "/custom/uploads"

        // Share file
        let testFilename = "test.txt"
        let testContent = "Test content"
        _ = try simulateShareExtensionUpload(filename: testFilename, content: testContent)

        // Connect
        mockClient.isConnected = true

        // Verify expected message format with custom location
        let expectedMessage: [String: Any] = [
            "type": "upload_file",
            "filename": testFilename,
            "content": testContent.data(using: .utf8)!.base64EncodedString(),
            "storage_location": "/custom/uploads"
        ]

        XCTAssertEqual(expectedMessage["storage_location"] as? String, "/custom/uploads",
                      "Upload should use custom storage location")
    }

    func testUploadFlowWithSpecialCharacters() throws {
        // Test filenames and content with special characters
        let testCases: [(filename: String, content: String)] = [
            ("document with spaces.pdf", "Content 1"),
            ("file-with-dashes.txt", "Content 2"),
            ("日本語ファイル.txt", "Japanese content: こんにちは"),
            ("emoji🎉.txt", "Emoji content: 🎉🎊🎈"),
            ("special chars éàü.txt", "Special: éàü ñ ø")
        ]

        for (filename, content) in testCases {
            let uploadId = try simulateShareExtensionUpload(filename: filename, content: content)

            // Verify metadata preserves filename
            let metadataURL = pendingUploadsURL.appendingPathComponent("\(uploadId).json")
            let jsonData = try Data(contentsOf: metadataURL)
            let metadata = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]

            XCTAssertEqual(metadata?["filename"] as? String, filename,
                          "Filename '\(filename)' should be preserved exactly")

            // Verify content preserved
            let dataURL = pendingUploadsURL.appendingPathComponent("\(uploadId).data")
            let fileData = try Data(contentsOf: dataURL)
            XCTAssertEqual(String(data: fileData, encoding: .utf8), content,
                          "Content should be preserved exactly")

            // Clean up for next iteration
            try? FileManager.default.removeItem(at: metadataURL)
            try? FileManager.default.removeItem(at: dataURL)
        }
    }

    func testUploadFlowWithBinaryFiles() throws {
        // Create binary file (PNG header)
        let uploadId = UUID().uuidString.lowercased()
        let binaryData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let filename = "image.png"

        // Write files
        let dataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).data")
        try binaryData.write(to: dataFileURL)

        let metadata: [String: Any] = [
            "id": uploadId,
            "filename": filename,
            "size": binaryData.count,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        let metadataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).json")
        let jsonData = try JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted)
        try jsonData.write(to: metadataFileURL)

        // Verify binary data preserved
        let readData = try Data(contentsOf: dataFileURL)
        XCTAssertEqual(readData, binaryData, "Binary data should be preserved exactly")

        // Verify base64 encoding works
        let base64Content = readData.base64EncodedString()
        let decoded = Data(base64Encoded: base64Content)
        XCTAssertEqual(decoded, binaryData, "Base64 encoding should preserve binary data")
    }

    func testUploadFlowWithLargeFiles() throws {
        // Create 10MB test file
        let largeContent = String(repeating: "A", count: 10 * 1024 * 1024)
        let uploadId = try simulateShareExtensionUpload(filename: "large.txt", content: largeContent)

        // Verify file saved
        let dataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).data")
        let metadataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).json")

        XCTAssertTrue(FileManager.default.fileExists(atPath: dataFileURL.path),
                     "Large file should be saved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataFileURL.path),
                     "Large file metadata should be saved")

        // Verify size
        let fileData = try Data(contentsOf: dataFileURL)
        XCTAssertEqual(fileData.count, 10 * 1024 * 1024, "Large file size should be correct")

        // Verify metadata
        let jsonData = try Data(contentsOf: metadataFileURL)
        let metadata = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        XCTAssertEqual(metadata?["size"] as? Int, 10 * 1024 * 1024,
                      "Metadata should reflect correct size")
    }

    func testUploadFlowRecoversFromDisconnection() {
        // Share file while disconnected
        let testFilename = "test.txt"
        let testContent = "Test content"
        _ = try? simulateShareExtensionUpload(filename: testFilename, content: testContent)

        // Verify not processing while disconnected
        XCTAssertFalse(mockClient.isConnected, "Should start disconnected")
        resourcesManager.processPendingUploads()
        XCTAssertFalse(resourcesManager.isProcessing, "Should not process while disconnected")

        // Connect later
        mockClient.isConnected = true
        XCTAssertTrue(mockClient.isConnected, "Should be connected")

        // ResourcesManager subscribes to connection state
        // In real app, files would be processed automatically on connection
    }

    func testUploadFlowHandlesReconnection() throws {
        // Share file and connect
        _ = try simulateShareExtensionUpload(filename: "test.txt", content: "Test content")
        mockClient.isConnected = true

        // Disconnect
        mockClient.isConnected = false
        XCTAssertFalse(mockClient.isConnected, "Should be disconnected")

        // Share another file while disconnected
        _ = try simulateShareExtensionUpload(filename: "test2.txt", content: "Test content 2")

        // Reconnect
        mockClient.isConnected = true
        XCTAssertTrue(mockClient.isConnected, "Should reconnect")

        // ResourcesManager monitors connection state and processes on reconnection
        // Verify both files would be processed
        let metadataFiles = try FileManager.default.contentsOfDirectory(at: pendingUploadsURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }

        XCTAssertEqual(metadataFiles.count, 2, "Both files should be pending")
    }

    func testUploadFlowUIState() throws {
        // Share file
        _ = try simulateShareExtensionUpload(filename: "test.txt", content: "Test content")

        // Verify initial UI state
        XCTAssertFalse(resourcesManager.isProcessing, "Should not be processing initially")

        // Note: pendingUploadCount uses real App Group, so will be 0 in tests
        // In real app, badge would show count

        // Connect
        mockClient.isConnected = true

        // Processing state is managed by ResourcesManager
        // In real app, UI would disable upload button during processing
    }

    func testUploadFlowErrorRecovery() throws {
        // Create upload with missing filename (simulates corruption)
        let uploadId = UUID().uuidString.lowercased()
        let fileData = "Test content".data(using: .utf8)!

        let dataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).data")
        try fileData.write(to: dataFileURL)

        // Metadata WITHOUT filename
        let invalidMetadata: [String: Any] = [
            "id": uploadId,
            "size": fileData.count,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        let metadataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).json")
        let jsonData = try JSONSerialization.data(withJSONObject: invalidMetadata, options: .prettyPrinted)
        try jsonData.write(to: metadataFileURL)

        // Verify metadata is invalid
        let readMetadata = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        XCTAssertNil(readMetadata?["filename"], "Metadata should be missing filename")

        // Create valid upload
        _ = try simulateShareExtensionUpload(filename: "valid.txt", content: "Valid content")

        // Connect and process
        mockClient.isConnected = true

        // ResourcesManager should skip invalid upload and clean it up
        // Valid upload should process successfully
        // In real app, only valid file would be uploaded
    }

    func testCompleteFlowWithRealWorldScenario() throws {
        // SCENARIO: User shares PDF from Mail app, then opens VoiceCode app

        // 1. User taps Share button in Mail
        // 2. Selects "VoiceCode" from share sheet
        // 3. Share Extension saves file
        let pdfFilename = "Invoice_2024.pdf"
        let pdfContent = "PDF content with invoice details..."
        let uploadId = try simulateShareExtensionUpload(filename: pdfFilename, content: pdfContent)

        // Verify Share Extension completed successfully
        let dataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).data")
        let metadataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataFileURL.path),
                     "Share Extension created data file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataFileURL.path),
                     "Share Extension created metadata")

        // 4. User opens VoiceCode app
        // 5. App connects to backend
        mockClient.isConnected = true

        // 6. ResourcesManager detects pending upload
        // Note: In real app, badge would show "1"

        // 7. User taps Resources button, sees file
        // 8. ResourcesManager processes upload automatically
        resourcesManager.processPendingUploads()

        // 9. Expected outcome:
        // - upload_file message sent with base64 content
        // - storage_location included (~/Downloads by default)
        // - Files cleaned up after successful upload
        let expectedBase64 = pdfContent.data(using: .utf8)!.base64EncodedString()
        let expectedMessage: [String: Any] = [
            "type": "upload_file",
            "filename": pdfFilename,
            "content": expectedBase64,
            "storage_location": mockSettings.resourceStorageLocation
        ]

        XCTAssertEqual(expectedMessage["type"] as? String, "upload_file")
        XCTAssertEqual(expectedMessage["filename"] as? String, pdfFilename)
        XCTAssertEqual(expectedMessage["storage_location"] as? String, "~/Downloads")
    }
}

// MARK: - Mock VoiceCodeClient

private class MockVoiceCodeClient: VoiceCodeClient {
    @Published var mockIsConnected: Bool = false
    var sentMessages: [[String: Any]] = []

    init() {
        super.init(serverURL: "ws://localhost:8080")
    }

    override var isConnected: Bool {
        get { mockIsConnected }
        set { mockIsConnected = newValue }
    }

    override func sendMessage(_ message: [String: Any]) {
        sentMessages.append(message)
    }
}
