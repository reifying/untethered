import XCTest
@testable import VoiceCodeShared

final class VoiceCodeSharedTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(VoiceCodeShared.version, "1.0.0")
    }
}
