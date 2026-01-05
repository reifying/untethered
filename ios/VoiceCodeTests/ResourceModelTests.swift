import XCTest
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCodeMac
#endif

final class ResourceModelTests: XCTestCase {
    
    func testResourceInitFromJSON() {
        // Given
        let json: [String: Any] = [
            "filename": "test.pdf",
            "path": ".untethered/resources/test.pdf",
            "size": 12345 as Int64,
            "timestamp": "2025-11-14T10:30:00Z"
        ]
        
        // When
        let resource = Resource(json: json)
        
        // Then
        XCTAssertNotNil(resource)
        XCTAssertEqual(resource?.filename, "test.pdf")
        XCTAssertEqual(resource?.path, ".untethered/resources/test.pdf")
        XCTAssertEqual(resource?.size, 12345)
    }
    
    func testResourceInitFromJSONWithMissingFields() {
        // Given
        let json: [String: Any] = [
            "filename": "test.pdf"
            // Missing required fields
        ]
        
        // When
        let resource = Resource(json: json)
        
        // Then
        XCTAssertNil(resource)
    }
    
    func testResourceFormattedSize() {
        // Given
        let resource = Resource(
            filename: "test.pdf",
            path: ".untethered/resources/test.pdf",
            size: 1024,
            timestamp: Date()
        )
        
        // When
        let formattedSize = resource.formattedSize
        
        // Then
        XCTAssertTrue(formattedSize.contains("KB") || formattedSize.contains("bytes"))
    }
    
    func testResourceEquality() {
        // Given
        let id = UUID()
        let date = Date()
        let resource1 = Resource(id: id, filename: "test.pdf", path: ".untethered/resources/test.pdf", size: 1024, timestamp: date)
        let resource2 = Resource(id: id, filename: "test.pdf", path: ".untethered/resources/test.pdf", size: 1024, timestamp: date)
        let resource3 = Resource(filename: "other.pdf", path: ".untethered/resources/other.pdf", size: 2048, timestamp: date)
        
        // Then
        XCTAssertEqual(resource1, resource2)
        XCTAssertNotEqual(resource1, resource3)
    }
}
