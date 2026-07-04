# macOS Headset SCO Mic Pre‑Warm on BLE Reconnect

> **Language note:** This feature is entirely client‑side Swift (macOS app under `ios/`,
> `#if os(macOS)`). There are **no backend or Clojure components** and **no WebSocket
> protocol changes** — the backend receives the same transcribed text. All code examples
> are Swift, matching the codebase. (The template's "Data Model" / "API Design" sections
> describe the *Swift* type and seam surface, not a DB schema or HTTP/WS API, of which
> there are none.)
>
> **Companion docs:** the interaction state machine in
> @docs/design/macos-headset-loop-state-machine.md; the SCO warm‑up / "No speech" evidence
> in @docs/design/macos-headset-loop-findings.md; the BLE button transport in
> @docs/design/macos-blueparrott-corebluetooth.md; the audible‑cue work in
> @docs/design/macos-headset-audible-feedback.md.

## 1. Overview

### Problem statement
On the **first button press after the headset (re)connects**, the BlueParrott B450‑XT II
drops the first word (or the whole short utterance): the capture summary shows
`buffers=…, silent=100%, firstAudio=never` or a late `firstAudio`, and the user has to
stop and press again. Subsequent presses are fine. This is the **cold SCO mic**: the
Bluetooth headset mic only works over the **HFP/SCO** profile, and the macOS audio
subsystem must switch the headset from A2DP (output‑only) into HFP and **establish the SCO
link — an operation that can take up to a few seconds** the first time an app opens the
input after a (re)connect. The user is talking into a route that isn't live yet.

### Goals
1. **Capture the first word on a cold press.** Make the SCO mic route already live (or
   nearly so) by the time the user's first press after a reconnect opens capture.
2. **Trigger it automatically** off the existing BLE connection signal — no new gesture or
   user action.
3. **Bounded and quiet.** The pre‑warm is short, runs only around a reconnect, suspends the
   keep‑alive output during the warm‑up window (so it doesn't re‑introduce the F2
   half‑duplex contention), and releases the mic if no press lands.
4. **Pure, testable decision core**, mirroring `CaptureReadiness` / `SessionReducer`: the
   *when/how‑long* policy is a pure function; only the capture I/O is impure.
5. **Complement, not replace, the stall watchdog.** Pre‑warm reduces how often a cold route
   is hit; the delta stall‑watchdog (parked work, see §5) still recovers a route that
   stalls mid‑recording.

### Non‑goals
- **Not** iOS. iOS drives the headset via the BPHeadset SDK and manages its own
  `AVAudioSession` (`.playAndRecord` + `allowBluetoothA2DP`); this is `#if os(macOS)` only.
- **Not** a continuous always‑on warm hold. Holding the SCO mic open indefinitely forces
  HFP mono output and lights the mic‑in‑use indicator the whole time — out of scope.
- **Not** a change to the gesture/transport, the send path, or the audible cues.
- **Not** a guarantee on a *pathological* route (a headset whose SCO refuses to come up);
  that still falls through to the stall‑watchdog / restart path.

## 2. Background & Context

### Current state
- The BlueParrott button arrives over **BLE/GATT** (`BlueParrottBLEManager`, an
  `@Published private(set) var isConnected`); the audio mic arrives over **Classic
  HFP/SCO**. They share the radio (a dual‑mode device).
- `HeadsetRemoteCommandManager` (macOS) observes the BLE link in `startBlueParrott()`:
  ```swift
  bleDisconnectCancellable = ble.$isConnected
      .receive(on: DispatchQueue.main)
      .dropFirst()
      .sink { [weak self] connected in
          guard let self = self, !connected else { return }   // only the disconnect edge
          self.handleSystemEvent(.captureEnded)                // mid‑record drop → no strand
      }
  ```
  Today it acts **only on the disconnect edge**; the connect edge is unused.
- **macOS has no `AVAudioSession`.** The HFP/SCO switch happens implicitly when an app
  opens the `AVAudioEngine` input (`VoiceInputManager.startCaptureEngine`). There is no
  session to pre‑configure into HFP — *opening capture is the only lever*.
- The **keep‑alive** (`setupKeepAlive`) plays a looping, inaudible ~20 Hz/−80 dB tone via
  `AVAudioPlayer`. Its job is to register the app as the Now Playing app (so the BlueParrott
  media key routes to us) — it produces **output** samples; it does **not** warm the SCO
  **mic**. This is exactly why subsequent presses are warm (a recent capture left SCO up)
  but the first press after a reconnect is cold.
