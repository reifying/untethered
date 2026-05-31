// BluetoothAudioMonitorTests.swift
// Unit tests for BluetoothAudioMonitor lifecycle and callback delivery.
// Included in VoiceCodeMacTests only; excluded from iOS VoiceCodeTests target
// via project.yml. The #if os(macOS) guard is a secondary safeguard.

import XCTest
@testable import VoiceCode

#if os(macOS)

final class BluetoothAudioMonitorTests: XCTestCase {

    // MARK: - Lifecycle

    func testInit_succeeds() {
        let monitor = BluetoothAudioMonitor()
        XCTAssertNotNil(monitor)
    }

    func testStopMonitoring_beforeStart_doesNotCrash() {
        let monitor = BluetoothAudioMonitor()
        // Two protections prevent a crash when stop is called before start:
        // - stopMonitoringCurrentDevice() returns early via the kAudioObjectUnknown guard
        // - deviceListenerActive is false, so AudioObjectRemovePropertyListenerBlock is skipped
        monitor.stopMonitoring()
    }

    func testStartMonitoring_withoutBluetoothDevice_doesNotCrash() {
        let monitor = BluetoothAudioMonitor()
        var callbackInvoked = false
        monitor.startMonitoring { _ in callbackInvoked = true }
        // No BT device in CI — device list enumeration runs without crash.
        // The callback is not invoked at this point.
        XCTAssertFalse(callbackInvoked)
    }

    func testStopMonitoring_afterStart_doesNotCrash() {
        let monitor = BluetoothAudioMonitor()
        monitor.startMonitoring { _ in }
        monitor.stopMonitoring()
    }

    func testStopMonitoring_isIdempotent() {
        let monitor = BluetoothAudioMonitor()
        monitor.startMonitoring { _ in }
        monitor.stopMonitoring()
        monitor.stopMonitoring() // second call must not crash
    }

    func testDeinit_callsStopMonitoring() {
        // Verify that deinit doesn't crash when the monitor was started.
        // We rely on the guard in stopMonitoringCurrentDevice() for safety.
        var monitor: BluetoothAudioMonitor? = BluetoothAudioMonitor()
        monitor?.startMonitoring { _ in }
        monitor = nil // triggers deinit → stopMonitoring()
    }

    // MARK: - Callback Delivery

    func testSimulateMuteChanged_invokesCallback_withMutedTrue() {
        let monitor = BluetoothAudioMonitor()
        var received: Bool?
        monitor.startMonitoring { isMuted in received = isMuted }

        monitor.simulateMuteChanged(isMuted: true)

        XCTAssertEqual(received, true)
    }

    func testSimulateMuteChanged_invokesCallback_withMutedFalse() {
        let monitor = BluetoothAudioMonitor()
        var received: Bool?
        monitor.startMonitoring { isMuted in received = isMuted }

        monitor.simulateMuteChanged(isMuted: false)

        XCTAssertEqual(received, false)
    }

    func testSimulateMuteChanged_afterStop_doesNotInvokeCallback() {
        let monitor = BluetoothAudioMonitor()
        var callCount = 0
        monitor.startMonitoring { _ in callCount += 1 }
        monitor.stopMonitoring()

        monitor.simulateMuteChanged(isMuted: true)

        // stopMonitoring() nils out onMuteChanged, so the callback is not invoked.
        XCTAssertEqual(callCount, 0)
    }

    func testSimulateMuteChanged_multipleTimes_invokesCallbackEachTime() {
        let monitor = BluetoothAudioMonitor()
        var received: [Bool] = []
        monitor.startMonitoring { isMuted in received.append(isMuted) }

        monitor.simulateMuteChanged(isMuted: false)
        monitor.simulateMuteChanged(isMuted: true)
        monitor.simulateMuteChanged(isMuted: false)

        XCTAssertEqual(received, [false, true, false])
    }

    func testStartMonitoring_replacesCallback_onSecondCall() {
        let monitor = BluetoothAudioMonitor()
        var firstCount = 0
        var secondCount = 0

        monitor.startMonitoring { _ in firstCount += 1 }
        // Second call replaces the callback and does NOT double-register the
        // device list listener (deviceListenerActive guards the registration).
        monitor.startMonitoring { _ in secondCount += 1 }

        monitor.simulateMuteChanged(isMuted: true)

        XCTAssertEqual(firstCount, 0)
        XCTAssertEqual(secondCount, 1)
    }
}

#endif
