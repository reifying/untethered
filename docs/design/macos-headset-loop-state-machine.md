# macOS Headset Hands-Free Loop — State-Machine Overhaul

> **Language note:** This feature is entirely client-side Swift (iOS/macOS app under
> `ios/`). There are **no backend or Clojure components** and **no WebSocket protocol
> changes** — the backend receives transcribed text regardless of what drives
> recording. All code examples are Swift, matching the codebase.
>
> **Companion docs:** findings/evidence in @docs/design/macos-headset-loop-findings.md;
> the BLE button transport in @docs/design/macos-blueparrott-corebluetooth.md; the
> shared remote-control history in @docs/design/headset-remote-control.md and
> @docs/design/ios-headset-remote-control.md.

## 1. Overview

### Problem statement
The macOS hands-free loop (BlueParrott button → record → transcribe → send → hear
response → idle) works in the happy path but **strands and misfires** because its
control logic is implicit — scattered across `if state == …` guards in
`HeadsetRemoteCommandManager`, the `BlueParrottPTTArbitrator`, and ad-hoc Combine
sinks, with no single owner of "what state are we in and what may happen next." The
concrete failures (full evidence in @docs/design/macos-headset-loop-findings.md):

- **F4 (worst):** after one utterance the machine can sit in `.sending` ("Processing")
  forever — the *only* exit on macOS is TTS starting (`voiceOutput.$isSpeaking`); a
  prompt that produces no spoken output leaves the button dead.
- **F3:** the first capture right after BLE connect returns **zero** audio buffers
  (dead route) → "No speech"; the next press works.
- **F5:** no discrete gestures and **no barge-in** — a press during `speaking`/`sending`
  does nothing; the arbitrator drops tap/double/long, so you can't interrupt.
- **F1:** BLE first-connect takes ~41–53 s (rare advertisement; `retrieveConnectedPeripherals`
  is always empty because HFP ≠ BLE GATT).
- **F2:** a warm-up dead zone clips the start of capture (the always-on keep-alive
  output is a measured contributor).

### Goals
1. Model the loop as **explicit, pure, unit-testable state machines** — one for the
   **BLE connection lifecycle**, one for the **interaction/session** — each a
   `reduce(state, event) → (state, [effect])` reducer with an effect executor.
2. **No stranding:** every non-idle state has a fallback/timeout/interrupt edge back to
   `idle`. Fixes F4.
3. **Capture readiness:** detect a dead first capture and recover without user
   intervention. Fixes F3.
4. **Gesture parity + barge-in:** support hold-to-talk *and* tap-to-toggle, and let a
   press interrupt `speaking`/`awaitingResponse`. Fixes F5.
5. **Fast, reliable reconnect:** identifier-based reconnect with watchdogs (no stale-id
   hang), held-peripheral reconnect on disconnect. Improves F1.
6. **Reliable capture on the headset mic:** keep the HFP mic, gate the keep-alive
   suspension to the BLE path, add warm-up handling. Improves F2 (per bug
   `voice-code-headset-hfp-mic-warmup-66p`).

### Non-goals
- Rewiring **iOS** off the `BPHeadset` SDK. The reducer core is designed to be reusable
  by iOS later, but this work only changes the macOS event sources and the shared state
  logic in a backward-compatible way.
- Backend / WebSocket / protocol changes.
- The AirPods / `MPRemoteCommandCenter` media-key path's *transport* (it keeps emitting
  play/pause/next); it will feed the **same** new interaction reducer, and must not
  regress.
- Reverse-engineering additional BlueParrott characteristics beyond button + App Mode
  (out of scope per @docs/design/macos-blueparrott-corebluetooth.md).
- Fixing the `VoiceCodeClient` reconnection-timer log spam (F8) — tracked separately;
  noted only because it impedes diagnosis.

### Decisions taken (were open questions in the findings doc)
1. **Gesture model = unified:** hold = push-to-talk (and barge-in to "talk now" from a
   busy state); quick tap = toggle (and dismiss a busy state); double-tap = hard
   interrupt. Disambiguated by a hold-timer (the raw GATT stream brackets every
   gesture — see §3). There is **no** distinct long-press action (a hold is PTT), so the
   in-bracket `04` long-press code is ignored. 2. **Barge-in = yes** (both a hold and a
   tap act during `speaking`/`awaitingResponse`). 3. **`.sending` fallback = interrupt +
   generous timeout to `idle`, without cancelling the backend prompt.** 4. **Mic = headset
   HFP with warm-up handling**, not built-in. 5. **Scope = shared reducer core, macOS
   event sources first.**

## 2. Background & Context

### Current state
`HeadsetRemoteCommandManager` owns `enum HeadsetState { ready, recording, sending,
speaking }` (`sending.description == "Processing"`). Transitions are implicit:

- `blueParrottButtonDown()` → `if state == .ready { startRecording() }`
- `blueParrottButtonUp()` → `if state == .recording { stopRecordingAndSend() }`
- `voiceInput.$isRecording` sink → auto-finalize `recording → sending`
- `voiceOutput.$isSpeaking` sink → `sending → speaking → ready` (**the only macOS exit
  from `sending`**)
- macOS button events arrive via `BlueParrottBLEManager` → `BlueParrottPTTArbitrator`
  (forwards down/up, **drops** tap/double/long) → the delegate methods above.

The BLE transport (`BlueParrottBLEManager`) already has a connect/retry/re-arm machine
with a scan-timeout re-probe and (newly) a continuous scan; it is driven through an
injected `BLECentral` seam for testability.

### Why now
Hardware testing on 2026-06-03 reached an end-to-end success ("Testing 123" captured and
sent) but in the same session reproduced F3 (zero-buffer first capture) and F4
(strand in `.sending`), and confirmed F1's discovery latency and F2's dead zone. The
implicit logic can't express the fallback/interrupt edges these fixes require without
becoming a tangle of new flags — hence an explicit state-machine model.

