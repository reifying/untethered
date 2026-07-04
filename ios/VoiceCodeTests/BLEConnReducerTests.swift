// BLEConnReducerTests.swift
// Table tests for the pure connection reducer. `ConnReducer.reduce` carries no
// I/O, so coverage is exhaustive and hardware-free — every (state, event) pair,
// with emphasis on the stale-id-hang fix (F1), the continuous-scan invariant
// (the tick must NOT tear down the scan), the watchdogs, and the held-peripheral
// reconnect. See @docs/design/macos-headset-loop-state-machine.md §Connection machine.
//
// Only `CBManagerState` is referenced, available on iOS too, so this file is
// unguarded and runs under both `make test` (iOS) and the macOS unit bundle —
// no project.yml exclude.

import XCTest
import CoreBluetooth
@testable import VoiceCode

final class BLEConnReducerTests: XCTestCase {

    /// True if `fx` carries any `.resolveKnownPeripheral(_)` (the associated UUID
    /// makes `contains(_:)` awkward; this matches regardless of the id).
    private func containsResolveKnown(_ fx: [BLEConnEffect]) -> Bool {
        fx.contains { if case .resolveKnownPeripheral = $0 { return true }; return false }
    }

    /// Pulls the UUID out of the first `.resolveKnownPeripheral(_)`, or nil if none.
    private func resolvedID(_ fx: [BLEConnEffect]) -> UUID? {
        for case let .resolveKnownPeripheral(id) in fx { return id }
        return nil
    }

    // MARK: - Stop / unavailable (from any state)

    func testStop_fromAnyState_tearsDownEverything() {
        for s: BLEConnState in [.stopped, .unavailable(.poweredOff), .scanning(attempt: 3),
                                .connecting(.known), .connecting(.advertised),
                                .discovering, .live, .reconnecting] {
            let (state, fx) = ConnReducer.reduce(s, .stop, savedID: UUID())
            XCTAssertEqual(state, .stopped, "stop must go to .stopped from \(s)")
            XCTAssertTrue(fx.contains(.stopScan))
            XCTAssertTrue(fx.contains(.cancelConnection))
            XCTAssertTrue(fx.contains(.cancelTimer(.scanTick)))
            XCTAssertTrue(fx.contains(.cancelTimer(.connectWatchdog)))
            XCTAssertTrue(fx.contains(.cancelTimer(.discoveryWatchdog)))
        }
    }

    func testManagerStateNotPoweredOn_fromAnyState_goesUnavailable() {
        for st: CBManagerState in [.poweredOff, .unauthorized, .unsupported, .resetting, .unknown] {
            let (state, fx) = ConnReducer.reduce(.live, .managerState(st), savedID: nil)
            XCTAssertEqual(state, .unavailable(st), "managerState \(st.rawValue) must go to .unavailable")
            XCTAssertFalse(fx.contains(.startContinuousScan), "no retry storm while unavailable")
        }
    }

    func testManagerStatePoweredOn_whileLive_isNoOp() {
        // poweredOn is only meaningful out of .unavailable (recovery) or .stopped (start);
        // a redundant poweredOn while already live is ignored, not a re-scan.
        let (state, fx) = ConnReducer.reduce(.live, .managerState(.poweredOn), savedID: UUID())
        XCTAssertEqual(state, .live)
        XCTAssertTrue(fx.isEmpty)
    }

    // MARK: - Powered on → prefer known peripheral, else scan

    func testStart_withSavedID_resolvesKnown_armsConnectWatchdog() {
        let id = UUID()
        let (state, fx) = ConnReducer.reduce(.stopped, .start, savedID: id)
        XCTAssertEqual(state, .connecting(.known))
        XCTAssertEqual(resolvedID(fx), id, "resolve must carry the saved id")
        XCTAssertTrue(fx.contains(.armTimer(.connectWatchdog)), "the speculative known connect must be watchdogged")
        XCTAssertFalse(fx.contains(.startContinuousScan), "a saved id is tried before scanning")
    }

    func testStart_withoutSavedID_startsContinuousScan() {
        let (state, fx) = ConnReducer.reduce(.stopped, .start, savedID: nil)
        XCTAssertEqual(state, .scanning(attempt: 1))
        XCTAssertTrue(fx.contains(.startContinuousScan))
        XCTAssertTrue(fx.contains(.armTimer(.scanTick)))
        XCTAssertFalse(containsResolveKnown(fx), "no saved id → no resolve")
    }

