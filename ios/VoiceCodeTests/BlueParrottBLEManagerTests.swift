// BlueParrottBLEManagerTests.swift
// Unit tests for the macOS BlueParrottBLEManager connect/retry/re-arm state
// machine and CBManagerState handling, driven through the injected `BLECentral`
// seam — no real CoreBluetooth/hardware. Mirrors the iOS
// BlueParrottButtonManagerTests retry suite.
//
// Included in VoiceCodeMacTests only; excluded from the iOS VoiceCodeTests
// target via project.yml (macOS-only sources are listed under that target's
// `excludes`). The #if os(macOS) guard is a secondary safeguard.

import XCTest
import CoreBluetooth
@testable import VoiceCode

#if os(macOS)

// MARK: - Test doubles

/// In-memory `BLECentral` so the lifecycle runs without a real CBCentralManager.
private final class FakeBLECentral: BLECentral {
    var managerState: CBManagerState
    weak var centralDelegate: BLECentralEvents?
    var scanCount = 0
    var stopScanCount = 0
    var cancelCount = 0
    var subscribeCount = 0
    /// Records every App-Mode enable payload written (empty when none — the
    /// persistent path must never write).
    var enableWrites: [Data] = []

    init(state: CBManagerState = .poweredOn) { managerState = state }

    func scanForButtonService() { scanCount += 1 }
    func stopScan() { stopScanCount += 1 }
    func cancelConnection() { cancelCount += 1 }
    func subscribeToButtonEvents() { subscribeCount += 1 }
    func writeAppModeEnable(_ payload: Data) { enableWrites.append(payload) }
}

/// Captures scheduled connect work so tests fire it synchronously instead of
/// waiting on real GCD timers.
private final class ScheduleRecorder {
    private(set) var scheduled: [(delay: TimeInterval, work: DispatchWorkItem)] = []
    var count: Int { scheduled.count }
    var lastDelay: TimeInterval? { scheduled.last?.delay }

    lazy var schedule: (TimeInterval, DispatchWorkItem) -> Void = { [weak self] delay, work in
        self?.scheduled.append((delay, work))
    }

    func fireLatest() { scheduled.last?.work.perform() }
}

/// Records the ordered sequence of delegate calls so a parsed gesture can be
/// matched to exactly one dispatched method.
private final class DelegateSpy: BlueParrottButtonDelegate {
    private(set) var calls: [BlueParrottButtonEvent] = []
    func blueParrottButtonDown() { calls.append(.down) }
    func blueParrottButtonUp() { calls.append(.up) }
    func blueParrottTap() { calls.append(.tap) }
    func blueParrottDoubleTap() { calls.append(.doubleTap) }
    func blueParrottLongPress() { calls.append(.longPress) }
}

final class BlueParrottBLEManagerTests: XCTestCase {

    private func makeManager(state: CBManagerState = .poweredOn)
        -> (BlueParrottBLEManager, FakeBLECentral, ScheduleRecorder) {
        let central = FakeBLECentral(state: state)
        let recorder = ScheduleRecorder()
        let manager = BlueParrottBLEManager(central: central, scheduleWork: recorder.schedule)
        return (manager, central, recorder)
    }

    // MARK: - Construction / hookup

    func testInit_doesNotScheduleUntilStart() {
        let (_, _, recorder) = makeManager()
        XCTAssertEqual(recorder.count, 0)
    }

    func testInit_wiresCentralDelegate() {
        let (manager, central, _) = makeManager()
        XCTAssertTrue(central.centralDelegate === manager)
    }

    func testDelegate_hookupPoint() {
        let (manager, _, _) = makeManager()
        let spy = DelegateSpy()
        manager.delegate = spy
        XCTAssertTrue(manager.delegate === spy)
    }

    // MARK: - Initial connect

    func testStart_whenPoweredOn_schedulesFirstScanAtInitialDelay() {
        let (manager, central, recorder) = makeManager(state: .poweredOn)

        manager.start()

        XCTAssertEqual(recorder.count, 1)
        XCTAssertEqual(recorder.lastDelay, BlueParrottBLEManager.initialDelay)
        XCTAssertFalse(manager.testInSlowRetry)

        recorder.fireLatest()
        XCTAssertEqual(central.scanCount, 1)
    }

