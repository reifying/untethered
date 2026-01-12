// VoiceCodeClientHeartbeatTests.swift
// Unit tests for server heartbeat monitoring and zombie connection detection.
//
// These tests verify:
// - Heartbeat message updates lastHeartbeatReceived timestamp
// - Heartbeat timeout detection triggers zombie connection handling
// - Graceful degradation when server doesn't support heartbeat
// - Heartbeat monitoring starts after authentication
// - Heartbeat monitoring stops on disconnect
//
// Related task: connectivity-1qq.6 (iOS Heartbeat Monitoring)
// Design doc: @docs/design-connectivity-resilience.md

import XCTest
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCode
#endif

final class VoiceCodeClientHeartbeatTests: XCTestCase {

    var client: VoiceCodeClient!
    let testServerURL = "ws://localhost:8080"

    override func setUp() {
        super.setUp()
        client = VoiceCodeClient(serverURL: testServerURL, setupObservers: false)
    }

    override func tearDown() {
        client?.disconnect()
        client = nil
        super.tearDown()
    }

    // MARK: - Heartbeat Constants Tests

    func testHeartbeatConstants_CorrectValues() {
        // Verify heartbeat timing constants match design spec
        XCTAssertEqual(VoiceCodeClient.testableExpectedHeartbeatInterval, 45.0,
                       "Expected heartbeat interval should be 45 seconds")
        XCTAssertEqual(VoiceCodeClient.testableHeartbeatTimeout, 90.0,
                       "Heartbeat timeout should be 90 seconds (2x interval)")
    }

    // MARK: - Heartbeat Message Handling Tests

    func testHandleHeartbeat_UpdatesLastHeartbeatTime() {
        // Given: A client with no heartbeat received yet
        XCTAssertNil(client.testableLastHeartbeatReceived,
                     "lastHeartbeatReceived should initially be nil")

        let beforeTime = Date()

        // When: Heartbeat message is received
        client.testableHandleHeartbeat(["type": "heartbeat", "timestamp": "2025-01-12T12:00:00Z"])

        // Then: lastHeartbeatReceived should be updated
        let lastHeartbeat = client.testableLastHeartbeatReceived
        XCTAssertNotNil(lastHeartbeat, "lastHeartbeatReceived should be set after heartbeat")
        XCTAssertGreaterThanOrEqual(lastHeartbeat!, beforeTime,
                                     "lastHeartbeatReceived should be at or after beforeTime")
    }

