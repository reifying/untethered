# Code review of the vibrate-speech fix — findings

**Date:** 2026-09-22 · Review of the uncommitted change described in `vibrate-speech-bug-2026-09-22.md`.
**Resolved.** Everything below was acted on; the working tree now holds the revised change. See
`vibrate-speech-bug-2026-09-22.md` for the final shape. Dispositions are recorded at the end.

## What the review confirmed

- Root cause, regression commit (`e4dbb860`), the pure-function split, and the Android assessment all
  check out against the tree.
- Platform compilation is fine — `project.yml` already excludes `DeviceAudioSessionManager.swift` and
  both touched test files from the macOS targets, so no `#if os(iOS)` is needed in the new code.
- `HeadsetIOSAudioSessionTests.testTTSEnd_reassertsAudioSession` is independent of this change: it
  drives `MockVoiceOutputForHeadset.isSpeaking` directly and never calls `speakWithVoice`, so no line
  of the diff executes during it. (I had already confirmed it fails identically at `HEAD`.)
- Test runs reproduced: `DeviceAudioSessionManagerTests` 17/17, `VoiceOutputManagerTests` 21/21,
  `make build-mac` succeeded.

## The defects worth acting on

### 1. The headset re-assert can undo `.ambient` on a live utterance — reproduces the original bug

`HeadsetRemoteCommandManager.swift:252-260` re-asserts `.playAndRecord` on **any** `isSpeaking → false`
whose category isn't already `.playAndRecord`. It has no way to know a *new* utterance is already
speaking under a category we deliberately chose.

`VoiceOutputManager.speakWithVoice` preempts the previous utterance (`:227-229
stopSpeaking(at: .immediate)`) and sets the new category synchronously, but `didCancel` for the
preempted utterance arrives later and posts `isSpeaking = false` asynchronously — the file's own
comment at `:48-55` documents exactly this late-delivery race, and `stop(completion:)` budgets 300 ms
for it.

**Failure:** headset control on, no headset in the route, ringer on silent. Two assistant messages land
back-to-back (`SessionSyncManager.swift:767` fires per message). Message 2 preempts message 1, sets
`.ambient`, starts speaking. Message 1's `didCancel` lands tens of ms later → observer sees
`category != .playAndRecord` → `activateAudioSession()` → message 2 is now under `.playAndRecord` and
**speaks out loud on vibrate.** The `.speaking → .ready` branch at `:248-251` reaches the same call.

This is the bug the change exists to fix, resurrected through the "self-heal" the note relied on.
Verified against the source; the note's framing of that heal as purely a safety net is wrong.

### 2. `.leaveHeadsetSession` asserts an invariant it never checks

`speechSessionPlan` returns `.leaveHeadsetSession` from the `headsetModeEnabled` **setting**, not from
the live session state, and the call site then touches nothing on the assumption the session is
`.playAndRecord`.

**Failure, and it contradicts the caption I added:** headset control on, no headset, ringer silent. An
automatic reply takes `.respectSilentSwitch` → session is `.ambient`. The user taps **Read Aloud** on
that message (`ConversationView.swift:1690`, `respectSilentMode: false`) → plan is
`.leaveHeadsetSession` → nothing changes → still `.ambient` → **silent**. The new Settings caption says
"Tapping Read Aloud yourself always speaks."

Same shape at launch: `activate()` runs off a `.receive(on: .main)` sink, so there's a window where
`headsetModeEnabled == true` but the session is still iOS's default `.soloAmbient` — which the ringer
switch *does* silence.

Fix for both 1 and 2: feed the live category into the plan and only return `.leaveHeadsetSession` when
the session actually is `.playAndRecord`; and give the observer a way to skip while speech is in flight.

### 3. The port table includes three routes that are rooms, not ears

`.airPlay`, `.HDMI` and `.lineOut` are in `privateListeningPorts`. AirPlay means a HomePod or Apple TV;
HDMI means a television; lineOut means a dock or desk speaker. All three are shared rooms, so the new
rule is **strictly worse than the old one** there: phone on silent, casting to the living-room speaker,
agent reply read out to everyone.

Cut those three. Keep `.headphones`, `.bluetoothA2DP`, `.bluetoothHFP`, `.bluetoothLE`, `.carAudio`,
`.usbAudio`. `.bluetoothA2DP` stays knowingly permissive — iOS reports it for a JBL on a conference
table as well as for AirPods, and no API distinguishes them. That residual risk should be in the
caption, which currently doesn't mention it.

