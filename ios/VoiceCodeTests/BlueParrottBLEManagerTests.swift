// BlueParrottBLEManagerTests.swift
// Integration tests for the macOS BlueParrottBLEManager as the ConnReducer effect
// executor: it feeds BLE callbacks into the pure reducer and applies the returned
// effects to the faked `BLECentral` seam and to the watchdog/scan-tick timers
// (driven through a non-firing `scheduleWork` recorder + `testFireTimer`). No real
// CoreBluetooth/hardware. See @docs/design/macos-headset-loop-state-machine.md
// §Executor wiring + §Verification (faked BLECentral + synchronous scheduleWork).
//
// Included in VoiceCodeMacTests only; excluded from the iOS VoiceCodeTests target
// via project.yml. The #if os(macOS) guard is a secondary safeguard.

import XCTest
import CoreBluetooth
@testable import VoiceCode

#if os(macOS)

// MARK: - Test doubles

/// In-memory `BLECentral` so the executor runs without a real CBCentralManager.
/// Records every effect-driven call so tests can assert what the reducer asked the
/// seam to do; `centralDelegate` is the hook tests drive callbacks through.
private final class FakeBLECentral: BLECentral {
    var managerState: CBManagerState
    weak var centralDelegate: BLECentralEvents?
    /// Identifier the executor reads for `.persistIdentifier`; set by tests to the
    /// "connected" peripheral's id.
    var connectedPeripheralIdentifier: UUID?

    var scanCount = 0
    var stopScanCount = 0
    var cancelCount = 0
    var subscribeCount = 0
    var connectAdvertisedCount = 0
    var connectKnownCount = 0
    var reconnectHeldCount = 0
    /// Every id passed to `resolveKnownPeripheral`, in order.
    var resolveCalls: [UUID] = []
    /// Every App-Mode enable payload written (empty when none — the persistent
    /// path must never write).
    var enableWrites: [Data] = []

    init(state: CBManagerState = .poweredOn) { managerState = state }

    func scanForButtonService() { scanCount += 1 }
    func stopScan() { stopScanCount += 1 }
    func resolveKnownPeripheral(_ id: UUID) { resolveCalls.append(id) }
    func connectAdvertised() { connectAdvertisedCount += 1 }
    func connectKnown() { connectKnownCount += 1 }
    func reconnectHeld() { reconnectHeldCount += 1 }
    func cancelConnection() { cancelCount += 1 }
    func subscribeToButtonEvents() { subscribeCount += 1 }
    func writeAppModeEnable(_ payload: Data) { enableWrites.append(payload) }
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

/// Records the identifier the executor would persist / clear, so tests assert
/// stale-id hygiene without touching real UserDefaults.
private final class IdentifierStore {
    var saved: UUID?
    var clearCount = 0
    func persist(_ id: UUID) { saved = id }
    func clear() { saved = nil; clearCount += 1 }
}

/// A central whose `resolveKnownPeripheral` fires its outcome callback
/// SYNCHRONOUSLY — exactly as the real `CBCentralAdapter` does, since
/// `retrievePeripherals(withIdentifiers:)` is a synchronous CoreBluetooth call.
/// This reproduces the reentrant `handle()` the real adapter triggers (a resolve
/// callback arrives while `handle(.start)` is still applying its effects) so the
/// manager's reentrancy queue is exercised under the same ordering as production.
private final class SyncResolveFakeBLECentral: BLECentral {
    enum Outcome { case resolved, empty }
    var managerState: CBManagerState = .poweredOn
    weak var centralDelegate: BLECentralEvents?
    var connectedPeripheralIdentifier: UUID?
    var outcome: Outcome = .empty
    var scanCount = 0
    var connectKnownCount = 0

    func scanForButtonService() { scanCount += 1 }
    func stopScan() {}
    func resolveKnownPeripheral(_ id: UUID) {
        switch outcome {
        case .resolved: centralDelegate?.bleKnownPeripheralResolved()  // synchronous reentry
        case .empty:    centralDelegate?.bleNoKnownPeripheral()        // synchronous reentry
        }
    }
    func connectAdvertised() {}
    func connectKnown() { connectKnownCount += 1 }
    func reconnectHeld() {}
    func cancelConnection() {}
    func subscribeToButtonEvents() {}
    func writeAppModeEnable(_ payload: Data) {}
}

final class BlueParrottBLEManagerTests: XCTestCase {

