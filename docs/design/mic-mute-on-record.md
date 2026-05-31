# Mic-Mute on Record: Suppress TTS During Voice Input

## Overview

### Problem Statement

When the user taps the microphone record button, the app continues playing text-to-speech audio of assistant messages. The TTS audio feeds back into the open microphone, creating a feedback loop where the speech recognizer transcribes the assistant's own words back as user input.

The existing `startRecording()` logic stops *current* TTS before opening the mic, but new assistant messages arriving via WebSocket trigger fresh `speak()` calls from `SessionSyncManager` while recording is active. There is no gate preventing new TTS from being enqueued during recording.

### Goals

1. Suppress all TTS playback while the microphone is recording — no audio output into the open mic
2. Cover all speak paths: auto-speak from SessionSyncManager, background "Read Aloud" notification action, and any direct `speak()` caller
3. Work identically on iOS and macOS
4. Drop suppressed speech (don't queue it for later playback)

### Non-goals

- Unifying the macOS manual-mute toggle (`isMuted`) with iOS (separate concern, different lifecycle)
- Queueing suppressed speech for playback after recording stops
- Changing the push-to-talk (Option+Space) or record button UX
- Backend/protocol changes (TTS is purely client-side)

## Background & Context

### Current State

**Recording path** (`VoiceInputManager.swift`):
- `startRecording()` checks if TTS is playing and calls `voiceOutputManager.stop(completion:)` to kill current speech and wait for audio session release before flipping to `.record` mode
- Multiple `VoiceInputManager` instances exist (one per ConversationView via SessionLookupView, one in MenuBarExtra on macOS), all pointing at the same single `VoiceOutputManager`
- `isRecording` is `@Published`, updated on main queue

**TTS playback path** (`VoiceOutputManager.swift`):
- `speakWithVoice()` is the true sink — all speech routes through it
- macOS-only `isMuted` property causes early return when set (user-toggled, persisted to UserDefaults)
- `resume()` calls `synthesizer.continueSpeaking()` directly, bypassing `speakWithVoice()`

**Auto-speak triggers** (`SessionSyncManager.swift`):
- Three call sites (lines 612, 912, 1538) dispatch `voiceManager.speak()` on the main queue when new assistant messages arrive for the active session
- None check whether recording is active

**Notification "Read Aloud"** (`NotificationManager.swift`):
- Calls `voiceOutputManager.speak()` directly when user taps the notification action
- Bypasses SessionSyncManager entirely

### Why Now

Regression observed in iOS and Mac apps: the feedback loop renders voice input unusable when assistant messages arrive during dictation. The existing one-shot `stop()` in `startRecording()` was sufficient when messages arrived slowly, but streaming responses trigger multiple rapid auto-speak calls that re-start TTS after the initial stop.

### Related Work

- `docs/design/macos-desktop-redesign.md` — introduced push-to-talk and Cmd+Shift+M mute toggle
- `VoiceOutputManagerTests.swift` — existing tests for mute, session-change cancellation, stop(completion:)
- `VoiceInputManagerTests.swift` — existing test for TTS-stop-on-record

## Detailed Design

### Data Model

No schema or persistence changes. The new state is transient (in-memory only, not persisted).

### API Design

#### New property on `VoiceOutputManager`

```swift
/// When true, all speech requests are silently dropped. Set by VoiceInputManager
/// when recording starts; cleared when recording stops or fails to start.
/// Unlike `isMuted` (macOS-only, user-toggled, persisted), this is automatic,
/// cross-platform, and transient.
var isRecordingActive = false
```

No new public methods. The property is `internal` (plain `var`) so `VoiceInputManager` can set it from a different file. `private(set)` would prevent cross-file access.

#### Modified methods on `VoiceOutputManager`

**`speakWithVoice()`** — add recording-active guard after existing `isMuted` check:

```swift
func speakWithVoice(_ text: String, rate: Float = 0.5, voiceIdentifier: String? = nil,
                    respectSilentMode: Bool = false, sessionId: UUID? = nil) {
    #if os(macOS)
    if isMuted {
        logger.info("🔇 Speech muted, ignoring request")
        return
    }
    #endif

    // NEW: Suppress all speech while microphone is recording
    if isRecordingActive {
        logger.debug("🔇 Speech suppressed — recording active, dropping request")
        return
    }

    // ... rest of existing implementation unchanged
}
```

**`resume()`** — add recording-active guard (bypasses `speakWithVoice`, would play into open mic):

```swift
func resume() {
    guard !isRecordingActive else { return }
    synthesizer.continueSpeaking()
}
```

#### Modified methods on `VoiceInputManager`

**`startRecording()`** — set flag at the very top, before `stop()` call:

```swift
func startRecording() {
    // Gate up FIRST — blocks any new speech from being enqueued during
    // the async window between here and audio session configuration.
    voiceOutputManager?.isRecordingActive = true

    if let voiceOutputManager = voiceOutputManager, voiceOutputManager.isSpeaking {
        voiceOutputManager.stop { [weak self] in
            self?.startRecordingAfterTTSStopped()
        }
    } else {
        voiceOutputManager?.stop()
        startRecordingAfterTTSStopped()
    }
}
```

**`startRecordingAfterTTSStopped()`** — clear flag on every error exit:

```swift
private func startRecordingAfterTTSStopped() {
    guard authorizationStatus == .authorized else {
        print("Speech recognition not authorized")
        voiceOutputManager?.isRecordingActive = false
        return
    }

    // ... cancel ongoing recognition ...

    #if os(iOS)
    let audioSession = AVAudioSession.sharedInstance()
    do {
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    } catch {
        print("Failed to setup audio session: \(error)")
        voiceOutputManager?.isRecordingActive = false
        return
    }
    #endif

    // ... create recognition request ...
    guard let recognitionRequest = recognitionRequest else {
        print("Unable to create recognition request")
        voiceOutputManager?.isRecordingActive = false
        return
    }

    // ... create audio engine ...
    guard let audioEngine = audioEngine else {
        print("Unable to create audio engine")
        voiceOutputManager?.isRecordingActive = false
        return
    }

    // ... install tap, prepare engine ...

    do {
        try audioEngine.start()
    } catch {
        print("Failed to start audio engine: \(error)")
        voiceOutputManager?.isRecordingActive = false
        return
    }

    // ... start recognition task, set isRecording = true ...
}
```

**`stopRecording()`** — clear flag alongside `isRecording`:

```swift
func stopRecording() {
    audioEngine?.stop()
    audioEngine?.inputNode.removeTap(onBus: 0)
    recognitionRequest?.endAudio()

    DispatchQueue.main.async {
        self.isRecording = false
        self.voiceOutputManager?.isRecordingActive = false
    }

    #if os(iOS)
    let audioSession = AVAudioSession.sharedInstance()
    try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    #endif
}
```

### Component Interactions

**Sequence: User taps Record while assistant message arrives**

```
User taps Record
    │
    ▼
VoiceInputManager.startRecording()
    │
    ├─► voiceOutputManager.isRecordingActive = true   ← gate UP
    │
    ├─► voiceOutputManager.stop(completion:)          ← kill current TTS
    │
    │   ╔══════════════════════════════════════════╗
    │   ║  Meanwhile: WebSocket delivers message   ║
    │   ║  SessionSyncManager dispatches speak()   ║
    │   ║  → speakWithVoice() sees isRecordingActive║
    │   ║  → returns early (speech dropped)        ║
    │   ╚══════════════════════════════════════════╝
    │
    ├─► completion fires → startRecordingAfterTTSStopped()
    │       ├─► configure audio session
    │       ├─► start audio engine
    │       └─► isRecording = true
    │
    ... user speaks ...
    │
    ▼
VoiceInputManager.stopRecording()
    │
    ├─► tear down audio engine
    ├─► isRecording = false
    └─► voiceOutputManager.isRecordingActive = false  ← gate DOWN
            │
            ▼
        (future speak() calls proceed normally)
```

**Error path: Authorization denied**

```
VoiceInputManager.startRecording()
    │
    ├─► voiceOutputManager.isRecordingActive = true
    ├─► voiceOutputManager.stop()
    └─► startRecordingAfterTTSStopped()
            │
            ├─► guard authorizationStatus == .authorized → FAILS
            ├─► voiceOutputManager.isRecordingActive = false  ← gate cleared
            └─► return (no recording started)
```

### Thread Safety

All access to `isRecordingActive` occurs on the main queue:
- **Setter** in `startRecording()`: called from SwiftUI button actions / push-to-talk modifier (main queue)
- **Setter** in `stopRecording()`: wrapped in `DispatchQueue.main.async`
- **Reader** in `speakWithVoice()`: all three SessionSyncManager call sites dispatch to main queue; NotificationManager actions run on main

No lock or atomic needed.

## Verification Strategy

### Unit Tests

#### VoiceOutputManager — recording suppression

```swift
func testSpeechSuppressedWhenRecordingActive() {
    let manager = VoiceOutputManager(appSettings: settings)

    manager.isRecordingActive = true
    manager.speak("This should be suppressed")

    let expectation = XCTestExpectation(description: "main queue settles")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        XCTAssertFalse(manager.isSpeaking,
                       "Should not be speaking when recording is active")
        expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)
}

func testSpeechResumesWhenRecordingEnds() {
    let manager = VoiceOutputManager(appSettings: settings)

    manager.isRecordingActive = true
    manager.speak("Suppressed")

    manager.isRecordingActive = false
    manager.speak("This should play")

    let expectation = XCTestExpectation(description: "speech starts")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        XCTAssertTrue(manager.isSpeaking,
                      "Should be speaking after recording ends")
        expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)
    manager.stop()
}

func testResumeSuppressedWhenRecordingActive() {
    let manager = VoiceOutputManager(appSettings: settings)

    // Use a short utterance that completes quickly once resumed
    manager.speak("Hi")
    let started = XCTestExpectation(description: "speech starts")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { started.fulfill() }
    wait(for: [started], timeout: 1.0)

    XCTAssertTrue(manager.isSpeaking, "Precondition: synthesizer should be speaking")

    manager.pause()
    manager.isRecordingActive = true
    manager.resume()  // Should be suppressed by guard

    // Wait long enough that "Hi" would have finished if resume() went through.
    // isSpeaking stays true after pause (no didFinish fires while paused), so
    // if it's STILL true here, the utterance is still paused — proving
    // resume() was suppressed.
    let stillPaused = XCTestExpectation(description: "still paused after suppressed resume")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        XCTAssertTrue(manager.isSpeaking,
                      "Utterance should still be paused — resume() was suppressed")
        stillPaused.fulfill()
    }
    wait(for: [stillPaused], timeout: 2.0)

    // Now clear flag and resume for real — utterance should finish
    manager.isRecordingActive = false
    manager.resume()

    let finished = XCTestExpectation(description: "speech finishes after real resume")
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        XCTAssertFalse(manager.isSpeaking,
                       "Speech should finish after un-suppressed resume()")
        finished.fulfill()
    }
    wait(for: [finished], timeout: 3.0)
}
```

#### VoiceInputManager — flag lifecycle

```swift
func testRecordingActiveFlagSetOnStartRecording() {
    let voiceOutput = VoiceOutputManager()
    let inputManager = VoiceInputManager(voiceOutputManager: voiceOutput)

    XCTAssertFalse(voiceOutput.isRecordingActive)
    inputManager.startRecording()
    XCTAssertTrue(voiceOutput.isRecordingActive,
                  "Flag must be set synchronously at the top of startRecording()")
    inputManager.stopRecording()
}

func testRecordingActiveFlagClearedOnStopRecording() {
    let voiceOutput = VoiceOutputManager()
    let inputManager = VoiceInputManager(voiceOutputManager: voiceOutput)

    inputManager.startRecording()
    XCTAssertTrue(voiceOutput.isRecordingActive)

    inputManager.stopRecording()

    let expectation = XCTestExpectation(description: "flag cleared on main queue")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        XCTAssertFalse(voiceOutput.isRecordingActive,
                       "Flag must be cleared in stopRecording()")
        expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)
}

func testRecordingActiveFlagClearedOnAuthorizationFailure() {
    let voiceOutput = VoiceOutputManager()
    let inputManager = VoiceInputManager(voiceOutputManager: voiceOutput)

    // Regardless of actual authorization state, verify the invariant:
    // after startRecording() returns synchronously, the flag must not be
    // stuck true. Either recording started (flag stays true, cleared by
    // stopRecording) or it failed (flag cleared before return).
    inputManager.startRecording()

    if inputManager.authorizationStatus != .authorized {
        // Auth failed → flag must be cleared synchronously
        XCTAssertFalse(voiceOutput.isRecordingActive,
                       "Flag must be cleared when authorization check fails")
    } else {
        // Auth succeeded → flag stays true until stopRecording
        XCTAssertTrue(voiceOutput.isRecordingActive,
                      "Flag must remain set when recording starts successfully")
        inputManager.stopRecording()
    }
}
```

### Integration Tests

- Verify that `SessionSyncManager` auto-speak calls are suppressed during recording (mock VoiceOutputManager with recording-active flag set, send session history payload, assert no speak() calls proceed)
- Verify push-to-talk (Option+Space) path sets and clears the flag correctly

### Acceptance Criteria

1. While the microphone is recording, no TTS audio plays — regardless of the speak() caller
2. TTS resumes normally after recording stops
3. Speech that would have played during recording is dropped (not queued)
4. The flag is set synchronously at the top of `startRecording()` — zero race window with WebSocket-delivered messages
5. Every error exit path in `startRecording()` / `startRecordingAfterTTSStopped()` clears the flag
6. `resume()` is also suppressed during recording (prevents stray continueSpeaking into open mic)
7. Works identically on iOS and macOS
8. Push-to-talk (Option+Space on macOS) is covered without special handling
9. Existing macOS `isMuted` behavior is unaffected (orthogonal mechanism)
10. All existing VoiceOutputManager and VoiceInputManager tests continue to pass

## Alternatives Considered

### Gate at each SessionSyncManager call site

Check `voiceInput.isRecording` before each `speak()` call in SessionSyncManager.

**Rejected because:** Requires threading VoiceInputManager into SessionSyncManager (no reference today). Doesn't cover NotificationManager's direct `speak()` path. Requires remembering to add the check in every future speak() caller. The sink-level gate is simpler and comprehensive.

### Combine/publisher observation (VoiceOutputManager subscribes to VoiceInputManager.isRecording)

VoiceOutputManager could observe VoiceInputManager's `$isRecording` publisher.

**Rejected because:** Multiple VoiceInputManager instances exist — which one to observe? Would require a registry or shared singleton. The flag-setting approach is simpler: the instance that records sets the flag on the one VoiceOutputManager it already holds a reference to.

### Reuse macOS `isMuted` property, make it cross-platform

Extend `isMuted` to iOS and have recording toggle it.

**Rejected because:** `isMuted` is a user-facing setting (persisted to UserDefaults, toggled via Cmd+Shift+M, shown in Settings UI). Conflating automatic recording-suppression with user-intentional mute creates surprising behavior (recording would appear to "mute" the app permanently if UserDefaults is written). The two mechanisms have different lifecycles and semantics.

### Queue speech for playback after recording

Buffer suppressed speech and play it when recording stops.

**Rejected because:** By the time recording stops, the user has likely read the message on screen. Delayed TTS of already-read content is surprising and confusing. The goal is purely to kill the feedback loop, not to guarantee every message is heard aloud.

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Flag stuck `true` if VoiceInputManager deallocated during stop-completion window | Very low | User must restart app to hear TTS | `deinit` calls `stopRecording()` only if `isRecording == true`. If deallocation happens between flag-set and `isRecording = true` (the ~300ms stop-completion window), `deinit` won't clear the flag. In practice, the owning @StateObject view is on-screen when the user taps record, so deallocation during this window requires immediate navigation away — extremely unlikely. App relaunch resets all in-memory state regardless. |
| Multiple VoiceInputManagers conflict on the flag | Very low | TTS suppressed when it shouldn't be, or not suppressed when it should be | In practice only one records at a time (iOS audio hardware enforces single-recorder). Simple boolean is correct for this constraint. |
| Existing tests break due to new property | None | — | `isRecordingActive` defaults to `false`, so existing tests that don't set it behave identically to today. |
| Race between `stopRecording()` clearing the flag and a speak() call in the same runloop tick | Very low | One message might be suppressed after recording ends | Acceptable — the user just stopped recording, one dropped message is invisible to them. No corrective action needed. |

**Rollback:** Revert the three file changes (VoiceOutputManager.swift, VoiceInputManager.swift, new test file). No data migration, no protocol change, no backend involvement.