### 4. `.ambient` is also silenced by screen lock, overriding `continuePlaybackWhenLocked`

Inherent to the category, not new in general — but **new for headset-mode users**. Pre-fix, headset
mode kept `.playAndRecord` and TTS played through a locked screen; post-fix, headset mode with no
headset in the route takes `.ambient` and goes silent when locked **even with the ringer on loud**.
`e4dbb860` deleted the comment that used to document this coupling; the new code and the note both
omit it. There is no way to honour the switch and play when locked at the same time — the honest
move is to document the trade-off and decide which default wins.

## Smaller correctness items

- **New early-return can wedge the headset state machine.** `VoiceOutputManager.swift:268-271` returns
  without speaking on a session-config throw. Headset users never reached a `setCategory` here before,
  so this was unreachable for them; now `isSpeaking` never goes true, `HeadsetRemoteCommandManager:245`
  never advances `.sending → .speaking`, and there's no timeout out of `.sending`.
- **The route is read twice.** `DeviceAudioSessionManager.swift:58` feeds the decision;
  `VoiceOutputManager.swift:247` reads `currentRoute` again for the log line. If the route moves
  between them, the log disagrees with the decision it exists to explain — which is exactly what
  on-device check #2 tells Travis to trust. Use one snapshot.
- **The route is read under the previous category.** `currentRoute` is a function of the current
  category and options; under `.playAndRecord` with no `.defaultToSpeaker` the built-in output resolves
  to `.builtInReceiver`, not `.builtInSpeaker`. Both are non-private so the decision is unchanged
  today, but the classification is made against a route the utterance won't use.
- **Empty route maps to "stay quiet."** On a cold launch `currentRoute.outputs` can be empty, so the
  first automatic reply goes `.ambient` even with headphones connected. Conservative in the meeting
  direction, wrong in the driving direction. At minimum log "route unknown" distinctly so check #2 can
  tell it from an unrecognised port.
- **Keep-alive dies during an `.ambient` utterance.** `configureAudioSessionForSilentMode` resets
  options to `[]`, and the existing test `testStartRecording_keepAliveActiveUnderPlayAndRecord`
  documents that a category switch silently kills a prepared `AVAudioPlayer`. It rebuilds on TTS end,
  but a stem press *during* a long silenced reply may not be delivered. "No headset attached → nothing
  to lose" holds only if "not in the output route" equals "not connected", which it doesn't — a device
  paired HFP-only keeps AVRCP while the route stays built-in.
- **`didFinish` teardown is now inconsistent with the speak path.** `VoiceOutputManager.swift:406-414`
  is still keyed on `headsetModeEnabled != true` while the speak path stopped being. The speak path can
  set `.ambient` under headset mode; the teardown refuses to touch the session under headset mode. It
  only works because the observer heals it — see defect 1.

## Test gaps

- **`testHeadsetModeKeepsSessionWhenSilentModeRespectIsOff` doesn't pin what it claims.** It pre-sets
  `.ambient` and asserts `.ambient`; `.respectSilentSwitch` would pass too, as would a `speakWithVoice`
  that did nothing at all. Pre-set `.playAndRecord` and assert it's still `.playAndRecord`.
- **No seam for the route, so the two cases that actually changed behaviour are untested end-to-end.**
  "headphones + vibrate → speaks" and "headset mode + headset → session untouched" are covered only by
  the pure function, never through `speak`. A closure seam (`var outputIsPrivateListening: () -> Bool`)
  matches the pattern already used for `prefersBluetoothHFPInput` / `isBlueParrottConnected`.
- `outputIsPrivateListening()` itself has no tests — the static classifier is covered, the live reader
  that feeds it isn't.
- **Pre-existing tests quietly became route-dependent.** Four category assertions in
  `VoiceOutputManagerTests` now pass only because the simulator's route classifies as non-private.
- `testHeadsetAndCarRoutesArePrivateListening` iterates 7 of the 9 ports; `.lineOut` and `.HDMI` are
  untested — and they're the two most questionable entries (see defect 3).
- No test for `appSettings == nil` (the `?? true` defaults).
- Nothing tests defect 1. A test with a real `HeadsetRemoteCommandManager` and real
  `VoiceOutputManager` sharing one `AppSettings`, speaking twice back-to-back and asserting the
  category after the second `speak`, would have caught it.

## Design concerns worth a decision, not a patch

