// BLEConnReducer.swift
// Pure connection state machine for the macOS BlueParrott BLE control link:
// scanning → connecting → discovering → live, with identifier reconnect and
// watchdogs so first-connect is fast and a stale/unreachable id can never hang
// the button. Replaces the implicit connect/retry/re-arm guards in
// `BlueParrottBLEManager`; an executor (the `CBCentralAdapter` driven through the
// `BLECentral` seam) applies the returned effects to the real CoreBluetooth I/O
// and feeds resulting events back in.
//
// Platform-agnostic and I/O-free (only `CBManagerState` is referenced, available
// on iOS too), so it compiles into BOTH the iOS and macOS targets and its tests
// run under `make test` and the macOS unit bundle. See
// @docs/design/macos-headset-loop-state-machine.md §Connection machine.
//
// Key invariant — NO STALE-ID HANG (F1 / the Opus consult's critical hole): the
// speculative `known` connect runs under its own `connectWatchdog`; on timeout it
// cancels the forever-pending connect, forgets the saved id, and falls to a
// continuous scan. An empty retrieve (`knownPeripheralUnresolved`) short-circuits
// straight to scan without waiting out the watchdog. Out-of-range reconnect uses
// the RETAINED peripheral (`reconnectHeld`) with no retrieve and no watchdog — an
// indefinite pending connect is correct there; it completes the instant the
// headset returns.

import CoreBluetooth

/// Lifecycle of the macOS BlueParrott BLE control link. Pure state; the executor
/// (`CBCentralAdapter`) performs the CoreBluetooth I/O the effects describe.
enum BLEConnState: Equatable {
    case stopped                       // not enabled
    case unavailable(CBManagerState)   // poweredOff / unauthorized / unsupported / resetting
    case scanning(attempt: Int)        // ONE continuous scan running (findings F1, Step A)
    case connecting(ConnectMode)       // a connect is in flight
    case discovering                   // connected; discovering chars + subscribing
    case live                          // subscribed; button notifications flow
    case reconnecting                  // disconnected; pending connect to the held peripheral
}

/// Which path issued the in-flight connect — the executor picks the watchdog
/// duration from this (advertised is imminent, known is speculative).
enum ConnectMode: Equatable {
    case advertised                    // from didDiscover — imminent, short watchdog
    case known                         // from retrievePeripherals(withIdentifiers:) — speculative, may be unreachable
}

enum BLEConnEvent: Equatable {
    case start, stop
    case managerState(CBManagerState)
    case knownPeripheralResolved       // retrievePeripherals returned our saved id
    case knownPeripheralUnresolved     // retrievePeripherals returned empty (stale/forgotten id)
    case advertisementDiscovered       // didDiscover
    case connected                     // didConnect
    case connectFailed(retryable: Bool)
    case subscribed                    // isNotifying == true on the button char
    case scanTick                      // re-check timer fired (does NOT stop the scan)
    case connectWatchdog               // a connect didn't complete in time
    case discoveryWatchdog             // connected but never reached `subscribed`
    case disconnected
}

enum BLEConnEffect: Equatable {
    case startContinuousScan           // idempotent; no-op if already scanning
    case stopScan
    case resolveKnownPeripheral(UUID)  // retrievePeripherals(withIdentifiers:)
    case connectAdvertised             // connect() to the just-discovered peripheral
    case connectKnown                  // connect() to the resolved known peripheral (pending; watchdogged)
    case reconnectHeld                 // connect() to the RETAINED CBPeripheral (no retrieve, no timeout)
    case cancelConnection
    case discoverAndSubscribe
    case persistIdentifier             // save peripheral.identifier on subscribe
    case clearSavedIdentifier          // stale-id hygiene
    case armTimer(BLETimer)
    case cancelTimer(BLETimer)
    case log(String)
}

enum BLETimer: Equatable { case scanTick, connectWatchdog, discoveryWatchdog }

