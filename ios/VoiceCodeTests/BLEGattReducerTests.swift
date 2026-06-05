// BLEGattReducerTests.swift
// Table tests for the pure per-peripheral GATT choreography. `GATTReducer.reduce`
// carries no I/O, so the full discover→descriptor→subscribe sequence the real
// hardware follows is replayable here with NO CoreBluetooth objects — events carry
// `CBUUID`/`Data` only. This is the seam that locks in the ordering the
// firmware-2.6.4 subscribe bug lived in (and which the old, adapter-internal logic
// had no way to test). See @docs/design/macos-blueparrott-corebluetooth.md §3.
//
// Only `CBUUID`/`Data` are referenced (available on iOS too), so this file is
// unguarded and runs under both `make test` (iOS) and the macOS unit bundle.

import XCTest
import CoreBluetooth
@testable import VoiceCode

final class BLEGattReducerTests: XCTestCase {

    private let layout = GATTLayout.blueParrott
    private var button: CBUUID { layout.button }
    private var mode: CBUUID { layout.mode }
    private var service: CBUUID { layout.service }

    private func hasSetNotify(_ fx: [GATTEffect]) -> Bool {
        fx.contains { if case .setNotify = $0 { return true }; return false }
    }
    private func hasDiscoverDescriptors(_ fx: [GATTEffect]) -> Bool {
        fx.contains { if case .discoverDescriptors = $0 { return true }; return false }
    }

    // MARK: - Connect → discover services → discover characteristics

    func testConnected_discoversControlService() {
        let (state, fx) = GATTReducer.reduce(.idle, .connected)
        XCTAssertEqual(state, .discoveringServices)
        XCTAssertEqual(fx, [.discoverServices([service])])
    }

    func testServicesDiscovered_withControlService_discoversCharacteristics() {
        let (state, fx) = GATTReducer.reduce(.discoveringServices, .servicesDiscovered([service]))
        XCTAssertEqual(state, .discoveringCharacteristics)
        XCTAssertEqual(fx, [.discoverCharacteristics(service: service)])
    }

    func testServicesDiscovered_withoutControlService_failsAndReProbes() {
        let (state, fx) = GATTReducer.reduce(.discoveringServices, .servicesDiscovered([CBUUID(string: "180A")]))
        XCTAssertEqual(state, .failed)
        XCTAssertTrue(fx.contains(.emitSubscribeFailed), "no control service → surface a subscribe failure (fast re-probe)")
    }

    // MARK: - THE INVARIANT: descriptors before subscribe (the litmus test)

    /// The bug, encoded as a guard: after characteristics are discovered the reducer
    /// must discover the button char's descriptors (its CCCD) and must NOT subscribe
    /// yet. This test goes RED against the old "setNotify straight from characteristic
    /// discovery" behavior and GREEN against the descriptor-first ordering.
    func testCharacteristicsDiscovered_discoversDescriptorsFirst_neverSubscribesYet() {
        let (state, fx) = GATTReducer.reduce(.discoveringCharacteristics,
                                             .characteristicsDiscovered([button, mode]))
        XCTAssertEqual(state, .resolvingButton)
        XCTAssertTrue(hasDiscoverDescriptors(fx), "must resolve the button CCCD before enabling notifications")
        XCTAssertFalse(hasSetNotify(fx),
                       "subscribing before descriptor discovery is the firmware-2.6.4 bug — must NOT happen")
        XCTAssertTrue(fx.contains(.discoverDescriptors(characteristic: button)))
    }

    /// The mode characteristic is read for App-Mode truth when present (tracing), but
    /// the read must not gate or precede the descriptor resolution.
    func testCharacteristicsDiscovered_alsoReadsModeForAppModeTruth() {
        let (_, fx) = GATTReducer.reduce(.discoveringCharacteristics,
                                         .characteristicsDiscovered([button, mode]))
        XCTAssertTrue(fx.contains(.readValue(characteristic: mode)),
                      "read the mode char so the executor logs real App-Mode value, not the optimistic flag")
    }