- `VoiceInputManager` already exposes live capture‑readiness signals the pre‑warm reuses:
  `capturedBufferCount` and the one‑shot `onCaptureProducedAudio` (first non‑silent buffer).

### Why now
On‑hardware testing (logs‑20260606‑115252) showed the first press 1.5 s after a reconnect
losing its first words while the route warmed (`route warming (1 buffer) → … → live,
firstAudio 0.55 s after a restart`). Web research into Bluetooth‑audio best practices
converged on the fix: HFP/SCO link establishment "may take several seconds," and the
standard mitigation is to **pre‑warm / keep the route established before you need it**, then
discard the warm‑up audio (see Related work).

### Related work
- @docs/design/macos-headset-loop-findings.md — F2 (output‑during‑capture doubles warm‑up)
  and F3 (cold‑route dead zone) evidence this builds on.
- @docs/design/macos-headset-audible-feedback.md — the `.listening` "talk‑now" cue; this doc
  explains why pre‑warm is the better lever for first‑word capture (the cue can't fire
  before the user talks).
- Industry best practice (external): Microsoft HFP driver docs — "Opening the SCO stream
  channel … is an asynchronous call that may take several seconds to complete"; Apple
  `AVAudioSession.allowBluetoothHFP`; the common VoIP pattern of keeping the input route
  established before recording and discarding warm‑up audio.
- The parked **delta stall‑watchdog** (git stash, task `…‑5ew.5`) — complementary recovery
  for a route that stalls after going live; folded in as the safety net (§5).

## 3. Detailed Design

### Data Model

Two additive macOS‑only pieces: a pure policy and a small amount of pre‑warm state on
`VoiceInputManager`. No persisted‑schema or network change.

```swift
#if os(macOS)
/// Pure policy for the SCO mic pre‑warm — the testable when/how‑long decisions; no I/O.
enum ScoPrewarm {
    /// How long the pre‑warm capture is held open with no press before releasing the mic.
    /// Long enough to cover "reconnect → user presses" (observed ~1.5 s) with margin, short
    /// enough not to sit on the mic.
    static let holdDuration: TimeInterval = 8.0

    /// Pre‑warm only on a fresh connect, while idle, and not already warming/recording.
    static func shouldPrewarm(connected: Bool, isRecording: Bool, isPrewarming: Bool) -> Bool {
        connected && !isRecording && !isPrewarming
    }
}
#endif
```

```swift
// VoiceInputManager (macOS): pre‑warm state — a capture with NO recognizer, opened purely
// to bring the HFP/SCO route up. Kept running so a real recording can ADOPT the live route
// (zero re‑warm) rather than reopen a cold one.
#if os(macOS)
private(set) var isPrewarming = false
#endif
```

No migration: additive flag + a new code path; the non‑pre‑warm flow is unchanged.

### API Design (internal Swift surface)

There is no HTTP/WS API. The surface is (a) the pure `ScoPrewarm` policy, (b) two new
`VoiceInputManager` capture entry points, and (c) executor wiring + an injected scheduler
seam (mirroring `sessionScheduleWork`).

```swift
#if os(macOS)
extension VoiceInputManager {
    /// Open the mic input WITHOUT recognition to establish the HFP/SCO route, discarding
    /// captured audio. MIRRORS `startCaptureEngine`'s `AVAudioEngine` + `AudioCaptureMonitor`
    /// setup (it can't call it — that function appends to the recognizer), but installs a
    /// DISCARDING tap and starts no `recognitionTask`. Idempotent. `onWarm` (diagnostic)
    /// fires once when the route delivers its FIRST buffer of ANY kind — silent or not —
    /// which is when the SCO is up. It deliberately does NOT use the monitor's non‑silent
    /// one‑shot (`onFirstAudio`): nobody talks during pre‑warm, so a non‑silent buffer may
    /// never arrive. "Warm" for any other purpose is `capturedBufferCount > 0`.
    func prewarmCapture(onWarm: (() -> Void)? = nil)

    /// Tear down a pre‑warm capture if one is open (no‑op otherwise). Does NOT touch a real
    /// recording.
    func stopPrewarm()
}
#endif
```

