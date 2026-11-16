# Driving mode for the Mac app

**Date:** 2026-11-16 · **Status:** on `main`, built, unit-tested. Not yet tried with a real headset or a real microphone (see "What was run").

Driving mode is a mode of the Mac app you turn on once and then run for hours from the headset.
The laptop is used for one thing: a click on a large band to hear a recent reply again.

## Turning it on and off

- **On:** Driving ▸ Enter Driving Mode (⌘⇧D), the car button in a conversation's toolbar, or
  Settings ▸ Driving. It drives the conversation on screen. With none open it takes the session it
  drove last time, else the most recently used one.
- **Off:** the same menu item or shortcut, or the Exit Driving Mode button at the top right of the
  driving screen. The window, its level and the settings the mode changed go back to what they were.
- **It stays on until you turn it off.** If the app is relaunched mid-drive, after a crash or a
  restart, it comes back in driving mode on the same session. Nothing relaunches the app for you:
  after a crash it takes one click on the Dock icon.
- On entry it says "Driving mode on" and the session's name, and says so if there is no connection
  to the server yet.

## The screen

The window fills the visible screen and floats above other apps' windows. It is three kinds of
band, each the full width of the window:

| Band | What a click does |
|---|---|
| Status strip (top, thin) | Nothing. Shows connection, state (READY, LISTENING, SENDING, WAITING, SPEAKING), the session, and the exit button. |
| Reply bands, three by default | Reads that reply again from the top. The top band is always the newest reply, the next one the reply before it, and so on. |
| Talk bar (bottom) | Starts talking, or stops and sends. The same action as a press of the headset button. |

- The number of reply bands is a setting, 1 to 5 (Settings ▸ Driving).
- Keys work too, with no pointer to aim: `1` to `5` replay that band, Space is the talk bar.
- A click works the first time even when another app is in front.
- Replaying cuts off whatever is being read. Replies that have not been read yet are kept and are
  read after the replay.

## Headset buttons

These are the same on the driving screen and off it.

| Gesture | BlueParrott button | AirPods-style headset or media keys | What it does |
|---|---|---|---|
| Hold | hold | (none) | Talk while held. Release sends. Interrupts a reply being read. |
| Press | tap | play/pause | Start talking, or stop and send. While a reply is being read: stop reading, all of it. While waiting on the agent: stop waiting (the prompt is not cancelled). |
| Double press | double tap | next track | While a reply is being read: skip to the next reply waiting. Otherwise: read the last reply again. |
| Triple press | (none) | previous track | Read the last reply again, at any time except while recording. |

Two of these are new with this work: the double press used to stop all reading (now a single
press does that, and a double press skips one reply), and a double press with nothing going on
used to do nothing.

A press that does nothing audible, such as a repeat when there is no reply yet, plays the error
tone instead of leaving silence.

## What the mode keeps right during a long drive

Everything below is checked on entry and again every ten seconds, and put back if it has drifted.

- **The session stays live.** It is kept as the active session and kept subscribed, so replies
  arrive and are read aloud with no conversation view on screen. The sidebar and conversation are
  not built at all while the mode is on.
- **The Mac stays awake.** The mode holds a power assertion: no idle sleep, no display sleep, no
  App Nap. Closing the lid still sleeps the Mac.
- **A lost connection is retried without limit**, every 30 seconds after the first 15, and said
  aloud once ("Connection lost. Retrying." then "Reconnected."). A rejected key or a version
  mismatch is said once and not retried, because retrying cannot fix either.
- **A button source is on.** If neither "headset control" nor "BlueParrott button" was on, both are
  turned on. If one was already chosen it is left alone. Audible cues are turned on and speech is
  unmuted.
- **Replies that arrive while you are talking are not lost.** Speech is dropped while the
  microphone is open. The mode notes replies that land then and reads them, in order, when the
  microphone closes.
- **The window stays on the screen.** If any part of it is found outside the visible screen it is
  moved back, at once on a resize, move or display change and otherwise at the next check.
- **Speech cannot stay silenced.** The flag that suppresses speech during a recording is lowered
  if it is found raised with no recording in progress.

From iOS, the behaviours asked for were already in the Mac build and needed no porting: tool calls
and thinking are filtered on the backend for every client, and replies are queued and read in turn
by code the two apps share. The Kokoro voice is iPhone only and was left that way.

## The microphone button going off-screen

**The cause was not established.** What is known:

- The conversation view lays out inside whatever window it has, and nothing in it scrolls except
  the message list. If the window's bottom edge is below the screen, the microphone button on that
  edge is out of reach, and there is no way to scroll to it.
- Two things can put the bottom edge there, and neither was reproduced: a window frame saved on a
  taller display and restored on the laptop's own screen, and the window growing to fit a taller
  minimum when rows appear in the input area while the window is short.
- One suspicion was tested and ruled out as the cause. The live transcript under the microphone
  button had no line limit, and on the Mac it stays after sending. Measured, a two-minute dictation
  made the input area ask for 1,052 points instead of 196. But its minimum height did not change,
  so it squeezes the message list and does not move the window. It is now limited to three lines,
  and so is the error line, because taking half the window for a sent dictation is its own defect.

What was done about it, since the cause is open:

- The driving screen cannot lay a control outside its window. Its bands are computed from the
  window's size and nothing is sized by its content. A test checks this with three replies of
  100,000 characters each and a long dictation in progress.
- The driving window is put on the visible screen on entry and put back whenever any part of it
  is found outside, whatever moved it. A test starts from a window taller than the screen with
  its bottom edge 600 points below it.
- The ordinary conversation window is not policed this way. If the button goes off-screen there,
  entering driving mode (⌘⇧D) brings the window back.

## What was found about crashes and long sessions

