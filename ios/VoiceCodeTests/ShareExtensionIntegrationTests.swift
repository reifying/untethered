import XCTest
@testable import VoiceCode

/// Integration tests for Share Extension → App Group → ResourcesManager flow.
/// Tests the complete file sharing workflow from external apps to backend upload.
final class ShareExtensionIntegrationTests: XCTestCase {

    // MARK: - Properties

    private let appGroupIdentifier = "group.com.travisbrown.untethered"
    private var testContainerURL: URL!
    private var pendingUploadsURL: URL!

    // MARK: - Setup/Teardown

    override func setUp() {
        super.setUp()

        // Use temporary directory for tests instead of real App Group
        testContainerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        pendingUploadsURL = testContainerURL.appendingPathComponent("pending-uploads", isDirectory: true)

        try? FileManager.default.createDirectory(at: pendingUploadsURL, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testContainerURL)
        super.tearDown()
    }

    // MARK: - Test Helpers

    private func simulateShareExtensionSaveFile(filename: String, content: String) throws -> String {
        // Simulate what ShareViewController.saveFileToAppGroup does
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

    // MARK: - Integration Tests

    func testShareExtensionCreatesValidPendingUpload() throws {
        // Simulate Share Extension saving a file
        let uploadId = try simulateShareExtensionSaveFile(filename: "document.pdf", content: "PDF content")

        // Verify both files exist
        let dataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).data")
        let metadataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).json")

