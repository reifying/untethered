// BLEManagerTests.swift
// Unit tests for BLE spike (non-hardware-dependent parts only)

import XCTest
import CoreBluetooth
@testable import VoiceCode

final class BLEManagerTests: XCTestCase {

    // MARK: - UUID Constants

    func testServiceUUIDParsesCorrectly() {
        let uuid = BLEConstants.serviceUUID
        XCTAssertEqual(uuid.uuidString, "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")
    }

    func testCharacteristicUUIDParsesCorrectly() {
        let uuid = BLEConstants.characteristicUUID
        XCTAssertEqual(uuid.uuidString, "A1B2C3D4-E5F6-7890-ABCD-EF1234567891")
    }

    func testServiceAndCharacteristicUUIDsAreDifferent() {
        XCTAssertNotEqual(BLEConstants.serviceUUID, BLEConstants.characteristicUUID)
    }

    func testLocalName() {
        XCTAssertEqual(BLEConstants.localName, "VoiceCode")
    }

    // MARK: - Connection State

    func testConnectionStateRawValues() {
        XCTAssertEqual(BLEConnectionState.idle.rawValue, "idle")
        XCTAssertEqual(BLEConnectionState.scanning.rawValue, "scanning")
        XCTAssertEqual(BLEConnectionState.advertising.rawValue, "advertising")
        XCTAssertEqual(BLEConnectionState.connecting.rawValue, "connecting")
        XCTAssertEqual(BLEConnectionState.connected.rawValue, "connected")
        XCTAssertEqual(BLEConnectionState.disconnected.rawValue, "disconnected")
    }

    func testAllConnectionStatesAreUnique() {
        let allCases: [BLEConnectionState] = [.idle, .scanning, .advertising, .connecting, .connected, .disconnected]
        let rawValues = allCases.map(\.rawValue)
        XCTAssertEqual(Set(rawValues).count, allCases.count, "All connection state raw values should be unique")
    }

    // MARK: - BLEManager Initial State

    func testInitialConnectionStateIsIdle() {
        let manager = BLEManager()
        XCTAssertEqual(manager.connectionState, .idle)
    }

    func testInitialConnectedPeerNameIsNil() {
        let manager = BLEManager()
        XCTAssertNil(manager.connectedPeerName)
    }

    func testInitialLastReceivedMessageIsNil() {
        let manager = BLEManager()
        XCTAssertNil(manager.lastReceivedMessage)
    }

    func testInitialLastSentMessageIsNil() {
        let manager = BLEManager()
        XCTAssertNil(manager.lastSentMessage)
    }
}
