# macOS Headset Hands-Free Loop — Audible State-Change Feedback (Earcons)

> **Language note:** This feature is entirely client-side Swift (iOS/macOS app under
> `ios/`). There are **no backend or Clojure components** and **no WebSocket protocol
> changes** — the backend still receives the same transcribed text. All code examples are
> Swift, matching the codebase. (This document follows the standard design-doc template;
> its "Data Model" / "API Design" sections describe the *Swift* type and seam surface, not
> a database schema or an HTTP/WS API, of which there are none.)
>
> **Companion docs:** the interaction state machine this builds on in
> @docs/design/macos-headset-loop-state-machine.md; the SCO warm-up / "No speech"
> evidence in @docs/design/macos-headset-loop-findings.md; the BLE button transport in
> @docs/design/macos-blueparrott-corebluetooth.md.

## 1. Overview

### Problem statement
The macOS hands-free loop (button → record → transcribe → send → hear response → idle)
gives the user **no eyes-free confirmation of state changes**. While driving the user
cannot see the screen, so today they only learn what happened when the TTS response
arrives — or never, when something fails silently:

- Did the press register and is the mic **actually recording**?
- Did my utterance **send**?
- Did it capture **nothing** ("No speech detected"), or is the backend just slow?

This is compounded by the **SCO cold-start dead zone** (F3 in
@docs/design/macos-headset-loop-findings.md): the Bluetooth HFP mic needs ~0.6–1 s to
warm up after capture starts, and audio spoken into that window is lost. The user has no
signal for *when the mic is live*, so they speak too early and get an empty transcription.

### Goals
1. Give the hands-free user **language-neutral, eyes-free audible cues** for the
   highest-value state changes: recording started, prompt sent, and failure.
2. Make the cues **route to the headset** (HFP), not the Mac speaker, so a driver hears
   them in-ear.
3. Use the cue for the recording-start transition as a **"speak now" signal** that, in its
   fuller form, doubles as an **SCO warm-up primer** — directly attacking the lost-first-
   word problem.
4. Keep the change **pure and testable**: the decision of *which* cue to play lives in the
   existing `SessionReducer` as a new effect; only playback is I/O.
5. Make it **opt-out** via a setting and **silent on the desktop** (only when the headset
   loop is engaged).

### Non-goals
- **Not** a general notification/sound framework for the whole app (TTS already owns the
  response channel; this is scoped to the hands-free session loop).
- **Not** spoken word cues by default — earcons are short tones (spoken cues are listed as
  an accessibility alternative in §5).
- **Not** custom-recorded/branded audio assets in the first cut (runtime-synthesized tones;
  assets remain a later option, §5).
- **Not** haptics (the B450-XT exposes no haptic channel; macOS has none relevant here).
- **No** change to gesture semantics, the send path, or the BLE transport.

## 2. Background & Context

### Current state
The loop is driven by a pure reducer and an executor:

- `SessionReducer.reduce(state, event, source) → (state, [SessionEffect])` in
  `ios/VoiceCode/Managers/HeadsetSessionReducer.swift` — I/O-free, exhaustively unit-
  tested, compiles into both targets.
- The executor `apply(_:)` in `HeadsetRemoteCommandManager.swift` (macOS extension) turns
  each `SessionEffect` into real `VoiceInput` / `VoiceOutput` / `VoiceCodeClient` calls and
  feeds resulting events back in via `handleSystemEvent`.

States: `idle · recording · finalizing · awaitingResponse · speaking`.
Effects today: `startCapture · restartCapture · stopCapture · sendPrompt · interruptTTS ·
suspendKeepAlive · resumeKeepAlive · armTimer · cancelTimer · updateNowPlaying · log`.

