import XCTest
import SwiftUI
@testable import VoiceCodeDesktop
@testable import VoiceCodeShared

@MainActor
final class ConnectionStatusIndicatorTests: XCTestCase {

    // MARK: - ConnectionStatusIndicator Tests

    func testConnectionStatusIndicatorInitializesWithConnected() {
        let view = ConnectionStatusIndicator(connectionState: .connected)
        XCTAssertNotNil(view)
    }

    func testConnectionStatusIndicatorInitializesWithDisconnected() {
        let view = ConnectionStatusIndicator(connectionState: .disconnected)
        XCTAssertNotNil(view)
    }

    func testConnectionStatusIndicatorInitializesWithConnecting() {
        let view = ConnectionStatusIndicator(connectionState: .connecting)
        XCTAssertNotNil(view)
    }

    func testConnectionStatusIndicatorInitializesWithAuthenticating() {
        let view = ConnectionStatusIndicator(connectionState: .authenticating)
        XCTAssertNotNil(view)
    }

    func testConnectionStatusIndicatorInitializesWithReconnecting() {
        let view = ConnectionStatusIndicator(connectionState: .reconnecting)
        XCTAssertNotNil(view)
    }

    func testConnectionStatusIndicatorInitializesWithFailed() {
        let view = ConnectionStatusIndicator(connectionState: .failed)
        XCTAssertNotNil(view)
    }

    func testConnectionStatusIndicatorWithCustomSize() {
        let view = ConnectionStatusIndicator(connectionState: .connected, size: 24)
        XCTAssertNotNil(view)
    }

    func testConnectionStatusIndicatorAllStates() {
        // Verify all ConnectionState cases can be handled
        for state in ConnectionState.allCases {
            let view = ConnectionStatusIndicator(connectionState: state)
            XCTAssertNotNil(view, "ConnectionStatusIndicator should handle \(state)")
        }
    }

    // MARK: - ConnectionStatusDot Tests

    func testConnectionStatusDotInitializesWithConnected() {
        let view = ConnectionStatusDot(connectionState: .connected)
        XCTAssertNotNil(view)
    }

    func testConnectionStatusDotInitializesWithDisconnected() {
        let view = ConnectionStatusDot(connectionState: .disconnected)
        XCTAssertNotNil(view)
    }

    func testConnectionStatusDotInitializesWithConnecting() {
        let view = ConnectionStatusDot(connectionState: .connecting)
        XCTAssertNotNil(view)
    }

    func testConnectionStatusDotInitializesWithAuthenticating() {
        let view = ConnectionStatusDot(connectionState: .authenticating)
        XCTAssertNotNil(view)
    }

    func testConnectionStatusDotInitializesWithReconnecting() {
        let view = ConnectionStatusDot(connectionState: .reconnecting)
        XCTAssertNotNil(view)
    }

    func testConnectionStatusDotInitializesWithFailed() {
        let view = ConnectionStatusDot(connectionState: .failed)
        XCTAssertNotNil(view)
    }

    func testConnectionStatusDotWithCustomSize() {
        let view = ConnectionStatusDot(connectionState: .connected, size: 12)
        XCTAssertNotNil(view)
    }

    func testConnectionStatusDotAllStates() {
        // Verify all ConnectionState cases can be handled
        for state in ConnectionState.allCases {
            let view = ConnectionStatusDot(connectionState: state)
            XCTAssertNotNil(view, "ConnectionStatusDot should handle \(state)")
        }
    }

    // MARK: - ConnectionStatusText Tests

    func testConnectionStatusTextInitializesWithConnected() {
        let view = ConnectionStatusText(connectionState: .connected)
        XCTAssertNotNil(view)
    }

    func testConnectionStatusTextInitializesWithDisconnected() {
        let view = ConnectionStatusText(connectionState: .disconnected)
        XCTAssertNotNil(view)
    }

    func testConnectionStatusTextInitializesWithConnecting() {
        let view = ConnectionStatusText(connectionState: .connecting)
        XCTAssertNotNil(view)
    }

    func testConnectionStatusTextInitializesWithAuthenticating() {
        let view = ConnectionStatusText(connectionState: .authenticating)
        XCTAssertNotNil(view)
    }

    func testConnectionStatusTextInitializesWithReconnecting() {
        let view = ConnectionStatusText(connectionState: .reconnecting)
        XCTAssertNotNil(view)
    }

    func testConnectionStatusTextInitializesWithFailed() {
        let view = ConnectionStatusText(connectionState: .failed)
        XCTAssertNotNil(view)
    }

    func testConnectionStatusTextWithDetails() {
        let view = ConnectionStatusText(
            connectionState: .connected,
            showDetails: true,
            serverURL: "localhost",
            serverPort: "8080"
        )
        XCTAssertNotNil(view)
    }

    func testConnectionStatusTextWithoutDetails() {
        let view = ConnectionStatusText(
            connectionState: .connected,
            showDetails: false
        )
        XCTAssertNotNil(view)
    }

    func testConnectionStatusTextWithEmptyServerURL() {
        let view = ConnectionStatusText(
            connectionState: .connected,
            showDetails: true,
            serverURL: "",
            serverPort: "8080"
        )
        XCTAssertNotNil(view)
    }

    func testConnectionStatusTextAllStates() {
        // Verify all ConnectionState cases can be handled
        for state in ConnectionState.allCases {
            let view = ConnectionStatusText(connectionState: state)
            XCTAssertNotNil(view, "ConnectionStatusText should handle \(state)")
        }
    }
}
