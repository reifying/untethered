// NetworkPathProtocol.swift
// Protocol abstraction for NWPath to enable unit testing of network monitoring logic.
//
// NWPath is a final class that cannot be subclassed or directly mocked.
// This protocol captures the interface needed by our network monitoring code
// and allows injecting mock network paths in tests.

import Network

/// Protocol abstraction for NWPath to enable testability.
/// NWPath is a final class that cannot be subclassed or mocked directly.
protocol NetworkPathProtocol {
    /// The current network path status.
    var status: NWPath.Status { get }

    /// Whether the network path is constrained (e.g., Low Data Mode).
    var isConstrained: Bool { get }

    /// Check if the network path uses a specific interface type.
    /// - Parameter type: The interface type to check (e.g., .wifi, .cellular)
    /// - Returns: True if the path uses the specified interface type.
    func usesInterfaceType(_ type: NWInterface.InterfaceType) -> Bool
}

// MARK: - NWPath Conformance

extension NWPath: NetworkPathProtocol {}
