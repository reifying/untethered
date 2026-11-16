# Speech plays while the phone is on vibrate — root cause and fix

**Date:** 2026-09-22 · **Branch:** `main` (3 commits ahead of origin, untouched) · **Status:** fix applied, uncommitted and unstaged

## Root cause, in one line

`VoiceOutputManager.speakWithVoice` wrapped the entire silent-mode decision in
`if appSettings?.headsetModeEnabled != true`, so with **Enable headset control** on, the
`respectSilentMode` setting was never consulted and the session stayed in `.playAndRecord` —
a category iOS deliberately does *not* silence with the ringer switch.

`ios/VoiceCode/Managers/VoiceOutputManager.swift:237` (pre-fix):

```swift
// When headset mode is active, HeadsetRemoteCommandManager owns the audio
// session in .playAndRecord — switching to .playback/.ambient here would
// cause iOS to re-evaluate the Now Playing slot ...
if appSettings?.headsetModeEnabled != true {
    let shouldRespectSilentMode = respectSilentMode && (appSettings?.respectSilentMode ?? true)
    if shouldRespectSilentMode {
        try audioSessionManager.configureAudioSessionForSilentMode()   // .ambient
    } else {
        try audioSessionManager.configureAudioSessionForForcedPlayback()  // .playback
    }
} else {
    LogManager.shared.log("VoiceOutput: headset mode active — keeping .playAndRecord session", ...)
}
```

Why that silences nothing: iOS gives no API for the ringer switch position. The only lever is the
`AVAudioSession` **category**, and the switch is honoured by exactly one of the three we use:

| Category | Ringer switch | Set by |
|---|---|---|
| `.ambient` | **silences it** | `DeviceAudioSessionManager.configureAudioSessionForSilentMode` |
| `.playback` | ignored | `configureAudioSessionForForcedPlayback` |
| `.playAndRecord` | ignored | `VoiceInputManager.swift:201`, `HeadsetRemoteCommandManager.swift:908` |

With headset mode on, `HeadsetRemoteCommandManager` pins `.playAndRecord` and keeps re-asserting it
(`activate()` at `:376`, after every TTS at `:251`/`:259`, after each recording at `:780`, after
interruptions at `:395`). `speakWithVoice` then declined to change it. Result: the ringer switch was
structurally unreachable for every headset user, and the toggle in Settings did nothing at all.

The auto-speak paths themselves are wired correctly — all three pass `respectSilentMode: true`
(`SessionSyncManager.swift:767`, `:1115`, `:1939`). Nothing was wrong upstream of the audio session.

## Did it regress?

Yes. **`e4dbb860` — "fix(headset): drop .mixWithOthers to prevent audiobook from stealing Now Playing
slot" (2026-05-25).** Before that commit the silent-mode branch ran unconditionally on iOS; that commit
wrapped it in the `headsetModeEnabled` guard. The commit was solving a real problem (AirPod stem
presses being routed to a background audiobook during TTS) and the message says nothing about silent
mode — the silent-mode regression was collateral, not a decision.