/// The pure connection reducer: `(state, event, savedID) → (state, [effect])`, no
/// I/O. `savedID` is the persisted BlueParrott peripheral identifier (nil ⇒
/// first-run scan path). Irrelevant `(state, event)` pairs fall through to the
/// `default` and are a no-op (state unchanged, no effects).
enum ConnReducer {
    static func reduce(_ s: BLEConnState, _ e: BLEConnEvent,
                       savedID: UUID?) -> (BLEConnState, [BLEConnEffect]) {
        switch (s, e) {
        case (_, .stop):
            return (.stopped, [.stopScan, .cancelConnection,
                               .cancelTimer(.scanTick), .cancelTimer(.connectWatchdog),
                               .cancelTimer(.discoveryWatchdog)])

        case (_, .managerState(let st)) where st != .poweredOn:
            return (.unavailable(st), [.log("BLE unavailable: \(st.rawValue)")])

        // Powered on (from start or recovery): prefer a known peripheral, else scan.
        case (.stopped, .start), (.unavailable, .managerState(.poweredOn)):
            if let id = savedID {
                return (.connecting(.known),
                        [.resolveKnownPeripheral(id), .armTimer(.connectWatchdog),
                         .log("resolving saved peripheral")])
            }
            return (.scanning(attempt: 1), [.startContinuousScan, .armTimer(.scanTick)])

        case (.connecting(.known), .knownPeripheralResolved):
            return (.connecting(.known), [.connectKnown])           // pending; watchdog already armed
        case (.connecting(.known), .knownPeripheralUnresolved):
            // System has forgotten the saved id (re-paired/reset/different host): don't
            // wait out the watchdog — forget it and fall straight to scanning.
            return (.scanning(attempt: 1),
                    [.cancelTimer(.connectWatchdog), .clearSavedIdentifier,
                     .startContinuousScan, .armTimer(.scanTick),
                     .log("saved peripheral not found → scanning")])
        case (.connecting(.known), .connectWatchdog):
            // Stale/unreachable id: stop the forever-pending connect, forget it, scan.
            return (.scanning(attempt: 1),
                    [.cancelConnection, .clearSavedIdentifier,
                     .startContinuousScan, .armTimer(.scanTick),
                     .log("known-connect timed out → scanning")])

        // Continuous scan: the tick re-checks but NEVER stops the scan (findings F1).
        case (.scanning(let n), .scanTick):
            return (.scanning(attempt: n + 1), [.armTimer(.scanTick)])
        case (.scanning, .advertisementDiscovered):
            // Advertised connect is imminent but still watchdogged — a silent connect
            // (no didConnect/didFailToConnect) must not hang.
            return (.connecting(.advertised),
                    [.stopScan, .cancelTimer(.scanTick), .connectAdvertised,
                     .armTimer(.connectWatchdog)])
        case (.connecting(.advertised), .connectWatchdog):
            return (.scanning(attempt: 1),
                    [.cancelConnection, .startContinuousScan, .armTimer(.scanTick),
                     .log("advertised-connect timed out → scanning")])

        case (.connecting, .connected):
            return (.discovering, [.cancelTimer(.connectWatchdog),
                                   .discoverAndSubscribe, .armTimer(.discoveryWatchdog)])
        // didFailToConnect for EITHER mode (advertised or known) → fall back to scan;
        // the stale-id `clearSavedIdentifier` is handled by the known connectWatchdog.
        case (.connecting, .connectFailed(let retryable)):
            return retryable
                ? (.scanning(attempt: 1),
                   [.cancelTimer(.connectWatchdog), .startContinuousScan, .armTimer(.scanTick)])
                : (.unavailable(.unknown),
                   [.cancelTimer(.connectWatchdog), .log("connect failed (non-retryable)")])

        case (.discovering, .subscribed):
            return (.live, [.cancelTimer(.discoveryWatchdog), .persistIdentifier,
                            .log("BlueParrottBLE live — button events flowing")])
        case (.discovering, .discoveryWatchdog):
            return (.scanning(attempt: 1),
                    [.cancelConnection, .startContinuousScan, .armTimer(.scanTick),
                     .log("connected but never subscribed → re-probing")])

        // Out of range / power cycle: reconnect to the RETAINED peripheral directly —
        // no retrieve, no watchdog (an indefinite pending connect is correct here; it
        // completes the instant the headset returns). The near-instant reconnect the
        // driving use case needs.
        case (.live, .disconnected):
            return (.reconnecting, [.reconnectHeld, .log("disconnected → pending reconnect to held peripheral")])
        case (.reconnecting, .connected):
            return (.discovering, [.discoverAndSubscribe, .armTimer(.discoveryWatchdog)])

        default:
            return (s, [])   // ignore irrelevant events in the current state
        }
    }
}
