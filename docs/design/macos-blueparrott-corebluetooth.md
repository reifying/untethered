# macOS BlueParrott Button via CoreBluetooth

> **Language note:** This feature is entirely client-side Swift (iOS/macOS app
> under `ios/`). There are **no backend or Clojure components** and **no
> WebSocket protocol changes** — the backend already receives transcribed text
> regardless of what triggers recording (see @docs/blueparrott-headset-integration.md
> §Backend). All code examples below are therefore Swift, matching the codebase.

## 1. Overview

### Problem Statement

The BlueParrott multifunction button does **not** drive the microphone on the
macOS app — pressing it produces no recording start/stop. The macOS build never
talks to the button at all: it *infers* a press from the Bluetooth input
device's mute property (`BluetoothAudioMonitor`, CoreAudio
`kAudioDevicePropertyMute`). That listener only fires if the button is
configured to toggle HFP mute **and** macOS surfaces that toggle as a device
mute change — neither holds reliably, so the callback never fires and the app
appears dead to the button.

iOS works for a different reason: it links the BlueParrott `BPHeadset` SDK, a
CoreBluetooth client that talks to a proprietary BLE GATT service in "App/SDK
mode" to receive real button events (down/up/tap/double-tap/long-press). The SDK
xcframework ships **iOS-only** slices (`ios-arm64`,
`ios-arm64_x86_64-simulator`); there is no macOS slice, so the SDK cannot be
linked on macOS.

CoreBluetooth is fully available on macOS with the same API as iOS, and the
button events are BLE GATT notifications. The faithful fix is to reimplement the
relevant subset of the SDK directly on CoreBluetooth for macOS. The blocker is
that the GATT-level protocol (characteristic UUIDs, the App-Mode enable
handshake, the button-event byte format) is **not** in the public SDK header —
it lives inside the compiled binary. This doc covers (1) a DEBUG collector that
captures that protocol by instrumenting the working iOS SDK, and (2) the macOS
CoreBluetooth client that consumes it.

### Goals

1. Detect real BlueParrott button events on macOS (down, up, tap, double-tap,
   long-press) and drive the existing recording state machine — parity with iOS.
2. Build a DEBUG-only collector that captures the proprietary GATT protocol
   (characteristic UUIDs, App-Mode enable write, button-event byte format).
3. Determine whether App/SDK mode is **persisted on the headset hardware** — if
   so, the macOS client may only need to connect + subscribe, no handshake.
4. Reuse the existing `BlueParrottButtonDelegate` surface and
   `HeadsetRemoteCommandManager` state machine so macOS and iOS converge.
5. Retire `BluetoothAudioMonitor` as the macOS button trigger once parity holds.

### Non-goals

- Reverse-engineering enterprise config, speed-dial, proximity, or
  firmware-update characteristics — only button events + App Mode.
- Changing the iOS implementation (it keeps using `BPHeadset` unchanged).
- Shipping the collector in release builds (it is `#if DEBUG` only).
- macOS audio routing / now-playing / TTS changes (see
  @docs/blueparrott-headset-integration.md).
- Android. Backend. WebSocket protocol.

## 2. Background & Context

### Current State

**iOS (works).** `ios/VoiceCode/Managers/BlueParrottButtonManager.swift`
(entirely `#if os(iOS)`) drives the `BPHeadset` SDK:
- `configureSDK()` sets `customerUUID = 4bcf295c-…`, `autoReconnect = true`,
  `remoteLogging = false` (lines 118–122).
- On `onValuesRead`, if `!sdkModeEnabled`, calls `enableSDKMode("Untethered")`
  (lines 307–310) — the proprietary handshake we need to capture.
- `BPHeadsetListener` callbacks (`onButtonDown/Up/Tap/DoubleTap/LongPress`,
  lines 347–380) forward to the platform-agnostic `BlueParrottButtonDelegate`
  (lines 18–24).
- A connect/retry/re-arm state machine (fast retries → infinite 30s slow retry,
  foreground re-arm) is already unit-tested via an injected
  `BlueParrottHeadsetControlling` protocol (lines 30–43).

**macOS (broken).** `ios/VoiceCode/Managers/BluetoothAudioMonitor.swift`
(`#if os(macOS)`) watches `kAudioDevicePropertyMute` on the Bluetooth input
device, wired into the state machine at
`HeadsetRemoteCommandManager.swift:675–678` (`startMonitoring { isMuted in … }`),
mapping unmute→`buttonDown`, mute→`buttonUp`. It does not fire for the
BlueParrott button in practice.