`startRecording` gains a small adoption step: if a pre‑warm capture is live when a real
recording begins, **adopt the running engine** (swap the discarding tap for the
recognizer‑feeding tap) instead of building a fresh, cold one:

```swift
// VoiceInputManager.startRecordingAfterTTSStopped (macOS), conceptually:
if isPrewarming {
    adoptPrewarmEngineForRecognition(recognitionRequest)   // live SCO → no re‑warm
} else {
    _ = startCaptureEngine()                               // existing cold path
}
```

**Error/edge cases (state → action):**

| BLE/loop state when connect edge fires | Action |
|---|---|
| idle, not recording, not pre‑warming | start pre‑warm (suspend keep‑alive) |
| already recording | skip (the mic is already open/warm) |
| already pre‑warming | skip (idempotent) |
| pre‑warm hold elapses, still idle | stop pre‑warm, resume keep‑alive |
| real press during pre‑warm | recording adopts the live engine (no re‑warm) |
| disconnect during pre‑warm | stop pre‑warm, resume keep‑alive |

**Breaking changes / deprecation:** none. The connect‑edge handler and pre‑warm path are
additive; the disconnect edge and the normal record path are unchanged.

### Code Examples

**Trigger — extend the existing `$isConnected` sink to act on the connect edge too:**

```swift
// startBlueParrott() (macOS) — the sink now handles BOTH edges.
bleConnectionCancellable = ble.$isConnected
    .receive(on: DispatchQueue.main)
    .dropFirst()                                  // skip the initial false
    .sink { [weak self] connected in
        guard let self = self else { return }
        if connected {
            self.prewarmScoOnReconnect()          // NEW: warm the mic before the first press
        } else {
            self.handleSystemEvent(.captureEnded) // existing: mid‑record drop → no strand
        }
    }
```

**Happy path — start the bounded pre‑warm:**

```swift
private func prewarmScoOnReconnect() {
    guard stateMachineEngaged,
          ScoPrewarm.shouldPrewarm(connected: true,
                                   isRecording: voiceInput.isRecording,
                                   isPrewarming: voiceInput.isPrewarming) else { return }
    hLog("Headset: BLE reconnect — pre‑warming SCO mic")
    stopKeepAlive()                               // F2: no output during the warm‑up window
    voiceInput.prewarmCapture(onWarm: { [weak self] in
        self?.hLog("Headset: SCO mic warm (pre‑warm) — first press will be live")
    })
    // Bounded warm‑hold: release the mic if no press lands.
    prewarmScheduleWork(ScoPrewarm.holdDuration) { [weak self] in
        self?.endPrewarmIfIdle()
    }
}
```

**Edge case — release the mic when the hold elapses with no press:**

```swift
private func endPrewarmIfIdle() {
    guard voiceInput.isPrewarming, state == .idle else { return }  // a recording adopted it
    voiceInput.stopPrewarm()
    startKeepAlive()
    hLog("Headset: pre‑warm hold elapsed — released SCO mic")
}
```

**Edge case — a disconnect during pre‑warm tears it down (alongside the existing
no‑strand):**

```swift
// inside the `else` (disconnect) branch, before handleSystemEvent(.captureEnded):
if voiceInput.isPrewarming { voiceInput.stopPrewarm(); startKeepAlive() }
```

**Pre‑warm capture (the I/O) — open the engine with a discarding tap, no recognizer:**

```swift
// VoiceInputManager (macOS)
func prewarmCapture(onWarm: (() -> Void)? = nil) {
    guard !isPrewarming, !isRecording else { return }
    isPrewarming = true
    let engine = AVAudioEngine(); audioEngine = engine
    let input = engine.inputNode
    // No `onFirstAudio` here: do NOT touch the shared, executor‑owned `onCaptureProducedAudio`
    // (clobbering it would break the next real recording's first‑audio readiness), and a
    // non‑silent buffer may never arrive during a silent pre‑warm anyway.
    let monitor = AudioCaptureMonitor(startTime: CFAbsoluteTimeGetCurrent())
    captureMonitor = monitor
    var sawBuffer = false
    input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in
        monitor.record(peak: VoiceInputManager.peakAmplitude(of: buf),
                       frames: Int(buf.frameLength), at: CFAbsoluteTimeGetCurrent())
        // SCO is up the instant the FIRST buffer arrives — silent or not. Fire `onWarm` once;
        // DISCARD the audio (no `recognitionRequest.append`).
        if !sawBuffer { sawBuffer = true; DispatchQueue.main.async { onWarm?() } }
    }
    do { try engine.start(); log("VoiceInput: SCO pre‑warm capture started") }
    catch { log("VoiceInput: pre‑warm failed: \(error.localizedDescription)"); stopPrewarm() }
}
```

