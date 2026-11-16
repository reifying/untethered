# Driving mode for the Mac app

**Date:** 2026-11-16 · **Status:** on `main`, built, unit-tested, and entered and left in the real app. Not yet tried with a real headset, a real microphone or a server connection (see "What was run").

Driving mode is a mode of the Mac app you turn on once and then run for hours from the headset.
The laptop is used for one thing: a click on a large band to hear a recent reply again.

## Turning it on and off

- **On:** Driving ▸ Enter Driving Mode (⌘⇧D), the car button in a conversation's toolbar, or
  Settings ▸ Driving. It drives the conversation on screen. With none open it takes the session it
  drove last time, else the most recently used one.
- **Off:** the same menu item or shortcut, or the Exit Driving Mode button at the top right of the
  driving screen. The window, its level and the settings the mode changed go back to what they were.
- **Without touching the laptop:** the links `voicecode://driving/on` and `voicecode://driving/off`
  do the same, so an agent or a shortcut can switch the mode. While the mode is on,
  `voicecode://session/<id>` changes which session is driven. With more than one copy of the app on
  the Mac, name the copy that is running, or macOS may start another:
  `open -a <path to the app> voicecode://driving/on`.
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

## Why the microphone button went off-screen

Found, measured in the running app, and fixed.

On the Mac a window cannot be shorter than its content's minimum height, and SwiftUI works that
minimum out at the content's minimum *width*. The caption under the ghost-task switch had a
vertically fixed size. At that width it wraps to about a word per line and reports the whole
height of that: 495 points for the switch alone.

- With a resumed Claude session open (the only time the ghost switch shows), the window's minimum
  height came out at 964 to 1,018 points. This laptop's screen has 949 below the menu bar.
- The window was therefore forced to 1,018 points tall. Its top cannot go above the menu bar, so
  its bottom edge went 69 points below the bottom of the screen, with the microphone button on it.
  Nothing there scrolls, so there was no way to reach it.
- That is why it was "sometimes": a new session, or one that is not Claude, has no ghost switch.

The caption is now limited to two lines, and the two warning banners, which had the same fixed
size, to four. After the fix the same window, same session, stays at 949. Tests hold the
conversation view's minimum height under 600 points with the switch, both banners, an error and a
long dictation all showing.

Two smaller things in the same area:

- The live transcript under the microphone button had no line limit and on the Mac stays after
  sending. A two-minute dictation made the input area ask for 1,052 points instead of 196, at the
  message list's expense. It and the error line are limited to three lines.
- The driving screen cannot do any of this. Its bands are computed from the window's size and
  nothing is sized by its content. Its minimum is 320 by 240 whatever it shows. A test checks that
  with three replies of 100,000 characters each. The driving window is also put back on the screen
  whenever any part of it is found outside.

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
4. *One database query per session, on the main thread, every time the session list changed.* The
   list of sessions was filtered for deleted ones with a lookup each. The Mac app's store on this
   laptop holds 16,480 sessions, so that was 16,480 queries a time. It is now one. This slows the
   app as the list grows rather than as the hours pass, and may be much of what felt unstable.
5. *The app could go on believing it was speaking.* A reply cut off the moment it started (by a
   recording, a skip or a stop) could be reported as started after it had been stopped. Nothing
   cleared that, so the headset stayed in SPEAKING and the next press stopped nothing instead of
   starting a recording. Seen as a test that waited six seconds for a silence that never came.
   Fixed in the speech code both apps share.

**The tests were changing the real app.** The Mac unit tests run inside the app, in its own
sandbox. They cleared the headset and BlueParrott switches and the paired headset, could leave
speech muted, and read and wrote the real message store. Anyone running the tests on the Mac you
use reset the app's headset settings. Now a test run gets an in-memory store, and the app saves
its settings when launched for a test run and puts them back at the next normal launch.

## What was run

- **Mac unit tests: 1,961 pass, none fail, and the test host does not crash.** On `main` before
  this work the same suite passed 1,836, failed 9 and crashed its host 8 times in one run.
- **iOS:** builds, and 1,862 unit tests pass on the simulator. Ten fail, the same ten that fail on
  `main` without this work: nine in `BlueParrottButtonManagerTests` and
  `HeadsetIOSAudioSessionTests.testTTSEnd_reassertsAudioSession`. Two that used to crash the iOS
  test host now pass.
- **The real app, launched on this Mac with the screen locked.** Normal launch and clean quit.
  Driving mode entered and left by link, several times. Seen from outside the app: one window, on
  the screen, floating; both power assertions held while the mode was on and gone after; the
  window back at its earlier frame afterwards; no crash. Seen in the app's log: the session
  chosen, the announcement made, the BlueParrott and media-key sources switched on at entry and
  off at exit.
- The driving screen was also laid out in real windows by the tests, starting from a window
  taller than the screen and partly below it.

Not run:

- **Nobody has looked at the driving screen.** The Mac was locked; its layout is known from tests
  and window measurements, not from eyes.
- Any real headset button, real microphone or audible speech. The Mac's sound was muted.
- A connection to the server. The Mac app on this laptop has no server address set (see below).
- A drive.

**Things that happened on this Mac during the work:**

- The Mac app's settings on this laptop are blank: no server address or port, headset switches
  off, no remembered BlueParrott, and the upload folder holds a leftover test value. The first
  test run of this work, before the fix for it existed, cleared them, or an earlier test run had.
  It cannot be told which. The backend is running on this laptop on port 8080, so the address is
  `localhost` and the port `8080`.
- Running the real app turned on the Mac's Bluetooth search for the BlueParrott six times, for
  between five seconds and about a minute each. A headset that was connected to the phone at the
  time would not have been found.
- There are 18 crash reports for the Mac app dated today in `~/Library/Logs/DiagnosticReports`.
  Seventeen are the test host, from before the fixes above. One is from starting the app's program
  file directly from a shell, which macOS kills over a Bluetooth permission that a normal launch
  has. None is from the app in use.

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

Before step 1, set the server in Settings ▸ Connection (`localhost`, `8080` for the backend on this
laptop). Driving mode turns a headset button source on by itself; outside it, turn yours back on in
Settings ▸ Headset. The first BlueParrott connection may take up to a minute, because the headset
has to be found again.

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

To watch a debug build from a shell, launch it with `UNTETHERED_LOG_STDERR` set and a file for
standard error (`open --env UNTETHERED_LOG_STDERR=1 --stderr <file> <app>`). The log file itself is
inside the app's sandbox, which another process cannot read without a privacy prompt.