### Related work
- @docs/design/macos-headset-loop-findings.md — the evidence this design responds to.
- @docs/design/macos-blueparrott-corebluetooth.md — the GATT constants, App-Mode
  persistence, and the `BLECentral`/`BLECentralEvents` seam reused here.
- Bugs `voice-code-blueparrott-ble-scan-timeout-ghw` (F1, identifier reconnect + the
  Opus consult's stale-id-hang fix) and `voice-code-headset-hfp-mic-warmup-66p` (F2/F3).

## 3. Detailed Design

Two reducers. Each is a pure function `(State, Event) → (State, [Effect])`; an executor
applies effects (CoreBluetooth calls, audio engine, timers) and feeds resulting events
back in. The reducers carry **no** I/O, so they are exhaustively unit-testable; the
executors are thin and driven through the existing seams.

### Data Model

#### Connection machine
```swift
/// Lifecycle of the macOS BlueParrott BLE control link. Pure state; the executor
/// (CBCentralAdapter) performs the CoreBluetooth I/O the effects describe.
enum BLEConnState: Equatable {
    case stopped                       // not enabled
    case unavailable(CBManagerState)   // poweredOff / unauthorized / unsupported / resetting
    case scanning(attempt: Int)        // ONE continuous scan running (findings F1, Step A)
    case connecting(ConnectMode)       // a connect is in flight
    case discovering                   // connected; discovering chars + subscribing
    case live                          // subscribed; button notifications flow
    case reconnecting                  // disconnected; pending connect to the held peripheral
}

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
    case connectWatchdog               // a `known` connect didn't complete in time
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
```

#### Interaction (session) machine
```swift
/// Drives recording / sending / speaking. Replaces the implicit `HeadsetState`.
/// `awaitingResponse` is the old `.sending` ("Processing") with explicit exits.
enum SessionState: Equatable {
    case idle                  // was .ready
    case recording
    case finalizing            // reading the final transcription (one run-loop hop)
    case awaitingResponse      // prompt sent; waiting for spoken response
    case speaking              // TTS playing the response
}

/// Semantic, de-bracketed gestures (see GestureRecognizer) + system events.
enum SessionEvent: Equatable {
    case holdStarted           // button held past holdThreshold
    case holdEnded             // release after a hold
    case tap                   // quick press-release
    case doubleTap             // (no `longPress` — a hold is PTT; the raw `04` code is dropped)
    case captureProducedAudio  // first non-silent buffer arrived (F3 readiness)
    case captureStalled        // grace elapsed with zero buffers (F3)
    case captureEnded          // capture stopped with NO `up` gesture: recognizer silence
                               // auto-finalize, engine failure, or forced on BLE disconnect.
                               // Safety net so `.recording` can't strand (preserves the
                               // existing voiceInput.$isRecording→false transition).
    case transcription(String?)// nil/empty ⇒ nothing recognized
    case ttsStarted            // voiceOutput.isSpeaking → true
    case ttsEnded              // voiceOutput.isSpeaking → false
    case awaitTimedOut         // awaitingResponse fallback fired (F4)
    case backendUnavailable    // client disconnected mid-await
}

enum SessionEffect: Equatable {
    case startCapture
    case restartCapture        // F3 recovery
    case stopCapture
    case sendPrompt(String)
    case interruptTTS
    case suspendKeepAlive      // BLE path only (F2)
    case resumeKeepAlive
    case armTimer(SessionTimer)
    case cancelTimer(SessionTimer)
    case updateNowPlaying
    case log(String)
}

enum SessionTimer: Equatable { case captureGrace, awaitResponse }
```

#### Gesture recognizer (de-bracketer)
The raw GATT stream brackets every gesture with down/up (`tap = 01,00,02`,
`double = 01,00,01,00,03`, `hold = 01,04,00`; @docs/design/macos-blueparrott-corebluetooth.md
§3). Driving the session machine off raw down/up flickers on taps (findings F5). A pure
recognizer converts raw signals into exactly one semantic gesture per physical action.

```swift
enum RawButtonSignal: Equatable { case down, up, tapCode, doubleTapCode, longPressCode }

/// Converts the raw bracketed GATT stream into clean gestures. Hold is detected by a
/// timer (`holdThreshold`); discrete tap/double come from the hardware's own gesture
/// codes (02/03). A per-press `generation` + `isDown` guard prevents a stale hold timer
/// from firing across a fast double-tap. `scheduleAfter` is injected so it is
/// unit-testable without real time (no wall-clock is read).
final class BlueParrottGestureRecognizer {
    static let holdThreshold: TimeInterval = 0.30

    private let emit: (HeadsetGesture) -> Void
    private let scheduleAfter: (TimeInterval, @escaping () -> Void) -> Void
    private var generation = 0          // bumped per `down`; invalidates older hold timers
    private var isDown = false
    private var holdActive = false

    init(emit: @escaping (HeadsetGesture) -> Void,
         scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void) {
        self.emit = emit
        self.scheduleAfter = scheduleAfter
    }
    // feed(_:) in §Code Examples
}

enum HeadsetGesture: Equatable { case holdStarted, holdEnded, tap, doubleTap }
```

#### Persisted data
One new persisted value: the BlueParrott BLE peripheral identifier, stored in
`UserDefaults` (matching the `@Published … { didSet { UserDefaults.standard.set(…) } }`
pattern in `ios/VoiceCode/Managers/AppSettings.swift`). No schema/DB change.

| | Before | After |
|---|---|---|
| Persisted BLE state | none | `UserDefaults["blueParrottPeripheralID"] : String?` (a `UUID`) |
| macOS reconnect | scan only (~41–53 s) | resolve saved id → pending `connect()` (near-instant when reachable), scan as fallback |

**Migration:** additive; absent key ⇒ first-run scan path (unchanged behavior). The id
is cleared when retrieve returns empty (`knownPeripheralUnresolved`) or the
`connectWatchdog` fires (stale-id hygiene), so a re-paired/reset headset self-heals.

#### Tunable timing constants
Suggested defaults (grounded in the findings; all tunable). Only `holdThreshold` is
hard-pinned in the recognizer; the rest are executor parameters for the injected
`scheduleWork`:

| Constant | Suggested | Rationale (from @docs/design/macos-headset-loop-findings.md) |
|---|---|---|
| `holdThreshold` | 0.30 s | tap-vs-hold split; small enough that PTT feels responsive |
| `captureGrace` | ~1.0 s | a live route delivers buffers within ~300 ms even when silent; **zero** buffers by 1 s ⇒ dead route → `restartCapture` (F3). Distinct from the F2 silent-warm-up, which `captureProducedAudio` cancels |
| `awaitResponse` | ~120 s | generous — backend turns can be long; tap/double/hold also exit `awaitingResponse`, so this is only the no-interaction backstop (F4) |
| `scanTick` | ~8 s | matches the prior scan-timeout cadence; re-checks the connected fast path + logs (scan itself is continuous) |
| `connectWatchdog` | advertised ~6 s / known ~10 s | the executor knows which `connect*` it issued and picks the duration; advertised is imminent, known is speculative |
| `discoveryWatchdog` | ~5 s | connect → discover-chars → `isNotifying` should be quick; longer ⇒ fragile subscribe (F7) |

### API Design

There are **no network endpoints**. The "API" is (a) the two pure reducers, (b) the
BLE wire interface (unchanged GATT contract from the transport doc), and (c) the
in-process Swift surfaces below. No external/breaking API; the internal change is the
`HeadsetState` → `SessionState` rename and removal of `BlueParrottPTTArbitrator` (its
job moves into the gesture recognizer).

**Reducer surface (the testable core)** — signature sketch; the bodies are in
§Code Examples (this block is illustrative, not a second declaration to compile
alongside them):
```swift
enum ConnReducer {
    static func reduce(_ s: BLEConnState, _ e: BLEConnEvent,
                       savedID: UUID?) -> (BLEConnState, [BLEConnEffect])
}
enum SessionReducer {
    static func reduce(_ s: SessionState, _ e: SessionEvent,
                       source: ButtonSource) -> (SessionState, [SessionEffect])
}
enum ButtonSource: Equatable { case blueParrottBLE, mediaKey, iosSDK }
```

**`BLECentral` / `BLECentralEvents` seam additions (Step B).** The existing seam
(@docs/design/macos-blueparrott-corebluetooth.md) gains the methods/events the new
effects drive; `FakeBLECentral` implements them so the conn reducer + executor stay
hardware-free in tests:
```swift
protocol BLECentral: AnyObject {          // + additions
    // …existing: managerState, centralDelegate, scanForButtonService, stopScan,
    //            cancelConnection, subscribeToButtonEvents, writeAppModeEnable…
    func resolveKnownPeripheral(_ id: UUID)   // retrievePeripherals(withIdentifiers:); fires bleKnownPeripheralResolved (found) or bleNoKnownPeripheral (empty)
    func connectKnown()                       // connect() to the resolved peripheral (pending)
    func reconnectHeld()                      // connect() to the retained CBPeripheral (post-disconnect)
}
protocol BLECentralEvents: AnyObject {    // + additions
    // …existing: bleDidUpdateState, bleDidConnect, bleDidFailToConnect,
    //            bleDidDisconnect, bleDidUpdateButtonValue, bleDidStartConnecting…
    func bleKnownPeripheralResolved()         // → BLEConnEvent.knownPeripheralResolved
    func bleNoKnownPeripheral()               // → BLEConnEvent.knownPeripheralUnresolved (empty → scan)
}
```
`bleDidStartConnecting` keeps cancelling the **scan** path's expectations only; the
`connectWatchdog`/`discoveryWatchdog`/`scanTick` timers are reducer-internal (driven by
the injected `scheduleWork`, using the `scanTimeoutGeneration` guard pattern), not seam
methods.

**Failure / edge handling (no HTTP codes — these are the machine's safety edges):**

| Condition | Machine + edge | Result |
|---|---|---|
| Prompt yields no spoken response | session `awaitingResponse —[awaitTimedOut]→ idle` | button usable again (F4) |
| **Tap/double** during `speaking`/`awaitingResponse` | session → `idle` (`interruptTTS` / cancel await) | dismiss the busy state (F5) |
| **Hold** during `speaking`/`awaitingResponse` | session → `recording` (interrupt + `startCapture`) | barge-in — talk now (F4/F5) |
| First capture, 0 buffers | session `recording —[captureStalled]→ recording` (`restartCapture`, once) | auto-recover (F3) |
| Capture ends with no `up` (recognizer silence / disconnect mid-record / dropped event) | session `recording —[captureEnded]→ finalizing` | no recording strand; preserves auto-finalize |
| Saved id not found by retrieve | conn `connecting(.known) —[knownPeripheralUnresolved]→ scanning` (`clearSavedIdentifier`) | immediate fall-to-scan, no watchdog wait |
| Stale id resolves but won't connect | conn `connecting(.known) —[connectWatchdog]→ scanning` (`cancelConnection`,`clearSavedIdentifier`) | no infinite hang (F1/consult) |
| Advertised connect stalls | conn `connecting(.advertised) —[connectWatchdog]→ scanning` | no silent hang |
| Connect attempt fails (either mode) | conn `connecting —[connectFailed]→ scanning` (retryable) / `unavailable` (not) | falls back to scan |
| Connected but never subscribes | conn `discovering —[discoveryWatchdog]→ scanning` | recovers fragile subscribe (F7) |
| Bluetooth off/unauthorized | conn `* —[managerState]→ unavailable` | wait for power-on; no retry storm |

### Code Examples

#### Connection reducer — happy path, identifier reconnect, watchdogs
```swift
extension ConnReducer {
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
```

#### Session reducer — strand-proof, barge-in, capture readiness
```swift
extension SessionReducer {
    static func reduce(_ s: SessionState, _ e: SessionEvent,
                       source: ButtonSource) -> (SessionState, [SessionEffect]) {
        switch (s, e) {
        // Start recording: hold (PTT) or tap (toggle) both begin from idle.
        case (.idle, .holdStarted), (.idle, .tap):
            return beginRecording(source: source, interrupting: [])

        // Barge-in (F4/F5): a HOLD from a busy state means "talk now" — interrupt and
        // start a fresh recording turn (the primary PTT gesture must work here too).
        case (.speaking, .holdStarted):
            return beginRecording(source: source, interrupting: [.interruptTTS])
        case (.awaitingResponse, .holdStarted):
            return beginRecording(source: source, interrupting: [.cancelTimer(.awaitResponse)])

        // F3: first capture produced no audio within the grace window → restart once.
        case (.recording, .captureStalled):
            return (.recording, [.restartCapture, .armTimer(.captureGrace),
                                 .log("capture stalled (0 buffers) — restarting")])
        case (.recording, .captureProducedAudio):
            return (.recording, [.cancelTimer(.captureGrace)])

        // Stop: hold release (PTT), a second tap (toggle), or capture ending on its own
        // (recognizer silence auto-finalize / engine failure / forced on disconnect —
        // the safety net that keeps `.recording` from stranding) → finalize.
        case (.recording, .holdEnded), (.recording, .tap), (.recording, .captureEnded):
            return (.finalizing, [.stopCapture, .resumeKeepAlive, .cancelTimer(.captureGrace)])

        case (.finalizing, .transcription(let text)):
            if let text, !text.trimmed.isEmpty {
                return (.awaitingResponse,
                        [.sendPrompt(text), .armTimer(.awaitResponse), .updateNowPlaying])
            }
            return (.idle, [.updateNowPlaying])                    // empty → straight back to idle

        // F4: no spoken response in time (or backend dropped) → idle WITHOUT cancelling
        // the prompt (a late response still speaks via `idle —ttsStarted→ speaking`).
        case (.awaitingResponse, .awaitTimedOut), (.awaitingResponse, .backendUnavailable):
            return (.idle, [.cancelTimer(.awaitResponse), .updateNowPlaying,
                            .log("await ended — re-enabling button (prompt still in flight)")])
        case (.awaitingResponse, .ttsStarted):
            return (.speaking, [.cancelTimer(.awaitResponse), .updateNowPlaying])

        // Dismiss a busy state with a tap or double-tap (no new recording).
        case (.awaitingResponse, .tap), (.awaitingResponse, .doubleTap):
            return (.idle, [.cancelTimer(.awaitResponse), .updateNowPlaying])
        case (.speaking, .tap), (.speaking, .doubleTap):
            return (.idle, [.interruptTTS, .updateNowPlaying])

        // A late response after a timeout still speaks (idle → speaking).
        case (.idle, .ttsStarted):
            return (.speaking, [.updateNowPlaying])
        case (.speaking, .ttsEnded):
            return (.idle, [.updateNowPlaying])

        default:
            return (s, [])
        }
    }

    /// Shared "start a recording turn" effects, optionally preceded by interrupt/cleanup
    /// effects when barging in from a busy state. Keep-alive suspend is BLE-only (F2).
    private static func beginRecording(source: ButtonSource,
                                       interrupting: [SessionEffect]) -> (SessionState, [SessionEffect]) {
        var fx = interrupting
        if source == .blueParrottBLE { fx.append(.suspendKeepAlive) }
        fx.append(contentsOf: [.startCapture, .armTimer(.captureGrace), .updateNowPlaying])
        return (.recording, fx)
    }
}

private extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
```

#### Gesture recognizer — disambiguation (happy path + edge)
```swift
extension BlueParrottGestureRecognizer {
    /// Convert one raw GATT signal into at most one semantic gesture.
    /// - Hold: `down` arms a timer keyed to this press's `generation`; if it fires while
    ///   the button is still down → `.holdStarted`; the later `up` → `.holdEnded`.
    /// - Tap/double: a quick release classified by the trailing hardware code. The
    ///   `generation` + `isDown` guards stop a fast double-tap (two `down`s) from
    ///   tripping a stale hold timer.
    func feed(_ signal: RawButtonSignal) {
        switch signal {
        case .down:
            generation += 1
            isDown = true
            holdActive = false
            let gen = generation
            scheduleAfter(Self.holdThreshold) { [weak self] in
                guard let self, self.isDown, gen == self.generation, !self.holdActive else { return }
                self.holdActive = true
                self.emit(.holdStarted)              // still held, same press → it's a hold
            }
        case .up:
            isDown = false
            if holdActive { emit(.holdEnded); holdActive = false }
            // else: quick release — classified by the trailing tap/double code below.
        case .tapCode:        if !holdActive { emit(.tap) }
        case .doubleTapCode:  if !holdActive { emit(.doubleTap) }
        case .longPressCode:  break                  // in-bracket during a hold — ignored
        }
    }
}
```

> **Recognizer assumption (see Risk 8):** discrete tap/double classification relies on
> the hardware's `02`/`03` codes (authoritative and reliably observed on firmware 2.6.4,
> @docs/design/macos-blueparrott-corebluetooth.md §3). Hold/PTT is timer-based and
> code-independent. A timing-only recognizer (drive everything off down/up, ignore the
> codes) is the fallback if a firmware is found that omits them — see §5 Alternatives.

#### Executor wiring (where effects meet I/O)
The executor lives in `HeadsetRemoteCommandManager` (session) and the
`CBCentralAdapter` (connection). It pattern-matches effects to the existing seams —
e.g. `.startContinuousScan` → `central.scanForButtonService()`, `.resolveKnownPeripheral`
→ `central.resolveKnownPeripheral(id)`, `.connectKnown` → `central.connectKnown()` (which
wraps `retrievePeripherals(withIdentifiers:) + connect()`), `.reconnectHeld` →
`central.reconnectHeld()` (`connect()` to the retained `CBPeripheral`, no retrieve),
`.armTimer` → the injected `scheduleWork`, `.sendPrompt` → `client.sendMessage(...)`,
`.persistIdentifier`/`.clearSavedIdentifier` → the `AppSettings` UserDefaults helper,
`.suspendKeepAlive` → `stopKeepAlive()`. `.persistIdentifier` reads
`peripheral.identifier` from the adapter's **retained** `CBPeripheral` (the pure reducer
never sees the peripheral) and writes it via the `AppSettings` helper. Timers use the
same generation-guard pattern as today's `scanTimeoutGeneration` so a fired-but-superseded
timer no-ops.