    func testRecoveryFromUnavailable_withSavedID_resolvesKnown() {
        let id = UUID()
        let (state, fx) = ConnReducer.reduce(.unavailable(.poweredOff), .managerState(.poweredOn), savedID: id)
        XCTAssertEqual(state, .connecting(.known))
        XCTAssertEqual(resolvedID(fx), id)
        XCTAssertTrue(fx.contains(.armTimer(.connectWatchdog)))
    }

    func testRecoveryFromUnavailable_withoutSavedID_scans() {
        let (state, fx) = ConnReducer.reduce(.unavailable(.poweredOff), .managerState(.poweredOn), savedID: nil)
        XCTAssertEqual(state, .scanning(attempt: 1))
        XCTAssertTrue(fx.contains(.startContinuousScan))
    }

    // MARK: - Known connect path (resolve / empty / stale-id watchdog)

    func testKnownResolved_issuesConnectKnown_staysConnecting() {
        let (state, fx) = ConnReducer.reduce(.connecting(.known), .knownPeripheralResolved, savedID: UUID())
        XCTAssertEqual(state, .connecting(.known), "watchdog already armed; just issue the connect")
        XCTAssertEqual(fx, [.connectKnown])
    }

    /// Empty retrieve (re-paired / reset / different host): fall straight to scan,
    /// clearing the id, WITHOUT waiting out the watchdog.
    func testEmptyRetrieve_fallsToScanImmediately_clearingId() {
        let (state, fx) = ConnReducer.reduce(.connecting(.known), .knownPeripheralUnresolved, savedID: UUID())
        XCTAssertEqual(state, .scanning(attempt: 1))
        XCTAssertTrue(fx.contains(.clearSavedIdentifier))
        XCTAssertTrue(fx.contains(.startContinuousScan))
        XCTAssertTrue(fx.contains(.armTimer(.scanTick)))
        XCTAssertTrue(fx.contains(.cancelTimer(.connectWatchdog)), "no need to wait out the watchdog")
    }

    /// The stale-id-hang fix (F1 / Opus consult): a resolved-but-unreachable id whose
    /// connect never completes must cancel, forget the id, and scan.
    func testKnownConnect_watchdog_clearsStaleIdAndScans() {
        let (state, fx) = ConnReducer.reduce(.connecting(.known), .connectWatchdog, savedID: UUID())
        XCTAssertEqual(state, .scanning(attempt: 1))
        XCTAssertTrue(fx.contains(.cancelConnection))
        XCTAssertTrue(fx.contains(.clearSavedIdentifier))
        XCTAssertTrue(fx.contains(.startContinuousScan))
        XCTAssertTrue(fx.contains(.armTimer(.scanTick)))
    }

    // MARK: - Continuous scan + advertised connect

    /// The continuous-scan invariant: the tick re-arms and bumps the attempt counter
    /// but must NEVER stop the running scan (findings F1).
    func testScanTick_doesNotStopTheRunningScan() {
        let (state, fx) = ConnReducer.reduce(.scanning(attempt: 1), .scanTick, savedID: nil)
        XCTAssertEqual(state, .scanning(attempt: 2), "the tick bumps the attempt counter")
        XCTAssertTrue(fx.contains(.armTimer(.scanTick)), "the tick re-arms itself")
        XCTAssertFalse(fx.contains(.stopScan), "continuous scan: the tick must not tear down the scan")
        XCTAssertFalse(fx.contains(.startContinuousScan), "the scan is already running; don't restart it")
    }

    func testAdvertisementDiscovered_connectsAdvertised_stopsScan_armsWatchdog() {
        let (state, fx) = ConnReducer.reduce(.scanning(attempt: 4), .advertisementDiscovered, savedID: nil)
        XCTAssertEqual(state, .connecting(.advertised))
        XCTAssertTrue(fx.contains(.stopScan), "a discovered peripheral ends the scan")
        XCTAssertTrue(fx.contains(.cancelTimer(.scanTick)))
        XCTAssertTrue(fx.contains(.connectAdvertised))
        XCTAssertTrue(fx.contains(.armTimer(.connectWatchdog)), "a silent advertised connect must not hang")
    }

    /// An advertised connect that stalls recovers to scan but, unlike the known path,
    /// must NOT clear a saved id (the advertised connect was not from one).
    func testAdvertisedConnect_isWatchdogged_andRecoversToScan() {
        let (state, fx) = ConnReducer.reduce(.connecting(.advertised), .connectWatchdog, savedID: UUID())
        XCTAssertEqual(state, .scanning(attempt: 1))
        XCTAssertTrue(fx.contains(.cancelConnection))
        XCTAssertTrue(fx.contains(.startContinuousScan))
        XCTAssertFalse(fx.contains(.clearSavedIdentifier), "advertised connect is not from a saved id")
    }