    /// Build a manager wired to a fresh fake central, a non-firing `scheduleWork`
    /// recorder (timers are fired explicitly via `testFireTimer`), and an injected
    /// identifier store (so persistence stays off real UserDefaults).
    private func makeManager(state: CBManagerState = .poweredOn, savedID: UUID? = nil)
        -> (BlueParrottBLEManager, FakeBLECentral, IdentifierStore) {
        let central = FakeBLECentral(state: state)
        let store = IdentifierStore()
        store.saved = savedID
        let manager = BlueParrottBLEManager(
            central: central,
            scheduleWork: { _, _ in },                 // non-firing; tests use testFireTimer
            savedIdentifier: { store.saved },
            persistIdentifier: { store.persist($0) },
            clearSavedIdentifier: { store.clear() }
        )
        return (manager, central, store)
    }

    // MARK: - Construction / hookup

    func testInit_wiresCentralDelegate() {
        let (manager, central, _) = makeManager()
        XCTAssertTrue(central.centralDelegate === manager)
    }

    func testInit_doesNotScanUntilStart() {
        let (_, central, _) = makeManager()
        XCTAssertEqual(central.scanCount, 0)
    }

    func testStart_isIdempotent() {
        let (manager, central, _) = makeManager()
        manager.start()
        manager.start()
        XCTAssertEqual(central.scanCount, 1, "second start() must not re-scan")
    }

    // MARK: - Cold launch (no saved id) → continuous scan

    func testStart_noSavedID_startsContinuousScan_armsScanTick() {
        let (manager, central, _) = makeManager(savedID: nil)
        manager.start()

        XCTAssertEqual(central.scanCount, 1)
        XCTAssertEqual(manager.testConnState, .scanning(attempt: 1))
        XCTAssertTrue(manager.testHasArmedTimer(.scanTick))
        XCTAssertTrue(central.resolveCalls.isEmpty, "no saved id → no resolve")
    }

    func testStart_notPoweredOn_waitsForPowerOn_thenScans() {
        let (manager, central, _) = makeManager(state: .unknown, savedID: nil)
        manager.start()

        XCTAssertEqual(central.scanCount, 0, "must not scan until Bluetooth is powered on")
        XCTAssertEqual(manager.testConnState, .unavailable(.unknown))

        central.managerState = .poweredOn
        central.centralDelegate?.bleDidUpdateState(.poweredOn)

        XCTAssertEqual(central.scanCount, 1)
        XCTAssertEqual(manager.testConnState, .scanning(attempt: 1))
    }

    // MARK: - Continuous-scan invariant

    func testScanTick_doesNotRestartOrStopScan_reArms() {
        let (manager, central, _) = makeManager(savedID: nil)
        manager.start()
        XCTAssertEqual(central.scanCount, 1)

        manager.testFireTimer(.scanTick)

        XCTAssertEqual(central.scanCount, 1, "the tick must not restart the scan")
        XCTAssertEqual(central.stopScanCount, 0, "the tick must not tear down the scan")
        XCTAssertEqual(manager.testConnState, .scanning(attempt: 2), "the tick bumps the attempt")
        XCTAssertTrue(manager.testHasArmedTimer(.scanTick), "the tick re-arms itself")
    }

    // MARK: - Advertised connect (discover → connect, watchdogged)

    func testAdvertisement_connectsAdvertised_stopsScan_armsConnectWatchdog() {
        let (manager, central, _) = makeManager(savedID: nil)
        manager.start()

        central.centralDelegate?.bleDidDiscoverAdvertisement()

        XCTAssertEqual(central.connectAdvertisedCount, 1)
        XCTAssertEqual(central.stopScanCount, 1, "a discovered peripheral ends the scan")
        XCTAssertEqual(manager.testConnState, .connecting(.advertised))
        XCTAssertTrue(manager.testHasArmedTimer(.connectWatchdog), "a silent advertised connect must not hang")
        XCTAssertFalse(manager.testHasArmedTimer(.scanTick), "scan-tick cancelled while connecting")
    }

    func testAdvertisedConnect_watchdog_recoversToScan_withoutClearingId() {
        let (manager, central, store) = makeManager(savedID: UUID())
        // Force the advertised path (a stray discover while scanning), not the known path.
        manager.start()
        // start() with a saved id goes to connecting(.known); drive an empty retrieve
        // back to scanning first so we are scanning when the advertisement arrives.
        central.centralDelegate?.bleNoKnownPeripheral()
        XCTAssertEqual(manager.testConnState, .scanning(attempt: 1))
        store.clearCount = 0   // ignore the empty-retrieve clear; we assert the advertised path

        central.centralDelegate?.bleDidDiscoverAdvertisement()
        XCTAssertEqual(manager.testConnState, .connecting(.advertised))

        manager.testFireTimer(.connectWatchdog)

        XCTAssertEqual(manager.testConnState, .scanning(attempt: 1))
        XCTAssertEqual(central.cancelCount, 1, "advertised watchdog cancels the stalled connect")
        XCTAssertEqual(store.clearCount, 0, "advertised connect is not from a saved id — must not clear")
    }