**Shared downstream.** `HeadsetRemoteCommandManager.swift:626–665` maps button
events onto the `HeadsetState` machine (`ready`/`recording`/`sending`/`speaking`)
identically regardless of source. A macOS CoreBluetooth client only has to emit
the same `BlueParrottButtonDelegate` calls.

### What the SDK header reveals (and doesn't)

`ios/Frameworks/BPHeadset.xcframework/.../Headers/BPHeadsetNative.h`:
- Exposes exactly one UUID — the **service** UUID
  `kBP_PARROTTBUTTON_SERVICE_UUID_STRING = 95665a00-8704-11e5-960c-0002a5d5c51b`
  (line 9).
- Exposes the high-level contract only: the `BPHeadsetListener` callbacks (lines
  247–282) and `enableSDKMode` / `setAppModeWithAppKey:appName:` (lines 499–538).
  Default mode is `BPButtonModeMute` (line 23) — until App Mode is set, the
  button mutes the call and emits nothing on the control channel.

**Not exposed (the reverse-engineering gap):** characteristic UUIDs within the
service, the byte payload `enableSDKMode` writes, and the notification byte
format per gesture. All compiled into the binary — captured in Phase A.

### Why Now

The macOS app is the corporate-permitted client (per
@docs/blueparrott-headset-integration.md); the button is its most ergonomic
trigger; and the current mute-proxy approach is structurally unable to see the
button, so it must be replaced rather than patched.

### Related Work

- @docs/blueparrott-headset-integration.md — original recommendation doc; this
  doc supersedes its "P2: CoreAudio PTT Mute Detection" approach for macOS.
- @docs/design/headset-remote-control.md — shared headset state machine.
- @docs/design/ios-headset-remote-control.md — the iOS path this mirrors.
- @docs/design/mic-mute-on-record.md — mic/mute interaction.

## 3. Detailed Design

Two phases. **Phase A (the collector) is the unblocking step** — everything in
Phase B depends on the bytes it captures.

### Data Model

No persisted/DB schema. The data structures are the in-memory decoded event and
the GATT constant table.

```swift
/// Logical button gesture, decoded from a raw GATT notification.
/// Mirrors the events iOS's `BPHeadsetListener` delivers, so both platforms
/// converge on one `BlueParrottButtonDelegate`.
enum BlueParrottButtonEvent: Equatable {
    case down
    case up
    case tap
    case doubleTap
    case longPress
}
```

```swift
/// GATT identifiers for the BlueParrott control service.
///
/// `service` is the one value the public header exposes (`BPHeadsetNative.h:9`).
/// The characteristic UUIDs are NOT in the header; the constants here are
/// frozen from the Phase A capture on target firmware. The values shown are
/// illustrative of the expected `95665aXX-…` family and are replaced verbatim
/// with the captured UUIDs before Phase B lands.
enum BPGatt {
    static let service = CBUUID(string: "95665a00-8704-11e5-960c-0002a5d5c51b")
    /// Notifies on button gestures (subscribe → receive event payloads).
    /// Captured in Phase A2 (firmware 2.6.4).
    static let buttonEvent = CBUUID(string: "66339E60-D55A-11E5-B7CB-0002A5D5C51B")
    /// App/SDK mode (read/write). Holds "sdk" when App Mode is active; only
    /// written if mode is NOT already set (it persists — see §3 experiment).
    static let mode = CBUUID(string: "D24B6EC0-D55A-11E5-8476-0002A5D5C51B")
    /// App-mode owner name (read/write); the iOS SDK sets it to "Untethered".
    static let appName = CBUUID(string: "C3356EE0-D55A-11E5-8C19-0002A5D5C51B")
    /// Fallback enable (only for a never-enabled headset): write "sdk" to `mode`.
    static let appModeEnablePayload = Data("sdk".utf8)
}
```

**"Schema" change (before/after) — the macOS trigger source:**

| | Before | After |
|---|---|---|
| Button source | `BluetoothAudioMonitor` (CoreAudio mute proxy) | `BlueParrottBLEManager` (CoreBluetooth GATT) |
| Signal | `kAudioDevicePropertyMute` bool | parsed `BlueParrottButtonEvent` |
| Gestures seen | mute toggle only (unreliable) | down/up/tap/double/long |
| Downstream | `BlueParrottButtonDelegate` | `BlueParrottButtonDelegate` (unchanged) |

