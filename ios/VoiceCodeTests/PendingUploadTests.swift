import XCTest
@testable import VoiceCode

/// Tests for pending upload processing logic.
/// These tests verify the App Group file handling used by ResourcesManager.
final class PendingUploadTests: XCTestCase {

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
        // Clean up test files
        try? FileManager.default.removeItem(at: testContainerURL)
        super.tearDown()
    }

    // MARK: - Test Helper Methods

    private func createPendingUpload(filename: String, content: String) throws -> String {
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

    // MARK: - Tests

    func testFindPendingUploads() throws {
        // Create test uploads
        let uploadId1 = try createPendingUpload(filename: "test1.txt", content: "Test content 1")
        let uploadId2 = try createPendingUpload(filename: "test2.txt", content: "Test content 2")

        // Find all metadata files
        let metadataFiles = try FileManager.default.contentsOfDirectory(at: pendingUploadsURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }

        XCTAssertEqual(metadataFiles.count, 2, "Should find 2 metadata files")

        let uploadIds = metadataFiles.map { $0.deletingPathExtension().lastPathComponent }
        XCTAssertTrue(uploadIds.contains(uploadId1), "Should contain first upload ID")
        XCTAssertTrue(uploadIds.contains(uploadId2), "Should contain second upload ID")
    }

    func testReadPendingUploadMetadata() throws {
        let uploadId = try createPendingUpload(filename: "document.pdf", content: "PDF content here")

        let metadataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).json")
        let jsonData = try Data(contentsOf: metadataFileURL)
        let metadata = try JSONSerialization.jsonObject(with: jsonData) as! [String: Any]

        XCTAssertEqual(metadata["id"] as? String, uploadId, "ID should match")
        XCTAssertEqual(metadata["filename"] as? String, "document.pdf", "Filename should match")
        XCTAssertEqual(metadata["size"] as? Int, 16, "Size should match content length")
        XCTAssertNotNil(metadata["timestamp"], "Should have timestamp")
    }

    func testReadPendingUploadData() throws {
        let testContent = "This is test file content"
        let uploadId = try createPendingUpload(filename: "test.txt", content: testContent)

        let dataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).data")
        let fileData = try Data(contentsOf: dataFileURL)
        let readContent = String(data: fileData, encoding: .utf8)

        XCTAssertEqual(readContent, testContent, "File content should match")
    }

    func testBase64Encoding() throws {
        let testContent = "Test content for base64 encoding"
        let uploadId = try createPendingUpload(filename: "test.txt", content: testContent)

        let dataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).data")
        let fileData = try Data(contentsOf: dataFileURL)
        let base64String = fileData.base64EncodedString()

        // Verify it can be decoded back
        let decodedData = Data(base64Encoded: base64String)
        XCTAssertNotNil(decodedData, "Should decode base64 successfully")
        XCTAssertEqual(String(data: decodedData!, encoding: .utf8), testContent, "Decoded content should match")
    }

    func testDeletePendingUpload() throws {
        let uploadId = try createPendingUpload(filename: "test.txt", content: "Test content")

        let dataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).data")
        let metadataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).json")

        XCTAssertTrue(FileManager.default.fileExists(atPath: dataFileURL.path), "Data file should exist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataFileURL.path), "Metadata file should exist")

        // Delete both files
        try FileManager.default.removeItem(at: dataFileURL)
        try FileManager.default.removeItem(at: metadataFileURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dataFileURL.path), "Data file should be deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataFileURL.path), "Metadata file should be deleted")
    }

    func testEmptyPendingUploadsDirectory() throws {
        let metadataFiles = try FileManager.default.contentsOfDirectory(at: pendingUploadsURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }

        XCTAssertEqual(metadataFiles.count, 0, "Empty directory should have no metadata files")
    }

    func testMultiplePendingUploadsProcessing() throws {
        // Create multiple uploads
        _ = try createPendingUpload(filename: "file1.txt", content: "Content 1")
        _ = try createPendingUpload(filename: "file2.pdf", content: "PDF content")
        _ = try createPendingUpload(filename: "file3.log", content: "Log data")

        let metadataFiles = try FileManager.default.contentsOfDirectory(at: pendingUploadsURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }

        XCTAssertEqual(metadataFiles.count, 3, "Should have 3 pending uploads")

        // Verify each has corresponding data file
        for metadataFile in metadataFiles {
            let uploadId = metadataFile.deletingPathExtension().lastPathComponent
            let dataFile = pendingUploadsURL.appendingPathComponent("\(uploadId).data")
            XCTAssertTrue(FileManager.default.fileExists(atPath: dataFile.path),
                         "Data file should exist for upload \(uploadId)")
        }
    }

    func testFilenameValidation() throws {
        // Test various filename formats
        let testFilenames = [
            "simple.txt",
            "document with spaces.pdf",
            "file-with-dashes.log",
            "file_with_underscores.json",
            "UPPERCASE.TXT",
            "file.multiple.dots.tar.gz"
        ]

        for filename in testFilenames {
            let uploadId = try createPendingUpload(filename: filename, content: "test")

            let metadataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).json")
            let jsonData = try Data(contentsOf: metadataFileURL)
            let metadata = try JSONSerialization.jsonObject(with: jsonData) as! [String: Any]

            XCTAssertEqual(metadata["filename"] as? String, filename,
                          "Filename '\(filename)' should be preserved")
        }
    }

    func testLargeFileHandling() throws {
        // Create a larger test file (1MB)
        let largeContent = String(repeating: "A", count: 1024 * 1024)
        let uploadId = try createPendingUpload(filename: "large.txt", content: largeContent)

        let dataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).data")
        let fileData = try Data(contentsOf: dataFileURL)

        XCTAssertEqual(fileData.count, 1024 * 1024, "Large file size should be preserved")

        // Verify metadata
        let metadataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).json")
        let jsonData = try Data(contentsOf: metadataFileURL)
        let metadata = try JSONSerialization.jsonObject(with: jsonData) as! [String: Any]

        XCTAssertEqual(metadata["size"] as? Int, 1024 * 1024, "Metadata should reflect correct size")
    }

    func testBinaryFileHandling() throws {
        // Create binary data (not UTF-8 text)
        let binaryData = Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0xFD])
        let uploadId = UUID().uuidString.lowercased()

        // Write binary data file
        let dataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).data")
        try binaryData.write(to: dataFileURL)

        // Write metadata
        let metadata: [String: Any] = [
            "id": uploadId,
            "filename": "binary.dat",
            "size": binaryData.count,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        let metadataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).json")
        let jsonData = try JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted)
        try jsonData.write(to: metadataFileURL)

        // Read and verify
        let readData = try Data(contentsOf: dataFileURL)
        XCTAssertEqual(readData, binaryData, "Binary data should be preserved exactly")

        // Verify base64 encoding works for binary
        let base64 = readData.base64EncodedString()
        let decoded = Data(base64Encoded: base64)
        XCTAssertEqual(decoded, binaryData, "Base64 encoding should preserve binary data")
    }
}