    // MARK: - Known (identifier) reconnect

    func testSavedID_resolvesKnown_armsConnectWatchdog() {
        let id = UUID()
        let (manager, central, _) = makeManager(savedID: id)
        manager.start()

        XCTAssertEqual(central.resolveCalls, [id], "start with a saved id resolves it before scanning")
        XCTAssertEqual(central.scanCount, 0, "a saved id is tried before scanning")
        XCTAssertEqual(manager.testConnState, .connecting(.known))
        XCTAssertTrue(manager.testHasArmedTimer(.connectWatchdog))
    }

    func testKnownResolved_issuesConnectKnown() {
        let id = UUID()
        let (manager, central, _) = makeManager(savedID: id)
        manager.start()

        central.centralDelegate?.bleKnownPeripheralResolved()

        XCTAssertEqual(central.connectKnownCount, 1)
        XCTAssertEqual(manager.testConnState, .connecting(.known), "watchdog already armed; just connect")
    }

    func testEmptyRetrieve_clearsId_andScansImmediately() {
        let id = UUID()
        let (manager, central, store) = makeManager(savedID: id)
        manager.start()

        central.centralDelegate?.bleNoKnownPeripheral()

        XCTAssertEqual(store.clearCount, 1, "an empty retrieve forgets the stale id")
        XCTAssertEqual(central.scanCount, 1, "and falls straight to scanning")
        XCTAssertEqual(manager.testConnState, .scanning(attempt: 1))
        XCTAssertFalse(manager.testHasArmedTimer(.connectWatchdog), "no need to wait out the watchdog")
    }

    func testStaleID_connectWatchdog_clearsId_cancels_andScans() {
        let id = UUID()
        let (manager, central, store) = makeManager(savedID: id)
        manager.start()
        central.centralDelegate?.bleKnownPeripheralResolved()   // connecting(.known), connect issued

        manager.testFireTimer(.connectWatchdog)

        XCTAssertEqual(manager.testConnState, .scanning(attempt: 1))
        XCTAssertEqual(central.cancelCount, 1, "stop the forever-pending stale connect")
        XCTAssertEqual(store.clearCount, 1, "forget the stale id (self-heal a re-paired headset)")
        XCTAssertEqual(central.scanCount, 1)
    }

    func testConnectWatchdog_durations_knownLongerThanAdvertised() {
        // The executor picks the watchdog duration from the in-flight connect mode:
        // a known connect is speculative (longer), an advertised connect is imminent
        // (shorter). Capture the delay handed to `scheduleWork` for each.
        XCTAssertNotEqual(BlueParrottBLEManager.connectWatchdogKnown,
                          BlueParrottBLEManager.connectWatchdogAdvertised)

        var knownDelay: TimeInterval?
        let centralK = FakeBLECentral()
        let storeK = IdentifierStore(); storeK.saved = UUID()
        let mgrK = BlueParrottBLEManager(
            central: centralK,
            scheduleWork: { delay, _ in knownDelay = delay },
            savedIdentifier: { storeK.saved },
            persistIdentifier: { storeK.persist($0) },
            clearSavedIdentifier: { storeK.clear() })
        mgrK.start()   // connecting(.known) arms the known watchdog (its only timer)
        XCTAssertEqual(knownDelay, BlueParrottBLEManager.connectWatchdogKnown)

        var advDelay: TimeInterval?
        let centralA = FakeBLECentral()
        let mgrA = BlueParrottBLEManager(
            central: centralA,
            scheduleWork: { delay, _ in advDelay = delay },
            savedIdentifier: { nil },
            persistIdentifier: { _ in },
            clearSavedIdentifier: {})
        mgrA.start()   // scanning; the last arm here is scanTick
        centralA.centralDelegate?.bleDidDiscoverAdvertisement()  // connecting(.advertised)
        XCTAssertEqual(advDelay, BlueParrottBLEManager.connectWatchdogAdvertised)
    }

    // MARK: - Reentrancy (synchronous resolve callback, as the real adapter fires)