    func testCharacteristicsDiscovered_withoutModeChar_stillSubscribesPath_noModeRead() {
        let (state, fx) = GATTReducer.reduce(.discoveringCharacteristics,
                                             .characteristicsDiscovered([button]))
        XCTAssertEqual(state, .resolvingButton)
        XCTAssertTrue(hasDiscoverDescriptors(fx))
        XCTAssertFalse(fx.contains(.readValue(characteristic: mode)), "no mode char present → nothing to read")
    }

    func testCharacteristicsDiscovered_withoutButtonChar_failsAndReProbes() {
        let (state, fx) = GATTReducer.reduce(.discoveringCharacteristics,
                                             .characteristicsDiscovered([mode]))
        XCTAssertEqual(state, .failed)
        XCTAssertTrue(fx.contains(.emitSubscribeFailed), "no button char → subscribe failure (fast re-probe, not a hang)")
        XCTAssertFalse(hasSetNotify(fx))
    }

    // MARK: - Descriptors resolved → subscribe

    func testDescriptorsDiscovered_withCCCD_subscribes() {
        let (state, fx) = GATTReducer.reduce(.resolvingButton,
                                             .descriptorsDiscovered(characteristic: button, hasCCCD: true))
        XCTAssertEqual(state, .subscribing(hasCCCD: true))
        XCTAssertEqual(fx.first, .setNotify(characteristic: button),
                       "with the CCCD resolved, NOW subscribe")
    }

    func testDescriptorsDiscovered_withoutCCCD_subscribesAndCarriesNoCCCD() {
        let (state, fx) = GATTReducer.reduce(.resolvingButton,
                                             .descriptorsDiscovered(characteristic: button, hasCCCD: false))
        XCTAssertEqual(state, .subscribing(hasCCCD: false), "carry the no-CCCD fact so the notify-state outcome is read correctly")
        XCTAssertTrue(hasSetNotify(fx), "subscribe even with no CCCD; the notify-state callback decides")
    }

    func testDescriptorsDiscovered_forUnrelatedChar_isIgnored() {
        let (state, fx) = GATTReducer.reduce(.resolvingButton,
                                             .descriptorsDiscovered(characteristic: mode, hasCCCD: true))
        XCTAssertEqual(state, .resolvingButton, "only the button char's descriptors drive the subscribe")
        XCTAssertTrue(fx.isEmpty)
    }

    // MARK: - Notify-state outcome → subscribed / subscribeFailed (the hardware error replay)

    func testNotifyState_isNotifying_reachesSubscribed() {
        let (state, fx) = GATTReducer.reduce(.subscribing(hasCCCD: true),
                                             .notifyStateUpdated(characteristic: button, isNotifying: true, failed: false))
        XCTAssertEqual(state, .subscribed)
        XCTAssertTrue(fx.contains(.emitSubscribed))
    }

    /// A subscribe error WITH a CCCD present is a genuine fault → surface a subscribe
    /// failure so the connection machine re-probes.
    func testNotifyState_error_withCCCD_emitsSubscribeFailed() {
        let (state, fx) = GATTReducer.reduce(.subscribing(hasCCCD: true),
                                             .notifyStateUpdated(characteristic: button, isNotifying: false, failed: true))
        XCTAssertEqual(state, .failed)
        XCTAssertTrue(fx.contains(.emitSubscribeFailed))
        XCTAssertFalse(fx.contains(.emitSubscribed))
    }