The behaviour was correct from `909d50f2` ("Add setting to silence speech when phone is on
vibrate/silent") until `e4dbb860`.

## What the setting actually controlled vs. its label

Label (`SettingsView.swift:100`, pre-fix): **"Silence speech when phone is on vibrate"**, with the
caption "speech will not play when your phone's ringer switch is on silent/vibrate".

What it actually did:

- **Headset control off** — worked as labelled. Automatic responses used `.ambient`; the switch
  silenced them. Note this also silenced them *through connected headphones*, which is the opposite
  of what you want while driving.
- **Headset control on** — did nothing whatsoever. No code path read it.
- Manual **Read Aloud** (`ConversationView.swift:1690`) and the notification **Read Aloud** action
  (`NotificationManager.swift:179`) pass the default `respectSilentMode: false` and always use
  `.playback`. That is deliberate (`35690503`, "Only apply silent mode to automatic speech, not manual
  Read Aloud") and correct, but the label didn't say so.

## The design question: what *should* it do?

The ringer switch is a statement about **the room**, not about an ear you deliberately put a headset
in. Making the existing switch work more forcefully would be wrong: hands-free in the car, with a
headset connected and the phone face-down on the passenger seat, "stay quiet" is not the behaviour you
want — you want the response in your ear and nothing out of the phone.

So the rule is **route-based, not switch-based**:

- Audio would come out of the **phone itself** (built-in speaker or earpiece) → the ringer switch
  wins. This is the meeting case.
- Audio would come out of **something you plugged in or paired** (headphones, any Bluetooth headset,
  CarPlay/car audio, USB, AirPlay) → speak. You chose that route.
- Anything unrecognised → treat as the room and stay quiet. The failure mode being guarded against is
  a phone talking out loud where it shouldn't.

Manual Read Aloud is unchanged: you asked out loud, so it speaks.

## The fix (applied, uncommitted, unstaged)

Seven files (4 source, 3 test), no restructuring of the audio stack. Shape settled over two review
rounds, both of which found the same bug reopening through a different door — see
`vibrate-speech-bug-2026-09-22-review.md`.

### 1. The decision is a pure function, and headset mode no longer short-circuits it

`ios/VoiceCode/Managers/DeviceAudioSessionManager.swift`:

```swift
enum SpeechSessionPlan: Equatable {
    case respectSilentSwitch    // .ambient
    case forcePlayback          // .playback
    case leaveHeadsetSession    // don't touch .playAndRecord
}

static func speechSessionPlan(respectSilentModeRequested: Bool,
                              userRespectsSilentMode: Bool,
                              headsetSessionIsLive: Bool,
                              outputIsPrivateListening: Bool) -> SpeechSessionPlan {
    let mustStayQuiet = respectSilentModeRequested
        && userRespectsSilentMode
        && !outputIsPrivateListening
    if mustStayQuiet { return .respectSilentSwitch }
    return headsetSessionIsLive ? .leaveHeadsetSession : .forcePlayback
}
```

"Must stay quiet" is decided **first and independently of headset mode** — that ordering is the fix.

`.useHeadsetSession` **ensures** that session rather than assuming it. Assuming is what the first cut
did, and it is wrong twice over:

- The **setting** is a statement of intent, not of session state. `HeadsetRemoteCommandManager
  .activate()` runs off a main-queue sink, so there is a launch window where the setting is on and the
  session is still iOS's default — and an `.ambient` utterance leaves it somewhere else entirely.
  Trusting the setting meant manual Read Aloud sat mute in a silenced category, contradicting the
  caption that promises it always speaks.
- The **category** is also not enough, which is what the second review caught. `.playAndRecord`
  survives deactivation, and the headset manager deliberately leaves the session unrestored when an
  interruption ends without `.shouldResume` — so the category can read correct while the session is
  inactive and the utterance is silent. Deciding from the live category also fell through to
  `.playback` whenever it had drifted, throwing away the Bluetooth output options and re-triggering
  precisely the Now Playing re-evaluation `e4dbb860` exists to avoid.

So the plan takes the setting, and `configureAudioSessionForHeadsetPlayback` repairs: it rebuilds the
category only when it has drifted (leaving the headset manager's options alone when it hasn't, because
a BlueParrott session carries `.allowBluetoothHFP` for its mic) and always re-activates.

### 2. A preempted utterance no longer reports that speech stopped

This is the subtle half, and the first cut got it wrong by relying on the opposite.

`HeadsetRemoteCommandManager` re-asserts `.playAndRecord` whenever `isSpeaking` goes false and the
category has drifted (`:252-264`). When one reply preempts another, the old utterance's `didCancel`
reaches main **after** the replacement is already speaking under `.ambient` — so that re-assert fires
underneath a live utterance and speaks it out loud on vibrate. The original bug, through a new door.

Fixed at the source in `VoiceOutputManager`: each accepted `speakWithVoice` bumps a monotonic
generation and tags its utterance, and the **entire** `didFinish`/`didCancel` body is guarded on that
generation still being current.

The guard has to cover the whole callback, not just the `isSpeaking` publish. The first cut guarded
one line of four, and the other three were stale in exactly the same sense:

- `firePendingStopCompletion()` releases `VoiceInputManager` to reconfigure the session for recording
  while the replacement utterance is audibly still speaking — the feedback loop that completion exists
  to prevent.
- `clearInFlightIfMatches` drops the focus-change cancel tag. A batch of replies shares one session
  id (`SessionSyncManager` speaks every new assistant text for one session in a single loop), so the
  session-id match check does not catch this, and "navigate away stops TTS" silently stops working
  for the rest of the batch.
- `stopKeepAliveTimer()` kills the timer the **live** utterance just started, so background playback
  dies for the remainder of the reply.
- the deactivate-on-finish path tears the session down under a still-queued utterance.

Fixing it at the publisher rather than in the headset observer means every subscriber benefits — macOS
routes `isSpeaking` into its session reducer as `ttsEnded`, and it had the same exposure. The observer
also gained `.removeDuplicates()` so it no longer reacts to redundant repeats.

`synthesizer.isSpeaking` cannot serve as the in-flight signal: it flips true **asynchronously**, tens
of milliseconds after `speak()` returns, so it reads false during exactly the window that matters.
Three places were trusting it, and all three are now `synthesizer.isSpeaking || hasUtteranceInFlight`:

- **The preempt site itself.** With the lagging test alone, a second reply arriving in that window does
  not preempt — it queues *behind* the first, and both then play under whichever category the **last**
  speak configured. An automatic reply that chose `.ambient`, followed by a Read Aloud that chose
  `.playback`, is spoken out loud on vibrate. Same bug, third door.
- `stop(completion:)`, which would otherwise fire its completion for a queued-but-not-started
  utterance and let recording start under it.
- `stop`'s idle branch, which cleared the in-flight flags unguarded.

### 3. The route table is ears and cars only

`.airPlay`, `.HDMI` and `.lineOut` were in the first cut and are now out: a HomePod, a television and
a desk speaker are **rooms**, usually shared ones, so letting them overrule the switch would be
strictly worse than the old behaviour. What remains: `.headphones`, `.bluetoothA2DP`, `.bluetoothHFP`,
`.bluetoothLE`, `.carAudio`, `.usbAudio`.

`.bluetoothA2DP` stays knowingly permissive — iOS reports it for a JBL on a conference table exactly
as for AirPods, and no API distinguishes them. That residual risk is now disclosed in the caption.

The route is read **once** and that single snapshot feeds both the decision and the log line, so the
log can never describe a route the decision didn't use. An empty route (possible before the session
has ever been activated) logs as `unknown/empty` and resolves to "the room".

### 4. Settings label and caption

> **Keep quiet when phone is on vibrate**
> When enabled, responses aren't spoken out of the phone's own speaker while the ringer switch is on
> silent/vibrate. Headphones, a Bluetooth headset or car audio still speak — the switch silences the
> room, not your ear. Tapping Read Aloud yourself always speaks. iOS can't tell a headset from a
> Bluetooth speaker, so a paired speaker counts as "your ear" too.

### Resulting truth table

`.ambient` is the only category iOS silences for the ringer switch — and it is **also** the one iOS
silences on screen lock, so every `.ambient` row below overrides `continuePlaybackWhenLocked` for that
utterance. The two settings cannot both be honoured; quiet wins, because the cost of being wrong the
other way is noise in a meeting.

| Headset mode | Setting on | Output route | Session left as | Switch honoured? | Plays when locked? |
|---|---|---|---|---|---|
| off | yes | phone speaker | `.ambient` | yes — unchanged | no |
| off | yes | headphones/BT/car/USB | `.playback` | no — **new**, plays in-ear | yes |
| off | yes | AirPlay/TV/line-out | `.ambient` | yes — treated as a room | no |
| off | yes | unknown/empty | `.ambient` | yes — conservative default | no |
| off | no | any | `.playback` | no — unchanged | yes |
| **on** | **yes** | **phone speaker** | **`.ambient`** | **yes — the bug** | no |
| on | yes | headphones/BT/car/USB | `.playAndRecord`, category untouched if already there | no — `e4dbb860` preserved | yes |
| on | yes | AirPlay/TV/line-out | `.ambient` | yes | no |
| on | no | any | `.playAndRecord`, category untouched if already there | no — unchanged | yes |
| manual Read Aloud | — | any | `.playback`, or `.playAndRecord` under headset mode | no — unchanged | yes |

`e4dbb860`'s property is preserved where it mattered: when the session is already the headset session,
the category and its options are never changed, so the Now Playing slot and AVRCP stem presses are
safe. A drifted category is rebuilt to `.playAndRecord` rather than `.playback`, so the Bluetooth
output options are never dropped on the way.

### Failure policy differs by plan

If the session cannot be configured, the two directions are opposites and are handled separately:

- `.respectSilentSwitch` fails → **drop the utterance**. Quiet was the point; speaking under whatever
  category happens to be live is how the phone ends up talking in a meeting.
- `.forcePlayback` / `.useHeadsetSession` fail → **speak anyway** under the existing session. These
  plans had already decided the utterance should be heard. Dropping them silences the driving case,
  and under headset mode also wedges the state machine in `.sending` with no timeout out of it.

### Known, accepted costs

- **A `.respectSilentSwitch` utterance won't play through a locked screen**, even with the ringer on
  loud. New for headset users; inherent to `.ambient`. Flagged rather than fixed — changing which
  setting wins is Travis's call.
- **The keep-alive player is dead for the duration of an `.ambient` utterance.**
  `configureAudioSessionForSilentMode` resets category options, and a prepared `AVAudioPlayer` stops
  producing output across a category switch (the existing
  `testStartRecording_keepAliveActiveUnderPlayAndRecord` documents this). It rebuilds on TTS end, but a
  stem press *during* a long silenced reply may not be delivered.
- **Earcons are unchanged** and now inconsistent with speech: `playCue` is gated only by
  `headsetAudibleCuesEnabled` and plays through whatever session is live. Default is off.
- **`.usbAudio` shares the Bluetooth ambiguity**: on iPhone it is a USB-C headphone adapter or a USB
  DAC feeding desk speakers, and nothing distinguishes them. The caption now covers wired adapters
  alongside the Bluetooth-speaker case.
- **The route is classified under the category in force before the switch.** `currentRoute` is a
  function of the current category, so under `.playAndRecord` without `.defaultToSpeaker` the built-in
  output resolves to `.builtInReceiver` rather than `.builtInSpeaker`. Both are non-private, so the
  decision is unaffected today; noted because it stops being true if `.defaultToSpeaker` is ever added.
- **`didStart` is not generation-guarded**, unlike the end callbacks. It only ever sets `isSpeaking`
  to true, which `speakWithVoice` has already done, and the newest utterance's own end corrects it.

## Test results

```
make test-class CLASS=DeviceAudioSessionManagerTests      21 tests, 0 failures
make test-class CLASS=VoiceOutputManagerTests             28 tests, 0 failures
make test-class CLASS=HeadsetIOSAudioSessionTests         10 tests, 1 failure (pre-existing)
make test-class CLASS=HeadsetRemoteCommandManagerTests    23 tests, 0 failures
make test-class CLASS=ReadAloudTests                      13 tests, 0 failures
make test-class CLASS=SmartSpeakingTests                  16 tests, 0 failures
make test-class CLASS=SettingsViewHeadsetTests             4 tests, 0 failures
make test-class CLASS=AppSettingsTests                    67 tests, 0 failures
make build-mac                                            BUILD SUCCEEDED
make test-mac-class CLASS=HeadsetSessionReducerTests      58 tests, 0 failures (3 consecutive runs)
make test-mac-class CLASS=HeadsetRemoteCommandManagerMacTests  7 tests, 0 failures
make test-mac-class CLASS=MacAudioOutputRouterTests        5 tests, 0 failures
make test-mac-class CLASS=HeadsetEarconPlayerTests         5 tests, 0 failures
```

The macOS test host is **flaky to launch** — several attempts died with "The test runner timed out
while preparing to run tests" / "hung before establishing connection" before any test executed, and it
does so identically with every mac-compiled source reverted to `HEAD`, so it is pre-existing and
unrelated to this change. Retrying gets a clean run; the results above are real runs, not skips. This
matters here because the generation guard is cross-platform and the macOS session reducer consumes the
same signal via `ttsEnded`.

What the new tests pin:

- The plan truth table, every row, as a pure function.
- The port table: all six private ports, and `.airPlay`/`.HDMI`/`.lineOut` asserted **not** private.
  A count assertion fails if a port is added to the table without a case here.
- `configureAudioSessionForHeadsetPlayback`: it re-activates a session whose category is right but
  which was left inactive, it leaves `.allowBluetoothHFP` alone when the category is already correct,
  and it rebuilds a drifted category to `.playAndRecord` rather than `.playback`.
- The cases whose behaviour changed, end-to-end through `speak`, via a test seam on the route
  (`outputIsPrivateListening`, mirroring `VoiceInputManager.prefersBluetoothHFPInput`): headphones +
  vibrate speaks; a headset session keeps both category and options; a drifted category under a
  private route is rebuilt rather than forced to `.playback`; Read Aloud under headset mode is not
  left mute.
- The production path with the seam nil, so the live route reader is covered too, and
  `appSettings == nil` defaulting to the quiet side.
- **The preempt race**, with a real `HeadsetRemoteCommandManager` and a real `VoiceOutputManager`:
  speak, wait for the synthesizer to genuinely start, speak again to preempt, then wait until the
  dropped-stale-end counter increments before asserting the session is still `.ambient`. That counter
  is what stops the test passing for the wrong reason — without it, a simulator slow enough that the
  first utterance never started would deliver no cancel, exercise nothing, and pass every assertion.
  Its counterpart lets a short utterance run to `didFinish`, asserts the session **is** restored, and
  asserts the counter stayed at zero.

Waits in those two tests poll for the condition rather than sleeping a fixed interval — synthesizer
start latency on a cold simulator is unbounded (the run logs show multi-second voice-asset loads), so
a fixed wait fails in one direction or the other depending on the machine.

The original regression test was verified to **fail against HEAD** and pass with the fix:

```
VoiceOutputManagerTests.swift: XCTAssertEqual failed:
  ("AVAudioSessionCategoryPlayback") is not equal to ("AVAudioSessionCategoryAmbient")
  - Headset mode must not bypass the silent switch when audio would come out of the phone itself
```

`HeadsetIOSAudioSessionTests.testTTSEnd_reassertsAudioSession` fails with `("Ready") is not equal to
("Speaking")`. **Pre-existing** — confirmed by re-running it with every touched file reverted to
`HEAD`, where it fails identically. It drives `MockVoiceOutputForHeadset.isSpeaking` directly and never
calls `speakWithVoice`, so no line of this change executes during it. Not addressed here.

One test-hygiene note worth keeping: `MockVoiceOutputForHeadset.stop()` overrides `stop()` **without
calling super**, so it does not stop the real synthesizer. Tests that speak for real must use
`stop(completion:)` and wait for `hasUtteranceInFlight` to clear, or a live utterance runs on into
whichever test sorts next and mutates the shared `AVAudioSession` from its delegate callbacks.

## Android: not the same defect

`android/.../data/remote/VoiceOutputManager.kt:119` reads the ringer mode directly and drops the
utterance:

```kotlin
if (respectSilentMode && isDeviceSilent()) { onComplete?.invoke(); return }
...
private fun isDeviceSilent(): Boolean =
    audioManager?.ringerMode == AudioManager.RINGER_MODE_SILENT ||
    audioManager?.ringerMode == AudioManager.RINGER_MODE_VIBRATE
```

Android has a real `ringerMode` API, so it doesn't need the category trick and has no headset bypass —
the iOS bug does not exist there. It has the **inverse** shape of the design problem, though: the check
is route-blind and unconditional, so with `respectSilentMode` on (the default) Android also goes silent
through connected headphones, and it applies to manual read-aloud too (no per-call override — the flag
is instance state set once from `MainViewModel.kt:268`). Worth aligning with the route rule when Android
gets attention; it is not causing the reported symptom.

## Other things that can make noise on a silent phone

- **Earcons** (`HeadsetEarconPlayer`, played via `HeadsetRemoteCommandManager.playCue` at `:694`) are
  gated only by `headsetAudibleCuesEnabled` and play through whatever session is live — under
  `.playAndRecord` they ignore the ringer switch. Left alone: they only fire in response to a headset
  button press you just made, and the setting defaults off. Flagging, not fixing.
- **Keep-alive players.** `VoiceOutputManager.setupSilencePlayer` is true digital silence.
  `HeadsetRemoteCommandManager.setupKeepAlive` is **not** — it synthesizes a 20 Hz sine at amplitude
  0.0001 (-80 dB) precisely because pure zeros don't register with the Now Playing heuristic.
  Inaudible either way, so neither is a noise source, but the reason differs.
- **Local notifications** use `content.sound = .default`; iOS silences those with the ringer switch
  itself. Not implicated.
- Adjacent, not fixed: with **BlueParrott on and headset control off**, `speakWithVoice` switches the
  category out from under the BlueParrott session on every utterance, and the `stateMachineEngaged`
  re-assert at `HeadsetRemoteCommandManager.swift:256` is `isActive`-only on iOS, so nothing puts it
  back. That's a route-stability bug, not a loudness one.

## On-device check (needs your hand on the ringer switch)

Deploy with `make deploy-iphone15` (or `make deploy-iphone14`). Settings → the "Audio Playback" section
should now read **"Keep quiet when phone is on vibrate"**; leave it **on**. Leave **Enable headset
control** on — that's the configuration that was broken.

**1 — the meeting case (this is the actual bug).** Disconnect/switch off every headset, ringer switch
to silent, open a session, send a prompt, let the reply land.
*Expect:* nothing audible. *If it speaks:* the fix didn't take — grab the in-app log (ladybug →
Captured Logs) and look for the `VoiceOutput: audio session →` line; it prints the setting values, the
resolved route, and which plan was chosen.