    // MARK: - connected / connectFailed (both modes)

    func testConnected_fromAdvertised_discovers_cancelsConnectWatchdog() {
        let (state, fx) = ConnReducer.reduce(.connecting(.advertised), .connected, savedID: nil)
        XCTAssertEqual(state, .discovering)
        XCTAssertTrue(fx.contains(.cancelTimer(.connectWatchdog)))
        XCTAssertTrue(fx.contains(.discoverAndSubscribe))
        XCTAssertTrue(fx.contains(.armTimer(.discoveryWatchdog)))
    }

    func testConnected_fromKnown_discovers() {
        let (state, fx) = ConnReducer.reduce(.connecting(.known), .connected, savedID: UUID())
        XCTAssertEqual(state, .discovering)
        XCTAssertTrue(fx.contains(.discoverAndSubscribe))
    }

    func testConnectFailed_retryable_fallsToScan() {
        let (state, fx) = ConnReducer.reduce(.connecting(.advertised), .connectFailed(retryable: true), savedID: nil)
        XCTAssertEqual(state, .scanning(attempt: 1))
        XCTAssertTrue(fx.contains(.cancelTimer(.connectWatchdog)))
        XCTAssertTrue(fx.contains(.startContinuousScan))
    }

    func testConnectFailed_nonRetryable_goesUnavailable() {
        let (state, fx) = ConnReducer.reduce(.connecting(.known), .connectFailed(retryable: false), savedID: UUID())
        XCTAssertEqual(state, .unavailable(.unknown))
        XCTAssertTrue(fx.contains(.cancelTimer(.connectWatchdog)))
        XCTAssertFalse(fx.contains(.startContinuousScan), "non-retryable failure does not scan")
    }

    // MARK: - discovering → live / discoveryWatchdog

    func testSubscribed_goesLive_persistsIdentifier_cancelsDiscoveryWatchdog() {
        let (state, fx) = ConnReducer.reduce(.discovering, .subscribed, savedID: nil)
        XCTAssertEqual(state, .live)
        XCTAssertTrue(fx.contains(.persistIdentifier), "a successful subscribe saves the peripheral id")
        XCTAssertTrue(fx.contains(.cancelTimer(.discoveryWatchdog)))
    }

    func testDiscoveryWatchdog_reProbesViaScan() {
        let (state, fx) = ConnReducer.reduce(.discovering, .discoveryWatchdog, savedID: UUID())
        XCTAssertEqual(state, .scanning(attempt: 1))
        XCTAssertTrue(fx.contains(.cancelConnection))
        XCTAssertTrue(fx.contains(.startContinuousScan))
    }

    /// The CCCD/subscribe-failure fix: an explicit `setNotifyValue` error in
    /// `.discovering` must re-probe IMMEDIATELY (cancel the still-armed
    /// discoveryWatchdog and re-scan) rather than stranding until the 5s watchdog —
    /// the silent ~16s reconnect loop the hardware session exposed.
    func testSubscribeFailed_reProbesViaScan_cancellingDiscoveryWatchdog() {
        let (state, fx) = ConnReducer.reduce(.discovering, .subscribeFailed, savedID: UUID())
        XCTAssertEqual(state, .scanning(attempt: 1))
        XCTAssertTrue(fx.contains(.cancelConnection))
        XCTAssertTrue(fx.contains(.cancelTimer(.discoveryWatchdog)),
                      "the still-armed discoveryWatchdog must be cancelled — don't wait it out")
        XCTAssertTrue(fx.contains(.startContinuousScan))
        XCTAssertTrue(fx.contains(.armTimer(.scanTick)))
    }

    /// `subscribeFailed` only matters while `.discovering`; a stray one elsewhere is
    /// a no-op (the executor only emits it from a button-char notify-state error).
    func testSubscribeFailed_whileScanning_isNoOp() {
        let (state, fx) = ConnReducer.reduce(.scanning(attempt: 2), .subscribeFailed, savedID: nil)
        XCTAssertEqual(state, .scanning(attempt: 2))
        XCTAssertTrue(fx.isEmpty)
    }

    // MARK: - live → reconnecting (held peripheral, not retrieve)