    /// The real `resolveKnownPeripheral` fires its outcome callback synchronously, so
    /// the event re-enters `handle()` mid-apply. With the reentrancy queue, the empty
    /// retrieve's `cancelTimer(.connectWatchdog)` runs after the start effect's
    /// `armTimer(.connectWatchdog)`, leaving NO stray watchdog armed in `.scanning`.
    func testSyncResolve_empty_reentrancyQueued_leavesNoStrayConnectWatchdog() {
        let id = UUID()
        let central = SyncResolveFakeBLECentral()
        central.outcome = .empty
        let store = IdentifierStore(); store.saved = id
        let manager = BlueParrottBLEManager(
            central: central,
            scheduleWork: { _, _ in },
            savedIdentifier: { store.saved },
            persistIdentifier: { store.persist($0) },
            clearSavedIdentifier: { store.clear() })

        manager.start()   // connecting(.known) → resolve fires bleNoKnownPeripheral synchronously

        XCTAssertEqual(manager.testConnState, .scanning(attempt: 1))
        XCTAssertEqual(store.clearCount, 1, "empty retrieve forgets the stale id")
        XCTAssertEqual(central.scanCount, 1, "and falls to a continuous scan")
        XCTAssertTrue(manager.testHasArmedTimer(.scanTick))
        XCTAssertFalse(manager.testHasArmedTimer(.connectWatchdog),
                       "the reentrancy queue must cancel the watchdog the start effect armed — no stray timer")
    }

    /// A synchronous resolve-success still issues the known connect and arms the
    /// connect watchdog (the reentrant `.connectKnown` runs after the start effects).
    func testSyncResolve_resolved_reentrancyQueued_connectsKnown_watchdogged() {
        let id = UUID()
        let central = SyncResolveFakeBLECentral()
        central.outcome = .resolved
        central.connectedPeripheralIdentifier = id
        let store = IdentifierStore(); store.saved = id
        let manager = BlueParrottBLEManager(
            central: central,
            scheduleWork: { _, _ in },
            savedIdentifier: { store.saved },
            persistIdentifier: { store.persist($0) },
            clearSavedIdentifier: { store.clear() })

        manager.start()   // connecting(.known) → resolve fires bleKnownPeripheralResolved synchronously

        XCTAssertEqual(manager.testConnState, .connecting(.known))
        XCTAssertEqual(central.connectKnownCount, 1, "a synchronous resolve still issues the known connect")
        XCTAssertTrue(manager.testHasArmedTimer(.connectWatchdog),
                      "the known connect stays watchdogged even when resolve returns synchronously")
        XCTAssertEqual(store.clearCount, 0, "a successful resolve must not clear the saved id")
    }

    // MARK: - connected → discovering → live (persist identifier)

    func testConnected_discoversSubscribes_armsDiscoveryWatchdog_cancelsConnectWatchdog() {
        let id = UUID()
        let (manager, central, _) = makeManager(savedID: id)
        manager.start()
        central.centralDelegate?.bleKnownPeripheralResolved()
        XCTAssertTrue(manager.testHasArmedTimer(.connectWatchdog))

        central.centralDelegate?.bleDidConnect()

        XCTAssertEqual(central.subscribeCount, 1, "connected → discover + subscribe")
        XCTAssertEqual(manager.testConnState, .discovering)
        XCTAssertTrue(manager.testHasArmedTimer(.discoveryWatchdog))
        XCTAssertFalse(manager.testHasArmedTimer(.connectWatchdog), "connect watchdog cancelled on connect")
    }

    func testSubscribed_reachesLive_persistsIdentifier_setsConnected() {
        let id = UUID()
        let (manager, central, store) = makeManager(savedID: id)
        central.connectedPeripheralIdentifier = id      // the executor reads this for persist
        manager.start()
        central.centralDelegate?.bleKnownPeripheralResolved()
        central.centralDelegate?.bleDidConnect()

        central.centralDelegate?.bleDidSubscribe()

        XCTAssertEqual(manager.testConnState, .live)
        XCTAssertTrue(manager.isConnected)
        XCTAssertEqual(store.saved, id, "reaching live persists the peripheral id for next-launch fast reconnect")
        XCTAssertFalse(manager.testHasArmedTimer(.discoveryWatchdog), "discovery watchdog cancelled on subscribe")
    }

