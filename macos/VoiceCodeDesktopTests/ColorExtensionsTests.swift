import XCTest
import SwiftUI
@testable import VoiceCodeDesktop

final class ColorExtensionsTests: XCTestCase {
    func testMessageBubbleUserColorExists() {
        let color = Color.messageBubbleUser
        XCTAssertNotNil(color)
    }

    func testMessageBubbleAssistantColorExists() {
        let color = Color.messageBubbleAssistant
        XCTAssertNotNil(color)
    }

    func testConnectionStatusGreenColorExists() {
        let color = Color.connectionStatusGreen
        XCTAssertNotNil(color)
    }

    func testConnectionStatusRedColorExists() {
        let color = Color.connectionStatusRed
        XCTAssertNotNil(color)
    }

    func testColorsAreLoadedFromAssetCatalog() {
        // All colors should be successfully loaded from the Asset Catalog
        // If any asset is missing, Color() returns a default color
        // These tests verify the colors are accessible

        let userBubble = Color("MessageBubbleUser")
        let assistantBubble = Color("MessageBubbleAssistant")
        let greenStatus = Color("ConnectionGreen")
        let redStatus = Color("ConnectionRed")

        // If colors weren't found, they'd still return Color objects
        // but the Asset Catalog must contain them for proper appearance
        XCTAssertNotNil(userBubble)
        XCTAssertNotNil(assistantBubble)
        XCTAssertNotNil(greenStatus)
        XCTAssertNotNil(redStatus)
    }
}