**2 — the driving case (the behaviour change).** Connect the headset, ringer switch still on silent,
send a prompt.
*Expect:* the response in your ear at normal volume, and the log line says
`keeping .playAndRecord session` with `private=true`. *If it's silent:* the route classification
didn't recognise your headset — the log's `route=[...]` shows the port type it saw, which is what to
add to `privateListeningPorts`.

**3 — the stem-press regression guard for `e4dbb860`.** Same setup as 2, with a long reply speaking.
Press the headset button mid-speech.
*Expect:* it still starts a recording, i.e. the button is still reaching us. *If it doesn't:* the
category was disturbed while a headset was connected, which case 2's log line would also show.

**4 — the switch flipped back.** Ringer switch to loud, no headset, send a prompt.
*Expect:* it speaks. Confirms we're honouring the switch rather than just going quiet.

**5 — manual override.** Ringer on silent, no headset, open a message and tap **Read Aloud**.
*Expect:* it speaks. That's intentional.

**6 — the preempt case, which is what the code review caught.** Ringer on silent, no headset, headset
control on. Send a prompt that produces two replies in quick succession (a tool-using turn usually
does), or send a second prompt while the first reply is still being read.
*Expect:* still nothing audible. *If the second reply speaks:* the generation check isn't holding —
the log will show `Ignoring stale utterance end` for the suppressed one, and its absence is the tell.

## What I could not determine without the device

- **Whether "Enable headset control" is actually on in your install.** The whole diagnosis rests on it
  — it defaults to `false` (`AppSettings.swift:376`), and with it off the pre-fix code honoured the
  switch correctly on the phone's own speaker. If it turns out to be **off** for you, then case 1
  above would have passed before my change too, and the symptom you saw is something else — most
  likely the headphones case (`.ambient` through a *connected* headset) reading as "it spoke when it
  shouldn't have". Check 1 tells us which.
- **The real ringer switch.** The simulator has none; `.ambient` vs `.playback` vs `.playAndRecord` is
  verified by category assertion, and iOS's silencing of `.ambient` is taken from the platform
  contract. Only the device proves the last inch.
- **Which route your BlueParrott presents while headset mode is up** (`.bluetoothHFP` vs
  `.bluetoothA2DP`) — both are in `privateListeningPorts`, so either is handled, but the log line in
  check 2 is what confirms it rather than assuming.
