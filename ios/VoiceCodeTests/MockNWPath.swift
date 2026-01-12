// MockNWPath.swift
// Mock implementation of NetworkPathProtocol for unit testing.
//
// Since NWPath is a final class that cannot be subclassed or directly mocked,
// this class provides a testable implementation of NetworkPathProtocol for
// verifying network monitoring logic.

import Foundation
import Network
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCode
#endif

/// Mock implementation of NetworkPathProtocol for unit testing.
/// Allows configuring network status, constraint state, and interface types.
class MockNWPath: NetworkPathProtocol {

    // MARK: - NetworkPathProtocol Properties

    /// The mocked network path status.
    var status: NWPath.Status

    /// Whether the mocked network path is constrained (e.g., Low Data Mode).
    var isConstrained: Bool

    // MARK: - Private Properties

    private var usesWiFi: Bool
    private var usesCellular: Bool
    private var usesEthernet: Bool

    // MARK: - Initialization

    /// Create a mock network path with configurable properties.
    /// - Parameters:
    ///   - status: Network path status (default: .satisfied)
    ///   - isConstrained: Whether the path is constrained (default: false)
    ///   - usesWiFi: Whether the path uses WiFi interface (default: false)
    ///   - usesCellular: Whether the path uses cellular interface (default: false)
    ///   - usesEthernet: Whether the path uses ethernet interface (default: false)
    init(
        status: NWPath.Status = .satisfied,
        isConstrained: Bool = false,
        usesWiFi: Bool = false,
        usesCellular: Bool = false,
        usesEthernet: Bool = false
    ) {
        self.status = status
        self.isConstrained = isConstrained
        self.usesWiFi = usesWiFi
        self.usesCellular = usesCellular
        self.usesEthernet = usesEthernet
    }

    // MARK: - NetworkPathProtocol Methods

    func usesInterfaceType(_ type: NWInterface.InterfaceType) -> Bool {
        switch type {
        case .wifi:
            return usesWiFi
        case .cellular:
            return usesCellular
        case .wiredEthernet:
            return usesEthernet
        default:
            return false
        }
    }

    // MARK: - Factory Methods for Common Scenarios

    /// Create a mock path representing a WiFi connection.
    static func wifiConnected(isConstrained: Bool = false) -> MockNWPath {
        MockNWPath(
            status: .satisfied,
            isConstrained: isConstrained,
            usesWiFi: true,
            usesCellular: false
        )
    }

    /// Create a mock path representing a cellular connection.
    static func cellularConnected(isConstrained: Bool = false) -> MockNWPath {
        MockNWPath(
            status: .satisfied,
            isConstrained: isConstrained,
            usesWiFi: false,
            usesCellular: true
        )
    }

    /// Create a mock path representing no network connection.
    static func noConnection() -> MockNWPath {
        MockNWPath(
            status: .unsatisfied,
            isConstrained: false,
            usesWiFi: false,
            usesCellular: false
        )
    }

    /// Create a mock path representing a captive portal or network that requires connection.
    static func requiresConnection() -> MockNWPath {
        MockNWPath(
            status: .requiresConnection,
            isConstrained: false,
            usesWiFi: false,
            usesCellular: false
        )
    }

    /// Create a mock path representing a constrained (Low Data Mode) WiFi connection.
    static func constrainedWiFi() -> MockNWPath {
        MockNWPath(
            status: .satisfied,
            isConstrained: true,
            usesWiFi: true,
            usesCellular: false
        )
    }

    /// Create a mock path representing an ethernet connection.
    static func ethernetConnected() -> MockNWPath {
        MockNWPath(
            status: .satisfied,
            isConstrained: false,
            usesWiFi: false,
            usesCellular: false,
            usesEthernet: true
        )
    }
}
