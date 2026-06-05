// BLEGattReducer.swift
// Pure per-peripheral GATT choreography for the macOS BlueParrott control link:
// the ordering a connected peripheral must follow to start button notifications —
// discover service → discover characteristics → discover the button char's
// descriptors (its CCCD) → setNotifyValue → subscribed. Replaces the implicit
// ordering that used to live inside the CoreBluetooth-backed `CBCentralAdapter`,
// where it was untestable (CBPeripheral/CBService/CBCharacteristic can't be built
// in tests) — which is exactly where the firmware-2.6.4 subscribe bug hid.
//
// Key invariant — DESCRIPTORS BEFORE SUBSCRIBE: `setNotify` is only ever emitted
// after `descriptorsDiscovered` for the button char. Issuing `setNotifyValue`
// before the CCCD (0x2902) is resolved returns "attribute could not be found" on
// this hardware (macOS CoreBluetooth), stranding the connect and re-probing
// forever. Encoding the order here makes it impossible to regress and replayable
// in a pure test (events carry `CBUUID`/`Data`, never live CoreBluetooth objects).
//
// The reducer also issues a READ of the mode characteristic so the executor can
// log App-Mode TRUTH (the actual "sdk"/other value on the hardware) instead of the
// optimistic `appModePersistent` flag — the trace gap the hardware session exposed.
//
// Platform-agnostic and I/O-free (only `CBUUID`/`Data`), so it compiles into BOTH
// the iOS and macOS targets and its tests run under `make test` and the macOS unit
// bundle. The thin `CBCentralAdapter` translates CoreBluetooth delegate callbacks
// into these events and applies the effects to the real `CBPeripheral`.
//
// See @docs/design/macos-blueparrott-corebluetooth.md §3 (GATT layout + CCCD note)
// and @docs/design/macos-headset-loop-state-machine.md §Connection machine.

import CoreBluetooth

/// The BlueParrott control-service GATT layout the choreography targets. Frozen
/// from the Phase A2 capture (firmware 2.6.4); injected so the reducer stays pure
/// and tests can use synthetic UUIDs.
struct GATTLayout: Equatable {
    let service: CBUUID
    let button: CBUUID   // notifies on button gestures (subscribe target)
    let mode: CBUUID     // App/SDK mode (read for truth, write to enable)

    static let blueParrott = GATTLayout(
        service: CBUUID(string: "95665a00-8704-11e5-960c-0002a5d5c51b"),
        button: CBUUID(string: "66339E60-D55A-11E5-B7CB-0002A5D5C51B"),
        mode: CBUUID(string: "D24B6EC0-D55A-11E5-8476-0002A5D5C51B"))
}

/// Where the choreography is in the discover→subscribe handshake. Pure; the
/// executor performs the CoreBluetooth I/O the effects describe.
enum GATTState: Equatable {
    case idle                       // pre-connect / reset
    case discoveringServices        // discoverServices issued
    case discoveringCharacteristics // service found; discoverCharacteristics issued
    case resolvingButton            // button char found; its descriptors (CCCD) discovering
    case subscribing(hasCCCD: Bool) // setNotifyValue issued; awaiting the notify-state callback. `hasCCCD` carries whether the button char actually exposed a notify descriptor — it decides whether a subscribe error is fatal or the benign App-Mode-push case.
    case subscribed                 // button events expected to flow (isNotifying, or App-Mode push w/o CCCD)
    case failed                     // a real subscribe failure (no service / no button char / CCCD present but subscribe errored)
}

enum GATTEvent: Equatable {
    case connected                                   // didConnect → start the walk
    case servicesDiscovered([CBUUID])                // didDiscoverServices
    case characteristicsDiscovered([CBUUID])         // didDiscoverCharacteristicsFor the control service
    case descriptorsDiscovered(characteristic: CBUUID, hasCCCD: Bool)  // didDiscoverDescriptorsFor
    case notifyStateUpdated(characteristic: CBUUID, isNotifying: Bool, failed: Bool)  // didUpdateNotificationStateFor
    case valueUpdated(characteristic: CBUUID, data: Data)             // didUpdateValueFor (button NOTIFY or mode read)
}