**Migration strategy:** additive and reversible. `BlueParrottBLEManager` is
introduced behind the same `settings.blueParrottEnabled` toggle that already
gates the iOS path. `BluetoothAudioMonitor` stays compiled until parity is
confirmed by hardware testing, then is removed as the *button* trigger (it may
remain for a separate mic-mute feature if still desired). No data migration.

### API Design

There are **no network endpoints** and **no breaking protocol/deprecation
concerns** — the "API" here is the in-process Swift surface and the BLE "wire"
interface.

**Public Swift surface (macOS), mirroring the iOS manager** (signature sketch —
method bodies elided; this block illustrates the API, not a compilable unit):

```swift
#if os(macOS)
final class BlueParrottBLEManager: NSObject, ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var isSDKModeEnabled = false
    @Published private(set) var headsetName: String?

    weak var delegate: BlueParrottButtonDelegate?

    /// Set from the Phase A persistence experiment: if the headset retains App
    /// Mode across reconnects, the client skips the enable write entirely.
    var appModePersistent = true

    static let maxRetries = 5    // mirrors BlueParrottButtonManager.maxRetries

    /// The CoreBluetooth seam this manager drives (stored from init). The
    /// adapter delivers `BLECentralEvents` callbacks on the **main queue** (as
    /// `BluetoothAudioMonitor` already does, HeadsetRemoteCommandManager.swift:676),
    /// so `@Published` mutations in those callbacks are main-thread-safe.
    private let central: BLECentral?

    /// `central` is injectable so the connect/retry/re-arm machine is testable
    /// without real hardware (CoreBluetooth is unavailable in test runs). The
    /// default builds a real `CBCentralManager`-backed adapter.
    init(central: BLECentral? = nil,
         scheduleWork: @escaping (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         }) { /* … wires central.centralDelegate = self … */ }

    func start() { /* begin scan/connect; idempotent */ }
    func stop() { /* disconnect, cancel retries, drop App Mode if we set it */ }
    func reconnect() { /* re-arm fast retry cycle */ }
}

// DEBUG-only test hooks (e.g. `testInSlowRetry`) mirror the iOS manager,
// exposed via an `#if DEBUG` extension as in BlueParrottButtonManager.swift:396–419.
#endif
```

**Delegate contract (existing, platform-agnostic — reused verbatim):**

```swift
protocol BlueParrottButtonDelegate: AnyObject {
    func blueParrottButtonDown()
    func blueParrottButtonUp()
    func blueParrottTap()
    func blueParrottDoubleTap()
    func blueParrottLongPress()
}
```

**Test seam over CoreBluetooth** (mirrors iOS's `BlueParrottHeadsetControlling`,
`BlueParrottButtonManager.swift:30–43`):

```swift
/// The slice of CoreBluetooth the manager drives. Abstracted so connect/retry
/// logic is unit-testable without `CBCentralManager`.
protocol BLECentral: AnyObject {
    var managerState: CBManagerState { get }
    var centralDelegate: BLECentralEvents? { get set }
    func scanForButtonService()
    func stopScan()
    func connect()
    func cancelConnection()
    func subscribeToButtonEvents()
    func writeAppModeEnable(_ payload: Data)   // no-op if App Mode persists
}

/// Callbacks the manager reacts to (connect result, value updates).
protocol BLECentralEvents: AnyObject {
    func bleDidConnect()
    func bleDidFailToConnect(_ retryable: Bool)
    func bleDidDisconnect()
    func bleDidUpdateButtonValue(_ data: Data)
}
```

**Error cases** (no HTTP status codes — these are the BLE failure modes the
manager handles):

| Condition | Source | Handling |
|---|---|---|
| Bluetooth powered off / resetting | `CBManagerState` | wait for `.poweredOn`, then scan (retryable) |
| Unauthorized | `CBManagerState.unauthorized` | log, surface to UI, do not retry |
| Connect failed (transient) | `didFailToConnect` | fast retry ×N → infinite 30s slow retry |
| Unrecognized notification bytes | parser returns `nil` | log hex under "BlueParrottBLE", drop (never misclassify) |
| Disconnect (out of range) | `didDisconnectPeripheral` | reset to `ready`, re-arm retry |

### Code Examples

**Phase A1 — passive observer (DEBUG, iOS): swizzle CoreBluetooth to log the
SDK's own GATT traffic.** This captures the App-Mode handshake and event bytes
while the working SDK runs.

```swift
#if DEBUG && os(iOS)
import CoreBluetooth
import ObjectiveC.runtime

