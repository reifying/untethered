// VoiceCodeClientNetworkTests.swift
// Unit tests for network monitoring infrastructure and connectivity resilience.
//
// These tests verify:
// - NetworkPathProtocol abstraction works correctly
// - MockNWPath provides testable network path simulation
// - Network status mapping logic is correct
// - Interface change detection (WiFi↔Cellular handoff) works
//
// Related task: connectivity-1qq.1 (Test infrastructure)
// Design doc: @docs/design-connectivity-resilience.md

import XCTest
import Network
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCode
#endif

final class VoiceCodeClientNetworkTests: XCTestCase {

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

    // MARK: - MockNWPath Tests

    func testMockNWPath_DefaultValues() {
        // Given: A default mock path
        let mockPath = MockNWPath()

        // Then: Should have sensible defaults
        XCTAssertEqual(mockPath.status, .satisfied)
        XCTAssertFalse(mockPath.isConstrained)
        XCTAssertFalse(mockPath.usesInterfaceType(.wifi))
        XCTAssertFalse(mockPath.usesInterfaceType(.cellular))
    }

    func testMockNWPath_WiFiConnected() {
        // Given: A WiFi-connected mock path
        let mockPath = MockNWPath.wifiConnected()

        // Then: Should report WiFi usage
        XCTAssertEqual(mockPath.status, .satisfied)
        XCTAssertFalse(mockPath.isConstrained)
        XCTAssertTrue(mockPath.usesInterfaceType(.wifi))
        XCTAssertFalse(mockPath.usesInterfaceType(.cellular))
    }

    func testMockNWPath_CellularConnected() {
        // Given: A cellular-connected mock path
        let mockPath = MockNWPath.cellularConnected()

        // Then: Should report cellular usage
        XCTAssertEqual(mockPath.status, .satisfied)
        XCTAssertFalse(mockPath.isConstrained)
        XCTAssertFalse(mockPath.usesInterfaceType(.wifi))
        XCTAssertTrue(mockPath.usesInterfaceType(.cellular))
    }

    func testMockNWPath_NoConnection() {
        // Given: A mock path with no connection
        let mockPath = MockNWPath.noConnection()

        // Then: Should report unsatisfied status
        XCTAssertEqual(mockPath.status, .unsatisfied)
        XCTAssertFalse(mockPath.usesInterfaceType(.wifi))
        XCTAssertFalse(mockPath.usesInterfaceType(.cellular))
    }

    func testMockNWPath_ConstrainedWiFi() {
        // Given: A constrained WiFi mock path (Low Data Mode)
        let mockPath = MockNWPath.constrainedWiFi()

        // Then: Should report constrained status
        XCTAssertEqual(mockPath.status, .satisfied)
        XCTAssertTrue(mockPath.isConstrained)
        XCTAssertTrue(mockPath.usesInterfaceType(.wifi))
    }

    func testMockNWPath_RequiresConnection() {
        // Given: A mock path that requires connection (captive portal)
        let mockPath = MockNWPath.requiresConnection()

        // Then: Should report requiresConnection status
        XCTAssertEqual(mockPath.status, .requiresConnection)
    }

    func testMockNWPath_EthernetConnected() {
        // Given: An ethernet-connected mock path
        let mockPath = MockNWPath.ethernetConnected()

        // Then: Should report ethernet usage
        XCTAssertEqual(mockPath.status, .satisfied)
        XCTAssertTrue(mockPath.usesInterfaceType(.wiredEthernet))
        XCTAssertFalse(mockPath.usesInterfaceType(.wifi))
        XCTAssertFalse(mockPath.usesInterfaceType(.cellular))
    }

    func testMockNWPath_CustomConfiguration() {
        // Given: A custom-configured mock path
        let mockPath = MockNWPath(
            status: .satisfied,
            isConstrained: true,
            usesWiFi: true,
            usesCellular: true  // Rare but possible (simultaneous connections)
        )

        // Then: Should reflect custom configuration
        XCTAssertEqual(mockPath.status, .satisfied)
        XCTAssertTrue(mockPath.isConstrained)
        XCTAssertTrue(mockPath.usesInterfaceType(.wifi))
        XCTAssertTrue(mockPath.usesInterfaceType(.cellular))
    }

    // MARK: - Network Status Mapping Tests

    func testMapPathToStatus_Satisfied_ReturnsAvailable() {
        // Given: A mock path with satisfied status
        let mockPath = MockNWPath(status: .satisfied, isConstrained: false)

        // When: Mapping to status
        let status = client.testableMapPathToStatus(mockPath)

        // Then: Should return available
        XCTAssertEqual(status, .available)
    }