**Event sources the executor must feed in (beyond gestures/BLE callbacks):**
- `.captureEnded` — the session executor observes `voiceInput.$isRecording → false`
  (recognizer silence auto-finalize / engine failure) **and** `bleDidDisconnect` while
  the session is `.recording`, and feeds `.captureEnded` so a missed `up` or an
  out-of-range mid-recording can't strand `.recording` (this preserves today's
  `voiceInput.$isRecording` safety net). `stopCapture` is idempotent, so it's safe even
  when capture already ended on its own.
- `.transcription(_)` — the executor **always** emits this after `stopCapture` (the value
  is `nil` on a recognizer error), so `.finalizing` can never strand waiting for it.
- `.ttsStarted`/`.ttsEnded` from `voiceOutput.$isSpeaking`; `.awaitTimedOut` from the
  `awaitResponse` timer; `.backendUnavailable` from `client.isConnected → false`.

**Threading & gating.** The executor runs the reduce → apply step on the **main queue**
(matching today's `@Published`/Combine-on-main managers), so reducer state and effect
application are serialized. The `headsetModeEnabled`/`blueParrottEnabled` /
`stateMachineEngaged` gate sits at the executor's *input*: when disengaged it forwards
only lifecycle events (BLE `start`/`stop`, `managerState`) and drops gesture/session
events, so the machines stay inert without special-casing inside the pure reducers.

### Component Interactions

**Connection (cold launch with saved id, then steady state):**
```
start → resolveKnownPeripheral(id) ─connectKnown (pending)─┐
   │                                                       ▼
   │   reachable → connected → discoverAndSubscribe → subscribed → LIVE (persistIdentifier)
   │   stale/unreachable → connectWatchdog → cancel + clearSavedIdentifier → continuous scan
   ▼
(no saved id) → continuous scan → didDiscover → connectAdvertised → connected → … → LIVE
LIVE → disconnected → reconnecting (reconnectHeld: connect() to retained peripheral) → connected → … → LIVE
```

**Interaction (the loop, with the F4 escape):**
```
idle ─holdStarted/tap→ recording ─(captureStalled→restartCapture once)─ recording
recording ─holdEnded/tap/captureEnded→ finalizing ─transcription(text)→ awaitingResponse
  (captureEnded = recognizer silence / engine failure / forced on BLE disconnect — no strand)
awaitingResponse ─ttsStarted→ speaking ─ttsEnded→ idle
awaitingResponse ─awaitTimedOut→ idle                    ← F4 (was: stuck forever)
speaking/awaitingResponse ─tap/doubleTap→ idle (interruptTTS / cancel await)   ← F5 dismiss
speaking/awaitingResponse ─holdStarted→ recording (interrupt + capture)        ← F4/F5 barge-in
idle ─ttsStarted→ speaking                               ← late response after a timeout
```

**Integration points & dependencies.**
- Upstream sources feed `SessionEvent`s: macOS `BlueParrottBLEManager` →
  `BlueParrottGestureRecognizer` → session reducer; macOS `MPRemoteCommandCenter`
  (`togglePlayPause`/`play`/`pause` → `tap`; `nextTrack` → `doubleTap`;
  `previousTrack`/seek stay disabled) → session reducer with `source: .mediaKey`; iOS
  `BPHeadset` SDK (later) → the SDK already de-brackets, so it maps straight to gestures.
  Media-key sources never produce `holdStarted`/`holdEnded` (no hold semantics), so the
  PTT/barge-in-by-hold edges apply only to the BLE/SDK sources.
- Downstream effects drive the unchanged `VoiceInputManager`, `VoiceOutputManager`,
  `VoiceCodeClient`, and the Now-Playing/keep-alive plumbing.
- Gating unchanged: `settings.headsetModeEnabled` (→ `isActive`),
  `settings.blueParrottEnabled`, and `stateMachineEngaged` (macOS: `isActive ||
  blueParrottEnabled`).

## 4. Verification Strategy

The reducers are pure, so the bulk of coverage is fast table tests with no hardware,
mirroring `BlueParrottEventParserTests`. Hardware-only behavior (real CoreBluetooth /
`AVAudioEngine`) is exercised by the existing seams + a manual checklist.

### Testing approach
- **Unit — `SessionReducer.reduce`:** every (state, event) pair, especially the new
  safety edges: `awaitingResponse + awaitTimedOut → idle`; `speaking + tap → idle +
  interruptTTS`; `awaitingResponse + tap → idle`; `speaking + holdStarted → recording +
  interruptTTS + startCapture` and `awaitingResponse + holdStarted → recording`
  (hold barge-in); `recording + captureStalled → restartCapture`; `recording +
  captureEnded → finalizing` (no-strand safety net); `idle + ttsStarted → speaking`
  (late response). Assert returned effects, including `suspendKeepAlive` only
  when `source == .blueParrottBLE`.
- **Unit — `ConnReducer.reduce`:** `connecting(.known) + connectWatchdog →
  scanning + cancelConnection + clearSavedIdentifier` (the stale-id-hang fix);
  `connecting(.known) + knownPeripheralUnresolved → scanning + clearSavedIdentifier`
  (empty retrieve falls to scan immediately, no watchdog wait);
  `scanning + scanTick` does **not** emit `stopScan`; `discovering + discoveryWatchdog
  → scanning`; `live + disconnected → reconnecting + reconnectHeld` (not `connectKnown`);
  `subscribed` emits `persistIdentifier`.
- **Unit — `BlueParrottGestureRecognizer`:** a held press → `holdStarted` then
  `holdEnded`; `down,up,tapCode → tap` (no holdStarted, no flicker); a fast double-tap
  (`down,up,down,up,doubleTapCode`) emits **only** `doubleTap` (the `generation`/`isDown`
  guard suppresses the stale hold timer); `longPressCode` during a hold is ignored.
  Scheduler injected (no wall-clock).
- **Integration — `HeadsetRemoteCommandManager` (mocked `VoiceInput`/`VoiceOutput`/
  `Client`, faked `BLECentral`):** a BLE `down/up` drives `idle → … → awaitingResponse`;
  `awaitTimedOut` returns to `idle` and a subsequent `down` records again (the F4
  regression); a `captureStalled` triggers exactly one `restartCapture`; a
  `bleDidDisconnect` **while recording** (and a `voiceInput.isRecording → false` with no
  `up`) feeds `captureEnded` so the machine finalizes instead of stranding `.recording`.
- **End-to-end (manual, hardware):** §Acceptance criteria 1–7 on a real B450-XT
  (firmware 2.6.4) — confirmed via the `VoiceInput: capture summary firstAudio=…` and
  `BlueParrottBLE` logs.
- **Test host hygiene (findings F7):** reducers/recognizer never touch CoreBluetooth or
  `AVAudioPlayer`; real hardware stays guarded by `TestingEnvironment.isUnitTesting`;
  timers run on the injected `scheduleWork`. Validate via `make test-mac-unit` (clean
  unit signal) plus `make test` (iOS, no regression).

### Test examples
```swift
final class SessionReducerTests: XCTestCase {
    func testAwaitingResponse_timeout_returnsToIdle_withoutCancellingPrompt() {
        let (state, fx) = SessionReducer.reduce(.awaitingResponse, .awaitTimedOut, source: .blueParrottBLE)
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(fx.contains(.cancelTimer(.awaitResponse)))
        XCTAssertFalse(fx.contains { if case .sendPrompt = $0 { return true }; return false },
                       "timeout must not cancel/resend the in-flight prompt")
    }

    func testSpeaking_tap_dismissesToIdle() {
        let (state, fx) = SessionReducer.reduce(.speaking, .tap, source: .blueParrottBLE)
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(fx.contains(.interruptTTS))
    }

    func testSpeaking_hold_bargesInAndRecords() {
        let (state, fx) = SessionReducer.reduce(.speaking, .holdStarted, source: .blueParrottBLE)
        XCTAssertEqual(state, .recording, "a hold during speaking must interrupt and start a new turn")
        XCTAssertTrue(fx.contains(.interruptTTS))
        XCTAssertTrue(fx.contains(.startCapture))
    }

    func testAwaitingResponse_tap_dismissesToIdle() {
        let (state, _) = SessionReducer.reduce(.awaitingResponse, .tap, source: .blueParrottBLE)
        XCTAssertEqual(state, .idle, "a tap during Processing must free the button (matches the edge table)")
    }

    func testAwaitingResponse_hold_bargesInAndRecords() {
        let (state, fx) = SessionReducer.reduce(.awaitingResponse, .holdStarted, source: .blueParrottBLE)
        XCTAssertEqual(state, .recording)
        XCTAssertTrue(fx.contains(.startCapture))
        XCTAssertTrue(fx.contains(.cancelTimer(.awaitResponse)))
    }

    func testRecording_captureStalled_restartsCaptureOnce() {
        let (state, fx) = SessionReducer.reduce(.recording, .captureStalled, source: .blueParrottBLE)
        XCTAssertEqual(state, .recording)
        XCTAssertTrue(fx.contains(.restartCapture))
    }

    func testRecording_captureEnded_finalizes_noStrand() {
        // Recognizer silence / engine failure / forced on BLE disconnect — `.recording`
        // must not strand when no `up` gesture arrives.
        let (state, fx) = SessionReducer.reduce(.recording, .captureEnded, source: .blueParrottBLE)
        XCTAssertEqual(state, .finalizing)
        XCTAssertTrue(fx.contains(.stopCapture))
    }

    func testKeepAliveSuspend_isGatedToBLESource() {
        let (_, ble) = SessionReducer.reduce(.idle, .holdStarted, source: .blueParrottBLE)
        let (_, media) = SessionReducer.reduce(.idle, .holdStarted, source: .mediaKey)
        XCTAssertTrue(ble.contains(.suspendKeepAlive))
        XCTAssertFalse(media.contains(.suspendKeepAlive), "media-key path keeps the keep-alive for stem-press stop")
    }
}

final class ConnReducerTests: XCTestCase {
    func testKnownConnect_watchdog_clearsStaleIdAndScans() {
        let (state, fx) = ConnReducer.reduce(.connecting(.known), .connectWatchdog, savedID: UUID())
        XCTAssertEqual(state, .scanning(attempt: 1))
        XCTAssertTrue(fx.contains(.cancelConnection))
        XCTAssertTrue(fx.contains(.clearSavedIdentifier))
        XCTAssertTrue(fx.contains(.startContinuousScan))
    }

    func testScanTick_doesNotStopTheRunningScan() {
        let (_, fx) = ConnReducer.reduce(.scanning(attempt: 1), .scanTick, savedID: nil)
        XCTAssertFalse(fx.contains(.stopScan), "continuous scan: the tick must not tear down the scan")
    }

    func testEmptyRetrieve_fallsToScanImmediately_clearingId() {
        let (state, fx) = ConnReducer.reduce(.connecting(.known), .knownPeripheralUnresolved, savedID: UUID())
        XCTAssertEqual(state, .scanning(attempt: 1))
        XCTAssertTrue(fx.contains(.clearSavedIdentifier))
        XCTAssertTrue(fx.contains(.startContinuousScan))
        XCTAssertTrue(fx.contains(.cancelTimer(.connectWatchdog)), "no need to wait out the watchdog")
    }

    func testAdvertisedConnect_isWatchdogged_andRecoversToScan() {
        let (connecting, armFx) = ConnReducer.reduce(.scanning(attempt: 1), .advertisementDiscovered, savedID: nil)
        XCTAssertEqual(connecting, .connecting(.advertised))
        XCTAssertTrue(armFx.contains(.armTimer(.connectWatchdog)), "a silent advertised connect must not hang")
        let (state, fx) = ConnReducer.reduce(.connecting(.advertised), .connectWatchdog, savedID: nil)
        XCTAssertEqual(state, .scanning(attempt: 1))
        XCTAssertTrue(fx.contains(.cancelConnection))
        XCTAssertFalse(fx.contains(.clearSavedIdentifier), "advertised connect is not from a saved id")
    }

    func testDisconnect_reconnectsToHeldPeripheral_notRetrieve() {
        let (state, fx) = ConnReducer.reduce(.live, .disconnected, savedID: UUID())
        XCTAssertEqual(state, .reconnecting)
        XCTAssertTrue(fx.contains(.reconnectHeld))
        XCTAssertFalse(fx.contains(.connectKnown), "out-of-range reconnect uses the retained peripheral, not a retrieve")
    }
}
```

### Acceptance criteria
1. After a successful utterance whose prompt produces **no** spoken response, the button
   records again within the await timeout (no permanent strand). **(F4)**
2. A tap (or double-tap) during `speaking`/`awaitingResponse` interrupts/dismisses to
   `idle`; a **hold** during either state barges in — interrupts and starts a new
   recording in one gesture (no separate second press). **(F4/F5)**
3. The first capture after BLE connect that yields zero buffers auto-restarts once and
   captures on the retry (no user re-press required). **(F3)**
4. A held press records and release sends (PTT); a quick tap latches recording and a
   second tap sends (toggle) — no record/stop flicker on tap. **(F5)**
5. With a saved peripheral id, reconnect after the app relaunch or an out-of-range
   round-trip completes without waiting for an advertisement; a stale id never hangs the
   button (falls back to scan within the connect watchdog). **(F1)**
6. `SessionReducer`/`ConnReducer`/`BlueParrottGestureRecognizer` unit tests pass and the
   reducers contain no I/O; `make test-mac-unit` and `make test` are green.
7. The macOS AirPods path is unaffected: a `mediaKey`-sourced recording does **not**
   suspend the keep-alive, and play/pause stem presses still start/stop recording.
8. `.recording` cannot strand: if capture ends with no `up` — recognizer silence
   auto-finalize, or the headset disconnects mid-recording — the machine finalizes
   (sends if non-empty, else returns to `idle`), preserving the current
   `voiceInput.$isRecording` safety net. **(Goal #2)**

## 5. Alternatives Considered
1. **Patch the implicit logic (add flags/guards) instead of reducers.** Cheapest, but
   F4/F5 need new fallback/interrupt edges in several places; bolting them on recreates
   the tangle this doc exists to remove and is hard to test exhaustively. **Rejected.**
2. **One mega-machine for connection + interaction.** Simpler to wire, but the two
   lifecycles change independently (you can be `live` and `idle`, or `reconnecting`
   while `speaking`); a product state space would be large and the transitions
   unreadable. **Rejected** in favor of two cooperating reducers.
3. **OO state-object pattern (a `State` protocol with subclasses).** Idiomatic Swift,
   but spreads logic across types and is harder to table-test than a pure `reduce`.
   **Rejected**; the reducer keeps the whole transition table in one greppable, testable place.
4. **Keep PTT-only (no tap/de-bracketing).** Less code, but loses iOS parity and barge-in
   and keeps the tap-flicker. **Rejected**; the gesture recognizer is small and isolates
   the complexity.
5. **CoreBluetooth state preservation/restoration for reconnect.** The iOS-background
   answer; on a foreground macOS app it adds delegate complexity for little gain vs.
   persisting the identifier ourselves. **Rejected on macOS** (per the Opus consult).
6. **Timing-only gesture recognizer** (drive tap/double/hold purely off down/up timing,
   ignore the hardware `02`/`03`/`04` codes). *Pro:* robust if a firmware ever omits the
   codes. *Con:* tap must wait a double-tap window (~300 ms) before it can be confirmed,
   adding latency to every tap, and the logic is heavier. **Rejected for now** — the
   codes are authoritative and reliably observed (firmware 2.6.4); kept as the documented
   fallback (Risk 8) if a code-omitting firmware appears.

**Trade-off of the chosen approach:** two pure reducers + executors is more upfront
structure than scattered guards, and the gesture recognizer adds ~`holdThreshold`
(300 ms) of PTT-start latency. In return every edge is explicit, testable, and
strand-proof, and the connection/interaction concerns stay decoupled.

## 6. Risks & Mitigations
1. **Reducer/executor drift** (an effect emitted but not handled, or applied twice).
   *Detect:* effects are an `enum`, so the executor `switch` is exhaustive at compile
   time; unit tests assert emitted effects; the executor logs unknown/no-op effects.
2. **`holdThreshold` mis-tuned** (PTT feels laggy, or fast holds misread as taps).
   *Mitigate:* single tunable constant; validated against the captured gesture timings;
   acceptance #4 covers both directions.
3. **Await-timeout races a late response** (timeout fires, then the response speaks).
   *Mitigate:* `idle —[ttsStarted]→ speaking` handles the late case; the prompt is never
   cancelled, so the response still lands in the session.
4. **Identifier reconnect stale-id hang** (the consult's critical hole). *Mitigate:*
   `connectKnown` runs under its own `connectWatchdog`, never cancelled by the
   advertised-connect path; watchdog → `cancelConnection` + `clearSavedIdentifier` +
   scan. Acceptance #5.
5. **AirPods regression from keep-alive changes.** *Mitigate:* `suspendKeepAlive` is
   gated to `source == .blueParrottBLE`; acceptance #7; integration test asserts the
   gate.
6. **Test-host crashes from real hardware in unit tests** (findings F7). *Mitigate:*
   reducers/recognizer are pure; executors guard real CB/audio behind
   `TestingEnvironment.isUnitTesting`; timers use injected `scheduleWork`; CI uses
   `make test-mac-unit`.
7. **Capture-restart loop** (F3 retry itself stalls). *Mitigate:* restart is one-shot
   per recording; a second stall logs and finalizes to `idle` rather than looping.
8. **Gesture recognizer depends on the hardware tap/double codes (`02`/`03`)** for
   discrete classification (hold/PTT is code-independent). *Detect:* the parser already
   logs unrecognized payloads; a firmware that omits the codes would show quick
   down/up with no following code and dropped taps. *Mitigate:* the timing-only
   recognizer (§5 alt 6) is the drop-in fallback; validated on firmware 2.6.4 today.
9. **Barge-in cancels a still-in-flight prompt's UX** (a hold during `awaitingResponse`
   starts a new turn while the prior prompt is still processing). *Mitigate:* the prior
   prompt is **not** cancelled server-side; its response, if it arrives during the new
   recording, is suppressed by the existing recording gate and can be reviewed in the
   transcript. Documented behavior, not a silent drop.
10. **`captureEnded` and `holdEnded` both firing for one recording** (an `up` calls
    `stopCapture`, which flips `voiceInput.isRecording → false`, which the executor would
    feed back as `captureEnded`). *Mitigate:* the first event moves the machine to
    `.finalizing`; `(.finalizing, .captureEnded)` hits the reducer `default` and is a
    no-op, so there is no double-finalize. The state guard, not executor bookkeeping,
    makes this safe.

### Rollback strategy
The overhaul is macOS-gated (`settings.blueParrottEnabled`) and replaces internal logic
only. Rollback = revert the reducer wiring and restore the previous
`HeadsetState`/`BlueParrottPTTArbitrator` path; the BLE transport and the persisted
identifier key are inert if unused. Single-commit revert; no data migration, no backend
or protocol involvement. The identifier key can be left in `UserDefaults` harmlessly or
cleared.

## Implementation Notes

| File | Change |
|------|--------|
| `ios/VoiceCode/Managers/HeadsetSessionReducer.swift` (new) | `SessionState`/`SessionEvent`/`SessionEffect` + pure `SessionReducer.reduce` |
| `ios/VoiceCode/Managers/BLEConnReducer.swift` (new) | `BLEConnState`/`BLEConnEvent`/`BLEConnEffect` + pure `ConnReducer.reduce` |
| `ios/VoiceCode/Managers/BlueParrottGestureRecognizer.swift` (new) | raw→semantic de-bracketer (scheduler-injected; reads no wall-clock) |
| `ios/VoiceCode/Managers/HeadsetRemoteCommandManager.swift` | own the session reducer + effect executor; retire the implicit `HeadsetState` guards |
| `ios/VoiceCode/Managers/BlueParrottBLEManager.swift` | own the conn reducer + executor; add `connectKnown`/identifier persistence/watchdogs to the `BLECentral` seam |
| `ios/VoiceCode/Managers/AppSettings.swift` | `blueParrottPeripheralID` persistence helper |
| `ios/VoiceCodeTests/HeadsetSessionReducerTests.swift`, `BLEConnReducerTests.swift`, `BlueParrottGestureRecognizerTests.swift` (new) | reducer/recognizer table tests. These cover **pure, cross-platform** types (only `CBManagerState` is referenced, available on iOS too), so they run in **both** the iOS `VoiceCodeTests` and macOS `VoiceCodeMacTests` targets (per §4 — `make test` *and* `make test-mac-unit`). Only the macOS *manager/executor integration* tests are macOS-only (excluded from the iOS target like `BlueParrottBLEManagerTests`). |

### Build verification
```bash
make test-mac-unit   # macOS unit bundle only (clean signal; excludes flaky UI tests)
make test            # iOS — no regression
make build-mac       # scheme VoiceCodeMac
```