/// Logs every characteristic write and value-update the BPHeadset SDK performs.
/// Output goes to LogManager (category "BPSniff") so it lands in the in-app
/// Captured Logs the user already shares. Diagnostic only — never shipped.
enum BPSniffer {
    static func install() {
        swizzle(
            cls: CBPeripheral.self,
            original: #selector(CBPeripheral.writeValue(_:for:type:)),
            swizzled: #selector(CBPeripheral.bp_writeValue(_:for:type:))
        )
        // The notify-side delegate is the SDK's private class, discovered at
        // runtime via `peripheral.delegate` and swizzled the same way.
    }

    static func swizzle(cls: AnyClass, original: Selector, swizzled: Selector) {
        guard let orig = class_getInstanceMethod(cls, original),
              let new = class_getInstanceMethod(cls, swizzled) else { return }
        method_exchangeImplementations(orig, new)
    }
}

extension CBPeripheral {
    @objc func bp_writeValue(_ data: Data, for ch: CBCharacteristic, type: CBCharacteristicWriteType) {
        LogManager.shared.log("WRITE \(ch.uuid) ← \(data.bpHex)", category: "BPSniff")
        bp_writeValue(data, for: ch, type: type) // calls original after swap
    }
}

extension Data {
    var bpHex: String { map { String(format: "%02x", $0) }.joined(separator: " ") }
}
#endif
```

**Phase B — happy path: discover, subscribe, parse, dispatch.**

```swift
#if os(macOS)
// `BLECentralEvents` callbacks are delivered on the main queue by the adapter
// (see the `central` doc-comment above), so mutating `@Published` state here is
// main-thread-safe — matching how the iOS manager marshals to main.
extension BlueParrottBLEManager: BLECentralEvents {
    func bleDidConnect() {
        isConnected = true
        central?.subscribeToButtonEvents()
        if !appModePersistent {            // decided by the Phase A experiment
            central?.writeAppModeEnable(BPGatt.appModeEnablePayload)
        }
    }

    func bleDidUpdateButtonValue(_ data: Data) {
        guard let event = BlueParrottEventParser.parse(data) else {
            // Edge case: unknown payload — log, never guess.
            LogManager.shared.log("unknown button payload \(data.bpHex)", category: "BlueParrottBLE")
            return
        }
        dispatch(event)
    }

    private func dispatch(_ event: BlueParrottButtonEvent) {
        DispatchQueue.main.async { [weak self] in
            guard let delegate = self?.delegate else { return }
            switch event {
            case .down:      delegate.blueParrottButtonDown()
            case .up:        delegate.blueParrottButtonUp()
            case .tap:       delegate.blueParrottTap()
            case .doubleTap: delegate.blueParrottDoubleTap()
            case .longPress: delegate.blueParrottLongPress()
            }
        }
    }
}
#endif
```

**The byte parser (pure, the unit-testable core).** The opcode constants are the
values captured in Phase A; the example mapping below shows the intended
table-driven shape.

```swift
enum BlueParrottEventParser {
    /// Decode a raw notification payload from `BPGatt.buttonEvent`.
    /// Returns nil for unrecognized payloads — callers log and drop.
    static func parse(_ data: Data) -> BlueParrottButtonEvent? {
        guard let opcode = data.first else { return nil } // edge: empty payload
        // Opcodes captured in Phase A2 on firmware 2.6.4 (char 66339E60-…).
        switch opcode {
        case 0x01: return .down
        case 0x00: return .up
        case 0x02: return .tap
        case 0x03: return .doubleTap
        case 0x04: return .longPress
        default:   return nil                              // edge: unknown opcode
        }
    }
}
```

**Error-handling path: Bluetooth not ready / unauthorized.**

```swift
#if os(macOS)
extension BlueParrottBLEManager {
    func handleManagerState(_ state: CBManagerState) {
        switch state {
        case .poweredOn:     central?.scanForButtonService()
        case .poweredOff, .resetting:
            isConnected = false
            LogManager.shared.log("BLE not ready (\(state.rawValue)); awaiting power-on", category: "BlueParrottBLE")
        case .unauthorized:
            LogManager.shared.log("⚠️ BLE unauthorized — check entitlement & permission", category: "BlueParrottBLE")
        case .unsupported:
            LogManager.shared.log("❌ BLE unsupported on this Mac", category: "BlueParrottBLE")
        default:
            break
        }
    }
}
#endif
```

### Component Interactions

```
 Phase A (iOS, DEBUG)                         Phase B (macOS)
 ───────────────────────                      ──────────────────────────
 BPHeadset SDK (works)                        BlueParrottBLEManager
   │ enableSDKMode("Untethered")                │ CBCentralManager scan/connect
   ▼                                            ▼ discover svc 95665a00-…
 [swizzle CBPeripheral.writeValue]            [write enable payload? — only if
   → App-Mode enable: char + bytes              App Mode is NOT persistent]
 [swizzle delegate didUpdateValue]              │ subscribe to BPGatt.buttonEvent
   → per-gesture: char + bytes                  ▼
   │                                          BlueParrottEventParser.parse(bytes)
   ▼ LogManager "BPSniff"                       │ → BlueParrottButtonEvent
 captured protocol  ───────────────────────▶   ▼ BlueParrottButtonDelegate
                                              HeadsetRemoteCommandManager
                                                (state mapping :626–665 unchanged)