**Crashes.** This Mac holds one week of crash reports and none is from the Mac app in real use, so
the crash you have seen is not identified. What was found and fixed:

1. *A real crash in app code, which took the app down eight times in one run of the Mac unit
   tests.* When a voice input manager was released while recording, its `deinit` called
   `stopRecording()`, which queued a block holding the dying object. The block then ran on freed
   memory: a segmentation fault a moment later. The running app keeps one such manager for its
   whole life, so this is probably not what you hit, but it was a use-after-free and it is gone.
   It was also what made the Mac and iOS test hosts crash.
2. *A second one, seen once in the same tests.* Starting a command wrote a dictionary from a
   background thread while the main thread used it. Two commands started close together crashed
   in the dictionary. In the app this needs two commands from the command menu at nearly the same
   moment, or one at the moment a reply for another arrives. The write now happens on the main
   queue like every other use.
3. *An exception Swift cannot catch.* Starting a capture installs an audio tap with the input
   device's format. A device that is missing or switching profile, which a Bluetooth headset does
   at exactly that moment, reports 0 Hz, and the tap then raises an Objective-C exception that
   kills the app. The format is now checked first and a bad one is treated as a capture that did
   not start. This is a likely cause of a real crash; it was not observed.
4. *A crash left no trace.* The log lived only in memory. On the Mac it is now also written to a
   file. After a run that did not end cleanly, the next launch copies its last 300 lines into the
   in-app log, so Share Logs carries them.

**Long sessions.**

1. *The reconnect timer.* It kept firing about once a second for the whole life of a healthy
   connection and logged a line each time, which fills the 5,000-line log in about 80 minutes and
   pushes everything else out. When a connection attempt hung it also used up all 20 retries in
   about 23 seconds and then stayed offline until the app was clicked. The fix already existed on
   the unmerged `log-diagnostics-fixes` branch and was brought across as its own commit.
2. *Nothing kept the Mac awake.* With the BlueParrott source the silent keep-alive tone is
   deliberately off, so nothing held off idle sleep or App Nap during a drive. This is the most
   likely reason the app faded during long sessions. It is inferred from the code, not observed.
3. *Replies dropped while the microphone was open* and never read. Handled in driving mode as above.

**The tests were changing the real app.** The Mac unit tests run inside the app, in its own
sandbox. They cleared the headset and BlueParrott switches and the paired headset, could leave
speech muted, and read and wrote the real message store. Anyone running the tests on the Mac you
use reset the app's headset settings. Now a test run gets an in-memory store, and the app saves
its settings when launched for a test run and puts them back at the next normal launch.

## What was run

- **Mac unit tests: 1,953 pass, none fail, and the test host no longer crashes.** On `main` before
  this work the same suite passed 1,836, failed 9 and crashed its host 8 times in one run.
- **iOS:** builds, and 1,860 unit tests pass on the simulator. Ten fail, the same ten that failed
  before: nine in `BlueParrottButtonManagerTests` and
  `HeadsetIOSAudioSessionTests.testTTSEnd_reassertsAudioSession`. Two that used to crash the iOS
  test host now pass.
- The driving screen was laid out in real windows by the tests at several sizes, starting from a
  window taller than the screen and partly below it. The tests also checked that the window is
  put back after being pushed off-screen, and that a click target acts on the first click.

Not run, because this Mac was locked with nobody at it, and launching the app could have taken the
headset's button away from the phone:

- The app itself, on screen. Nobody has looked at the driving screen.
- Any real headset button, real microphone or real speech in driving mode.
- A drive.

## First real try

Needs you, the headset and five minutes parked.

1. Open a conversation and press ⌘⇧D. You should hear "Driving mode on" and the session's name,
   and the window should fill the screen.
2. Hold the headset button, say a sentence, release. The reply should be read aloud.
3. While it is being read, press once. Reading should stop.
4. With nothing playing, double press. The last reply should be read again.
5. Click the top band on the laptop. The same reply again. Click the second band: the one before.
6. Send a prompt that produces several replies, and double press during the first. It should move
   on to the next rather than stop.
7. Leave it alone for fifteen minutes. The screen should stay on and the next reply still be read.

The test runs done during this work reset this Mac's headset switches, and the BlueParrott it
remembered, before the fix for that was in place. Driving mode turns a button source on by itself.
Outside it, turn yours back on in Settings ▸ Headset. The first BlueParrott connection may take up
to a minute, because the headset has to be found again.

## Left alone

- **The headset path still sends the last partial transcript**, not the recognizer's final one. The
  fix is on `log-diagnostics-fixes` and is waiting on a decision; it changes capture timing and
  needs a real headset to check.
- **The tone two minutes after a prompt.** While waiting on the agent, the app gives up waiting
  after 120 seconds, plays the error tone, and goes back to READY. The prompt is not cancelled and
  the reply is still read when it comes. With long agent turns this tone will sound often.
- **Switching sessions from the headset.** The mode drives one session.
- **Relaunching after a crash.** The mode resumes on relaunch, but the relaunch is manual.
- **The Kokoro voice on the Mac.**

## Where the code is

- `ios/VoiceCode/Managers/DrivingModeController.swift`: the mode, and everything it keeps right.
- `ios/VoiceCode/Views/DrivingModeView.swift`: the screen, the first-click targets, the window pinning.
- `ios/VoiceCode/Utils/DrivingModeLayout.swift`: the geometry, as pure functions.
- `ios/VoiceCode/Utils/RecentReplies.swift`: the replies a replay chooses from.
- `ios/VoiceCode/Managers/HeadsetSessionReducer.swift`: the button table, with repeat and skip.
- `ios/VoiceCode/Utils/TestRunDefaultsGuard.swift`, `LogManager.swift`: test isolation and the log file.