There is **no audio-cue infrastructure**. The one precedent for *playing audio through the
headset route* is the **keep-alive silent player** (`keepAlivePlayer: AVAudioPlayer` in
`HeadsetRemoteCommandManager.swift`): `setupKeepAlive()` synthesizes a short file to a temp
URL, loads it into an `AVAudioPlayer`, and `prepareToPlay()`s it under the
`.playAndRecord` / `.allowBluetoothA2DP` session so playback binds to the Bluetooth route.
The capture-readiness hook `voiceInput.onCaptureProducedAudio` (the F3 "first non-silent
buffer" signal) and `voiceInput.capturedBufferCount` already exist and tell us when the
route is delivering audio.

### Why now
On-hardware validation of the loop (B450-XT II v1.08) confirmed the button + headset mic
work end-to-end, but exposed two recurring eyes-free pain points the user hit live:
SCO cold-start dropping the first utterance, and uncertainty about whether a press
registered. The reducer/effect architecture is now stable and committed (the on-screen mic
button shares the reducer, with barge-in), making this a clean additive effect.

### Related work
- @docs/design/macos-headset-loop-state-machine.md — the reducer this extends.
- @docs/design/macos-headset-loop-findings.md — F3 (dead route) and "No speech" evidence.
- @docs/design/macos-blueparrott-corebluetooth.md — BLE button transport + verification.
- The keep-alive player (`setupKeepAlive`) — the routing precedent reused here.

## 3. Detailed Design

### Data Model

Two additive changes in `HeadsetSessionReducer.swift` — a new `Earcon` type and a new
`SessionEffect` case; **no** persisted-schema or network change.

```swift
/// A short, language-neutral audio cue for a hands-free state change, played through the
/// headset HFP route so the user hears it without looking at the screen.
/// `Hashable` (not just `Equatable`) because `HeadsetEarconPlayer` keys a
/// `[Earcon: AVAudioPlayer]` cache by it; `Hashable` refines `Equatable`, so the
/// `SessionEffect` Equatable synthesis below still holds.
enum Earcon: Hashable {
    case listening   // recording began — "mic is live, talk now"
    case sent        // prompt dispatched — "got it"
    case error       // nothing recognized / no response / not connected — "that didn't work"
    case cancelled   // TTS dismissed without recording (optional; §3 Component Interactions)
}

enum SessionEffect: Equatable {
    // …existing cases…
    case playEarcon(Earcon)          // NEW: declare the intent to play a cue (no I/O here)
}
```

`SessionEffect` is already `Equatable`, so `.playEarcon(.listening)` is directly assertable in
reducer table tests. No migration: the case is additive and ignored by any code path that
does not handle it.

### API Design (internal Swift surface)

There is no HTTP/WS API. The "API" is (a) the new effect emitted by the reducer and (b) an
injected playback seam, mirroring the existing `sessionScheduleWork` / `sendVoicePrompt`
seams.

All earcon playback is **macOS-only**: only macOS is driven by `SessionReducer` — iOS keeps
its own `HeadsetState` machine (`HeadsetRemoteCommandManager.swift:28–32`), and the executor
plus its seams already live in `#if os(macOS)` (`:58–126`). The reducer *file* is
platform-agnostic, so `.playEarcon` compiles on iOS, but it is exercised there **only by
unit tests, never a live path**. So the protocol, player, and seam all sit in the macOS
block — there is no iOS branch and no `Noop` player.

```swift
#if os(macOS)
/// Plays an earcon. Injected into the executor; real impl routes to the headset, tests
/// inject a spy.
protocol EarconPlaying {
    func play(_ earcon: Earcon)
}

/// Synthesizes the earcon tones ONCE at init to temp files and `prepareToPlay()`s them
/// under the active `.playAndRecord` route — the exact pattern `setupKeepAlive()` uses so
/// playback binds to the Bluetooth (HFP) output, and `play()` is low-latency. A short
/// one-shot tone coexists with the silent looping keep-alive player.
final class HeadsetEarconPlayer: EarconPlaying {
    private var players: [Earcon: AVAudioPlayer] = [:]

    init() {
        for earcon in [Earcon.listening, .sent, .error, .cancelled] {
            players[earcon] = try? Self.makePlayer(for: earcon)   // sine/blip → temp file → prepareToPlay
        }
    }

    func play(_ earcon: Earcon) {
        guard let player = players[earcon] else { return }
        player.currentTime = 0
        player.play()
    }

    /// Test accessor (reachable via `@testable import`, unlike the `private` cache): which
    /// earcons got a prepared player at init. Lets the isolation test verify construction
    /// without a live audio route or any `private` access.
    var preparedEarcons: Set<Earcon> { Set(players.keys) }

    // makePlayer(for:) synthesizes a 1-channel PCM tone (distinct pitch/shape per earcon)
    // to a temp WAV, mirroring setupKeepAlive's temp-file approach. Omitted for brevity.
}
#endif
```

Injection on the manager — macOS-only, beside the existing `sessionScheduleWork` /
`sendVoicePrompt` seams (which are themselves inside the manager's `#if os(macOS)` block):

```swift
#if os(macOS)
/// Audible-cue player. Test seam: defaults to the headset player; tests inject a spy.
var earconPlayer: EarconPlaying = HeadsetEarconPlayer()
#endif
```

**Error/edge cases (which transitions emit which earcon).** "Errors" here are loop
failures, not status codes:

| Earcon | Emitted on (reducer transition / executor) |
|---|---|
| `.listening` | reducer — every recording-start transition (`beginRecording`): idle-start *and* UI barge-in |
| `.sent` | **executor** — in `apply(.sendPrompt)`, **only when the send is confirmed** (`sent == true`) |
| `.error` | reducer — `(.finalizing, .transcription(nil))` (nothing recognized) · `(.awaitingResponse, .awaitTimedOut)` · `(.awaitingResponse, .backendUnavailable)`; **executor** — not-connected guard |
| `.cancelled` (optional) | reducer — `(.speaking, .tap/.doubleTap)` dismiss, `(.awaitingResponse, .tap/.doubleTap)` dismiss |

**Why `.sent` is executor-side, not a reducer effect.** The reducer transitions to
`.awaitingResponse` and emits `.sendPrompt` **optimistically** — it cannot know whether the
send actually succeeds. If `.sent` were a reducer effect alongside `.sendPrompt`, a *failed*
send would play `.sent` and then, because `apply(.sendPrompt)` feeds `.backendUnavailable`
back in (which emits `.error`), the user would hear a contradictory **"sent" → "error"**.
Emitting `.sent` from the executor *only on confirmed send* (`sent == true`) makes the cue
truthful: a failed send plays `.error` alone.

**Note on `.error` for `backendUnavailable`.** This fires on *any* client disconnect during
`.awaitingResponse` — including a transient network blip or app backgrounding, not only a
user-meaningful failure (it is the F4 strand-exit; the prompt may still be in flight). This
is intended, but if it proves noisy in practice it can be debounced (suppress the cue when
reconnection succeeds within a short window). Flagged here as a known UX trade-off.

**Breaking changes / deprecation:** none. The effect is additive; existing transitions
are unchanged except for appended effects. Off by setting → no behavior change at all.

### Code Examples

**Happy path — recording start emits the cue (reducer `beginRecording`).** The reducer
declares intent; the executor owns play/warm sequencing (see §"The listening cue and SCO
warm-up").

```swift
private static func beginRecording(source: ButtonSource,
                                   interrupting: [SessionEffect]) -> (SessionState, [SessionEffect]) {
    var fx = interrupting
    if source == .blueParrottBLE { fx.append(.suspendKeepAlive) }   // BLE-only (F2), unchanged
    fx.append(contentsOf: [.startCapture, .playEarcon(.listening),
                           .armTimer(.captureGrace), .updateNowPlaying])
    return (.recording, fx)
}
```

**Happy path — empty-capture error (the `.finalizing` reducer transition).** The success
branch emits `.sendPrompt` but **no** earcon — the send cue is the executor's job (below).

```swift
case (.finalizing, .transcription(let text)):
    if let text, !text.trimmed.isEmpty {
        return (.awaitingResponse,
                [.sendPrompt(text), .armTimer(.awaitResponse), .updateNowPlaying])
    }
    return (.idle, [.playEarcon(.error), .updateNowPlaying])   // nothing recognized → "didn't catch that"
```

**Happy path — `.sent` on a confirmed send (executor `apply(.sendPrompt)`).** Extends the
existing send case so the cue only plays when the send actually went; a failed send still
unstrands via `.backendUnavailable` (which the reducer turns into `.error`), so the user
never hears a misleading "sent".

```swift
case .sendPrompt(let text):
    let sent = sendVoicePrompt?(text) ?? buildAndSend(text)
    if sent {
        playCue(.sent)                           // confirmed → "got it" (playCue gates on the setting)
    } else {
        handleSystemEvent(.backendUnavailable)   // no active session → reducer plays .error, not .sent
    }
```

**Error handling — no/late response (F4 strand exits already route here).**

```swift
case (.awaitingResponse, .awaitTimedOut), (.awaitingResponse, .backendUnavailable):
    return (.idle, [.cancelTimer(.awaitResponse), .playEarcon(.error), .updateNowPlaying,
                    .log("await ended — re-enabling button (prompt still in flight)")])
```

**Executor — apply the effect via the single gated play site.** `playCue` is the *one*
place the setting (and headset-engagement, already guaranteed upstream by
`handleButtonEvent` / `handleSystemEvent`) is checked, so no current or future play site can
forget the gate.

```swift
case .playEarcon(let earcon):
    playCue(earcon)

// …elsewhere in the macOS executor extension…

/// The ONE gated entry point for audible cues. Quiet on the desktop and when the user
/// opted out; every call site (reducer effects, confirmed-send, not-connected guard) routes
/// through here.
private func playCue(_ earcon: Earcon) {
    guard settings.headsetAudibleCuesEnabled else { return }
    earconPlayer.play(earcon)
}
```

**Edge case — a press that can't send (not connected) cues `.error` at the executor seam,**
since this guard returns before the reducer runs:

```swift
if beginsRecording(event, source: source), !client.isConnected {
    hLogWarning("Session: \(event) ignored — not connected to backend")
    playCue(.error)
    return
}
```

#### The `listening` cue and the SCO warm-up (phased)

The reducer always emits `.playEarcon(.listening)` at recording start; **the executor
decides how to sequence the tone against capture**, so the reducer (and its tests) are
identical across phases:

- **Phase 1 — confirmation tone.** `play(.listening)` fires concurrently with
  `startCapture`. It confirms "recording started" but does not fix the dead zone. Low risk,
  fully testable, ships first.
- **Phase 2 — warm-up primer.** The same `.listening` tone is played *into the HFP route*
  to force the SCO link active during its ~0.6–1 s warm-up. The existing
  `captureGrace`/`restart` logic (`CaptureReadiness.graceOutcome`) already tolerates the
  cold window; the tone occupies it and its tail-end is the user's "speak now" moment. The
  tone is short and is a pure tone, so even if a few buffers of it are captured, recognition
  ignores it. No reducer change — only `HeadsetEarconPlayer` gains the warm-route timing.

### Component Interactions

Flow of one full loop (BLE or UI source identical downstream):

```
button tap / mic-button         BlueParrottGestureRecognizer | toggleRecordingFromUI
      └─► handleButtonEvent(event, source)
           └─► SessionReducer.reduce ─► [.suspendKeepAlive?, .startCapture,
                                          .playEarcon(.listening), .armTimer(.captureGrace), …]
                 └─► apply(.playEarcon(.listening)) ─► playCue ─► earconPlayer.play ─► AVAudioPlayer ─► HFP/headset
                 └─► apply(.startCapture)          ─► voiceInput.startRecording()
   …user speaks…
   stop (tap / hold-release / silence-autofinalize)
      └─► .stopCapture ─► transcription(text?)
           └─► reduce(.finalizing, .transcription) ─► [.sendPrompt, …]   (no optimistic cue)
                 └─► apply(.sendPrompt): send ─► if confirmed: playCue(.sent)
                                               └─ else: handleSystemEvent(.backendUnavailable) ─► .error
   awaitingResponse ─ttsStarted─► speaking          (the TTS response is itself the "done" cue)
   — or — awaitTimedOut/backendUnavailable ─► idle + reducer .playEarcon(.error)
```

Integration points & dependencies:
- **Reducer** (`HeadsetSessionReducer.swift`): adds `Earcon`, `playEarcon`, and the
  `.listening`/`.error` emissions. Pure. (`.sent` is *not* a reducer effect — see below.)
- **Executor** (`HeadsetRemoteCommandManager.swift`): the `.playEarcon` apply case, the
  `.sent`-on-confirmed-send in `apply(.sendPrompt)`, one injected `earconPlayer` seam, and
  the not-connected-guard cue. Depends on `AppSettings`.
- **`HeadsetEarconPlayer`**: depends only on `AVFoundation`; reuses the keep-alive route
  pattern. Coexists with `keepAlivePlayer` under `.playAndRecord`.
- **`AppSettings`**: new `headsetAudibleCuesEnabled` flag; toggle surfaced in
  `MacSettingsView`.

## 4. Verification Strategy

### Testing Approach
- **Unit (primary) — reducer earcon emission.** `SessionReducer.reduce` is pure; table-test
  that each relevant `(state, event, source)` yields the right `.playEarcon(...)` in its
  effect list, and that unrelated transitions emit none. Runs under both `make test` and
  `make test-mac`.
- **Unit — executor seam + gating.** Extend the existing macOS harness: add an `earconPlayer`
  seam to `HeadsetRemoteCommandManager` (macOS) and an `EarconSpy` field to the test
  `Fixture`/`makeFixture` (alongside `sessionScheduleWork`). Drive a full record→send loop and
  assert the *ordered* earcons — `[.listening, .sent]` on a **confirmed** send and
  `[.listening, .error]` (never `.sent`) on a **failed** send. Assert `headsetAudibleCuesEnabled
  == false` ⇒ the spy records nothing, and that the not-connected guard plays `.error`.
- **Unit — player isolation.** `@testable`-assert that constructing `HeadsetEarconPlayer()`
  prepares a player for every shipped cue —
  `XCTAssertTrue(HeadsetEarconPlayer().preparedEarcons.isSuperset(of: [.listening, .sent, .error]))`
  — via the internal `preparedEarcons` accessor (no live route or `private` access needed;
  `AVAudioPlayer(contentsOf:)` + `prepareToPlay()` only loads the synthesized temp file).
- **Integration — no regression.** Existing reducer + `HeadsetRemoteCommandManagerMacTests`
  pass unchanged except for the added effects; the cross-source/barge-in tests still hold.
- **End-to-end (manual, hardware).** On the B450-XT II: hear `.listening` on press,
  `.sent` after speaking, `.error` on an empty capture, all **in the headset** (not the Mac
  speaker); confirm the `.listening` tone is **not** transcribed into the prompt.

### Test Examples

```swift
final class SessionReducerEarconTests: XCTestCase {
    func testRecordingStart_emitsListeningEarcon() {
        let (state, fx) = SessionReducer.reduce(.idle, .tap, source: .ui)
        XCTAssertEqual(state, .recording)
        XCTAssertTrue(fx.contains(.playEarcon(.listening)))
    }

    func testNonEmptyTranscription_emitsSend_butNoReducerEarcon() {
        // `.sent` is the executor's job (confirmed-send only), so the reducer emits the send
        // intent but NO earcon here — the success-path cue is asserted in the executor tests.
        let (state, fx) = SessionReducer.reduce(.finalizing, .transcription("hello"), source: .blueParrottBLE)
        XCTAssertEqual(state, .awaitingResponse)
        XCTAssertTrue(fx.contains(.sendPrompt("hello")))
        XCTAssertFalse(fx.contains(where: { if case .playEarcon = $0 { return true }; return false }))
    }

    func testEmptyTranscription_emitsErrorEarcon() {
        let (state, fx) = SessionReducer.reduce(.finalizing, .transcription(nil), source: .blueParrottBLE)
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(fx.contains(.playEarcon(.error)))
    }

    func testAwaitTimeout_emitsErrorEarcon() {
        let (state, fx) = SessionReducer.reduce(.awaitingResponse, .awaitTimedOut, source: .blueParrottBLE)
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(fx.contains(.playEarcon(.error)))
    }

    func testSpeakingState_noEarconOnTtsEnd() {   // negative: silence transitions stay silent
        let (_, fx) = SessionReducer.reduce(.speaking, .ttsEnded, source: .blueParrottBLE)
        XCTAssertFalse(fx.contains(where: { if case .playEarcon = $0 { return true }; return false }))
    }
}

/// Records played earcons in order. The whole test double (mirrors the existing mock
/// pattern in HeadsetRemoteCommandManagerMacTests).
final class EarconSpy: EarconPlaying {
    private(set) var played: [Earcon] = []
    func play(_ earcon: Earcon) { played.append(earcon) }
}

// Uses the real macOS harness in HeadsetRemoteCommandManagerMacTests: `makeFixture(...)`
// returns `Fixture(manager, input, output, client, central, settings)`; state is read via
// `manager.testSessionState`; `drainMainQueue()` is a test-CASE method (not on `f`). This
// suite requires extending the harness: add `var earconPlayer: EarconPlaying` to the manager
// (macOS), then in makeFixture do `let spy = EarconSpy(); manager.earconPlayer = spy` and
// surface it on `Fixture` (as `f.earconSpy`), the same way `sessionScheduleWork` is injected.
final class HeadsetEarconExecutorTests: XCTestCase {
    func testConfirmedSend_playsListeningThenSent_inOrder() {
        let f = makeFixture()                                        // engaged, connected, sync timers
        f.settings.headsetAudibleCuesEnabled = true
        f.input.transcribedText = "do the thing"                     // non-empty → buildAndSend succeeds
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // idle → recording (.listening)
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // recording → finalizing → send
        drainMainQueue()                                             // transcription read + send settle
        XCTAssertEqual(f.manager.testSessionState, .awaitingResponse)
        XCTAssertEqual(f.earconSpy.played, [.listening, .sent])
    }

    func testFailedSend_playsListeningThenError_neverSent() {
        let f = makeFixture(resolveSession: { nil })                 // connected, but no active session → send fails
        f.settings.headsetAudibleCuesEnabled = true
        f.input.transcribedText = "do the thing"
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)
        drainMainQueue()
        XCTAssertEqual(f.manager.testSessionState, .idle)            // backendUnavailable unstrands (F4)
        XCTAssertEqual(f.earconSpy.played, [.listening, .error])     // no contradictory .sent
    }

    func testNotConnectedGuard_playsError_onPress() {
        let f = makeFixture(connected: false)
        f.settings.headsetAudibleCuesEnabled = true
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // guard blocks recording
        XCTAssertEqual(f.manager.testSessionState, .idle)
        XCTAssertEqual(f.earconSpy.played, [.error])
    }

    func testCuesSuppressedWhenSettingOff() {
        let f = makeFixture()
        f.settings.headsetAudibleCuesEnabled = false
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)
        XCTAssertEqual(f.earconSpy.played, [])
    }
}
```

### Acceptance Criteria
1. `Earcon` enum and `SessionEffect.playEarcon(Earcon)` exist; `SessionEffect` stays
   `Equatable`.
2. The reducer emits `.playEarcon(.listening)` on **every** recording-start transition (idle
   start and UI barge-in) and `.playEarcon(.error)` on empty transcription, `awaitTimedOut`,
   and `backendUnavailable`. It does **not** emit `.sent` — the executor plays `.sent` in
   `apply(.sendPrompt)` **only when the send is confirmed** (`sent == true`).
3. Reducer table tests cover criterion 2, including that the success branch
   (`(.finalizing, .transcription(text))`) emits `.sendPrompt` with **no** earcon, plus a
   negative case (a silent transition emits none).
4. An injected `EarconPlaying` seam drives playback; executor tests assert the **ordered**
   `[.listening, .sent]` for a confirmed-send loop and `[.listening, .error]` (never `.sent`)
   for a failed send, using a spy.
5. `headsetAudibleCuesEnabled == false` ⇒ no earcon reaches the player (executor test); a
   toggle exists in `MacSettingsView`.
6. The executor not-connected guard plays `.error`.
7. Earcons play **through the headset** route (manually verified) and the `.listening`
   tone is **not** transcribed into the prompt.
8. `make test`, `make test-mac`, and `make build-mac` are green; existing reducer/manager
   tests pass with no behavioral regression.

## 5. Alternatives Considered

1. **Observe `state` changes in the manager (Combine sink) and play sounds there**, instead
   of a reducer effect. *Rejected:* scatters the "which cue when" logic outside the single
   greppable reducer, can't be unit-tested purely, and bypasses the established effect
   pattern. The effect approach keeps the decision pure and the playback a thin seam.
2. **Spoken TTS micro-cues** ("listening", "sent"). *Rejected as default:* higher latency,
   verbose with repetition, and they collide with the TTS **response** channel (the thing
   the user actually wants to hear). *Kept* as a future accessibility option behind the same
   `Earcon` abstraction (the player could synthesize speech instead of tones).
3. **macOS system sounds (`NSSound` "Tink"/"Basso")**. *Rejected:* they route to the default
   output, not reliably the HFP headset, and are generic/unbrandable. The whole point is
   in-ear feedback for a driver.
4. **Bundled recorded audio assets (.caf)**. *Deferred, not rejected:* nicer/brandable, but
   adds an asset pipeline and bundle weight. Runtime-synthesized tones mirror the existing
   `setupKeepAlive` temp-file approach with zero assets; assets can drop in behind
   `HeadsetEarconPlayer` later without touching the reducer.
5. **Tie `.listening` to `captureProducedAudio` (first non-silent buffer)** rather than to
   recording-start. *Rejected:* that signal only fires *after* the user has already spoken
   (it is their voice), so it can't be a "speak now" prompt. The warm-up-primer design
   (§3) puts the cue *before* speech and uses it to warm the route.
6. **Do nothing / rely on the screen.** *Rejected:* defeats the hands-free/driving use case
   and leaves the SCO dead-zone failure silent.

**Trade-off of the chosen approach.** A reducer effect + injected player is maximally
testable and consistent with the codebase, but it does spread a little earcon-specific
logic into the pure reducer (the `.playEarcon` emissions) and requires the executor to own
the subtle warm-up/route timing. We accept this: the alternative (manager-side observation)
trades that small coupling for untestable, scattered playback.

## 6. Risks & Mitigations

1. **Earcon captured by the mic (acoustic/electrical feedback into the prompt).**
   *Detect:* the `.listening` tone or a stray blip appears in `transcribedText`; manual
   listen-back. *Mitigate:* `.sent`/`.error` play after `stopCapture` (mic closed);
   `.listening` is a short pure tone during warm-up that recognition discards; keep tone
   energy modest. If it still bleeds, gate `.listening` to play only *before* the recognizer
   starts counting audio.
2. **Earcon plays on the Mac speaker, not the headset.** *Detect:* `HeadsetEarconPlayer`
   logs the resolved output route at play time (as `setupKeepAlive` already logs outputs);
   manual check. *Mitigate:* construct/prepare the `AVAudioPlayer` under
   `.playAndRecord`/`.allowBluetoothA2DP` exactly like `keepAlivePlayer`; (re)prepare after
   any category change.
3. **Collision with the keep-alive silent player** (two `AVAudioPlayer`s). *Detect:*
   keep-alive stops or the earcon is dropped. *Mitigate:* both run under `.playAndRecord`;
   the earcon is a brief one-shot over the silent loop — covered by the executor test and a
   manual back-to-back press check.
4. **SCO half-duplex contention** — playing out while capturing in on the same SCO channel.
   *Detect:* warm-up restarts increase or first-audio latency worsens *with* earcons on.
   *Mitigate:* Phase 1 keeps the tone tiny; Phase 2 sequences the primer into the existing
   warm-up window; compare `firstAudio`/restart counts in capture summaries with cues on vs
   off.
5. **Annoyance / over-cueing.** *Mitigate:* minimal 3-cue set, the `headsetAudibleCuesEnabled`
   toggle, and desktop silence (only when engaged). `.cancelled` ships only if wanted.
6. **Latency on first play.** *Mitigate:* synthesize + `prepareToPlay()` all tones once at
   init so `play()` is immediate.
7. **Contradictory / untruthful cues** — e.g. an optimistic "sent" immediately followed by
   "error" on a failed send. *Detect:* the `testFailedSend_*` executor test asserts
   `[.listening, .error]` with no `.sent`. *Mitigate (by design):* `.sent` is played by the
   executor only on a confirmed send (`sent == true`), never by the reducer alongside the
   optimistic `.sendPrompt` (see §3 "Why `.sent` is executor-side").

### Rollback strategy
The feature is gated by `headsetAudibleCuesEnabled` (ship defaulting **off**, or off until
Phase 1 is validated on hardware). The `.playEarcon` effect is additive and inert when
unhandled/ungated, so disabling the toggle — or reverting the small executor `apply` case —
fully restores prior behavior with no data or protocol implications.