enum GATTEffect: Equatable {
    case discoverServices([CBUUID])
    case discoverCharacteristics(service: CBUUID)
    case discoverDescriptors(characteristic: CBUUID)
    case readValue(characteristic: CBUUID)           // mode char → App-Mode truth (traced)
    case setNotify(characteristic: CBUUID)           // ONLY after descriptorsDiscovered (the invariant)
    case emitSubscribed                              // → BLECentralEvents.bleDidSubscribe
    case emitSubscribeFailed                         // → BLECentralEvents.bleSubscribeFailed
    case emitButtonValue(Data)                       // → BLECentralEvents.bleDidUpdateButtonValue
    case noteAppMode(value: Data)                    // mode read completed: log the real value
    case log(String)
}

/// The pure GATT choreography reducer: `(state, event, layout) → (state, [effect])`,
/// no I/O. Irrelevant `(state, event)` pairs fall through to the `default` and are a
/// no-op (state unchanged, no effects).
enum GATTReducer {
    static func reduce(_ s: GATTState, _ e: GATTEvent,
                       layout: GATTLayout = .blueParrott) -> (GATTState, [GATTEffect]) {
        switch (s, e) {
        case (.idle, .connected):
            return (.discoveringServices, [.discoverServices([layout.service])])

        case (.discoveringServices, .servicesDiscovered(let uuids)):
            guard uuids.contains(layout.service) else {
                // The control service isn't present — nothing to subscribe to. Surface
                // it as a subscribe failure so the connection machine re-probes rather
                // than waiting out the discoveryWatchdog.
                return (.failed, [.emitSubscribeFailed, .log("control service \(layout.service) not found")])
            }
            return (.discoveringCharacteristics, [.discoverCharacteristics(service: layout.service)])

        case (.discoveringCharacteristics, .characteristicsDiscovered(let uuids)):
            guard uuids.contains(layout.button) else {
                return (.failed, [.emitSubscribeFailed,
                                  .log("button characteristic \(layout.button) not found (firmware variation?)")])
            }
            // THE INVARIANT: resolve the button char's descriptors (its CCCD) BEFORE
            // enabling notifications — never `setNotify` straight from here. Also read
            // the mode char (when present) so the executor can log App-Mode truth.
            var fx: [GATTEffect] = [.discoverDescriptors(characteristic: layout.button)]
            if uuids.contains(layout.mode) { fx.append(.readValue(characteristic: layout.mode)) }
            fx.append(.log("characteristics discovered → resolving button descriptors before subscribe"))
            return (.resolvingButton, fx)

        case (.resolvingButton, .descriptorsDiscovered(let char, let hasCCCD)) where char == layout.button:
            // CCCD resolved (or absent): issue the subscribe. `hasCCCD` is carried into
            // `.subscribing` because it decides how to read the notify-state outcome.
            return (.subscribing(hasCCCD: hasCCCD),
                    [.setNotify(characteristic: layout.button),
                     .log(hasCCCD ? "button CCCD present → subscribing"
                                  : "button CCCD absent → subscribing (App-Mode push expected)")])

        case (.subscribing(let hasCCCD), .notifyStateUpdated(let char, let isNotifying, let failed)) where char == layout.button:
            if isNotifying {
                return (.subscribed, [.emitSubscribed, .log("isNotifying=true — button events flowing")])
            }
            if failed {
                // THE BLUEPARROTT QUIRK (Phase A2, firmware 2.6.4): the button char
                // exposes NO CCCD, so `setNotifyValue` errors with "attribute could not
                // be found" — yet the headset still pushes button notifications under
                // App Mode (verified on-hardware). So a subscribe error with no CCCD is
                // BENIGN: go live and listen for values via `didUpdateValueFor`; do NOT
                // re-probe (that churn tore the link down before any press could land —
                // the "no button feedback" bug). Only a failure WITH a CCCD present is a
                // genuine subscribe fault worth a re-probe.
                if hasCCCD {
                    return (.failed, [.emitSubscribeFailed, .log("subscribe failed despite CCCD present → re-probe")])
                }
                return (.subscribed, [.emitSubscribed,
                                      .log("subscribe errored (no CCCD) → going live, listening for App-Mode button notifications")])
            }
            // A clean notify-state callback with isNotifying=false is an unsubscribe;
            // not an error, just nothing to do.
            return (s, [])

        // Mode-char read completing (App-Mode truth) can land in any state after the
        // read is issued; record it without disturbing the subscribe handshake.
        case (_, .valueUpdated(let char, let data)) where char == layout.mode:
            return (s, [.noteAppMode(value: data)])

        // A button NOTIFY value (only meaningful once subscribed, but harmless earlier).
        case (_, .valueUpdated(let char, let data)) where char == layout.button:
            return (s, [.emitButtonValue(data)])

        default:
            return (s, [])
        }
    }
}