    func testMapPathToStatus_SatisfiedConstrained_ReturnsConstrained() {
        // Given: A mock path with satisfied but constrained status
        let mockPath = MockNWPath(status: .satisfied, isConstrained: true)

        // When: Mapping to status
        let status = client.testableMapPathToStatus(mockPath)

        // Then: Should return constrained
        XCTAssertEqual(status, .constrained)
    }

    func testMapPathToStatus_Unsatisfied_ReturnsUnavailable() {
        // Given: A mock path with unsatisfied status
        let mockPath = MockNWPath(status: .unsatisfied, isConstrained: false)

        // When: Mapping to status
        let status = client.testableMapPathToStatus(mockPath)

        // Then: Should return unavailable
        XCTAssertEqual(status, .unavailable)
    }

    func testMapPathToStatus_RequiresConnection_ReturnsUnknown() {
        // Given: A mock path that requires connection (captive portal)
        let mockPath = MockNWPath(status: .requiresConnection, isConstrained: false)

        // When: Mapping to status
        let status = client.testableMapPathToStatus(mockPath)

        // Then: Should return unknown
        XCTAssertEqual(status, .unknown)
    }

    func testMapPathToStatus_WiFi_ReturnsAvailable() {
        // Given: A WiFi-connected mock path
        let mockPath = MockNWPath.wifiConnected()

        // When: Mapping to status
        let status = client.testableMapPathToStatus(mockPath)

        // Then: Should return available
        XCTAssertEqual(status, .available)
    }

    func testMapPathToStatus_Cellular_ReturnsAvailable() {
        // Given: A cellular-connected mock path
        let mockPath = MockNWPath.cellularConnected()

        // When: Mapping to status
        let status = client.testableMapPathToStatus(mockPath)

        // Then: Should return available
        XCTAssertEqual(status, .available)
    }

    // MARK: - Interface Change Detection Tests

    func testDidInterfaceChange_WiFiToCellular_ReturnsTrue() {
        // Given: Old path on WiFi, new path on Cellular
        let oldPath = MockNWPath.wifiConnected()
        let newPath = MockNWPath.cellularConnected()

        // When: Checking for interface change
        let changed = client.testableDidInterfaceChange(from: oldPath, to: newPath)

        // Then: Should detect change
        XCTAssertTrue(changed)
    }

    func testDidInterfaceChange_CellularToWiFi_ReturnsTrue() {
        // Given: Old path on Cellular, new path on WiFi
        let oldPath = MockNWPath.cellularConnected()
        let newPath = MockNWPath.wifiConnected()

        // When: Checking for interface change
        let changed = client.testableDidInterfaceChange(from: oldPath, to: newPath)

        // Then: Should detect change
        XCTAssertTrue(changed)
    }

    func testDidInterfaceChange_WiFiToWiFi_ReturnsFalse() {
        // Given: Both paths on WiFi
        let oldPath = MockNWPath.wifiConnected()
        let newPath = MockNWPath.wifiConnected()

        // When: Checking for interface change
        let changed = client.testableDidInterfaceChange(from: oldPath, to: newPath)

        // Then: Should NOT detect change (same interface)
        XCTAssertFalse(changed)
    }

    func testDidInterfaceChange_CellularToCellular_ReturnsFalse() {
        // Given: Both paths on Cellular
        let oldPath = MockNWPath.cellularConnected()
        let newPath = MockNWPath.cellularConnected()

        // When: Checking for interface change
        let changed = client.testableDidInterfaceChange(from: oldPath, to: newPath)

        // Then: Should NOT detect change (same interface)
        XCTAssertFalse(changed)
    }

    func testDidInterfaceChange_NilOldPath_ReturnsFalse() {
        // Given: No old path (initial connection)
        let newPath = MockNWPath.wifiConnected()

        // When: Checking for interface change with nil old path
        let changed = client.testableDidInterfaceChange(from: nil, to: newPath)

        // Then: Should NOT detect change (no previous path to compare)
        XCTAssertFalse(changed)
    }

    func testDidInterfaceChange_WiFiToNoConnection_ReturnsTrue() {
        // Given: Old path on WiFi, new path with no connection
        let oldPath = MockNWPath.wifiConnected()
        let newPath = MockNWPath.noConnection()

        // When: Checking for interface change
        let changed = client.testableDidInterfaceChange(from: oldPath, to: newPath)

        // Then: Should detect change (WiFi status changed)
        // Note: This is a change from "usesWiFi=true" to "usesWiFi=false"
        XCTAssertTrue(changed)
    }