    /// THE REAL HARDWARE PATH (firmware 2.6.4, verified in logs-20260604-181213): the
    /// button char exposes NO CCCD, so `setNotifyValue` errors with "attribute could not
    /// be found" — but the headset pushes button notifications anyway under App Mode.
    /// The error must be BENIGN: go live and listen, NOT re-probe. Re-probing here is
    /// the churn that suppressed all button feedback.
    func testNotifyState_error_withoutCCCD_goesLive_doesNotReProbe() {
        let (state, fx) = GATTReducer.reduce(.subscribing(hasCCCD: false),
                                             .notifyStateUpdated(characteristic: button, isNotifying: false, failed: true))
        XCTAssertEqual(state, .subscribed, "no CCCD + subscribe error is the documented App-Mode-push case → go live")
        XCTAssertTrue(fx.contains(.emitSubscribed))
        XCTAssertFalse(fx.contains(.emitSubscribeFailed), "must NOT re-probe on the benign no-CCCD error (the no-feedback bug)")
    }

    func testNotifyState_cleanUnsubscribe_isNoOp() {
        let (state, fx) = GATTReducer.reduce(.subscribing(hasCCCD: true),
                                             .notifyStateUpdated(characteristic: button, isNotifying: false, failed: false))
        XCTAssertEqual(state, .subscribing(hasCCCD: true), "isNotifying=false with no error is an unsubscribe, not a failure")
        XCTAssertTrue(fx.isEmpty)
    }

    // MARK: - Value updates (button NOTIFY + mode read)

    func testButtonValue_isEmitted_whenSubscribed() {
        let payload = Data([0x01])
        let (state, fx) = GATTReducer.reduce(.subscribed, .valueUpdated(characteristic: button, data: payload))
        XCTAssertEqual(state, .subscribed)
        XCTAssertEqual(fx, [.emitButtonValue(payload)])
    }

    func testModeValueRead_notesAppModeTruth_inAnyState() {
        let sdk = Data("sdk".utf8)
        let (state, fx) = GATTReducer.reduce(.resolvingButton, .valueUpdated(characteristic: mode, data: sdk))
        XCTAssertEqual(state, .resolvingButton, "a mode read does not disturb the subscribe handshake")
        XCTAssertEqual(fx, [.noteAppMode(value: sdk)])
    }

    // MARK: - Irrelevant events are no-ops

    func testStrayServicesDiscovered_whileSubscribed_isNoOp() {
        let (state, fx) = GATTReducer.reduce(.subscribed, .servicesDiscovered([service]))
        XCTAssertEqual(state, .subscribed)
        XCTAssertTrue(fx.isEmpty)
    }

    // MARK: - End-to-end: the full hardware-faithful happy path

    func testFullHandshake_connectToSubscribed_inHardwareOrder() {
        var state = GATTState.idle
        var emitted: [GATTEffect] = []
        func step(_ e: GATTEvent) {
            let (next, fx) = GATTReducer.reduce(state, e)
            state = next
            emitted.append(contentsOf: fx)
        }

        step(.connected)
        step(.servicesDiscovered([service]))
        step(.characteristicsDiscovered([button, mode]))
        // Critical ordering check: descriptors must be discovered before any setNotify.
        let descriptorIdx = emitted.firstIndex(of: .discoverDescriptors(characteristic: button))
        let setNotifyIdxBeforeDescriptors = emitted.firstIndex(of: .setNotify(characteristic: button))
        XCTAssertNotNil(descriptorIdx)
        XCTAssertNil(setNotifyIdxBeforeDescriptors, "no setNotify may be emitted before descriptor discovery")

        step(.descriptorsDiscovered(characteristic: button, hasCCCD: true))
        step(.notifyStateUpdated(characteristic: button, isNotifying: true, failed: false))

        XCTAssertEqual(state, .subscribed)
        let order = emitted.compactMap { fx -> String? in
            switch fx {
            case .discoverServices: return "services"
            case .discoverCharacteristics: return "chars"
            case .discoverDescriptors: return "descriptors"
            case .setNotify: return "subscribe"
            case .emitSubscribed: return "subscribed"
            default: return nil
            }
        }
        XCTAssertEqual(order, ["services", "chars", "descriptors", "subscribe", "subscribed"],
                       "the choreography must follow the exact hardware order")
    }
}
