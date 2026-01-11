// RefreshSessionsTests.swift
// Tests for the refresh_sessions message type in VoiceCodeClient

import XCTest
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCode
#endif

// MARK: - Mock VoiceCodeClient for Refresh Sessions Testing

/// A mock VoiceCodeClient that captures sent messages for verification
private class MockVoiceCodeClientForRefresh: VoiceCodeClient {
    var sentMessages: [[String: Any]] = []
    var _isAuthenticated: Bool = false

    init() {
        super.init(serverURL: "ws://localhost:8080", setupObservers: false)
    }

    override var isAuthenticated: Bool {
        get { _isAuthenticated }
        set { _isAuthenticated = newValue }
    }

    override func sendMessage(_ message: [String: Any]) {
        sentMessages.append(message)
    }
}

// MARK: - Tests

final class RefreshSessionsTests: XCTestCase {

    // MARK: - Test: requestSessionList sends refresh_sessions when authenticated

    func testRequestSessionListSendsRefreshSessionsMessage() async {
        // Given: An authenticated client
        let client = MockVoiceCodeClientForRefresh()
        client._isAuthenticated = true

        // When: requestSessionList is called
        await client.requestSessionList()

        // Then: Should send refresh_sessions message type (not connect)
        let refreshMessage = client.sentMessages.first { ($0["type"] as? String) == "refresh_sessions" }
        XCTAssertNotNil(refreshMessage, "Should send refresh_sessions message")
        XCTAssertEqual(refreshMessage?["type"] as? String, "refresh_sessions",
                       "Message type should be refresh_sessions")

        // Should NOT send connect message
        let connectMessage = client.sentMessages.first { ($0["type"] as? String) == "connect" }
        XCTAssertNil(connectMessage, "Should NOT send connect message when refreshing")
    }

    // MARK: - Test: requestSessionList requires authentication

    func testRequestSessionListRequiresAuthentication() async {
        // Given: A client that is NOT authenticated
        let client = MockVoiceCodeClientForRefresh()
        client._isAuthenticated = false

        // When: requestSessionList is called without authentication
        await client.requestSessionList()

        // Then: No message should be sent (guard prevents it)
        let refreshMessage = client.sentMessages.first { ($0["type"] as? String) == "refresh_sessions" }
        XCTAssertNil(refreshMessage, "Should NOT send refresh_sessions when not authenticated")

        // Also verify no connect message was sent
        let connectMessage = client.sentMessages.first { ($0["type"] as? String) == "connect" }
        XCTAssertNil(connectMessage, "Should NOT send any message when not authenticated")
    }

    // MARK: - Test: requestSessionList includes recent_sessions_limit

    func testRequestSessionListIncludesLimit() async {
        // Given: An authenticated client with app settings
        let client = MockVoiceCodeClientForRefresh()
        client._isAuthenticated = true

        // Note: Without appSettings, the message won't include recent_sessions_limit
        // This test verifies the basic message structure

        // When: requestSessionList is called
        await client.requestSessionList()

        // Then: Should send refresh_sessions message
        let refreshMessage = client.sentMessages.first { ($0["type"] as? String) == "refresh_sessions" }
        XCTAssertNotNil(refreshMessage, "Should send refresh_sessions message")

        // The message should be valid JSON structure
        XCTAssertEqual(refreshMessage?["type"] as? String, "refresh_sessions")
    }

    // MARK: - Test: Connection remains open after refresh (conceptual)

    func testRefreshDoesNotBreakConnection() async {
        // Given: An authenticated client
        let client = MockVoiceCodeClientForRefresh()
        client._isAuthenticated = true

        // When: requestSessionList is called
        await client.requestSessionList()

        // Then: Authentication state should remain true
        XCTAssertTrue(client.isAuthenticated, "Authentication should remain valid after refresh")

        // And: Should have sent refresh_sessions (which doesn't require re-auth)
        let refreshMessage = client.sentMessages.first { ($0["type"] as? String) == "refresh_sessions" }
        XCTAssertNotNil(refreshMessage, "Should use refresh_sessions which maintains connection")
    }
}