### Component Interactions

```
BLE reconnect (power‑cycle / back in range)
  └─► BlueParrottBLEManager.isConnected: false → TRUE
       └─► HeadsetRemoteCommandManager $isConnected sink (connect edge)
            └─► prewarmScoOnReconnect()  [guarded by ScoPrewarm.shouldPrewarm]
                 ├─► stopKeepAlive()                       (F2: silence output during warm‑up)
                 ├─► VoiceInput.prewarmCapture()           (open AVAudioEngine input, discard)
                 │     └─► macOS audio subsystem brings up HFP/SCO  ← the warm‑up happens NOW
                 └─► prewarmScheduleWork(holdDuration)     (bounded release)

   …user presses (within the hold)…
  └─► handleButtonEvent → reducer → .startCapture → startSessionCapture
       └─► VoiceInput.startRecording(): isPrewarming==true → ADOPT the live engine
            └─► firstAudio is immediate — the SCO is already up → first word captured

   …no press before holdDuration…
  └─► endPrewarmIfIdle(): stopPrewarm() + startKeepAlive()   (mic released)
```

Integration points & dependencies:
- **`BlueParrottBLEManager.$isConnected`** — the trigger (already published; unchanged).
- **`HeadsetRemoteCommandManager`** (macOS): the connect‑edge handler, the
  `prewarmScheduleWork` seam, keep‑alive suspend/resume, and the `ScoPrewarm` guard. Depends
  on `VoiceInputManager` + `AppSettings`.
- **`VoiceInputManager`** (macOS): `prewarmCapture` / `stopPrewarm` / `isPrewarming` and the
  `startRecording` adoption step; reuses `AudioCaptureMonitor`.
- **`ScoPrewarm`**: pure; lives beside `CaptureReadiness` in `HeadsetSessionReducer.swift`.

## 4. Verification Strategy

### Testing Approach
- **Unit (primary) — pure policy.** `ScoPrewarm.shouldPrewarm` table‑tested across the
  connect/recording/pre‑warming matrix; `holdDuration > 0`.
- **Unit — executor wiring (mac harness + injected seams).** This requires extending the
  existing `HeadsetRemoteCommandManagerMacTests` harness — the new pieces (matching how
  `sessionScheduleWork`/`EarconSpy` are already added):
  - manager: a non‑firing `var prewarmScheduleWork` seam + `testFirePrewarmHold()`, and a
    `testKeepAliveSuspendedForPrewarm` observable (DEBUG counter, like `suspendKeepAliveCount`);
  - `MockVoiceInputForHeadset`: override `prewarmCapture`/`stopPrewarm` to set
    `prewarmCaptureCalled`/`stopPrewarmCalled` and a settable `isPrewarming`;
  - drive the fake BLE to connected via the harness's **existing** `driveBLELive(_:)`
    (`HeadsetRemoteCommandManagerMacTests.swift:155‑161`), which runs the full advertise →
    connect → subscribe sequence that flips `isConnected` true (a partial sequence does not
    reach `.discovering`). The new tests therefore live in that test class to reach the
    `private` helper.

  Then: connect → pre‑warm starts (assert `prewarmCaptureCalled`, keep‑alive suspended); the
  hold timer while idle stops it (keep‑alive resumed); a press during pre‑warm records and
  leaves no dangling pre‑warm; a disconnect during pre‑warm stops it; no pre‑warm while
  recording / already pre‑warming.
- **Unit — `VoiceInputManager` pre‑warm seam.** `prewarmCapture` sets `isPrewarming` and is
  idempotent; `stopPrewarm` clears it; `onWarm` fires once on the first buffer (driven from the
  tap, NOT the executor‑owned `onCaptureProducedAudio`, which must be left intact). (No live
  route needed — exercise via the monitor/tap seam, like the existing readiness tests.)
- **Integration — no regression.** The disconnect edge still feeds `captureEnded`
  (no‑strand); the normal record/send/earcon flows are unchanged.
- **End‑to‑end (manual, hardware).** Power‑cycle the headset; the first press ≤ holdDuration
  later captures the first word (`firstAudio` small, no restart). Compare cold‑press
  `firstAudio` / restart counts with pre‑warm on vs off.