```

**Integration points:**
- Upstream: `CBCentralManager` (system).
- Downstream: `BlueParrottButtonDelegate` →
  `HeadsetRemoteCommandManager.swift:626–665` → `HeadsetState` machine →
  recording / send / TTS-interrupt. **Unchanged.**
- Gating: `settings.blueParrottEnabled` (same toggle as iOS;
  `HeadsetRemoteCommandManager.swift:146–157`).

**Key experiment — does App Mode persist on the headset?**
`setAppModeWithAppKey:appName:` exists so an app can detect when *another* app
owns the button, implying the headset persists mode/owner. **Test first:** enable
App Mode once via the iOS SDK, power-cycle/reconnect, and check (via the Phase A2
explorer from macOS) whether button notifications still flow with no re-handshake.
- **Persistent** → macOS client = connect + subscribe + parse (no `writeAppModeEnable`).
- **Not persistent** → replay the captured enable payload; own App-Mode
  arbitration (see Risks #2).

**Experiment procedure (manual, hardware required).** The A2 harness is
`BPGattExplorer` (`BPGattExplorer.swift`, `#if DEBUG`, cross-platform). In a DEBUG
macOS build it auto-starts from `HeadsetRemoteCommandManager.activate()` and logs
to `LogManager` category "BPExplore".

1. On the **iOS** app (DEBUG), enable BlueParrott so the `BPHeadset` SDK runs
   `enableSDKMode("Untethered")` once — this puts the headset in App Mode. Confirm
   button events arrive on iOS.
2. Quit the iOS app and **power-cycle** the headset (or just let it reconnect to
   the Mac), so no app is actively setting App Mode.
3. Launch the **macOS** DEBUG build and enable headset mode. `BPGattExplorer`
   connects to service `95665a00-…`, logs the discovered characteristics with
   their properties, and subscribes to every notifier — **without** writing any
   App-Mode enable payload.
4. Press the headset button and watch the "BPExplore" logs:
   - If `NOTIFY …` lines appear for button gestures with **no** prior write →
     App Mode **persists** on the hardware.
   - If no notifications arrive until App Mode is re-enabled → **not persistent**.

**Decision: PERSISTENT** (observed 2026-06-02; see `…-b4i.3`). The Mac connected
fresh and the A2 explorer only subscribed/read — it never wrote an enable
payload — yet the headset reported mode `"sdk"` + owner `"Untethered"` and
streamed button events. So App Mode survives the phone→Mac handoff on the
hardware. **Phase B macOS client = connect + subscribe + parse; set
`BlueParrottBLEManager.appModePersistent = true` and skip the enable write in the
normal path.** Keep the conditional `writeAppModeEnable` only as a fallback for a
never-enabled / factory-reset headset (write `"sdk"` to the mode characteristic +
the app name) — see the captured constants below.

**Phase A2 capture results (target firmware 2.6.4).** Frozen from the on-hardware
log; these replace the illustrative placeholders elsewhere in this doc.

| Characteristic UUID | Props | Meaning | Observed value |
|---|---|---|---|
| `66339E60-D55A-11E5-B7CB-0002A5D5C51B` | read,notify | **button events** | `01`=down, `00`=up, `02`=tap, `03`=double-tap, `04`=long-press (fires ~1s after down) |
| `D24B6EC0-D55A-11E5-8476-0002A5D5C51B` | read,write | **mode** | `"sdk"` (`73 64 6b`) — write to enable App Mode |
| `C3356EE0-D55A-11E5-8C19-0002A5D5C51B` | read,write | **app-mode owner name** | `"Untethered"` |
| `F3F8A600-D55A-11E5-89FD-0002A5D5C51B` | read | firmware version | `"2.6.4"` |
| `E068B6C0-D55A-11E5-B756-0002A5D5C51B` | read | (device id?) | `"0025"` |
| `4A2B5193-640D-4398-8D4A-491EB95DC51B` | read | (version?) | `"1.08"` |

