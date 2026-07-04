# macOS Headset Hands-Free Loop — Findings (pre-design)

> **Status:** findings only — empirical observations + root causes from hardware
> debugging on 2026-06-03. No solution design here. This is the input to a
> forthcoming design doc that overhauls the headset loop as an explicit state
> machine. Companion to @docs/design/macos-blueparrott-corebluetooth.md (the
> CoreBluetooth button transport) and bugs
> `voice-code-blueparrott-ble-scan-timeout-ghw` and
> `voice-code-headset-hfp-mic-warmup-66p`.

## 1. Scope

The "hands-free loop" on macOS is: **BlueParrott button (BLE) → recording state
machine → speech capture → send to backend → spoken response → back to idle.**
It spans three components, all client-side Swift:

- `BlueParrottBLEManager` — CoreBluetooth transport for the button (scan / connect
  / retry; emits `BlueParrottButtonDelegate` events). macOS-only.
- `HeadsetRemoteCommandManager` — owns the `HeadsetState` machine and the
  keep-alive; cross-platform (iOS uses the `BPHeadset` SDK, macOS uses
  `BlueParrottBLEManager`, both feeding the same delegate + state machine). Also
  serves the AirPods / `MPRemoteCommandCenter` (media-key) path.
- `VoiceInputManager` — `AVAudioEngine` tap → `SFSpeechRecognizer`; cross-platform.

The debugging that produced these findings was driven entirely from on-device logs
(in-app `LogManager`, category tags `BlueParrottBLE` / `HeadsetRemote` /
`VoiceInput`) plus a CoreBluetooth crash report.

## 2. Current behavior (as-is)

### 2.1 State machine
`HeadsetState` (`HeadsetRemoteCommandManager.swift`): `ready`, `recording`,
`sending` (rendered as **"Processing"**), `speaking`.

Transitions actually exercised on macOS today:

| From | Event | To | Notes |
|---|---|---|---|
| ready | button **down** (or media play/toggle) | recording | `startRecording()` |
| recording | button **up** (or `voiceInput.isRecording→false` auto-finalize) | sending | `stopRecordingAndSend()` |
| sending | transcription empty | ready | early return |
| sending | `voiceOutput.isSpeaking→true` | speaking | the **only** non-empty exit on macOS |
| speaking | `voiceOutput.isSpeaking→false` | ready | |
| speaking | double-tap / long-press / next-track | ready | `performInterrupt()` — **but the macOS arbitrator drops double/long (§F5)** |

### 2.2 macOS button arbitration
`BlueParrottPTTArbitrator` forwards **down/up only** and **drops tap / double-tap /
long-press**. Rationale (design §3): the raw GATT stream brackets every gesture
with down/up (tap = `01,00,02`; double = `01,00,01,00,03`; hold = `01,04,00`), so
driving off both down/up and the gesture codes would double-drive the machine.

### 2.3 Capture + keep-alive
`startRecording()` builds a fresh `AVAudioEngine`, taps input → recognizer. A silent
keep-alive `AVAudioPlayer` runs continuously while headset mode is active (holds the
Now-Playing slot so AirPods media keys route to us). Observability added this session:
`VoiceInput: input device=…` at start and `VoiceInput: capture summary —
buffers=N frames=M silent=X% peak=P firstAudio=Ts` at stop.

## 3. Findings

Each finding: **evidence → root cause → status**. "Validated" = observed directly
on hardware; "Hypothesis" = inferred, not yet isolated.

### F1 — BLE first-connect is slow (~41–53 s) and advertisement-dependent
**Evidence.**
- 16:13 session: connected on scan attempt 6, ~53 s after start; `connected` followed a `didDiscover` (scan), not the already-connected fast path.
- 18:11 session: 5 attempts (~44 s), user gave up before connect.
- 20:03 session (continuous-scan build): connected ~41 s (start 20:03:14 → `connected` 20:03:55).
- **`retrieveConnectedPeripherals(withServices:)` returned empty in every session (0 hits).**

**Root cause.** The headset is bonded for **classic HFP audio** (BR/EDR), which is a
separate radio link from **BLE GATT** (LE/ATT). So `retrieveConnectedPeripherals`
legitimately returns nothing, and discovery depends on catching a BLE
**advertisement** of the control service — which the BlueParrott emits
**infrequently**. (Confirmed reasoning, Opus consult.)

**Status.** Root cause **validated**. Mitigations landed this session:
- Scan-timeout **re-probe** (was silent-forever after one scan → now retries; fast→30s slow). Validated.
- **Continuous scan** (Step A): removed the stop/2 s-gap/rescan churn. Confirmed working (single continuous scan, no restart) but only **marginally** faster (~41 s vs ~53 s) → the gaps were *not* the main cause; rare advertising is.
- **Not yet done (Step B):** identifier-based reconnect — see §5.

