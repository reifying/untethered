import XCTest
@testable import VoiceCodeShared

/// Mock file system for testing FileLogDestination
final class MockFileSystem: FileSystemProtocol, @unchecked Sendable {
    private let queue = DispatchQueue(label: "MockFileSystem")
    private var directories: Set<String> = []
    private var files: [String: Data] = [:]
    var createDirectoryCalled = false
    var removedFiles: [URL] = []

    func createDirectory(at url: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws {
        queue.sync {
            createDirectoryCalled = true
            directories.insert(url.path)
        }
    }

    func fileExists(atPath path: String) -> Bool {
        queue.sync {
            directories.contains(path) || files[path] != nil
        }
    }

    func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options: FileManager.DirectoryEnumerationOptions) throws -> [URL] {
        queue.sync {
            files.keys
                .filter { $0.hasPrefix(url.path + "/") }
                .map { URL(fileURLWithPath: $0) }
        }
    }

    func removeItem(at url: URL) throws {
        queue.sync {
            files.removeValue(forKey: url.path)
            removedFiles.append(url)
        }
    }

    func appendData(_ data: Data, to url: URL) throws {
        queue.sync {
            if let existing = files[url.path] {
                files[url.path] = existing + data
            } else {
                files[url.path] = data
            }
        }
    }

    func getFileContents(_ path: String) -> String? {
        queue.sync {
            guard let data = files[path] else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    func addFile(at path: String, contents: String) {
        _ = queue.sync {
            files[path] = contents.data(using: .utf8)
        }
    }

    func addDirectory(_ path: String) {
        _ = queue.sync {
            directories.insert(path)
        }
    }

    func getAllFilePaths() -> [String] {
        queue.sync {
            Array(files.keys)
        }
    }
}

/// Holder for test date that can be safely captured in closures
final class TestDateHolder: @unchecked Sendable {
    var date: Date

    init(_ date: Date = Date()) {
        self.date = date
    }
}

final class FileLogDestinationTests: XCTestCase {
    var mockFileSystem: MockFileSystem!
    var testLogDirectory: URL!
    var testDateHolder: TestDateHolder!

    override func setUp() {
        super.setUp()
        mockFileSystem = MockFileSystem()
        testLogDirectory = URL(fileURLWithPath: "/tmp/test-logs")
        testDateHolder = TestDateHolder()
    }

    override func tearDown() {
        mockFileSystem = nil
        testLogDirectory = nil
        testDateHolder = nil
        super.tearDown()
    }

    func testWriteCreatesDirectory() {
        let dateHolder = testDateHolder!
        let destination = FileLogDestination(
            logDirectory: testLogDirectory,
            retentionDays: 7,
            fileSystem: mockFileSystem,
            dateProvider: { dateHolder.date }
        )

        destination.write("[12:00:00.000] [Test] Test message")

        // Give async write time to complete
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertTrue(mockFileSystem.createDirectoryCalled)
    }

    func testWriteCreatesLogFile() {
        let dateHolder = testDateHolder!
        let destination = FileLogDestination(
            logDirectory: testLogDirectory,
            retentionDays: 7,
            fileSystem: mockFileSystem,
            dateProvider: { dateHolder.date }
        )

        destination.write("[12:00:00.000] [Test] Test message")

        Thread.sleep(forTimeInterval: 0.1)

        let files = mockFileSystem.getAllFilePaths()
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].contains("voicecode-"))
        XCTAssertTrue(files[0].hasSuffix(".log"))
    }

    func testWriteAppendsToFile() {
        let dateHolder = testDateHolder!
        let destination = FileLogDestination(
            logDirectory: testLogDirectory,
            retentionDays: 7,
            fileSystem: mockFileSystem,
            dateProvider: { dateHolder.date }
        )

        destination.write("[12:00:00.000] [Test] Message 1")
        destination.write("[12:00:01.000] [Test] Message 2")
        destination.write("[12:00:02.000] [Test] Message 3")

        Thread.sleep(forTimeInterval: 0.1)

        let files = mockFileSystem.getAllFilePaths()
        XCTAssertEqual(files.count, 1, "Should write to single file")

        let contents = mockFileSystem.getFileContents(files[0])
        XCTAssertNotNil(contents)
        XCTAssertTrue(contents?.contains("Message 1") ?? false)
        XCTAssertTrue(contents?.contains("Message 2") ?? false)
        XCTAssertTrue(contents?.contains("Message 3") ?? false)
    }