- **This deliberately diverges from the platform.** iOS silences `.ambient` regardless of route, so
  "headphones connected, ringer on silent" means silence in every other app on the phone. Defensible
  here, but the only place it's disclosed is the Settings caption.
- **It couples "should we speak" to "where does output go right now" — which is under active change.**
  The macOS BlueParrott work parks system output *off* the headset so the HFP mic isn't starved. If
  iOS follows, `currentRoute` reports built-in while the headset is worn, the plan becomes
  `.respectSilentSwitch`, and the driving case goes silent — the exact failure this change exists to
  prevent. A connection signal is more stable than the output route for "is the user wearing something".
- **Earcons are now inconsistent.** `HeadsetRemoteCommandManager.playCue:694` is gated only by
  `headsetAudibleCuesEnabled` and plays through whatever session is live, so cue audibility became an
  accident of what TTS last did. Default is off, so low stakes, but the inconsistency is new.
- `.builtInReceiver` is classified as "the room" — the earpiece is an ear, and the comment says
  otherwise. Harmless today because nothing routes speech there.

## Corrections to the original note

- **Keep-alive is not digital silence.** `HeadsetRemoteCommandManager.setupKeepAlive:861-889`
  synthesizes a 20 Hz sine at amplitude 0.0001 (-80 dB) precisely *because* pure zeros don't register
  with the Now Playing heuristic. Inaudible either way, but the stated reason was wrong. Verified.
- The note says "+11" tests for `DeviceAudioSessionManagerTests`; it's +13 (17 total, 4 pre-existing).
- The truth table needs a lock-screen column — every `.ambient` row also means "silenced when the
  screen is locked, overriding `continuePlaybackWhenLocked`".
- The note calls the observer's re-assert a self-heal; it's also the mechanism of defect 1.
- "Manual Read Aloud always speaks" is not true under headset mode — defect 2.
- The truth table has no row for "route unknown/empty", which resolves to `.ambient`.
- The caveat about whether **Enable headset control** is actually on in the real install should stay
  front and centre: if it's off, the reported symptom is the headphones case, and this change makes
  that case *louder*, not quieter.

---

## Disposition

**Fixed:**

- **Defect 1 (stale stop re-asserts under live speech)** — fixed at the *publisher*, not in the
  observer. `VoiceOutputManager` tags each utterance with a monotonic generation and publishes
  `isSpeaking = false` only for the newest one (`publishStopped(generation:)`). Every subscriber
  benefits, including the macOS session reducer, which had the same exposure.
  - Worth recording: the first attempt guarded the observer on `synthesizer.isSpeaking`, and the test
    for it **failed on its own precondition** — `synthesizer.isSpeaking` flips true asynchronously,
    tens of ms after `speak()` returns, so it reads false during exactly the window that matters. That
    guard would have failed open in production. The test catching it is why the generation approach
    exists.
  - Follow-on: `stop(completion:)` used the same lagging signal, so it could fire its completion for a
    queued-but-not-started utterance and let `VoiceInputManager` reconfigure the session out from under
    speech about to start. Now consults `hasUtteranceInFlight`.
- **Defect 2 (`.leaveHeadsetSession` unchecked)** — the plan now takes `headsetSessionIsLive`
  (setting **and** live `.playAndRecord`), so Read Aloud under headset mode forces `.playback` rather
  than sitting mute in `.ambient`, and the launch window is covered.
- **Defect 3 (rooms in the port table)** — `.airPlay`, `.HDMI`, `.lineOut` removed. `.bluetoothA2DP`
  kept and its ambiguity disclosed in the caption.
- **Double route read** — one snapshot feeds both the decision and the log.
- **Empty route** — logs as `unknown/empty` so it is distinguishable from an unrecognised port.
- **Weak test** — `testLiveHeadsetSessionIsKeptWhenSilentModeRespectIsOff` now starts from
  `.playAndRecord`, so "untouched" is distinguishable from "moved" and from "did nothing".
- **Missing coverage** — route test seam added; both behaviour-changing cases now covered end-to-end
  through `speak`; `.airPlay`/`.HDMI`/`.lineOut`, the nil-settings default, and the preempt race all
  have tests. The port-table test asserts its own completeness by count.