### F2 — Warm-up dead zone at capture start; the keep-alive is a contributor
**Evidence (`firstAudio` = time to first non-silent buffer).**
- Built-in mic: `firstAudio=2.44 s` / 95 % silent (short clip) and `3.56 s` / 95 %.
- Headset HFP mic (keep-alive playing): `firstAudio=1.23 s` / 71 % silent.
- Headset HFP mic (**keep-alive suspended during recording**): `firstAudio=0.63 s` /
  52 % silent, peak 0.27 → captured "Testing 123".

**Root cause.** The input route delivers near-silence for the first fraction of a
recording. The continuously-playing silent keep-alive **output** is a real
contributor: suspending it during recording roughly **halved** the dead zone. The
dead zone is **not** Bluetooth-specific — the built-in mic is affected as badly or
worse, so "switch to the built-in mic" is the wrong fix.

**Status.** Keep-alive-suspend effect **validated** (1.23 s → 0.63 s). Suspension is
currently unconditional on macOS; needs gating to the BLE path so the macOS AirPods
"stop recording via second stem press" flow isn't regressed.

### F3 — First capture right after BLE connect returns **zero** buffers
**Evidence.** 20:04:24 first recording after connect: `buffers=0 frames=0
firstAudio=never` over a 4.7 s hold → "No speech." The very next press (20:04:31)
worked (`0.63 s`).

**Root cause (hypothesis).** The input route is not live on the first capture after
the connect/route transition — the engine starts but the tap never fires. This is the
macOS analog of a documented iOS issue (`VoiceInputManager` iOS comment: "the audio
engine would start without producing audio buffers — the user had to tap mic again").
Distinct from F2: F2 is *silent* buffers, F3 is *no* buffers.

**Status.** Behavior **validated**; mechanism a hypothesis. No fix yet.

### F4 — State machine strands in `.sending` ("Processing") when the response never speaks
**Evidence.** 20:04:36 "Testing 123" sent → state `.sending`. `Server ack:
Processing prompt…`, then **no response and no TTS for ~15 s**. Button presses at
20:04:38, :41, :44, :48 all logged (`button DOWN/UP — state=Processing`) but **did
nothing**. State never returned to `.ready`.

**Root cause.** On macOS the **only** exit from `.sending` is
`voiceOutput.isSpeaking→true` (`:122`). `buttonDown` only acts from `.ready`;
`buttonUp` only from `.recording`; tap/double/long are dropped by the arbitrator. So
if a sent prompt produces **no spoken output** (slow/empty/non-spoken response), the
machine has **no fallback exit** and the button is dead until the app resets.

**Status.** **Validated** and reproduced. Most severe of the three (silently breaks
the loop after the first utterance). No fix yet.

### F5 — Discrete gestures and barge-in are unsupported on the macOS PTT path
**Evidence.** Button presses during `.speaking` and `.sending` do nothing (F4 and the
20:04 sequence). `BlueParrottPTTArbitrator` drops tap/double/long.

**Root cause / context.** macOS deliberately drives PTT off down/up only (design §3)
and drops the gesture codes, so: no tap-to-toggle, no double-tap or long-press
**interrupt/barge-in**, and no way to interrupt a spoken response or a stuck
`.sending` from the button. iOS supports these because the `BPHeadset` SDK
de-brackets the stream into clean `onTap`/`onDoubleTap`/`onLongPress`. The platforms
have **diverged**, contrary to the epic's "parity with iOS" goal.

**Status.** Behavior **validated**. The intended UX (PTT-hold vs tap-to-toggle vs
both, and whether a press should interrupt speaking/processing) is an **open product
decision** for the design.

### F6 — `retrieveConnectedPeripherals` is structurally empty (supporting F1)
HFP classic link ≠ BLE GATT connection; `retrieveConnectedPeripherals(withServices:)`
only returns peripherals with an active **GATT** connection. 0 hits every session,
consistent across the live client and the diagnostic explorer. **Validated.**

### F7 — Subscribe error recurs but notifications still flow (fragile)
Every connect logs `subscribe error for 66339E60-… — The attribute could not be
found.`, yet button notifications arrive (the CCCD subscription persists from a prior
session). Design §3 note 2 predicted this. **Validated; fragile** — a session where
the subscription doesn't persist would receive no button events despite "connected."

### F8 — Diagnostics are drowned by reconnection-timer spam (observability)
`VoiceCodeClient: Reconnection timer fired …` logs ~1×/s **while already
connected/authenticated** (e.g. 496 lines in an 8-min capture), filling the in-app
log ring buffer and **evicting** the `BlueParrottBLE`/`HeadsetRemote`/`VoiceInput`
lines needed to debug the loop. Separate subsystem, but it materially impedes
diagnosis of this loop. **Validated.**

## 4. What is validated working
- **Full loop works end-to-end**: button press → record → transcribe → send. "Testing
  123" reached the backend session via the headset.
- **Keep-alive suspend** measurably reduces the capture dead zone (F2).
- **Continuous scan** behaves as designed (F1); **re-probe** prevents silent death.
- Capture **observability** (`input device` + `capture summary firstAudio`) is the
  metric that turned guesses into measurements and should be retained.

## 5. Known fix directions already identified (for the design to formalize)
- **F1 / Step B — identifier reconnect.** Persist `peripheral.identifier`; on launch
  `retrievePeripherals(withIdentifiers:)` + `connect()`. **Critical caveat (Opus
  consult):** `connect()` has no timeout and `bleDidStartConnecting` currently cancels
  the only watchdog — a **stale identifier would hang forever** (worse than slow).
  Required: split the adapter's connect into advert/already-connected (fast, cancels
  scan-timeout) vs `connectKnown(identifier:)` under a **separate connect-watchdog**;
  watchdog trip → `cancelPeripheralConnection` → fall back to scan; clear the saved id
  after repeated failures; on `didDisconnect`, reconnect via the **held `CBPeripheral`**
  (the legit no-timeout, near-instant case). Skip CB state restoration on macOS. Add a
  post-connect **discovery watchdog** ("connected but never `isNotifying`").