    func testLogFileNameFormat() {
        let dateHolder = testDateHolder!
        let calendar = Calendar.current
        let components = DateComponents(year: 2025, month: 12, day: 15)
        let testDate = calendar.date(from: components)!
        dateHolder.date = testDate

        let destination = FileLogDestination(
            logDirectory: testLogDirectory,
            retentionDays: 7,
            fileSystem: mockFileSystem,
            dateProvider: { dateHolder.date }
        )

        destination.write("[12:00:00.000] [Test] Test message")

        Thread.sleep(forTimeInterval: 0.1)

        let files = mockFileSystem.getAllFilePaths()
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].contains("voicecode-2025-12-15.log"))
    }

    func testDailyRotation() {
        let dateHolder = testDateHolder!
        let calendar = Calendar.current

        // Day 1
        let day1Components = DateComponents(year: 2025, month: 12, day: 15)
        dateHolder.date = calendar.date(from: day1Components)!

        let destination = FileLogDestination(
            logDirectory: testLogDirectory,
            retentionDays: 7,
            fileSystem: mockFileSystem,
            dateProvider: { dateHolder.date }
        )

        destination.write("[12:00:00.000] [Test] Day 1 message")

        Thread.sleep(forTimeInterval: 0.1)

        // Day 2
        let day2Components = DateComponents(year: 2025, month: 12, day: 16)
        dateHolder.date = calendar.date(from: day2Components)!

        destination.write("[12:00:00.000] [Test] Day 2 message")

        Thread.sleep(forTimeInterval: 0.1)

        let files = mockFileSystem.getAllFilePaths()
        XCTAssertEqual(files.count, 2, "Should create new file for new day")

        let fileNames = files.map { URL(fileURLWithPath: $0).lastPathComponent }
        XCTAssertTrue(fileNames.contains("voicecode-2025-12-15.log"))
        XCTAssertTrue(fileNames.contains("voicecode-2025-12-16.log"))
    }

    func testCleanupOldLogs() {
        let dateHolder = testDateHolder!
        let calendar = Calendar.current
        let currentComponents = DateComponents(year: 2025, month: 12, day: 20)
        dateHolder.date = calendar.date(from: currentComponents)!

        // Add some old files
        mockFileSystem.addDirectory(testLogDirectory.path)
        mockFileSystem.addFile(at: testLogDirectory.appendingPathComponent("voicecode-2025-12-10.log").path, contents: "Old log 1")
        mockFileSystem.addFile(at: testLogDirectory.appendingPathComponent("voicecode-2025-12-11.log").path, contents: "Old log 2")
        mockFileSystem.addFile(at: testLogDirectory.appendingPathComponent("voicecode-2025-12-15.log").path, contents: "Recent log 1")
        mockFileSystem.addFile(at: testLogDirectory.appendingPathComponent("voicecode-2025-12-19.log").path, contents: "Recent log 2")

        let destination = FileLogDestination(
            logDirectory: testLogDirectory,
            retentionDays: 7,
            fileSystem: mockFileSystem,
            dateProvider: { dateHolder.date }
        )

        destination.cleanupOldLogs()

        Thread.sleep(forTimeInterval: 0.1)

        // Files older than 7 days (before Dec 13) should be removed
        XCTAssertEqual(mockFileSystem.removedFiles.count, 2)

        let removedNames = mockFileSystem.removedFiles.map { $0.lastPathComponent }
        XCTAssertTrue(removedNames.contains("voicecode-2025-12-10.log"))
        XCTAssertTrue(removedNames.contains("voicecode-2025-12-11.log"))
    }

    func testCleanupIgnoresNonLogFiles() {
        let dateHolder = testDateHolder!
        let calendar = Calendar.current
        let currentComponents = DateComponents(year: 2025, month: 12, day: 20)
        dateHolder.date = calendar.date(from: currentComponents)!

        mockFileSystem.addDirectory(testLogDirectory.path)
        mockFileSystem.addFile(at: testLogDirectory.appendingPathComponent("voicecode-2025-12-10.log").path, contents: "Old log")
        mockFileSystem.addFile(at: testLogDirectory.appendingPathComponent("other-file.txt").path, contents: "Not a log")
        mockFileSystem.addFile(at: testLogDirectory.appendingPathComponent("random.log").path, contents: "Wrong format")

        let destination = FileLogDestination(
            logDirectory: testLogDirectory,
            retentionDays: 7,
            fileSystem: mockFileSystem,
            dateProvider: { dateHolder.date }
        )

        destination.cleanupOldLogs()

        Thread.sleep(forTimeInterval: 0.1)

        // Only the properly formatted old log should be removed
        XCTAssertEqual(mockFileSystem.removedFiles.count, 1)
        XCTAssertEqual(mockFileSystem.removedFiles.first?.lastPathComponent, "voicecode-2025-12-10.log")
    }

    func testGetAllLogFiles() {
        let dateHolder = testDateHolder!
        mockFileSystem.addDirectory(testLogDirectory.path)
        mockFileSystem.addFile(at: testLogDirectory.appendingPathComponent("voicecode-2025-12-18.log").path, contents: "Log 1")
        mockFileSystem.addFile(at: testLogDirectory.appendingPathComponent("voicecode-2025-12-19.log").path, contents: "Log 2")
        mockFileSystem.addFile(at: testLogDirectory.appendingPathComponent("voicecode-2025-12-20.log").path, contents: "Log 3")
        mockFileSystem.addFile(at: testLogDirectory.appendingPathComponent("other.txt").path, contents: "Not a log")

        let destination = FileLogDestination(
            logDirectory: testLogDirectory,
            retentionDays: 7,
            fileSystem: mockFileSystem,
            dateProvider: { dateHolder.date }
        )

        let files = destination.getAllLogFiles()

        XCTAssertEqual(files.count, 3)
        // Should be sorted most recent first
        XCTAssertEqual(files[0].lastPathComponent, "voicecode-2025-12-20.log")
        XCTAssertEqual(files[1].lastPathComponent, "voicecode-2025-12-19.log")
        XCTAssertEqual(files[2].lastPathComponent, "voicecode-2025-12-18.log")
    }

    func testGetAllLogFilesEmptyDirectory() {
        let dateHolder = testDateHolder!
        let destination = FileLogDestination(
            logDirectory: testLogDirectory,
            retentionDays: 7,
            fileSystem: mockFileSystem,
            dateProvider: { dateHolder.date }
        )

        let files = destination.getAllLogFiles()
        XCTAssertTrue(files.isEmpty)
    }

    func testCurrentLogFilePath() {
        let dateHolder = testDateHolder!
        let calendar = Calendar.current
        let components = DateComponents(year: 2025, month: 12, day: 15)
        dateHolder.date = calendar.date(from: components)!

        let destination = FileLogDestination(
            logDirectory: testLogDirectory,
            retentionDays: 7,
            fileSystem: mockFileSystem,
            dateProvider: { dateHolder.date }
        )

        // Before any writes, currentLogFilePath returns the expected path
        let path = destination.currentLogFilePath
        XCTAssertNotNil(path)
        XCTAssertEqual(path?.lastPathComponent, "voicecode-2025-12-15.log")
    }

    func testFileLogConfig() {
        // Test default values
        #if os(macOS)
        XCTAssertTrue(FileLogConfig.logDirectory.path.contains("Library/Logs/VoiceCode"))
        #else
        XCTAssertTrue(FileLogConfig.logDirectory.path.contains("Logs"))
        #endif
        XCTAssertEqual(FileLogConfig.retentionDays, 7)
    }

    func testThreadSafety() {
        let dateHolder = testDateHolder!
        let destination = FileLogDestination(
            logDirectory: testLogDirectory,
            retentionDays: 7,
            fileSystem: mockFileSystem,
            dateProvider: { dateHolder.date }
        )

        let expectation = expectation(description: "Concurrent writes complete")
        expectation.expectedFulfillmentCount = 100

        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)

        for i in 0..<100 {
            queue.async {
                destination.write("[12:00:\(String(format: "%02d", i / 100)).000] [Test] Message \(i)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5)

        // Give async writes time to complete
        Thread.sleep(forTimeInterval: 0.2)

        let files = mockFileSystem.getAllFilePaths()
        XCTAssertEqual(files.count, 1, "All writes should go to same file")

        let contents = mockFileSystem.getFileContents(files[0])
        XCTAssertNotNil(contents)

        // Should have 100 lines
        let lines = contents?.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines?.count, 100)
    }
}