### Test Examples

```swift
final class ScoPrewarmTests: XCTestCase {
    func testPrewarmsOnConnectWhenIdle() {
        XCTAssertTrue(ScoPrewarm.shouldPrewarm(connected: true, isRecording: false, isPrewarming: false))
    }
    func testNoPrewarmWhileRecordingOrAlreadyWarming() {
        XCTAssertFalse(ScoPrewarm.shouldPrewarm(connected: true, isRecording: true,  isPrewarming: false))
        XCTAssertFalse(ScoPrewarm.shouldPrewarm(connected: true, isRecording: false, isPrewarming: true))
    }
    func testNoPrewarmOnDisconnect() {
        XCTAssertFalse(ScoPrewarm.shouldPrewarm(connected: false, isRecording: false, isPrewarming: false))
    }
    func testHoldDurationIsPositive() { XCTAssertGreaterThan(ScoPrewarm.holdDuration, 0) }
}

// These live IN `HeadsetRemoteCommandManagerMacTests` (alongside the earcon tests) so they
// can reuse its `private func driveBLELive(_:)` — the existing full connect sequence
// (advertise → connect → subscribe) that flips `isConnected` true. A partial sequence does
// NOT reach `.discovering`, so it would not produce the connect edge.
#if os(macOS)
extension HeadsetRemoteCommandManagerMacTests {
    func testReconnect_startsPrewarm_andSuspendsKeepAlive() {
        let f = makeFixture()                                   // engaged
        driveBLELive(f.central)                                 // → isConnected true (the connect edge)
        XCTAssertTrue(f.input.prewarmCaptureCalled)
        XCTAssertTrue(f.manager.testKeepAliveSuspendedForPrewarm)
    }

    func testPrewarmHoldElapsed_whileIdle_releasesMic() {
        let f = makeFixture()
        driveBLELive(f.central)
        f.manager.testFirePrewarmHold()                         // injected scheduler fires
        XCTAssertTrue(f.input.stopPrewarmCalled)
    }

    func testPressDuringPrewarm_recordsAndDoesNotStrandPrewarm() {
        let f = makeFixture()
        driveBLELive(f.central)                                 // pre‑warming
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)
        XCTAssertTrue(f.input.startRecordingCalled)
        XCTAssertEqual(f.manager.testSessionState, .recording)
    }

    func testNoPrewarmWhileRecording() {
        let f = makeFixture()
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)  // recording
        driveBLELive(f.central)                                     // a flap mid‑record
        XCTAssertFalse(f.input.prewarmCaptureCalled)
    }
}
#endif
```

### Acceptance Criteria
1. A pure `ScoPrewarm.shouldPrewarm(connected:isRecording:isPrewarming:)` returns true only
   for a connect edge while idle and not already pre‑warming; `holdDuration > 0`.
2. `VoiceInputManager` exposes `prewarmCapture` / `stopPrewarm` / `isPrewarming`;
   `prewarmCapture` opens an engine with a **discarding** tap and **no** `recognitionTask`,
   and is idempotent.
3. On the BLE **connect** edge (idle), the executor starts a pre‑warm and **suspends the
   keep‑alive**; on the **disconnect** edge it still feeds `captureEnded` (no regression).
4. The pre‑warm is **bounded**: with no press within `holdDuration` it stops the capture and
   resumes the keep‑alive (executor test via the injected scheduler).
5. A real press during pre‑warm starts a recording that **adopts the live route** (no fresh
   cold engine), and leaves no dangling pre‑warm.
6. No pre‑warm starts while already recording or already pre‑warming.
7. **Manual/hardware:** after a power‑cycle, the first press within `holdDuration` captures
   the first word — small `firstAudio`, no `captureGrace … restart` — measurably better than
   pre‑warm‑off.
8. `make test`, `make test-mac`, and `make build-mac` are green; no behavioral regression in
   the existing reducer / executor tests.

## 5. Alternatives Considered

1. **Keep an always‑on warm hold (continuous SCO capture).** *Rejected:* holds the mic open
   indefinitely — HFP mono output the whole time, the mic‑in‑use indicator always lit, and
   battery cost. The bounded hold gets the benefit (warm for a press shortly after reconnect)
   without sitting on the mic.