    func testDidInterfaceChange_NoConnectionToCellular_ReturnsTrue() {
        // Given: Old path with no connection, new path on Cellular
        let oldPath = MockNWPath.noConnection()
        let newPath = MockNWPath.cellularConnected()

        // When: Checking for interface change
        let changed = client.testableDidInterfaceChange(from: oldPath, to: newPath)

        // Then: Should detect change (cellular status changed)
        XCTAssertTrue(changed)
    }

    func testDidInterfaceChange_ConstrainedToUnconstrained_ReturnsFalse() {
        // Given: Old path constrained WiFi, new path regular WiFi
        let oldPath = MockNWPath.constrainedWiFi()
        let newPath = MockNWPath.wifiConnected()

        // When: Checking for interface change
        let changed = client.testableDidInterfaceChange(from: oldPath, to: newPath)

        // Then: Should NOT detect change (still WiFi)
        XCTAssertFalse(changed)
    }

    func testDidInterfaceChange_EthernetToWiFi_ReturnsTrue() {
        // Given: Old path on Ethernet, new path on WiFi
        let oldPath = MockNWPath.ethernetConnected()
        let newPath = MockNWPath.wifiConnected()

        // When: Checking for interface change
        let changed = client.testableDidInterfaceChange(from: oldPath, to: newPath)

        // Then: Should detect change (WiFi status changed)
        // Note: We only track WiFi↔Cellular changes, so this is technically a "change"
        // because WiFi went from false to true
        XCTAssertTrue(changed)
    }

    // MARK: - Test Accessor Tests

    func testTestableSetConnected_SetsIsConnected() {
        // Given: Client with isConnected = false
        XCTAssertFalse(client.isConnected)

        // When: Setting connected via test accessor
        client.testableSetConnected(true)

        // Then: isConnected should be true
        XCTAssertTrue(client.isConnected)
    }

    func testTestableSetAuthenticated_SetsIsAuthenticated() {
        // Given: Client with isAuthenticated = false
        XCTAssertFalse(client.isAuthenticated)

        // When: Setting authenticated via test accessor
        client.testableSetAuthenticated(true)

        // Then: isAuthenticated should be true
        XCTAssertTrue(client.isAuthenticated)
    }

    func testTestableSetReconnectionAttempts_SetsAttempts() {
        // Given: Client with default reconnection attempts
        XCTAssertEqual(client.testableReconnectionAttempts, 0)

        // When: Setting attempts via test accessor
        client.testableSetReconnectionAttempts(5)

        // Then: Attempts should be 5
        XCTAssertEqual(client.testableReconnectionAttempts, 5)
    }

    func testTestableReconnectionTimer_InitiallyNil() {
        // Given: A freshly created client (not connected)
        let freshClient = VoiceCodeClient(serverURL: testServerURL, setupObservers: false)

        // Then: Reconnection timer should be nil
        XCTAssertNil(freshClient.testableReconnectionTimer)
    }

    // MARK: - NetworkStatus Enum Tests

    func testNetworkStatus_Equatable() {
        // Verify NetworkStatus is Equatable
        XCTAssertEqual(NetworkStatus.available, NetworkStatus.available)
        XCTAssertEqual(NetworkStatus.unavailable, NetworkStatus.unavailable)
        XCTAssertEqual(NetworkStatus.constrained, NetworkStatus.constrained)
        XCTAssertEqual(NetworkStatus.unknown, NetworkStatus.unknown)

        XCTAssertNotEqual(NetworkStatus.available, NetworkStatus.unavailable)
        XCTAssertNotEqual(NetworkStatus.available, NetworkStatus.constrained)
        XCTAssertNotEqual(NetworkStatus.available, NetworkStatus.unknown)
    }

    // MARK: - Reconnection Behavior Tests

    func testSetupReconnection_NetworkUnavailable_DoesNotScheduleTimer() {
        // Given: Network is unavailable
        client.testableSetNetworkAvailable(false)

        // When: Setup reconnection is called
        client.testableSetupReconnection()

        // Then: No timer should be scheduled
        XCTAssertNil(client.testableReconnectionTimer)
    }