    func testStart_whenNotPoweredOn_waitsForPowerOn() {
        let (manager, central, recorder) = makeManager(state: .unknown)

        manager.start()
        XCTAssertEqual(recorder.count, 0, "should not scan until Bluetooth is powered on")

        central.managerState = .poweredOn
        central.centralDelegate?.bleDidUpdateState(.poweredOn)

        XCTAssertEqual(recorder.count, 1)
        XCTAssertEqual(recorder.lastDelay, BlueParrottBLEManager.initialDelay)
    }

    func testStart_isIdempotent() {
        let (manager, _, recorder) = makeManager(state: .poweredOn)
        manager.start()
        manager.start()
        XCTAssertEqual(recorder.count, 1)
    }

    // MARK: - Retry → slow retry

    func testTransientFailures_exhaustFastRetries_thenSlowRetry() {
        let (manager, central, recorder) = makeManager(state: .poweredOn)
        manager.start()

        // 1 initial attempt + maxRetries retries before dropping to slow retry.
        let fastAttempts = BlueParrottBLEManager.maxRetries + 1
        for _ in 0..<fastAttempts {
            recorder.fireLatest()
            central.centralDelegate?.bleDidFailToConnect(true)
        }

        XCTAssertEqual(central.scanCount, fastAttempts)
        XCTAssertTrue(manager.testInSlowRetry,
                      "should switch to low-frequency retry once fast retries are exhausted")
        XCTAssertEqual(recorder.lastDelay, BlueParrottBLEManager.slowRetryDelay,
                       "exhausted retries should schedule at the slow interval, not give up")
    }

    func testSlowRetry_thenHeadsetReachable_connectsAndResets() {
        let (manager, central, recorder) = makeManager(state: .poweredOn)
        manager.start()
        let fastAttempts = BlueParrottBLEManager.maxRetries + 1
        for _ in 0..<fastAttempts {
            recorder.fireLatest()
            central.centralDelegate?.bleDidFailToConnect(true)
        }
        XCTAssertTrue(manager.testInSlowRetry)

        // Next slow-retry tick fires and the headset is now reachable.
        recorder.fireLatest()
        XCTAssertEqual(central.scanCount, fastAttempts + 1)

        central.centralDelegate?.bleDidConnect()

        XCTAssertTrue(manager.isConnected)
        XCTAssertFalse(manager.testInSlowRetry)
        XCTAssertEqual(manager.testRetryCount, 0)
    }

    func testNonRetryableFailure_doesNotReschedule() {
        let (manager, central, recorder) = makeManager(state: .poweredOn)
        manager.start()
        recorder.fireLatest()
        let before = recorder.count

        central.centralDelegate?.bleDidFailToConnect(false)

        XCTAssertEqual(recorder.count, before, "non-retryable failure should not schedule another attempt")
        XCTAssertFalse(manager.testInSlowRetry)
    }

    func testBleDidConnect_setsConnectedAndResetsRetry() {
        let (manager, central, recorder) = makeManager(state: .poweredOn)
        manager.start()
        recorder.fireLatest()
        central.centralDelegate?.bleDidFailToConnect(true)
        XCTAssertEqual(manager.testRetryCount, 1)

        central.centralDelegate?.bleDidConnect()

        XCTAssertTrue(manager.isConnected)
        XCTAssertEqual(manager.testRetryCount, 0)
        XCTAssertFalse(manager.testInSlowRetry)
    }

    // MARK: - Disconnect / reconnect

    func testDisconnect_marksDisconnectedAndReArmsRetry() {
        let (manager, central, recorder) = makeManager(state: .poweredOn)
        manager.start()
        central.centralDelegate?.bleDidConnect()
        XCTAssertTrue(manager.isConnected)
        let before = recorder.count

        central.centralDelegate?.bleDidDisconnect()

        XCTAssertFalse(manager.isConnected)
        XCTAssertEqual(recorder.count, before + 1, "disconnect should re-arm a reconnect attempt")
        XCTAssertEqual(recorder.lastDelay, BlueParrottBLEManager.initialDelay)
    }