Notes for Phase B: (1) **down/up bracket every gesture** — a tap emits `01,00,02`,
a double emits `01,00,01,00,03`, and a hold emits `01,04,00` (long-press fires
~1s after down). So the dispatcher must drive behavior off **either** down/up
(PTT) **or** the gesture codes (tap/double/long), never both, or it will
double-drive the state machine (e.g. a PTT hold would also fire long-press →
interrupt mid-recording). (2) `setNotifyValue` on these characteristics logged
"attribute could not be found" when issued as a burst, yet `66339E60` still
notified; subscribe to just the button characteristic and verify `isNotifying`
(discover the CCCD if the error recurs).

## 4. Verification Strategy

### Testing Approach

- **Unit (primary): byte parser.** `BlueParrottEventParser.parse` is pure —
  table-test every captured gesture sequence and the empty/unknown cases.
- **Unit: connect/retry/re-arm state machine.** Inject a fake `BLECentral` (as
  iOS injects `BlueParrottHeadsetControlling`) and drive
  connect/fail/disconnect/foreground transitions with a synchronous
  `scheduleWork`, asserting retry counts and slow-retry fallback.
- **Unit: delegate fan-out.** Each parsed event invokes the matching
  `BlueParrottButtonDelegate` method exactly once, on the main queue.
- **Integration:** existing `HeadsetRemoteCommandManagerTests` must still pass —
  the macOS source change feeds the same delegate, so state-machine tests
  (`:626–665` behavior) are unchanged. Add a macOS case asserting a
  `BlueParrottBLEManager`-sourced `down`/`up` produces record → stop+send.
- **End-to-end (manual, hardware required):** full PTT loop on macOS — press to
  record, release to send, hear TTS — plus tap/double/long-press and
  out-of-range reconnect.

The Phase A collector is exploratory; its swizzle plumbing is not unit-tested,
but the **format it discovers is frozen into the parser tests** below.

**Test target placement (important).** The new tests are macOS-only and live in
the shared `VoiceCodeTests/` source dir, which is compiled into *both* unit-test
targets. Guard the file with `#if os(macOS)` **and** add it to the **iOS**
`VoiceCodeTests` target's `excludes` in `project.yml` — the exact pattern
`BluetoothAudioMonitorTests.swift` already follows (`VoiceCodeTests` → `excludes`).
The tests then run under the `VoiceCodeMac` scheme via `make test-mac`, **not**
`make test`. (The existing `BlueParrottButtonManagerTests` is *not* the precedent
here — it is iOS-only and is itself listed in the macOS `VoiceCodeMacTests`
`excludes`; the right precedent is `BluetoothAudioMonitorTests.swift`.)

### Test Examples

```swift
final class BlueParrottEventParserTests: XCTestCase {
    func testDecodesEachGesture() {  // captured opcodes, firmware 2.6.4
        XCTAssertEqual(BlueParrottEventParser.parse(Data([0x01])), .down)
        XCTAssertEqual(BlueParrottEventParser.parse(Data([0x00])), .up)
        XCTAssertEqual(BlueParrottEventParser.parse(Data([0x02])), .tap)
        XCTAssertEqual(BlueParrottEventParser.parse(Data([0x03])), .doubleTap)
        XCTAssertEqual(BlueParrottEventParser.parse(Data([0x04])), .longPress)
    }

    func testEmptyPayloadReturnsNil() {
        XCTAssertNil(BlueParrottEventParser.parse(Data()))
    }

    func testUnknownOpcodeReturnsNil() {
        XCTAssertNil(BlueParrottEventParser.parse(Data([0xFF])))
    }
}

final class BlueParrottBLEManagerTests: XCTestCase {
    func testTransientFailureRetriesThenSlowRetry() {
        let central = FakeBLECentral()
        var scheduled: [DispatchWorkItem] = []
        let manager = BlueParrottBLEManager(central: central) { _, work in scheduled.append(work) }
        manager.start()

        for _ in 0..<BlueParrottBLEManager.maxRetries {
            central.centralDelegate?.bleDidFailToConnect(true)
            scheduled.removeLast().perform()
        }
        // Fast retries exhausted → switched to infinite slow retry, not given up.
        XCTAssertTrue(manager.testInSlowRetry)
    }

    func testButtonDownDispatchesToDelegate() {
        let central = FakeBLECentral()
        let spy = DelegateSpy()
        let manager = BlueParrottBLEManager(central: central) { _, w in w.perform() }
        manager.delegate = spy
        manager.start()
        central.centralDelegate?.bleDidConnect()
        central.centralDelegate?.bleDidUpdateButtonValue(Data([0x01])) // down

        let exp = expectation(description: "delegate")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(spy.calls, [.down])
    }
}
```