    func testSetupReconnection_NetworkAvailable_SchedulesTimer() {
        // Given: Network is available
        client.testableSetNetworkAvailable(true)

        // When: Setup reconnection is called
        client.testableSetupReconnection()

        // Then: Timer should be scheduled
        XCTAssertNotNil(client.testableReconnectionTimer)
    }

    func testNetworkBecameAvailable_ResetsBackoff() {
        // Given: Client was disconnected with backoff attempts
        client.testableSetReconnectionAttempts(5)
        client.testableSetConnected(false)
        client.testableSetNetworkAvailable(true)

        // When: Network becomes available
        client.testableHandleNetworkBecameAvailable()

        // Then: Backoff should be reset to 0
        XCTAssertEqual(client.testableReconnectionAttempts, 0)
    }

    func testNetworkBecameUnavailable_CancelsReconnectionTimer() {
        // Given: Network is available and timer is scheduled
        client.testableSetNetworkAvailable(true)
        client.testableSetupReconnection()
        XCTAssertNotNil(client.testableReconnectionTimer)

        // When: Network becomes unavailable
        client.testableHandleNetworkBecameUnavailable()

        // Then: Timer should be cancelled
        XCTAssertNil(client.testableReconnectionTimer)
    }

    func testAppBecameActive_NetworkUnavailable_DoesNotReconnect() {
        // Given: Client is disconnected and network is unavailable
        client.testableSetConnected(false)
        client.testableSetNetworkAvailable(false)

        // When: App becomes active
        client.testableHandleAppBecameActive()

        // Then: Should NOT have attempted connection (still disconnected)
        XCTAssertFalse(client.isConnected)
    }

    func testAppBecameActive_NetworkAvailable_AttemptsReconnect() {
        // Given: Client is disconnected and network is available with previous backoff
        client.testableSetConnected(false)
        client.testableSetNetworkAvailable(true)
        client.testableSetReconnectionAttempts(5)  // Simulate previous backoff

        // When: App becomes active
        // Note: This will attempt connect() but fail since there's no real server
        // The test verifies the code path is taken by checking reconnectionAttempts is reset
        client.testableHandleAppBecameActive()

        // Then: Backoff should be reset (indicating reconnection was attempted)
        XCTAssertEqual(client.testableReconnectionAttempts, 0)
    }

    func testNetworkAvailabilityAccessor_ReturnsCorrectValue() {
        // Given: Network availability is set
        client.testableSetNetworkAvailable(true)
        XCTAssertTrue(client.testableIsNetworkAvailable)

        // When: Set to false
        client.testableSetNetworkAvailable(false)

        // Then: Should return false
        XCTAssertFalse(client.testableIsNetworkAvailable)
    }

    // MARK: - Integration Tests (test methods work together)

    func testMapStatusAndInterfaceChange_Scenario_WiFiToCellularHandoff() {
        // Scenario: User walks away from WiFi and switches to cellular
        let wifiPath = MockNWPath.wifiConnected()
        let cellularPath = MockNWPath.cellularConnected()

        // Both paths should be "available"
        XCTAssertEqual(client.testableMapPathToStatus(wifiPath), .available)
        XCTAssertEqual(client.testableMapPathToStatus(cellularPath), .available)

        // But interface DID change
        XCTAssertTrue(client.testableDidInterfaceChange(from: wifiPath, to: cellularPath))
    }

    func testMapStatusAndInterfaceChange_Scenario_NetworkDropped() {
        // Scenario: Network becomes unavailable
        let wifiPath = MockNWPath.wifiConnected()
        let noConnectionPath = MockNWPath.noConnection()

        // Status should change from available to unavailable
        XCTAssertEqual(client.testableMapPathToStatus(wifiPath), .available)
        XCTAssertEqual(client.testableMapPathToStatus(noConnectionPath), .unavailable)

        // Interface also changed (WiFi went away)
        XCTAssertTrue(client.testableDidInterfaceChange(from: wifiPath, to: noConnectionPath))
    }

    func testMapStatusAndInterfaceChange_Scenario_LowDataModeToggle() {
        // Scenario: User enables Low Data Mode while on WiFi
        let wifiPath = MockNWPath.wifiConnected()
        let constrainedPath = MockNWPath.constrainedWiFi()

        // Status should change from available to constrained
        XCTAssertEqual(client.testableMapPathToStatus(wifiPath), .available)
        XCTAssertEqual(client.testableMapPathToStatus(constrainedPath), .constrained)

        // But interface did NOT change (still WiFi)
        XCTAssertFalse(client.testableDidInterfaceChange(from: wifiPath, to: constrainedPath))
    }
}