    func testReconnect_afterExhaustion_reArmsFastRetry() {
        let (manager, central, recorder) = makeManager(state: .poweredOn)
        manager.start()
        let fastAttempts = BlueParrottBLEManager.maxRetries + 1
        for _ in 0..<fastAttempts {
            recorder.fireLatest()
            central.centralDelegate?.bleDidFailToConnect(true)
        }
        XCTAssertTrue(manager.testInSlowRetry)

        manager.reconnect()

        XCTAssertFalse(manager.testInSlowRetry, "reconnect should re-arm the fast retry cycle")
        XCTAssertEqual(manager.testRetryCount, 0)
        XCTAssertEqual(recorder.lastDelay, BlueParrottBLEManager.initialDelay)
    }

    func testReconnect_whenConnected_doesNothing() {
        let (manager, central, recorder) = makeManager(state: .poweredOn)
        manager.start()
        central.centralDelegate?.bleDidConnect()
        let before = recorder.count

        manager.reconnect()

        XCTAssertEqual(recorder.count, before, "no re-arm should occur while connected")
    }

    // MARK: - Stop

    func testStop_haltsRetriesAndCancelsConnection() {
        let (manager, central, recorder) = makeManager(state: .poweredOn)
        manager.start()
        recorder.fireLatest()
        central.centralDelegate?.bleDidFailToConnect(true)

        manager.stop()
        let scansAfterStop = central.scanCount

        // Pending work that fires after stop() must not scan, and a late failure
        // callback must not re-arm.
        recorder.fireLatest()
        central.centralDelegate?.bleDidFailToConnect(true)

        XCTAssertEqual(central.scanCount, scansAfterStop, "no scan attempts after stop()")
        XCTAssertFalse(manager.testInSlowRetry)
        XCTAssertEqual(central.cancelCount, 1)
        XCTAssertEqual(central.stopScanCount, 1)
        XCTAssertFalse(manager.isConnected)
    }

    // MARK: - CBManagerState handling

    func testPoweredOff_marksDisconnected() {
        let (manager, central, _) = makeManager(state: .poweredOn)
        manager.start()
        central.centralDelegate?.bleDidConnect()
        XCTAssertTrue(manager.isConnected)

        central.centralDelegate?.bleDidUpdateState(.poweredOff)

        XCTAssertFalse(manager.isConnected)
    }

    func testUnauthorized_doesNotScheduleOrCrash() {
        let (manager, central, recorder) = makeManager(state: .unauthorized)
        manager.start()

        central.centralDelegate?.bleDidUpdateState(.unauthorized)

        XCTAssertEqual(recorder.count, 0)
        XCTAssertFalse(manager.isConnected)
    }

    func testUnsupported_doesNotSchedule() {
        let (manager, central, recorder) = makeManager(state: .unsupported)
        manager.start()

        central.centralDelegate?.bleDidUpdateState(.unsupported)

        XCTAssertEqual(recorder.count, 0)
    }

    func testResetting_marksDisconnected() {
        let (manager, central, _) = makeManager(state: .poweredOn)
        manager.start()
        central.centralDelegate?.bleDidConnect()

        central.centralDelegate?.bleDidUpdateState(.resetting)

        XCTAssertFalse(manager.isConnected)
    }

    // MARK: - Connect: subscribe + conditional App-Mode enable

    func testConnect_subscribesToButtonEvents() {
        let (manager, central, _) = makeManager(state: .poweredOn)
        manager.start()

        central.centralDelegate?.bleDidConnect()

        XCTAssertEqual(central.subscribeCount, 1, "connect should subscribe to the button-event characteristic")
        XCTAssertTrue(manager.isSDKModeEnabled)
    }