    func testDiscoveryWatchdog_reProbesViaScan() {
        let (manager, central, _) = makeManager(savedID: nil)
        manager.start()
        central.centralDelegate?.bleDidDiscoverAdvertisement()
        central.centralDelegate?.bleDidConnect()
        XCTAssertEqual(manager.testConnState, .discovering)
        let scansBefore = central.scanCount

        manager.testFireTimer(.discoveryWatchdog)

        XCTAssertEqual(manager.testConnState, .scanning(attempt: 1))
        XCTAssertEqual(central.cancelCount, 1, "connected-but-never-subscribed cancels and re-probes")
        XCTAssertEqual(central.scanCount, scansBefore + 1)
    }

    // MARK: - App Mode on connect

    func testReachingDiscover_persistentMode_marksSDKEnabled_noWrite() {
        let (manager, central, _) = makeManager(savedID: nil)
        XCTAssertTrue(manager.appModePersistent, "default reflects the b4i.3 experiment (persistent)")
        manager.start()
        central.centralDelegate?.bleDidDiscoverAdvertisement()

        central.centralDelegate?.bleDidConnect()

        XCTAssertTrue(central.enableWrites.isEmpty, "persistent App Mode must skip the enable write")
        XCTAssertTrue(manager.isSDKModeEnabled, "persistent mode already streams events")
    }

    func testReachingDiscover_notPersistent_writesEnable_doesNotClaimEnabled() {
        let (manager, central, _) = makeManager(savedID: nil)
        manager.appModePersistent = false
        manager.start()
        central.centralDelegate?.bleDidDiscoverAdvertisement()

        central.centralDelegate?.bleDidConnect()

        XCTAssertEqual(central.enableWrites, [BPGatt.appModeEnablePayload],
                       "a never-enabled headset receives the \"sdk\" payload exactly once")
        XCTAssertFalse(manager.isSDKModeEnabled,
                       "the unconfirmed fallback write must not optimistically report App Mode active")
    }

    // MARK: - live → disconnect → held reconnect

    /// Drive a saved-id manager to `.live` through the genuine known path:
    /// start (connecting(.known)) → resolved (connectKnown) → connected → subscribed.
    private func driveToLive(_ manager: BlueParrottBLEManager, _ central: FakeBLECentral, id: UUID) {
        central.connectedPeripheralIdentifier = id
        manager.start()
        central.centralDelegate?.bleKnownPeripheralResolved()
        central.centralDelegate?.bleDidConnect()
        central.centralDelegate?.bleDidSubscribe()
        XCTAssertEqual(manager.testConnState, .live)
    }

    func testLive_disconnect_reconnectsToHeldPeripheral_notRetrieve() {
        let id = UUID()
        let (manager, central, _) = makeManager(savedID: id)
        driveToLive(manager, central, id: id)
        // Capture the known-path counts from the initial connect; the disconnect must
        // add a `reconnectHeld` WITHOUT a fresh retrieve or known connect.
        let resolvesBefore = central.resolveCalls.count
        let connectKnownBefore = central.connectKnownCount

        central.centralDelegate?.bleDidDisconnect()

        XCTAssertEqual(manager.testConnState, .reconnecting)
        XCTAssertEqual(central.reconnectHeldCount, 1, "out-of-range uses the retained peripheral")
        XCTAssertEqual(central.connectKnownCount, connectKnownBefore,
                       "the disconnect must not issue a new known retrieve+connect")
        XCTAssertEqual(central.resolveCalls.count, resolvesBefore, "no retrieve on a held reconnect")
        XCTAssertFalse(manager.isConnected)
    }

    func testHeldReconnect_connected_discoversAgain_returnsToLive() {
        let id = UUID()
        let (manager, central, _) = makeManager(savedID: id)
        driveToLive(manager, central, id: id)
        central.centralDelegate?.bleDidDisconnect()
        XCTAssertEqual(manager.testConnState, .reconnecting)

        central.centralDelegate?.bleDidConnect()
        XCTAssertEqual(manager.testConnState, .discovering)
        XCTAssertTrue(manager.testHasArmedTimer(.discoveryWatchdog))

        central.centralDelegate?.bleDidSubscribe()
        XCTAssertEqual(manager.testConnState, .live)
        XCTAssertTrue(manager.isConnected)
    }

    // MARK: - Manager state / stop

    func testPoweredOff_whileScanning_goesUnavailable_noScanStorm() {
        let (manager, central, _) = makeManager(savedID: nil)
        manager.start()
        let scansBefore = central.scanCount

        central.centralDelegate?.bleDidUpdateState(.poweredOff)

        XCTAssertEqual(manager.testConnState, .unavailable(.poweredOff))
        XCTAssertEqual(central.scanCount, scansBefore, "no retry storm while unavailable")
        XCTAssertFalse(manager.isConnected)
    }