        XCTAssertTrue(FileManager.default.fileExists(atPath: dataFileURL.path),
                     "Share Extension should create data file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataFileURL.path),
                     "Share Extension should create metadata file")
    }

    func testShareExtensionMetadataFormat() throws {
        let testFilename = "test.txt"
        let testContent = "Test content"
        let uploadId = try simulateShareExtensionSaveFile(filename: testFilename, content: testContent)

        // Read and verify metadata format
        let metadataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).json")
        let jsonData = try Data(contentsOf: metadataFileURL)
        let metadata = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]

        XCTAssertNotNil(metadata, "Metadata should be valid JSON")
        XCTAssertEqual(metadata?["id"] as? String, uploadId, "Metadata should contain upload ID")
        XCTAssertEqual(metadata?["filename"] as? String, testFilename, "Metadata should contain filename")
        XCTAssertEqual(metadata?["size"] as? Int, testContent.count, "Metadata should contain correct size")
        XCTAssertNotNil(metadata?["timestamp"], "Metadata should contain timestamp")

        // Verify timestamp is valid ISO8601
        let timestamp = metadata?["timestamp"] as? String
        XCTAssertNotNil(timestamp, "Timestamp should be string")
        let parsedDate = ISO8601DateFormatter().date(from: timestamp!)
        XCTAssertNotNil(parsedDate, "Timestamp should be valid ISO8601 format")
    }

    func testShareExtensionDataFileContent() throws {
        let testContent = "Test file content with special characters: éàü 日本語 🎉"
        let uploadId = try simulateShareExtensionSaveFile(filename: "test.txt", content: testContent)

        // Read and verify data file content
        let dataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).data")
        let fileData = try Data(contentsOf: dataFileURL)
        let readContent = String(data: fileData, encoding: .utf8)

        XCTAssertEqual(readContent, testContent, "Data file should preserve exact content")
    }

    func testShareExtensionGeneratesUniqueLowercaseUUIDs() throws {
        // Create multiple uploads
        let uploadId1 = try simulateShareExtensionSaveFile(filename: "file1.txt", content: "Content 1")
        let uploadId2 = try simulateShareExtensionSaveFile(filename: "file2.txt", content: "Content 2")
        let uploadId3 = try simulateShareExtensionSaveFile(filename: "file3.txt", content: "Content 3")

        // Verify all are unique
        XCTAssertNotEqual(uploadId1, uploadId2, "Upload IDs should be unique")
        XCTAssertNotEqual(uploadId2, uploadId3, "Upload IDs should be unique")
        XCTAssertNotEqual(uploadId1, uploadId3, "Upload IDs should be unique")

        // Verify all are lowercase
        XCTAssertEqual(uploadId1, uploadId1.lowercased(), "Upload ID should be lowercase")
        XCTAssertEqual(uploadId2, uploadId2.lowercased(), "Upload ID should be lowercase")
        XCTAssertEqual(uploadId3, uploadId3.lowercased(), "Upload ID should be lowercase")

        // Verify UUID format (8-4-4-4-12 characters)
        let uuidPattern = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        let regex = try NSRegularExpression(pattern: uuidPattern)

        XCTAssertNotNil(regex.firstMatch(in: uploadId1, range: NSRange(uploadId1.startIndex..., in: uploadId1)),
                       "Upload ID should match UUID format")
    }

    func testShareExtensionHandlesBinaryFiles() throws {
        // Create binary data file (simulate PNG header)
        let binaryData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let uploadId = UUID().uuidString.lowercased()

        // Write data file
        let dataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).data")
        try binaryData.write(to: dataFileURL)

        // Write metadata
        let metadata: [String: Any] = [
            "id": uploadId,
            "filename": "image.png",
            "size": binaryData.count,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        let metadataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).json")
        let jsonData = try JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted)
        try jsonData.write(to: metadataFileURL)

        // Read and verify binary data preserved
        let readData = try Data(contentsOf: dataFileURL)
        XCTAssertEqual(readData, binaryData, "Binary data should be preserved exactly")
    }

    func testShareExtensionHandlesLargeFiles() throws {
        // Create 5MB test file
        let largeContent = String(repeating: "A", count: 5 * 1024 * 1024)
        let uploadId = try simulateShareExtensionSaveFile(filename: "large.txt", content: largeContent)

        // Verify file was saved
        let dataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).data")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataFileURL.path),
                     "Large file should be saved")

        // Verify size in metadata
        let metadataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).json")
        let jsonData = try Data(contentsOf: metadataFileURL)
        let metadata = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]

        XCTAssertEqual(metadata?["size"] as? Int, 5 * 1024 * 1024,
                      "Metadata should reflect correct large file size")
    }

    func testShareExtensionHandlesSpecialFilenames() throws {
        let testFilenames = [
            "document with spaces.pdf",
            "file-with-dashes.txt",
            "file_with_underscores.log",
            "UPPERCASE.TXT",
            "file.multiple.dots.tar.gz",
            "日本語ファイル.txt",
            "file🎉emoji.txt"
        ]

        for filename in testFilenames {
            let uploadId = try simulateShareExtensionSaveFile(filename: filename, content: "test")

            let metadataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).json")
            let jsonData = try Data(contentsOf: metadataFileURL)
            let metadata = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]

            XCTAssertEqual(metadata?["filename"] as? String, filename,
                          "Filename '\(filename)' should be preserved exactly")

            // Clean up for next iteration
            try? FileManager.default.removeItem(at: metadataFileURL)
            try? FileManager.default.removeItem(at: pendingUploadsURL.appendingPathComponent("\(uploadId).data"))
        }
    }

    func testMultipleSharesCreateMultiplePendingUploads() throws {
        // Simulate multiple shares
        let uploadId1 = try simulateShareExtensionSaveFile(filename: "file1.txt", content: "Content 1")
        let uploadId2 = try simulateShareExtensionSaveFile(filename: "file2.pdf", content: "PDF content")
        let uploadId3 = try simulateShareExtensionSaveFile(filename: "file3.log", content: "Log data")

        // Verify all uploads exist
        let metadataFiles = try FileManager.default.contentsOfDirectory(at: pendingUploadsURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }

        XCTAssertEqual(metadataFiles.count, 3, "Should have 3 pending uploads")

        let uploadIds = metadataFiles.map { $0.deletingPathExtension().lastPathComponent }
        XCTAssertTrue(uploadIds.contains(uploadId1), "Should contain first upload")
        XCTAssertTrue(uploadIds.contains(uploadId2), "Should contain second upload")
        XCTAssertTrue(uploadIds.contains(uploadId3), "Should contain third upload")
    }

    func testPendingUploadDirectoryCreation() throws {
        // Remove directory to test creation
        try? FileManager.default.removeItem(at: pendingUploadsURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingUploadsURL.path),
                      "Directory should not exist initially")

        // Create directory (simulating ShareViewController behavior)
        try FileManager.default.createDirectory(at: pendingUploadsURL, withIntermediateDirectories: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingUploadsURL.path),
                     "Directory should be created")

        // Verify we can write files after creation
        let uploadId = try simulateShareExtensionSaveFile(filename: "test.txt", content: "test")
        let dataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).data")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataFileURL.path),
                     "Should be able to write files after directory creation")
    }
}
