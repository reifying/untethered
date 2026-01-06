import XCTest
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCode
#endif

final class VoiceCodeClientResourcesTests: XCTestCase {
    var client: VoiceCodeClient!
    
    override func setUp() {
        super.setUp()
        client = VoiceCodeClient(
            serverURL: "ws://localhost:3000",
            setupObservers: false
        )
    }

    // Helper to wait for main queue async operations including debounced updates
    private func waitForMainQueue() {
        // Run the main run loop to process pending async operations
        // VoiceCodeClient uses 0.1s debounce delay, so we need to wait longer
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
    }
    
    func testHandleResourcesListMessage() {
        // Given
        let resourcesJSON = """
        {
            "type": "resources_list",
            "resources": [
                {
                    "filename": "test1.pdf",
                    "path": ".untethered/resources/test1.pdf",
                    "size": 1024,
                    "timestamp": "2025-11-14T10:30:00Z"
                },
                {
                    "filename": "test2.png",
                    "path": ".untethered/resources/test2.png",
                    "size": 2048,
                    "timestamp": "2025-11-14T10:31:00Z"
                }
            ],
            "storage_location": "/Users/test/project"
        }
        """
        
        // When
        client.handleMessage(resourcesJSON)
        waitForMainQueue()

        // Then
        XCTAssertEqual(client.resourcesList.count, 2)
        XCTAssertEqual(client.resourcesList[0].filename, "test1.pdf")
        XCTAssertEqual(client.resourcesList[0].size, 1024)
        XCTAssertEqual(client.resourcesList[1].filename, "test2.png")
        XCTAssertEqual(client.resourcesList[1].size, 2048)
    }

    func testHandleResourcesListMessageEmpty() {
        // Given
        let resourcesJSON = """
        {
            "type": "resources_list",
            "resources": [],
            "storage_location": "/Users/test/project"
        }
        """

        // When
        client.handleMessage(resourcesJSON)
        waitForMainQueue()

        // Then
        XCTAssertEqual(client.resourcesList.count, 0)
    }
    
    func testHandleResourceDeletedMessage() {
        // Given - populate resources list first
        client.resourcesList = [
            Resource(filename: "test1.pdf", path: ".untethered/resources/test1.pdf", size: 1024, timestamp: Date()),
            Resource(filename: "test2.png", path: ".untethered/resources/test2.png", size: 2048, timestamp: Date())
        ]

        let deleteJSON = """
        {
            "type": "resource_deleted",
            "filename": "test1.pdf",
            "path": "/Users/test/project/.untethered/resources/test1.pdf"
        }
        """

        // When
        client.handleMessage(deleteJSON)
        waitForMainQueue()

        // Then
        XCTAssertEqual(client.resourcesList.count, 1)
        XCTAssertEqual(client.resourcesList[0].filename, "test2.png")
    }
    
    func testHandleFileUploadedMessage() {
        // Given
        let uploadJSON = """
        {
            "type": "file_uploaded",
            "filename": "test.pdf",
            "path": ".untethered/resources/test.pdf",
            "size": 1024,
            "timestamp": "2025-11-14T10:30:00Z"
        }
        """

        // When
        client.handleMessage(uploadJSON)
        waitForMainQueue()

        // Then
        XCTAssertNotNil(client.fileUploadResponse)
        XCTAssertEqual(client.fileUploadResponse?.filename, "test.pdf")
        XCTAssertTrue(client.fileUploadResponse?.success ?? false)
    }
}