    func testStop_tearsDownScanConnectionAndTimers() {
        let (manager, central, _) = makeManager(savedID: nil)
        manager.start()
        XCTAssertTrue(manager.testHasArmedTimer(.scanTick))

        manager.stop()

        XCTAssertEqual(manager.testConnState, .stopped)
        XCTAssertEqual(central.stopScanCount, 1)
        XCTAssertEqual(central.cancelCount, 1)
        XCTAssertFalse(manager.testHasArmedTimer(.scanTick))
        XCTAssertFalse(manager.isConnected)
    }

    func testStop_thenLateCallback_isIgnored() {
        let (manager, central, _) = makeManager(savedID: nil)
        manager.start()
        manager.stop()
        let stateAfterStop = manager.testConnState

        // A late connect callback after stop() must not re-drive the machine.
        central.centralDelegate?.bleDidConnect()

        XCTAssertEqual(manager.testConnState, stateAfterStop, "callbacks are gated while stopped")
        XCTAssertEqual(manager.testConnState, .stopped)
    }

    // MARK: - Button value → parse → dispatch + raw signal

    func testButtonValue_dispatchesToDelegate_andEmitsRawSignal() {
        let (manager, central, _) = makeManager()
        let spy = DelegateSpy()
        var rawSignals: [RawButtonSignal] = []
        manager.delegate = spy
        manager.rawSignalSink = { rawSignals.append($0) }
        manager.start()

        // Captured opcodes (firmware 2.6.4): down, up, tap, double-tap, long-press.
        for byte in [0x01, 0x00, 0x02, 0x03, 0x04] as [UInt8] {
            central.centralDelegate?.bleDidUpdateButtonValue(Data([byte]))
        }
        flushMainQueue()

        XCTAssertEqual(spy.calls, [.down, .up, .tap, .doubleTap, .longPress])
        XCTAssertEqual(rawSignals, [.down, .up, .tapCode, .doubleTapCode, .longPressCode],
                       "the gesture recognizer receives de-bracketed raw signals")
    }

    func testUnknownAndEmptyPayloads_areDroppedNotMisclassified() {
        let (manager, central, _) = makeManager()
        let spy = DelegateSpy()
        var rawSignals: [RawButtonSignal] = []
        manager.delegate = spy
        manager.rawSignalSink = { rawSignals.append($0) }
        manager.start()

        central.centralDelegate?.bleDidUpdateButtonValue(Data([0xFF])) // unknown opcode
        central.centralDelegate?.bleDidUpdateButtonValue(Data())       // empty payload
        flushMainQueue()

        XCTAssertTrue(spy.calls.isEmpty, "unknown/empty payloads must be dropped, never guessed at")
        XCTAssertTrue(rawSignals.isEmpty, "no raw signal for an undecodable payload")
    }

    func testNoSinks_buttonValue_doesNotCrash() {
        let (manager, central, _) = makeManager()
        manager.start()
        central.centralDelegate?.bleDidUpdateButtonValue(Data([0x01]))
        flushMainQueue()
        // No delegate / no rawSignalSink — reaching here without a crash is the assertion.
    }

    // MARK: - End-to-end happy path (cold launch, no saved id → live)

    func testColdLaunch_noSavedID_reachesLive_persistsId() {
        let id = UUID()
        let (manager, central, store) = makeManager(savedID: nil)
        central.connectedPeripheralIdentifier = id
        manager.start()
        XCTAssertEqual(manager.testConnState, .scanning(attempt: 1))

        central.centralDelegate?.bleDidDiscoverAdvertisement()
        XCTAssertEqual(manager.testConnState, .connecting(.advertised))
        central.centralDelegate?.bleDidConnect()
        XCTAssertEqual(manager.testConnState, .discovering)
        central.centralDelegate?.bleDidSubscribe()

        XCTAssertEqual(manager.testConnState, .live)
        XCTAssertEqual(store.saved, id, "reaching live persists the id for the next-launch fast reconnect")
        XCTAssertTrue(manager.isConnected)
    }

    // MARK: - Helpers

    /// Drain the main queue so the async delegate/raw-signal hops have run before
    /// asserting. FIFO ordering guarantees prior async work runs before this.
    private func flushMainQueue() {
        let exp = expectation(description: "main queue drained")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }
}

#endif