    func testHandleHeartbeat_ViaHandleMessage_UpdatesTimestamp() {
        // Given: A client with no heartbeat received yet
        XCTAssertNil(client.testableLastHeartbeatReceived)

        // When: Heartbeat message is handled via main message handler
        client.handleMessage("""
        {"type": "heartbeat", "timestamp": "2025-01-12T12:00:00Z"}
        """)

        // Then: lastHeartbeatReceived should be updated (async on main queue)
        let expectation = XCTestExpectation(description: "Heartbeat processed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertNotNil(self.client.testableLastHeartbeatReceived,
                           "lastHeartbeatReceived should be set after heartbeat message")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testHandleHeartbeat_SubsequentHeartbeats_UpdateTimestamp() {
        // Given: A client that has already received one heartbeat
        let firstTime = Date().addingTimeInterval(-30)  // 30 seconds ago
        client.testableSetLastHeartbeat(firstTime)

        // When: Another heartbeat is received
        let beforeSecondHeartbeat = Date()
        client.testableHandleHeartbeat(["type": "heartbeat", "timestamp": "2025-01-12T12:00:30Z"])

        // Then: Timestamp should be updated to the newer time
        let lastHeartbeat = client.testableLastHeartbeatReceived
        XCTAssertNotNil(lastHeartbeat)
        XCTAssertGreaterThanOrEqual(lastHeartbeat!, beforeSecondHeartbeat,
                                     "lastHeartbeatReceived should be updated to current time")
    }

    // MARK: - Heartbeat Timeout Detection Tests

    func testCheckHeartbeatTimeout_RecentHeartbeat_NoAction() {
        // Given: Client is connected, authenticated, and recently received heartbeat
        client.testableSetConnected(true)
        client.testableSetAuthenticated(true)
        client.testableSetLastHeartbeat(Date())  // Just now

        // When: Timeout check is called
        client.testableCheckHeartbeatTimeout()

        // Then: Client should still be connected (no timeout)
        XCTAssertTrue(client.isConnected, "Client should remain connected with recent heartbeat")
    }

    func testCheckHeartbeatTimeout_OldHeartbeat_TriggersReconnection() {
        // Given: Client is connected, authenticated, with old heartbeat
        client.testableSetConnected(true)
        client.testableSetAuthenticated(true)
        client.testableSetNetworkAvailable(true)
        client.testableSetReconnectionAttempts(3)

        // Set last heartbeat to 100 seconds ago (> 90s timeout)
        let oldHeartbeat = Date().addingTimeInterval(-100)
        client.testableSetLastHeartbeat(oldHeartbeat)

        // When: Timeout check is called
        client.testableCheckHeartbeatTimeout()

        // Then: Reconnection should be triggered (backoff reset to 0)
        // We verify this by checking that reconnectionAttempts was reset
        // (The actual disconnect/reconnect cycle is async and depends on network)
        XCTAssertEqual(client.testableReconnectionAttempts, 0,
                       "Reconnection attempts should reset on zombie detection")
    }

    func testCheckHeartbeatTimeout_ExactlyAtTimeout_NoAction() {
        // Given: Client with heartbeat exactly at timeout threshold
        client.testableSetConnected(true)
        client.testableSetAuthenticated(true)

        // Set last heartbeat to exactly 90 seconds ago (not > 90)
        let borderlineHeartbeat = Date().addingTimeInterval(-90)
        client.testableSetLastHeartbeat(borderlineHeartbeat)

        // When: Timeout check is called
        client.testableCheckHeartbeatTimeout()

        // Then: Client should still be connected (timeout is >90, not >=90)
        XCTAssertTrue(client.isConnected, "Client should remain connected at exactly timeout threshold")
    }

    func testCheckHeartbeatTimeout_NilHeartbeat_GracefulDegradation() {
        // Given: Client is connected but never received a heartbeat (server doesn't support it)
        client.testableSetConnected(true)
        client.testableSetAuthenticated(true)
        client.testableSetLastHeartbeat(nil)

        // When: Timeout check is called
        client.testableCheckHeartbeatTimeout()

        // Then: Client should remain connected (graceful degradation)
        XCTAssertTrue(client.isConnected,
                     "Client should remain connected when server doesn't support heartbeat")
    }

    func testCheckHeartbeatTimeout_NotConnected_NoAction() {
        // Given: Client is not connected
        client.testableSetConnected(false)
        client.testableSetAuthenticated(true)
        client.testableSetLastHeartbeat(Date().addingTimeInterval(-100))

        // When: Timeout check is called
        client.testableCheckHeartbeatTimeout()

        // Then: No action (guard should early return)
        // This test verifies no crash occurs
        XCTAssertFalse(client.isConnected)
    }

    func testCheckHeartbeatTimeout_NotAuthenticated_NoAction() {
        // Given: Client is connected but not authenticated
        client.testableSetConnected(true)
        client.testableSetAuthenticated(false)
        client.testableSetLastHeartbeat(Date().addingTimeInterval(-100))

        // When: Timeout check is called
        client.testableCheckHeartbeatTimeout()

        // Then: No action (guard should early return), client remains connected
        XCTAssertTrue(client.isConnected,
                     "Client should not disconnect when not authenticated")
    }

    // MARK: - Zombie Connection Handling Tests

    func testHandleZombieConnection_ResetsBackoff() {
        // Given: Client with existing backoff attempts
        client.testableSetConnected(true)
        client.testableSetNetworkAvailable(true)
        client.testableSetReconnectionAttempts(5)

        // When: Zombie connection is detected
        client.testableHandleZombieConnection()

        // Then: Backoff should be reset for immediate reconnection
        XCTAssertEqual(client.testableReconnectionAttempts, 0,
                       "Reconnection attempts should reset to 0 on zombie detection")
    }

    func testHandleZombieConnection_ResetsBackoffAndCallsDisconnect() {
        // Given: Client is connected with existing backoff
        client.testableSetConnected(true)
        client.testableSetNetworkAvailable(true)
        client.testableSetReconnectionAttempts(5)

        // When: Zombie connection is detected
        client.testableHandleZombieConnection()

        // Then: Backoff should be reset and heartbeat monitoring should be stopped
        // (disconnect() was called - we verify via side effects)
        XCTAssertEqual(client.testableReconnectionAttempts, 0,
                       "Reconnection attempts should reset on zombie detection")
        // Heartbeat timer should be nil (stopped during disconnect)
        XCTAssertNil(client.testableHeartbeatTimeoutTimer,
                     "Heartbeat monitoring should stop on disconnect")
    }

    func testHandleZombieConnection_NetworkUnavailable_StillResetsBackoff() {
        // Given: Client is connected but network is unavailable
        client.testableSetConnected(true)
        client.testableSetNetworkAvailable(false)
        client.testableSetReconnectionAttempts(5)
        client.startHeartbeatMonitoring()

        // When: Zombie connection is detected
        client.testableHandleZombieConnection()

        // Then: Backoff should reset and heartbeat should stop (disconnect called)
        // connect() is NOT called when network unavailable
        XCTAssertEqual(client.testableReconnectionAttempts, 0,
                       "Backoff should reset even with no network")
        XCTAssertNil(client.testableHeartbeatTimeoutTimer,
                     "Heartbeat monitoring should stop on disconnect")
    }

    func testHandleZombieConnection_RequiresReauth_StillResetsBackoff() {
        // Given: Client requires reauthentication
        client.testableSetConnected(true)
        client.testableSetNetworkAvailable(true)
        client.requiresReauthentication = true
        client.testableSetReconnectionAttempts(5)
        client.startHeartbeatMonitoring()

        // When: Zombie connection is detected
        client.testableHandleZombieConnection()

        // Then: Backoff should reset and heartbeat should stop (disconnect called)
        // connect() is NOT called when reauthentication required
        XCTAssertEqual(client.testableReconnectionAttempts, 0,
                       "Backoff should reset even when reauth required")
        XCTAssertNil(client.testableHeartbeatTimeoutTimer,
                     "Heartbeat monitoring should stop on disconnect")
    }

    // MARK: - Heartbeat Monitoring Lifecycle Tests

    func testStartHeartbeatMonitoring_CreatesTimer() {
        // Given: Client with no heartbeat timer
        XCTAssertNil(client.testableHeartbeatTimeoutTimer,
                     "Heartbeat timer should initially be nil")

        // When: Start heartbeat monitoring
        client.startHeartbeatMonitoring()

        // Then: Timer should be created
        XCTAssertNotNil(client.testableHeartbeatTimeoutTimer,
                        "Heartbeat timer should be created")
    }

    func testStartHeartbeatMonitoring_InitializesLastHeartbeat() {
        // Given: Client with no last heartbeat
        XCTAssertNil(client.testableLastHeartbeatReceived)

        let beforeStart = Date()

        // When: Start heartbeat monitoring
        client.startHeartbeatMonitoring()

        // Then: lastHeartbeatReceived should be initialized to current time
        let lastHeartbeat = client.testableLastHeartbeatReceived
        XCTAssertNotNil(lastHeartbeat, "lastHeartbeatReceived should be initialized")
        XCTAssertGreaterThanOrEqual(lastHeartbeat!, beforeStart,
                                     "lastHeartbeatReceived should be at or after start time")
    }

    func testStartHeartbeatMonitoring_ReplacesExistingTimer() {
        // Given: Existing heartbeat timer
        client.startHeartbeatMonitoring()
        let firstTimer = client.testableHeartbeatTimeoutTimer

        // When: Start heartbeat monitoring again
        client.startHeartbeatMonitoring()

        // Then: Timer should be replaced (not nil, but potentially different instance)
        XCTAssertNotNil(client.testableHeartbeatTimeoutTimer,
                        "Timer should still exist after restart")
    }

    func testStopHeartbeatMonitoring_ClearsTimer() {
        // Given: Active heartbeat timer
        client.startHeartbeatMonitoring()
        XCTAssertNotNil(client.testableHeartbeatTimeoutTimer)

        // When: Stop heartbeat monitoring
        client.stopHeartbeatMonitoring()

        // Then: Timer should be cleared
        XCTAssertNil(client.testableHeartbeatTimeoutTimer,
                     "Heartbeat timer should be nil after stopping")
    }

    func testStopHeartbeatMonitoring_ClearsLastHeartbeat() {
        // Given: Client with heartbeat state
        client.startHeartbeatMonitoring()
        XCTAssertNotNil(client.testableLastHeartbeatReceived)

        // When: Stop heartbeat monitoring
        client.stopHeartbeatMonitoring()

        // Then: lastHeartbeatReceived should be cleared
        XCTAssertNil(client.testableLastHeartbeatReceived,
                     "lastHeartbeatReceived should be nil after stopping")
    }

    func testStopHeartbeatMonitoring_Idempotent() {
        // Given: Client with no heartbeat monitoring
        XCTAssertNil(client.testableHeartbeatTimeoutTimer)
        XCTAssertNil(client.testableLastHeartbeatReceived)

        // When: Stop is called (without ever starting)
        client.stopHeartbeatMonitoring()

        // Then: No crash, state remains nil
        XCTAssertNil(client.testableHeartbeatTimeoutTimer)
        XCTAssertNil(client.testableLastHeartbeatReceived)
    }

    func testDisconnect_StopsHeartbeatMonitoring() {
        // Given: Client with active heartbeat monitoring
        client.startHeartbeatMonitoring()
        XCTAssertNotNil(client.testableHeartbeatTimeoutTimer)

        // When: Client disconnects
        client.disconnect()

        // Then: Heartbeat monitoring should be stopped
        XCTAssertNil(client.testableHeartbeatTimeoutTimer,
                     "Heartbeat timer should be cleared on disconnect")
        XCTAssertNil(client.testableLastHeartbeatReceived,
                     "lastHeartbeatReceived should be cleared on disconnect")
    }

    // MARK: - Integration Tests

    func testFullHeartbeatCycle_NormalOperation() {
        // Simulate a full heartbeat cycle in normal operation

        // 1. Start monitoring (simulates receiving "connected" message)
        client.startHeartbeatMonitoring()
        client.testableSetConnected(true)
        client.testableSetAuthenticated(true)

        // 2. Receive heartbeat from server
        let firstHeartbeatTime = client.testableLastHeartbeatReceived!
        Thread.sleep(forTimeInterval: 0.01)  // Small delay
        client.testableHandleHeartbeat(["type": "heartbeat", "timestamp": "2025-01-12T12:00:45Z"])

        // 3. Verify heartbeat updated timestamp
        let secondHeartbeatTime = client.testableLastHeartbeatReceived!
        XCTAssertGreaterThan(secondHeartbeatTime, firstHeartbeatTime,
                            "Heartbeat should update timestamp")

        // 4. Check timeout (should not trigger with recent heartbeat)
        client.testableCheckHeartbeatTimeout()
        XCTAssertTrue(client.isConnected, "Should remain connected with recent heartbeat")

        // 5. Stop monitoring (simulates disconnect)
        client.stopHeartbeatMonitoring()
        XCTAssertNil(client.testableHeartbeatTimeoutTimer)
    }

    func testFullHeartbeatCycle_ZombieDetection() {
        // Simulate zombie connection detection

        // 1. Start monitoring
        client.startHeartbeatMonitoring()
        client.testableSetConnected(true)
        client.testableSetAuthenticated(true)
        client.testableSetNetworkAvailable(true)
        client.testableSetReconnectionAttempts(5)

        // Verify timer was created
        XCTAssertNotNil(client.testableHeartbeatTimeoutTimer,
                        "Timer should be active during monitoring")

        // 2. Simulate stale heartbeat (server stopped sending)
        client.testableSetLastHeartbeat(Date().addingTimeInterval(-100))

        // 3. Check timeout (should trigger zombie handling)
        client.testableCheckHeartbeatTimeout()

        // 4. Verify reconnection was triggered (verify via side effects)
        XCTAssertEqual(client.testableReconnectionAttempts, 0,
                       "Backoff should reset for reconnection")
        XCTAssertNil(client.testableHeartbeatTimeoutTimer,
                     "Heartbeat monitoring should stop after zombie detected")
    }

    func testHeartbeat_ViaHandleMessage_FullIntegration() {
        // Test heartbeat handling through the main message handler

        // Setup
        client.testableSetConnected(true)
        client.testableSetAuthenticated(true)
        client.startHeartbeatMonitoring()

        let initialHeartbeat = client.testableLastHeartbeatReceived!

        // Small delay to ensure time difference
        Thread.sleep(forTimeInterval: 0.01)

        // Process heartbeat message
        client.handleMessage("""
        {"type": "heartbeat", "timestamp": "2025-01-12T12:00:45.000Z"}
        """)

        // Wait for async processing
        let expectation = XCTestExpectation(description: "Heartbeat processed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let updatedHeartbeat = self.client.testableLastHeartbeatReceived!
            XCTAssertGreaterThan(updatedHeartbeat, initialHeartbeat,
                                "Heartbeat timestamp should be updated")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }
}