`FakeBLECentral` (a `BLECentral` test double whose `centralDelegate` the manager
wires in `start()`), `DelegateSpy` (records `BlueParrottButtonDelegate` calls),
and the `maxRetries` / `testInSlowRetry` members are the macOS analogues of the
helpers in `BlueParrottButtonManagerTests` / `BlueParrottButtonManager.swift` and
are built alongside this suite.

### Acceptance Criteria

1. macOS button **down** starts recording and **up** stops+sends, matching iOS
   PTT behavior.
2. macOS **tap / double-tap / long-press** map to the same actions as iOS
   (`HeadsetRemoteCommandManager.swift:626–665`).
3. `BlueParrottEventParser` unit tests pass against the **captured real-device**
   byte sequences for all five gestures, and return `nil` for empty/unknown
   payloads.
4. Connect/retry/re-arm unit tests pass with a faked `BLECentral` (no hardware).
5. Out-of-range disconnect returns the state machine to `ready` and reconnects
   automatically when the headset returns.
6. `make build-mac` (scheme `VoiceCodeMac`) succeeds with
   `com.apple.security.device.bluetooth` added; `make build` (iOS) is unchanged.
7. The Phase A collector (`BPSniffer`) is absent from release builds
   (`#if DEBUG` verified by a release-config build).
8. `make test-mac` passes (runs the new macOS `VoiceCodeMacTests`) **and**
   `make test` still passes (iOS suite — no regression). No single target spans
   both platforms, so both must be run.

## 5. Alternatives Considered

1. **Apple PacketLogger HCI capture** (instead of in-app swizzling for Phase A).
   Captures the same writes/notifications with zero app code while the SDK runs.
   *Pro:* no swizzling. *Con:* external tool, not reproducible from shared
   in-app logs. **Decision:** keep as a fallback/cross-check; prefer the in-app
   collector the user asked for.
2. **Ask GN/Jabra for a macOS SDK build or GATT spec** (via the
   developer.jabra.com account tied to `customerUUID`). *Pro:* could remove the
   reverse-engineering entirely. *Con:* vendor dependency/latency.
   **Decision:** pursue in parallel; cheap and may obviate Phase A.
3. **Keep the CoreAudio mute proxy, fix configuration.** **Decision:** rejected —
   it is the current broken approach; cannot see non-mute gestures and is
   unreliable even for mute.
4. **IOKit HID / `MPRemoteCommandCenter` media key.** *Con:* HID needs
   `com.apple.security.device.usb` (not granted to sandboxed App Store apps);
   media-key gives at most play/pause, not five gestures. **Decision:** rejected
   as primary; `MPRemoteCommandCenter` remains a possible *additional* trigger
   (see @docs/blueparrott-headset-integration.md Mac P0).

**Trade-off of the chosen approach:** reimplementing on CoreBluetooth gives full
gesture fidelity and reuses the entire downstream path, but front-loads a
reverse-engineering step. Phase A converts that risk into a one-time capture
against the working SDK, and the App-Mode persistence experiment may shrink
Phase B to connect+subscribe+parse.

## 6. Risks & Mitigations

1. **Protocol may be more than a byte map** (encryption, sequence numbers, auth
   tied to `customerUUID`). *Detect:* Phase A observes the SDK end-to-end. *Plan:*
   if non-trivially stateful, escalate to alternative #2.
2. **App-Mode arbitration conflict.** If iOS and macOS apps both set App Mode
   with different keys/names they may fight for ownership. *Mitigate:* the
   persistence experiment + reuse the iOS app name (`"Untethered"`); document
   single-active-client behavior.
3. **Dual-mode coexistence.** Confirm the headset advertises the BLE control
   service while also connected for HFP audio (it does on iOS). *Detect:* verify
   early with the Phase A2 explorer from macOS.
4. **Sandbox entitlement / App Store review.** `com.apple.security.device.bluetooth`
   is grantable for sandboxed apps; confirm no extra justification. *Detect:*
   `.unauthorized` state in `handleManagerState`.