- **F2** — gate keep-alive suspend to the BLE path; consider keeping the capture
  engine warm; treat as warm-up handling, not mic-switching.
- **F3** — warm the engine / wait for route-ready before first capture, or detect
  `buffers=0` and auto-restart the capture once.
- **F4** — add a fallback exit from `.sending` (timeout → `.ready`, and/or a button
  press during `.sending` resets/aborts); tie the exit to response completion, not
  only to TTS.
- **F5** — decide the gesture/interrupt model and (if parity is wanted) de-bracket the
  raw GATT stream so tap/double/long are usable on macOS.

## 6. Constraints the design must respect
- **Cross-platform state machine.** iOS drives the *same* `HeadsetState` via the
  `BPHeadset` SDK. The overhaul must not regress iOS (or must be explicitly
  macOS-scoped with shared parts factored cleanly).
- **AirPods / `MPRemoteCommandCenter` path** shares `HeadsetRemoteCommandManager`
  (play/pause/next, keep-alive, Now-Playing). Changes (esp. keep-alive, F2) must not
  break AirPods stem-press behavior.
- **Gating** already exists: `settings.headsetModeEnabled` (→ `isActive`),
  `settings.blueParrottEnabled`, and the macOS-only `stateMachineEngaged`
  (`isActive || blueParrottEnabled`).
- **Testability.** Unit tests must drive the machine via seams (`BLECentral`,
  injected `scheduleWork`, mock `VoiceInput`/`VoiceOutput`/`Client`) **without** real
  CoreBluetooth or `AVAudioPlayer` — both crash the headless test host (F7 lessons:
  guard real hardware behind `TestingEnvironment.isUnitTesting`; avoid synchronous
  self-rescheduling work). Use `make test-mac-unit` for a clean unit signal.

## 7. Open questions for the design
1. **Gesture/UX model:** PTT-hold, tap-to-toggle, or both (de-bracketed)? Should a
   press during `.speaking`/`.sending` **interrupt** (barge-in) and/or start a new
   recording?
2. **`.sending` fallback:** timeout duration? Should it cancel the in-flight prompt or
   just re-enable recording? How does it interact with a late-arriving response?
3. **Mic source policy** (driving use case): headset HFP mic vs built-in — reconcile
   with the iOS "force built-in" decision (@docs/design/.../66p, the dash-mount bug).
4. **One unified state machine** across BLE + media-key + iOS-SDK sources, or
   platform-specific machines sharing a core?
5. **Connection lifecycle** as part of the same machine (disconnected / connecting /
   connected) or a separate BLE state machine feeding it?

## 8. References
- Bugs: `voice-code-blueparrott-ble-scan-timeout-ghw` (F1, Step A/B),
  `voice-code-headset-hfp-mic-warmup-66p` (F2, F3).
- Existing design: @docs/design/macos-blueparrott-corebluetooth.md (button transport).
- Logs (2026-06-03): `…200451` (loop works; F2/F3/F4 evidence), `…181224` (F1 ~44 s,
  re-probe), `…161342` (F1 ~53 s connect, cims working dir), `…154427` / `…151946` /
  `…104047` (earlier F2/tap-flicker evidence).
- Opus design consult (recorded on bug `…ghw`): F1/Step B refinement + stale-id hang.