2. **Warm the SCO with the keep‑alive instead of a capture.** *Rejected:* the keep‑alive is
   an A2DP **output** tone; on macOS the SCO **mic** only comes up when an app opens the
   **input**. Output can't warm the input route. (This is the root‑cause insight — see §2.)
3. **Rely on the `.listening` "talk‑now" cue** (from @docs/design/macos-headset-audible-feedback.md)
   to tell the user when the route is live. *Rejected as the fix:* the cue can only fire
   *after* the route is live, and the user talks immediately — so it can't prevent the
   first‑word loss; on hardware it never fired (the user's first audio cancels the grace
   first). Pre‑warm attacks the cause (route not live yet); the cue stays as feedback.
4. **Pre‑warm then STOP and rely on the SCO "tail" for the press** (don't keep the engine
   open). *Considered, secondary:* simpler (no engine adoption), but the SCO can re‑cool in
   the gap between stopping the pre‑warm and the press, re‑opening cold. The warm‑hold +
   engine adoption keeps the route continuously live across the press. Kept as a fallback if
   engine adoption proves fragile on some macOS versions.
5. **Stall‑watchdog alone** (the parked delta watchdog: restart capture when buffers stop
   arriving). *Complementary, not an alternative:* it *recovers* a route that goes cold/stalls
   but still loses the audio spoken during the warm‑up+restart (~2 s, observed). Pre‑warm
   removes the cold start in the first place; the watchdog remains the safety net for a route
   that stalls *after* going live. This design assumes the watchdog is (re)landed alongside it.

**Trade‑off of the chosen approach.** A bounded warm‑hold + engine adoption captures the
first word with no user‑visible behavior change, but it briefly opens the mic on every
reconnect (privacy‑indicator flicker, small battery cost) and adds an engine‑adoption path
to `startRecording`. We accept this: the window is short, gated to reconnects, and the
adoption path is the only way to land a press on a *continuously* live route.

## 6. Risks & Mitigations

1. **Privacy/UX — the mic indicator lights on reconnect without a press.** *Detect:* visible
   orange mic dot; user reports. *Mitigate:* keep `holdDuration` short (~8 s) and gate to the
   reconnect edge only; never a continuous hold; release immediately on hold‑elapse or
   disconnect. Optionally gate behind a setting if it proves surprising.
2. **F2 contention — output during the warm‑up re‑doubles the dead zone.** *Detect:* pre‑warm
   `firstAudio` worse with keep‑alive playing. *Mitigate:* `stopKeepAlive()` for the entire
   pre‑warm window (mirrors the BLE recording's `.suspendKeepAlive`); resume only on release.
3. **Engine adoption races a real press** (pre‑warm engine vs the recording engine →
   double‑open of the input device). *Detect:* `startRecording` opens a second engine while
   `isPrewarming`; capture summary anomalies. *Mitigate:* `startRecording` checks
   `isPrewarming` and adopts the running engine (single engine); `stopPrewarm` is a no‑op once
   adopted. Covered by the press‑during‑pre‑warm test.
4. **SCO doesn't actually warm from a brief capture** (some headsets/macOS versions).
   *Detect:* pre‑warm `onWarm` never fires; first press still cold. *Mitigate:* the
   stall‑watchdog (§5) still recovers; `holdDuration` keeps the engine open long enough for a
   slow SCO; fall back to alternative #4 (tail) if adoption is unavailable.
5. **Keep‑alive state confusion** (double stop/start across pre‑warm, recording, and TTS).
   *Detect:* keep‑alive not playing when expected (media key stops routing) or playing during
   capture (F2). *Mitigate:* funnel pre‑warm suspend/resume through the same
   `startKeepAlive`/`stopKeepAlive` the recording path uses; assert the suspend/resume balance
   in the executor tests.
6. **Reconnect flapping** (rapid connect/disconnect re‑triggering pre‑warm). *Detect:* repeated
   `pre‑warming SCO mic` logs. *Mitigate:* the `isPrewarming` guard makes re‑entry a no‑op;
   the hold timer is re‑armed, not stacked.

### Rollback strategy
The feature is additive and reconnect‑scoped. Disable it by **not calling
`prewarmScoOnReconnect()`** from the connect edge (one line) — the disconnect edge and the
normal record path are untouched, so behavior reverts exactly to today's (first press cold,
recovered by the watchdog). If gated behind a setting, default it off until hardware‑validated.
No data or protocol implications.
