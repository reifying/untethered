# Mac app bug hunt, 2026-11-19

An agent read the Mac code paths, built the app and ran its tests, looking for bugs. Ten were fixed
and are on `main`. The rest are listed here, unfixed, because each needs a decision, a real headset,
or a larger change. Nothing in this note was seen in the running app: it all comes from reading code
and from unit tests.

Confidence is in brackets. "(agent)" marks findings that came from a read-only review pass and were
not traced a second time.

## Fixed (on `main`)

| Commit | What was wrong |
|---|---|
| `e8b8aa25` | After a BlueParrott disconnect, a refused reconnect was ignored: no scan, no timer, button dead until Bluetooth or the setting was cycled. |
| `51eb8d89` | Test Connection replaced every result, including a success, with "Connection timeout" five seconds later. |
| `740f69b8` | A recent session whose timestamp had no fractional seconds was dropped from the list. |
| `db86b31c` | Every deliberate reconnect (new address, new key, driving mode's retry) cancelled its own new socket once and showed "cancelled". |
| `63a6e1b5` | Refresh Session, Compact Session and Session Info did nothing from the Session menu or the command palette. |
| `e62e5e67` | A command waiting to start hung for ever when the socket died by itself. |
| `7c48b6f6` | A recording that could not start (input device missing or switching) sent the previous prompt again. |
| `abd8e687` | Menu bar popover: Settings… and Open VoiceCode did nothing; the quick prompt's default folder was the sandbox container. |
| `da992771` | Type a server address, switch tabs, come back: the Apply button was gone and the old address stayed in use. |
| `0df955ca` | New Session's "Create Git Worktree" switch was ignored on the Mac. |

Also on `main` from the same day, found separately: the conversation did not follow a new message
when older ones were pruned in the same save (`6cd18aca`).

Tests weaker than "fails without the fix": the Settings… button has no automated test; Open
VoiceCode is tested up to the window choice, not the click; the Apply button and worktree switch
are tested through new helper functions.

## Not fixed

### Menus and windows

- **⌘K is bound twice** [high]: Command Palette (`VoiceCodeApp.swift`) and Cancel Prompt in the
  conversation toolbar (`ConversationView.swift`). Which wins was not observed.
- **⌘N is probably bound twice** [medium]: Session ▸ New Session and the File ▸ New Window that
  `WindowGroup` adds. A second window would connect a second time.
- **Command palette "run command" does nothing** [high]: it posts `.executeCommand`, which nothing receives.
- **Sidebar Commands rows are not clickable** [high]: `CommandSidebarRow` has no action.
- **Focus Sidebar / Focus Conversation (⌘1, ⌘2) do not move focus** [high].
- **Option+Space push-to-talk records but never sends** [medium]: `PushToTalkModifier.swift`.
- **No rename or delete for a session in the Mac sidebar** [high; missing, not broken].

### Menu bar quick prompt

- **It always ends in "Error: Request timed out" after 120 seconds** [high]: the client waits for a
  `response` message the backend never sends. The prompt is delivered and the agent runs. Needs a
  decision on what "done" means there.
- **The mic button reads the transcript at the moment of stop**, so it can miss the last words [medium].

### Headset and audio (agent)

- **"Auto-send on recording stop" is ignored on the Mac** [high]: the setting is read only in the iOS code.
- **The keep-alive tone starts with headset control off and never stops** [high on mechanism]: one
  click on the on-screen mic is enough. Left alone because three tests from `252db0d1` assert the
  current behaviour.
- **Speech that starts while a prompt is being sent is never registered** [high, from the reducer]:
  `.ttsStarted` is handled only in `.idle` and `.awaitingResponse`. Driving mode reading held replies
  when the microphone closes hits this routinely; the next press then does not stop the reply.
- **Turning BlueParrott off mid-recording leaves the microphone open** [high]. Leaving driving mode
  mid-recording goes this way, and the stuck-gate check does not cover it.
- **The retry for an unusable input format never runs** [high]: `restartCapture()` returns early.
- **A late callback from the previous recognition can stop the new recording** [medium].
- **A press of about 0.30 to 0.35 seconds during a reply can send stale text and leave the mic open** [medium-low].
- **Presses while a prompt is being sent are dropped silently**, including a hold-to-talk [high].
- **No audio device change is observed anywhere** [high]: a device lost mid-recording leaves LISTENING showing.
- **The system output is left on the built-in speakers** after captures and not restored on quit [high].
- **App Mode on the BlueParrott is assumed on and never written** [medium; needs the headset].
- **Keep-alive does not follow BlueParrott connect or disconnect** [medium].
- **A session change keeps queued replies that nothing then starts** [medium].

### Connection (agent)

- **"Connected" can stay showing with no socket** [medium]: a late `hello` can land after a failure.
- **A half-open connection is not detected** [medium]: pings are sent, pongs never checked.
- **After 20 failed attempts the app stays offline until activated** [high]: no wake or
  network-change trigger. Driving mode has its own retry and is not affected.
- **A command started while already disconnected still hangs** [high]: only the socket-death case was fixed.
- **A message sent with no socket is dropped silently** and still removes the session from the priority queue.
- **Two reply-ordering races** in `SessionSyncManager.swift` that can skip speaking a reply or
  delete one that just arrived [low-medium].

### Persistence and settings (agent)

- **Any error loading the store deletes the database** [high that the code does this]:
  `PersistenceController.swift`, and it leaves the `-wal` and `-shm` files behind.
- **Server address, port and system prompt save half a second after the last keystroke**, so an
  address that was typed but not applied is still used at the next launch [high; low severity].
- **`NotificationManager.pendingResponses`** is written off the main thread and never shrinks [medium].
- **Every background save is merged into the view context twice** [medium].
- Smaller: the key prompt says keys start with `voice-code-` while validation wants `untethered-`;
  pasted keys are not trimmed; `notifyOnResponse` is never read; the Mac has no app group, so
  shared-defaults calls fail and log on every connect; the log records full prompt text, now written
  to disk on the Mac; the Headset tab shows its status and mute warning only for headset control,
  not for BlueParrott alone.

## What was run

- Mac unit tests on `main` with all of the day's work merged: 2,021 run, 0 failures, 1 skipped.
- Eight of the new tests were run with their fix disabled, and all eight failed.

Not run: the real app (nothing here was clicked), the Mac UI tests, the iPhone build and tests
(shared files changed: `VoiceCodeApp.swift`, `VoiceCodeClient.swift`, `VoiceInputManager.swift`,
`RecentSession.swift`, `AppSettings.swift`), any real headset, microphone or backend connection.

`WindowGroup` now has an id, which may change the name the main window's saved frame is stored
under: the window could open at its default size once.