**Documented, not changed** (each is a real cost, recorded in the note's "Known, accepted costs"):

- **Defect 4 (lock screen)** — `.ambient` is silenced by lock as well as by the switch, so it overrides
  `continuePlaybackWhenLocked`. The two cannot both be honoured. Quiet wins by default; which one
  should win is Travis's call, not mine.
- **Early-return wedge** — kept the drop (safe direction for a noise bug), now logged with `❌` and the
  full decision context so the `.sending` wedge is diagnosable from the log.
- **Keep-alive death during an `.ambient` utterance**, and the **earcon inconsistency**.
- **`didFinish` teardown still keyed on the setting** — deliberate, and now commented: tearing the
  session down remains the headset manager's call.
- **Route-vs-connection fragility** — if iOS follows macOS in parking output off the headset, the
  route stops meaning "is the user wearing something". Recorded as the thing to revisit first if the
  driving case ever goes quiet.
- **`.builtInReceiver` classified as "the room"** — comment now says ears *and cars*, not "an ear", so
  it no longer contradicts itself.

**Corrections applied to the original note:** the keep-alive tone (a 20 Hz sine at -80 dB, not digital
silence), the test counts, the lock-screen column in the truth table, the Read Aloud claim, the
unknown-route row, and the framing of the observer's re-assert as a mechanism of defect 1 rather than
a safety net.

---

# Round 2

A second review of the revised change. It confirmed the round-1 fixes were the right shape and found
that the generation guard had been applied too narrowly, plus two session-state assumptions.

## Fixed

- **The guard covered one line of four.** `didFinish`/`didCancel` still ran
  `firePendingStopCompletion()` (releasing `VoiceInputManager` to start recording under live speech),
  `clearInFlightIfMatches` (breaking focus-change cancellation for a batch of same-session replies),
  `stopKeepAliveTimer()` (killing the live utterance's timer) and the deactivate-on-finish path, all
  unguarded. The guard is now over the whole callback body.
- **The preempt site still used `synthesizer.isSpeaking`** — the exact signal this change declares
  unusable — so in the lag window a second reply did not preempt but *queued*, and both utterances
  played under whichever category the last speak set. `.ambient` reply then `.playback` Read Aloud =
  spoken aloud on vibrate. Now `synthesizer.isSpeaking || hasUtteranceInFlight`, as `stop` already was.
- **`stop`'s idle branch** cleared the in-flight flags with no generation guard. Now routed through the
  same check.
- **Deciding from the live category was wrong too.** The category survives deactivation, so
  `.playAndRecord` can be set on an inactive session (an interruption ending without `.shouldResume`
  leaves exactly that) and the utterance is silent; and a drifted category fell through to `.playback`,
  dropping the Bluetooth output options and re-triggering the Now Playing re-evaluation `e4dbb860`
  avoids. The plan now takes the setting and `configureAudioSessionForHeadsetPlayback` repairs the
  session — rebuilding only a drifted category, preserving the headset manager's options otherwise,
  and always re-activating.
- **Failure policy split by plan.** Dropping the utterance is right for `.respectSilentSwitch` and
  wrong for the other two, where it silences the driving case and wedges the state machine.
- **The race test could pass for the wrong reason** — its mechanism depended on the synthesizer having
  started, and nothing observed that a cancel had occurred. It now waits on a dropped-stale-end
  counter. Both race tests poll for conditions instead of sleeping fixed intervals.
- **Test hygiene**: `MockVoiceOutputForHeadset.stop()` doesn't call super, so the tests now quiesce
  through `stop(completion:)` and wait for the synthesizer to idle rather than leaking a live
  utterance into the next test.
- **Dropped gaps from round 1, now closed**: the four pre-existing tests that had silently become
  route-dependent pin the route explicitly, and the live route reader has a test of its own.
- `.removeDuplicates()` on the headset observer, so it stops reacting to redundant repeats rather than
  relying entirely on the publisher's suppression.

## Documented, not changed

- `.usbAudio` shares the Bluetooth speaker/headphone ambiguity; the caption now covers wired adapters.
- The route is classified under the category in force before the switch — inert today, recorded.
- `didStart` is not generation-guarded; it only sets `isSpeaking` true, which `speakWithVoice` has
  already done.

## Judgement calls the review raised

It agreed the publisher is the right layer for the stale stop — two subscribers with different
reactions, one of them a macOS reducer, so a per-observer fix would have to be written twice and kept
in sync. And it accepted the lock-screen trade-off, the A2DP ambiguity, the earcon inconsistency and
the route-vs-connection fragility as genuine decisions rather than disguised bugs.