    func testConnect_whenAppModePersistent_doesNotWriteEnable() {
        let (manager, central, _) = makeManager(state: .poweredOn)
        XCTAssertTrue(manager.appModePersistent, "default reflects the b4i.3 experiment (persistent)")
        manager.start()

        central.centralDelegate?.bleDidConnect()

        XCTAssertTrue(central.enableWrites.isEmpty,
                      "persistent App Mode must skip the enable write (it already streams events)")
    }

    func testConnect_whenAppModeNotPersistent_writesEnablePayload() {
        let (manager, central, _) = makeManager(state: .poweredOn)
        manager.appModePersistent = false
        manager.start()

        central.centralDelegate?.bleDidConnect()

        XCTAssertEqual(central.enableWrites, [BPGatt.appModeEnablePayload],
                       "a never-enabled headset must receive the \"sdk\" enable payload exactly once")
    }

    func testConnect_whenAppModeNotPersistent_doesNotClaimSDKModeEnabled() {
        let (manager, central, _) = makeManager(state: .poweredOn)
        manager.appModePersistent = false
        manager.start()

        central.centralDelegate?.bleDidConnect()

        XCTAssertFalse(manager.isSDKModeEnabled,
                       "the unconfirmed fallback enable write must not optimistically report App Mode active")
    }

    func testDisconnect_clearsSDKModeEnabled() {
        let (manager, central, _) = makeManager(state: .poweredOn)
        manager.start()
        central.centralDelegate?.bleDidConnect()
        XCTAssertTrue(manager.isSDKModeEnabled)

        central.centralDelegate?.bleDidDisconnect()

        XCTAssertFalse(manager.isSDKModeEnabled)
    }

    // MARK: - Button value → parse → dispatch

    func testButtonDown_dispatchesDownToDelegate() {
        let (manager, central, _) = makeManager(state: .poweredOn)
        let spy = DelegateSpy()
        manager.delegate = spy
        manager.start()
        central.centralDelegate?.bleDidConnect()

        central.centralDelegate?.bleDidUpdateButtonValue(Data([0x01])) // down
        flushMainQueue()

        XCTAssertEqual(spy.calls, [.down])
    }

    func testEachGesture_dispatchesMatchingDelegateMethodInOrder() {
        let (manager, central, _) = makeManager(state: .poweredOn)
        let spy = DelegateSpy()
        manager.delegate = spy
        manager.start()
        central.centralDelegate?.bleDidConnect()

        // Captured opcodes (firmware 2.6.4): down, up, tap, double-tap, long-press.
        for byte in [0x01, 0x00, 0x02, 0x03, 0x04] as [UInt8] {
            central.centralDelegate?.bleDidUpdateButtonValue(Data([byte]))
        }
        flushMainQueue()

        XCTAssertEqual(spy.calls, [.down, .up, .tap, .doubleTap, .longPress])
    }

    func testUnknownAndEmptyPayloads_areDroppedNotMisclassified() {
        let (manager, central, _) = makeManager(state: .poweredOn)
        let spy = DelegateSpy()
        manager.delegate = spy
        manager.start()
        central.centralDelegate?.bleDidConnect()

        central.centralDelegate?.bleDidUpdateButtonValue(Data([0xFF])) // unknown opcode
        central.centralDelegate?.bleDidUpdateButtonValue(Data())       // empty payload
        flushMainQueue()

        XCTAssertTrue(spy.calls.isEmpty, "unknown/empty payloads must be dropped, never guessed at")
    }

    func testNoDelegate_unknownPayload_doesNotCrash() {
        let (manager, central, _) = makeManager(state: .poweredOn)
        manager.start()
        central.centralDelegate?.bleDidConnect()

        central.centralDelegate?.bleDidUpdateButtonValue(Data([0x01]))
        flushMainQueue()
        // No delegate set — reaching here without a crash is the assertion.
    }

    // MARK: - Helpers

    /// Drain the main queue so `dispatch(_:)`'s async delegate hop has run before
    /// asserting. FIFO ordering guarantees prior async work runs before this.
    private func flushMainQueue() {
        let exp = expectation(description: "main queue drained")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }
}

#endif