5. **Swizzling fragility (Phase A).** A private SDK delegate class is
   runtime-discovered and could break on SDK updates. *Mitigate:* DEBUG-only,
   one-time capture; PacketLogger fallback (#1).
6. **Firmware variation.** Byte format could differ across B450-XT firmware.
   *Mitigate:* capture on target firmware; parser logs unknown payloads rather
   than misclassifying (criterion #3).

### Rollback Strategy

The change is gated by `settings.blueParrottEnabled` and is macOS-only.
`BluetoothAudioMonitor` remains compiled until parity is confirmed, so rollback
is: re-point `HeadsetRemoteCommandManager` (macOS) back to
`BluetoothAudioMonitor.startMonitoring`, drop the `BlueParrottBLEManager` wiring,
and remove the Bluetooth entitlement. No data migration, no backend or protocol
involvement, single-commit revert. The `BPSniffer` is DEBUG-only and never ships,
so it carries no release-rollback risk.

## Implementation Notes

### Files

| File | Change |
|------|--------|
| `ios/VoiceCode/Managers/BPSniffer.swift` (new, `#if DEBUG && os(iOS)`) | CoreBluetooth swizzle collector (A1); logs via `LogManager` "BPSniff" |
| `ios/VoiceCode/Managers/BPGattExplorer.swift` (new, `#if DEBUG`, **cross-platform**) | Standalone `CBCentralManager` GATT explorer (A2): scans svc `95665a00-…`, enumerates services/characteristics + properties, subscribes to all notifiers, logs notification hex via `LogManager` "BPExplore". Compiled into **both** the iOS and macOS targets so the persistence experiment can be observed from macOS; launched in DEBUG macOS builds from `HeadsetRemoteCommandManager.activate()`/`deactivate()` |
| `ios/VoiceCode/Managers/BlueParrottBLEManager.swift` (new, `#if os(macOS)`) | CoreBluetooth client, byte parser, connect/retry/re-arm, emits `BlueParrottButtonDelegate` |
| `ios/VoiceCode/Managers/HeadsetRemoteCommandManager.swift` | macOS: drive `BlueParrottBLEManager` instead of `BluetoothAudioMonitor` (mapping `:626–665` unchanged) |
| `ios/VoiceCode/Managers/BluetoothAudioMonitor.swift` | Retire as button trigger once parity proven |
| `ios/VoiceCodeMac/VoiceCodeMac.entitlements` | Add `com.apple.security.device.bluetooth` |
| `ios/project.yml` | macOS `NSBluetoothAlwaysUsageDescription`; **add `BlueParrottBLEManagerTests.swift` to the iOS `VoiceCodeTests` target's `excludes`** (macOS-only test, mirrors `BluetoothAudioMonitorTests.swift`) |
| `ios/VoiceCodeTests/BPGattExplorerTests.swift` (new, `#if DEBUG`, **cross-platform**) | Unit tests for the A2 explorer's pure helpers (hex, property description, subscribable classification, log-line formatting) + construction/teardown safety. Not excluded from either target, so it runs under **both** `make test` and `make test-mac`. The CoreBluetooth plumbing is exercised by the manual persistence experiment, not unit tests |
| `ios/VoiceCodeTests/BlueParrottBLEManagerTests.swift` (new, `#if os(macOS)`) | Byte-parser + connect-state-machine tests + macOS delegate→state-machine case; runs under the `VoiceCodeMac` scheme (`make test-mac`) |

### Build Verification

Use the repo's Makefile targets — the macOS app/tests use the **`VoiceCodeMac`**
scheme, not the iOS-only `VoiceCode` scheme:

```bash
# Build both platforms:
make build-mac    # xcodebuild build -scheme VoiceCodeMac -destination 'platform=macOS'
make build        # iOS-simulator build (scheme VoiceCode)

# Run tests on BOTH targets — no single target spans both platforms:
make test-mac     # xcodebuild test -scheme VoiceCodeMac -destination 'platform=macOS'
                  #   → runs VoiceCodeMacTests, where the new macOS tests live
make test         # iOS-simulator unit tests (scheme VoiceCode) — verifies no iOS regression
```

### Sequencing

1. Phase A1 collector → capture handshake + event bytes on target firmware.
2. App-Mode persistence experiment (decides Phase B scope).
3. Phase B client + byte parser + tests.
4. Rewire macOS `HeadsetRemoteCommandManager`; retire mute proxy as trigger.
5. Manual hardware validation against the acceptance criteria.