    func testDisconnect_reconnectsToHeldPeripheral_notRetrieve() {
        let (state, fx) = ConnReducer.reduce(.live, .disconnected, savedID: UUID())
        XCTAssertEqual(state, .reconnecting)
        XCTAssertTrue(fx.contains(.reconnectHeld))
        XCTAssertFalse(fx.contains(.connectKnown), "out-of-range reconnect uses the retained peripheral, not a retrieve")
        XCTAssertFalse(containsResolveKnown(fx), "no retrieve on a held-peripheral reconnect")
        XCTAssertFalse(fx.contains(.armTimer(.connectWatchdog)), "held reconnect is correctly indefinite — no watchdog")
    }

    func testReconnecting_connected_discoversAgain() {
        let (state, fx) = ConnReducer.reduce(.reconnecting, .connected, savedID: UUID())
        XCTAssertEqual(state, .discovering)
        XCTAssertTrue(fx.contains(.discoverAndSubscribe))
        XCTAssertTrue(fx.contains(.armTimer(.discoveryWatchdog)))
    }

    // MARK: - No-op / irrelevant events (defaults)

    func testIrrelevantEvent_isNoOp() {
        // `subscribed` only matters in .discovering; in .scanning it is ignored.
        let (state, fx) = ConnReducer.reduce(.scanning(attempt: 1), .subscribed, savedID: nil)
        XCTAssertEqual(state, .scanning(attempt: 1))
        XCTAssertTrue(fx.isEmpty)
    }

    func testDisconnect_whileScanning_isNoOp() {
        // Only a `live` disconnect triggers held reconnect; a stray disconnect while
        // scanning has no held peripheral to reconnect to.
        let (state, fx) = ConnReducer.reduce(.scanning(attempt: 2), .disconnected, savedID: UUID())
        XCTAssertEqual(state, .scanning(attempt: 2))
        XCTAssertTrue(fx.isEmpty)
    }

    func testScanTick_whileConnecting_isNoOp() {
        // The scanTick timer belongs to the scanning phase; if it fires after we've
        // already moved to connecting, it is ignored (the executor cancels it, but the
        // reducer is safe either way).
        let (state, fx) = ConnReducer.reduce(.connecting(.advertised), .scanTick, savedID: nil)
        XCTAssertEqual(state, .connecting(.advertised))
        XCTAssertTrue(fx.isEmpty)
    }

    // MARK: - End-to-end happy path (cold launch, no saved id → live)

    func testColdLaunch_noSavedID_reachesLive() {
        var (state, _) = ConnReducer.reduce(.stopped, .start, savedID: nil)
        XCTAssertEqual(state, .scanning(attempt: 1))
        (state, _) = ConnReducer.reduce(state, .advertisementDiscovered, savedID: nil)
        XCTAssertEqual(state, .connecting(.advertised))
        (state, _) = ConnReducer.reduce(state, .connected, savedID: nil)
        XCTAssertEqual(state, .discovering)
        let (live, fx) = ConnReducer.reduce(state, .subscribed, savedID: nil)
        XCTAssertEqual(live, .live)
        XCTAssertTrue(fx.contains(.persistIdentifier), "reaching live persists the id for next-launch fast reconnect")
    }

    // MARK: - End-to-end: saved id reconnect, then live → disconnect → held reconnect

    func testSavedID_reconnect_thenHeldReconnectRoundTrip() {
        let id = UUID()
        var (state, fx) = ConnReducer.reduce(.stopped, .start, savedID: id)
        XCTAssertEqual(state, .connecting(.known))
        XCTAssertEqual(resolvedID(fx), id)
        (state, _) = ConnReducer.reduce(state, .knownPeripheralResolved, savedID: id)
        XCTAssertEqual(state, .connecting(.known))
        (state, _) = ConnReducer.reduce(state, .connected, savedID: id)
        XCTAssertEqual(state, .discovering)
        (state, _) = ConnReducer.reduce(state, .subscribed, savedID: id)
        XCTAssertEqual(state, .live)
        // Out of range:
        (state, fx) = ConnReducer.reduce(state, .disconnected, savedID: id)
        XCTAssertEqual(state, .reconnecting)
        XCTAssertTrue(fx.contains(.reconnectHeld))
        // Headset returns:
        (state, _) = ConnReducer.reduce(state, .connected, savedID: id)
        XCTAssertEqual(state, .discovering)
        (state, _) = ConnReducer.reduce(state, .subscribed, savedID: id)
        XCTAssertEqual(state, .live)
    }
}
