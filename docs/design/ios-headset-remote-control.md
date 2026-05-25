# iOS Headset Remote Control

## Overview

### Problem Statement

`HeadsetRemoteCommandManager` and `BluetoothAudioMonitor` are wrapped in `#if os(macOS)` and are completely absent from the iOS build. AirPods and other Bluetooth headsets connected to an iPhone can receive media button events via `MPRemoteCommandCenter` — the same API the Mac app already uses — but no handler is registered, so single-press play/pause clicks do nothing in VoiceCode on iOS.

A compounding problem specific to iOS: `MPRemoteCommandCenter` only delivers events to an app that holds an active `AVAudioSession`. The Mac app sidesteps this because macOS media key routing is driven by `MPNowPlayingInfoCenter` ownership alone. On iOS, without an active audio session in between recordings, the click-to-start-recording command is silently dropped before reaching the app.

### Goals

1. AirPods (and any MFB-equipped Bluetooth headset) single-press starts/stops voice recording in the iOS app
2. AI responses are automatically spoken through the headset (the auto-speak path already exists)
3. Double-press or next-track button interrupts TTS mid-response
4. The feature works when the app is in the foreground and when locked / backgrounded
5. Headset mode can be toggled in iOS Settings without restarting the app

### Non-goals

- BlueParrott PTT mute detection on iOS (CoreAudio device property monitoring is not available on iOS; the MFB single-press path is sufficient for AirPods and similar headsets)
- Automatic Bluetooth audio routing (user sets input/output in iOS Settings)
- iOS-to-macOS parity for the PTT toggle in the Settings UI
- Backend protocol changes (audio is entirely client-side)

## Background & Context

### Current State

The macOS implementation is complete. `HeadsetRemoteCommandManager` registers with `MPRemoteCommandCenter`, maintains a now-playing slot, and coordinates the recording → send → speak cycle. `BluetoothAudioMonitor` extends this with CoreAudio mute-state detection for the BlueParrott PTT button. See @docs/design/headset-remote-control.md for the full macOS design.

The iOS app has `UIBackgroundModes: [audio]` declared in `Info.plist` and `VoiceOutputManager` already manages an iOS-specific `AVAudioPlayer` keep-alive (25-second silence pulses via `startKeepAliveTimer()`) to sustain background TTS. `VoiceInputManager` already has the iOS `AVAudioSession` wiring for recording (`.record` category in `startRecordingAfterTTSStopped()`). Neither registers with `MPRemoteCommandCenter`.

`SessionLookupView` already accepts `sharedVoiceInput: VoiceInputManager? = nil` and falls back to creating its own instance when not provided, so the view signature is forward-compatible.

**What is missing:**
- `HeadsetRemoteCommandManager` entirely absent from iOS build
- No shared `VoiceInputManager` instance at the iOS app level
- No `MPRemoteCommandCenter` registration
- No audio session keep-alive for the headset-idle (ready) state on iOS
- No headset settings section in the iOS `SettingsView`

### Why Now

A user tested the macOS headset feature with AirPods. When they clicked their AirPods, the iPhone (not the Mac) was the active Bluetooth media target, and the click went to whatever app owned the now-playing slot on the phone. There is no VoiceCode handler on iOS to catch that event.

### Related Work

- @docs/design/headset-remote-control.md — Full macOS design; iOS reuses the core state machine and command registration verbatim
- @docs/blueparrott-headset-integration.md — Original capability analysis; section 4 ("iOS") covers the same use cases described here

## Detailed Design

### Data Model

No new settings. The three existing headset settings in `AppSettings` — `headsetModeEnabled`, `headsetAutoSend`, `headsetPTTEnabled` — are already cross-platform. `headsetPTTEnabled` has no effect on iOS (BluetoothAudioMonitor is macOS-only) and should be hidden from the iOS settings UI.

No CoreData changes. No migration needed.

### API Design

No HTTP or WebSocket protocol changes. The existing `prompt` message type carries all headset-initiated transcriptions, identical to the macOS path.

### Code Examples

#### Change 1: Cross-platform HeadsetRemoteCommandManager

Remove the `#if os(macOS)` file-level guard. Keep `BluetoothAudioMonitor` usage inside a nested `#if os(macOS)`. Add an iOS-specific audio session keep-alive block.

```swift
// HeadsetRemoteCommandManager.swift
// Remove: #if os(macOS)  ← delete this guard

import Foundation
import MediaPlayer
import Combine
import os.log
#if os(iOS)
import AVFoundation
#endif

// ... (existing class body unchanged) ...

func activate() {
    guard !isActive else { return }
    registerRemoteCommands()
    #if os(macOS)
    if settings.headsetPTTEnabled { startPTTMonitoring() }
    #elseif os(iOS)
    activateAudioSession()
    interruptionObserver = NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: AVAudioSession.sharedInstance(),
        queue: .main
    ) { [weak self] notification in
        guard let self = self, self.isActive else { return }
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue),
              type == .ended else { return }
        let shouldResume = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
            .flatMap { AVAudioSession.InterruptionOptions(rawValue: $0) }
            .map { $0.contains(.shouldResume) } ?? false
        if shouldResume {
            self.activateAudioSession()
            logger.info("Headset: audio session restored after interruption")
        }
    }
    #endif
    updateNowPlayingState()
    isActive = true
    logger.info("Headset remote control activated")
}

func deactivate() {
    guard isActive else { return }
    if state == .recording { voiceInput.stopRecording() }
    #if os(macOS)
    stopPTTMonitoring()
    #endif
    unregisterRemoteCommands()
    #if os(iOS)
    if let token = interruptionObserver {
        NotificationCenter.default.removeObserver(token)
        interruptionObserver = nil
    }
    deactivateAudioSession()
    #endif
    MPNowPlayingInfoCenter.default().playbackState = .unknown
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    isActive = false
    state = .ready
    logger.info("Headset remote control deactivated")
}
```

In `stopRecordingAndSend()`, re-assert the playback session after `VoiceInputManager` releases the `.record` category:

```swift
private func stopRecordingAndSend() {
    voiceInput.stopRecording()
    #if os(iOS)
    // Re-assert playback session now that .record is released.
    // Without this, MPRemoteCommandCenter loses our app as the delivery
    // target during the sending/ready gap before TTS starts.
    activateAudioSession()
    #endif
    state = .sending
    updateNowPlayingState()
    // ... (existing async send logic unchanged) ...
}
```

The PTT extension (`startPTTMonitoring` / `stopPTTMonitoring`) and `BluetoothAudioMonitor` stay inside `#if os(macOS)` in their existing extension file.

#### Change 2: iOS audio session keep-alive

Add an `#if os(iOS)` extension to `HeadsetRemoteCommandManager` that maintains a `.playback` + `.mixWithOthers` session while headset mode is active. This keeps the app in the Now Playing slot and ensures `MPRemoteCommandCenter` routes single-press commands to us during the idle (ready) state.

```swift
// HeadsetRemoteCommandManager.swift — iOS audio session extension

#if os(iOS)
extension HeadsetRemoteCommandManager {

    func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setActive(true)
            startKeepAlive()
            logger.info("Headset: iOS audio session activated (.playback + .mixWithOthers)")
        } catch {
            logger.error("Headset: failed to activate audio session: \(error.localizedDescription)")
        }
    }

    func deactivateAudioSession() {
        stopKeepAlive()
        do {
            try AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation
            )
            logger.info("Headset: iOS audio session deactivated")
        } catch {
            logger.error("Headset: failed to deactivate audio session: \(error.localizedDescription)")
        }
    }

    private func startKeepAlive() {
        stopKeepAlive()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: true) { [weak self] _ in
            self?.keepAlivePlayer?.play()
        }
    }

    private func stopKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }
}
#endif
```

Add the backing storage to the class body (inside `#if os(iOS)`):

```swift
#if os(iOS)
private var keepAlivePlayer: AVAudioPlayer?
private var keepAliveTimer: Timer?
#endif
```

Initialize `keepAlivePlayer` in a helper called from `init()`:

```swift
#if os(iOS)
private func setupKeepAlive() {
    // 100ms silent PCM buffer — identical to VoiceOutputManager.setupSilencePlayer()
    let sampleRate: Double = 44100.0
    let frameCount = UInt32(0.1 * sampleRate)
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
    buffer.frameLength = frameCount
    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("headset_silence.caf")
    do {
        let file = try AVAudioFile(forWriting: tempURL, settings: format.settings)
        try file.write(from: buffer)
        keepAlivePlayer = try AVAudioPlayer(contentsOf: tempURL)
        keepAlivePlayer?.prepareToPlay()
    } catch {
        logger.error("Headset: failed to create silence player: \(error.localizedDescription)")
    }
}
#endif
```

Call `setupKeepAlive()` at the end of `init()`:

```swift
#if os(iOS)
setupKeepAlive()
#endif
```

#### Change 3: Wire VoiceInputManager at the iOS app level

`VoiceInputManager` is currently view-local on iOS — each `ConversationView` creates its own instance. Headset mode requires a single shared instance so that recording triggered by a headset button is visible to the on-screen UI, and vice versa.

```swift
// VoiceCodeApp.swift

struct VoiceCodeApp: App {
    // Existing declarations ...

    // Both properties are now unconditional — HeadsetRemoteCommandManager is
    // cross-platform and VoiceInputManager is needed at app level on both platforms.
    @StateObject private var voiceInput: VoiceInputManager
    @StateObject private var headsetManager: HeadsetRemoteCommandManager

    init() {
        // Existing setup (settings, voiceManager, voiceClient, resManager) ...

        // Shared voice input — hoisted for both platforms
        let sharedVoiceInput = VoiceInputManager(voiceOutputManager: voiceManager)
        _voiceInput = StateObject(wrappedValue: sharedVoiceInput)

        let headset = HeadsetRemoteCommandManager(
            voiceInput: sharedVoiceInput,
            voiceOutput: voiceManager,
            client: voiceClient,
            settings: settings
        )
        _headsetManager = StateObject(wrappedValue: headset)

        // Remove the existing #if os(macOS) blocks that previously declared these.
    }
}
```

With both properties unconditional, the `#if os(macOS)` guards that previously wrapped `voiceInput` and `headsetManager` in the struct body are deleted. The `HeadsetRemoteCommandManager` init signature is identical on both platforms now that the class is cross-platform. Any other code in the app that references `headsetManager` inside a `#if os(macOS)` block (e.g. the `Commands` menu, the Settings scene) should remain guarded — only the property declaration itself becomes unconditional.

Pass `voiceInput` through the `navigationDestination` closure in `VoiceCodeApp.body`:

```swift
// VoiceCodeApp.body — iOS NavigationStack path

NavigationStack(path: $navigationPath) {
    DirectoryListView(
        client: client,
        settings: settings,
        voiceOutput: voiceOutput,
        showingSettings: $showingSettings,
        recentSessions: $recentSessions,
        navigationPath: $navigationPath,
        resourcesManager: resourcesManager
        // No voiceInput here — DirectoryListView navigates via UUID path values,
        // not by constructing SessionLookupView directly
    )
    .navigationDestination(for: UUID.self) { sessionId in
        SessionLookupView(
            sessionId: sessionId,
            client: client,
            voiceOutput: voiceOutput,
            settings: settings,
            sharedVoiceInput: voiceInput   // ← pass shared instance (param already exists)
        )
    }
    // ... other destinations unchanged ...
}
```

`DirectoryListView` and `SessionsForDirectoryView` both navigate by pushing UUID values onto the navigation path via `NavigationLink(value: session.id)`. The `navigationDestination(for: UUID.self)` closure defined at the `NavigationStack` level captures `voiceInput` from the app scope and injects it into `SessionLookupView`. Neither intermediate view needs a `voiceInput` parameter. `SessionLookupView` already accepts `sharedVoiceInput: VoiceInputManager? = nil` and passes it to `ConversationView`, so no further changes are needed below that layer.

#### Change 4: iOS Settings UI

Add a "Headset" section to the existing `SettingsView`. No PTT toggle — `BluetoothAudioMonitor` is macOS-only.

```swift
// SettingsView.swift — add below the existing "Audio Playback" section (iOS path)

#if os(iOS)
Section(header: Text("Headset")) {
    Toggle("Enable headset control", isOn: $settings.headsetModeEnabled)
    Text("Single-press play/pause on AirPods or any Bluetooth headset starts and stops recording.")
        .font(.caption)
        .foregroundColor(.secondary)

    if settings.headsetModeEnabled {
        Toggle("Auto-send on recording stop", isOn: $settings.headsetAutoSend)
        Text("Transcription is sent to the active session automatically when you press stop.")
            .font(.caption)
            .foregroundColor(.secondary)
    }
}
#endif
```

No "Reclaim" button is needed in the iOS settings — on iOS the Now Playing slot is managed by the system more aggressively, and the app will re-assert on the next `activateAudioSession()` call (which happens automatically on `activate()` and on each `stopRecordingAndSend()`).

#### Change 5: Inject headsetManager into the iOS environment

`headsetManager` is created at the `VoiceCodeApp` level but the iOS `RootView` currently receives no reference to it — unlike macOS, where it is passed as an `.environmentObject` to the Settings scene. For the iOS settings section to access manager state, and for the foreground re-assertion observer (see Risks), `RootView` on iOS must also have access to it.

The least-invasive fix is injecting it as an environment object alongside the existing `draftManager` injection:

```swift
// VoiceCodeApp.body — iOS WindowGroup body

#else
RootView(
    settings: settings,
    voiceOutput: voiceOutput,
    client: client,
    resourcesManager: resourcesManager
)
.environment(\.managedObjectContext, persistenceController.container.viewContext)
.environmentObject(draftManager)
.environmentObject(headsetManager)   // ← new for iOS
#endif
```

Environment objects flow through SwiftUI's environment automatically, including into sheets. The `settingsView` sheet presented by `RootView` will therefore have `headsetManager` available without any changes to `RootView`'s parameter list or the `settingsView` computed property.

To access `headsetManager` inside `RootView` (for the foreground re-assertion observer — see Risks), add an environment object property inside an `#if os(iOS)` guard:

```swift
// RootView — iOS only
#if os(iOS)
@EnvironmentObject private var headsetManager: HeadsetRemoteCommandManager
#endif
```

To access it in `SettingsView` for the headset section, add the same declaration inside `#if os(iOS)` in `SettingsView`.

### Component Interactions

#### Single-press AirPods → start recording (iOS)

```
User presses AirPods stem once (foreground or locked screen)
    │
    ▼
iOS routes togglePlayPauseCommand to the app holding the active
AVAudioSession + nowPlayingInfo slot (VoiceCode, when headset mode is on)
    │
    ▼
HeadsetRemoteCommandManager.handleTogglePlayPause()
    │  state == .ready
    ▼
startRecording()
    ├── guard client.isConnected
    ├── state = .recording
    ├── updateNowPlayingState() → "VoiceCode — Recording"
    └── VoiceInputManager.startRecording()
        ├── AVAudioSession.setCategory(.record, .duckOthers)  ← overrides our .playback session
        └── AVAudioEngine + SFSpeechRecognizer begin capture

User presses AirPods stem once again
    │
    ▼
togglePlayPauseCommand  →  handleTogglePlayPause()
    │  state == .recording
    ▼
stopRecordingAndSend()
    ├── VoiceInputManager.stopRecording()       ← releases .record session
    ├── activateAudioSession()                  ← iOS: re-asserts .playback + .mixWithOthers
    ├── state = .sending
    ├── updateNowPlayingState() → "VoiceCode — Processing"
    └── [async, next run-loop tick]
        └── sendToActiveSession(transcription)
            ├── createOptimisticMessage(...)
            └── client.sendMessage({type: "prompt", ...})

[backend responds]

SessionSyncManager auto-speak path (existing)
    └── VoiceOutputManager.speak(responseText)
        └── AVAudioSession.setCategory(.playback)  ← overrides our .mixWithOthers session, fine

voiceOutput.$isSpeaking → true
    └── HeadsetRemoteCommandManager: state = .speaking

[TTS completes]

voiceOutput.$isSpeaking → false
    └── HeadsetRemoteCommandManager: state = .ready
        └── (iOS: audio session was released by VoiceOutputManager; re-assert on next activate() cycle
             or next recording stop — not needed until the next recording attempt since
             MPRemoteCommandCenter will deliver commands while isSpeaking is true via VoiceOutputManager's session)
```

**Session gap note:** There is a window between TTS ending and the next user press where VoiceOutputManager has released its session and our keep-alive has not re-asserted. During this window, the next AirPods press might not be delivered. To close this gap, observe `voiceOutput.$isSpeaking` in the iOS path and re-call `activateAudioSession()` when it transitions to `false` and state returns to `.ready`:

```swift
// In HeadsetRemoteCommandManager.init() — extend the existing isSpeaking sink:
voiceOutput.$isSpeaking
    .receive(on: DispatchQueue.main)
    .sink { [weak self] isSpeaking in
        guard let self = self, self.isActive else { return }
        if isSpeaking && self.state == .sending {
            self.state = .speaking
            self.updateNowPlayingState()
        } else if !isSpeaking && self.state == .speaking {
            self.state = .ready
            self.updateNowPlayingState()
            #if os(iOS)
            self.activateAudioSession()  // re-claim session after TTS ends
            #endif
        }
    }
    .store(in: &cancellables)
```

#### Audio session ownership timeline

```
Headset mode OFF  ─────── Headset mode ON ──────────────────────────────────
                  │
                  ├── activate()
                  │    └── AVAudioSession: .playback + .mixWithOthers (headset keep-alive)
                  │        MPNowPlayingInfo: "Ready" / .paused
                  │
                  ├── User presses AirPods → startRecording()
                  │    └── VoiceInputManager: .record (overrides keep-alive — expected)
                  │        MPNowPlayingInfo: "Recording" / .playing
                  │
                  ├── User presses AirPods → stopRecordingAndSend()
                  │    └── VoiceInputManager releases .record
                  │        activateAudioSession() re-asserts .playback + .mixWithOthers
                  │        MPNowPlayingInfo: "Processing" / .paused
                  │
                  ├── VoiceOutputManager.speak() fires
                  │    └── VoiceOutputManager: .playback (no conflict — both are .playback)
                  │        MPNowPlayingInfo: "Speaking" / .playing
                  │
                  ├── TTS ends → isSpeaking = false
                  │    └── activateAudioSession() re-asserts .playback + .mixWithOthers
                  │        MPNowPlayingInfo: "Ready" / .paused
                  │
                  │    (cycle repeats)
                  │
                  └── deactivate()
                       └── deactivateAudioSession()
                           MPNowPlayingInfo cleared
```

#### Dependencies

```
VoiceCodeApp (iOS)
    ├── HeadsetRemoteCommandManager  ← previously macOS-only, now cross-platform
    │   ├── VoiceInputManager        ← hoisted to app level (was view-local on iOS)
    │   ├── VoiceOutputManager       ← existing
    │   ├── VoiceCodeClient          ← existing
    │   ├── AppSettings              ← existing
    │   └── [macOS only] BluetoothAudioMonitor
    └── voiceInput (shared)
        └── passed to SessionLookupView → ConversationView (replaces per-view instance)
```

## Verification Strategy

### Testing Approach

#### Unit Tests

All new unit tests belong in the existing `VoiceCodeTests` target (iOS) and should be guarded as needed. The `HeadsetRemoteCommandManagerTests` that already exist in the macOS target cover the state machine — those tests should be made to compile on iOS as well now that the class is cross-platform.

1. **State machine** — verify all `togglePlayPause` × state combinations on iOS. Make the existing `HeadsetRemoteCommandManagerTests.swift` compile in the iOS target with two mechanical changes: (a) remove `"HeadsetRemoteCommandManagerTests.swift"` from the `excludes` list under `VoiceCodeTests` in `project.yml`; (b) remove the `#if os(macOS)` outer file guard from `HeadsetRemoteCommandManagerTests.swift` (the comment already calls it "a secondary safeguard"). Any PTT test cases that depend on `BluetoothAudioMonitor` should stay inside a nested `#if os(macOS)` block. No mock class duplication is needed — once the file is in both targets, `MockVoiceInputForHeadset`, `MockVoiceOutputForHeadset`, and `MockVoiceCodeClientForHeadset` compile on iOS as well.
2. **Audio session activation** — verify `activateAudioSession()` sets `.playback` + `.mixWithOthers` category and that `deactivateAudioSession()` calls `setActive(false, .notifyOthersOnDeactivation)`.
3. **Session re-assertion** — verify that `stopRecordingAndSend()` calls `activateAudioSession()` on iOS (via the existing `simulatePause()` test hook).
4. **TTS-end re-assertion** — verify that transitioning `isSpeaking` from `true` to `false` while in `.speaking` state calls `activateAudioSession()` on iOS.

#### Integration Tests

1. **VoiceInputManager coordination** — with the shared instance at app level, verify that starting recording via `simulateTogglePlayPause()` sets `VoiceInputManager.isRecording = true` and that the on-screen mic button reflects this state.
2. **Settings reactivity** — toggling `headsetModeEnabled` from the iOS settings activates / deactivates the manager without app restart; verify `isActive` changes accordingly.

#### End-to-End Tests (Manual, with AirPods)

1. Open iOS app, connect AirPods, enable "Headset control" in Settings
2. Single-press AirPods stem → verify recording starts (microphone icon becomes active)
3. Speak a phrase → verify partial transcription appears on screen
4. Single-press again → verify recording stops and prompt is sent
5. Wait for AI response → verify TTS plays through AirPods
6. Double-press (or press again during TTS) → verify TTS stops
7. Lock the phone with headset mode on → single-press from lock screen → verify recording starts
8. Open Spotify, play a song → verify AirPods route to Spotify
9. Return to VoiceCode, toggle headset mode off and back on → verify AirPods route back

### Test Examples

After applying the state machine portability change (item 1 above), `HeadsetRemoteCommandManagerTests.swift` compiles in both the `VoiceCodeTests` (iOS) and `VoiceCodeMacTests` targets. iOS-specific audio session tests still go in a **separate file** — they depend on `AVFoundation` APIs (`AVAudioSession`) that do not exist on macOS — and reference the mock classes from the shared test file directly.

Create `VoiceCodeTests/HeadsetRemoteCommandManagerIOSTests.swift`:

```swift
// VoiceCodeTests/HeadsetRemoteCommandManagerIOSTests.swift
// Add to VoiceCodeTests target (iOS), NOT to VoiceCodeMacTests.

#if os(iOS)
import AVFoundation
import XCTest
@testable import VoiceCode

final class HeadsetIOSAudioSessionTests: XCTestCase {

    // MARK: - Helpers
    // MockVoiceInputForHeadset, MockVoiceOutputForHeadset, and MockVoiceCodeClientForHeadset
    // are defined in HeadsetRemoteCommandManagerTests.swift. That file is added to the
    // VoiceCodeTests (iOS) target as part of Issue 4 above, so no duplication is needed here.

    private struct Mocks {
        let voiceInput: MockVoiceInputForHeadset
        let voiceOutput: MockVoiceOutputForHeadset
        let client: MockVoiceCodeClientForHeadset
        let settings: AppSettings
    }

    private let testSessionId = UUID()

    private func makeManager() -> (HeadsetRemoteCommandManager, Mocks) {
        let settings = AppSettings()
        let output = MockVoiceOutputForHeadset(appSettings: settings)
        let input = MockVoiceInputForHeadset(voiceOutputManager: output)
        let syncManager = SessionSyncManager(
            persistenceController: PersistenceController(inMemory: true),
            voiceOutputManager: output
        )
        let client = MockVoiceCodeClientForHeadset(
            serverURL: "ws://localhost:8080",
            voiceOutputManager: output,
            sessionSyncManager: syncManager,
            appSettings: settings,
            setupObservers: false
        )
        client.isConnected = true
        let sessionId = testSessionId
        let manager = HeadsetRemoteCommandManager(
            voiceInput: input,
            voiceOutput: output,
            client: client,
            settings: settings,
            resolveActiveSession: { (sessionId, "/test/working-dir") }
        )
        return (manager, Mocks(voiceInput: input, voiceOutput: output, client: client, settings: settings))
    }

    // MARK: - Audio Session Tests

    func testActivate_activatesAudioSession() {
        let (manager, _) = makeManager()
        let session = AVAudioSession.sharedInstance()

        manager.activate()

        XCTAssertEqual(session.category, .playback)
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers))
    }

    func testDeactivate_setsManagerInactive() {
        let (manager, _) = makeManager()
        manager.activate()

        manager.deactivate()

        XCTAssertFalse(manager.isActive)
    }

    func testStopRecordingAndSend_reassertsAudioSession() {
        let (manager, mocks) = makeManager()
        manager.activate()
        manager.simulateTogglePlayPause()   // → .recording
        mocks.voiceInput.transcribedText = "test"

        // activateAudioSession() is called synchronously inside stopRecordingAndSend()
        // before the async text-read defer, so the session assertion is valid here.
        manager.simulatePause()

        let session = AVAudioSession.sharedInstance()
        XCTAssertEqual(session.category, .playback)
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers))
    }

    func testTTSEnd_reassertsAudioSession() {
        let (manager, mocks) = makeManager()
        manager.activate()
        manager.simulateTogglePlayPause()   // → .recording
        mocks.voiceInput.transcribedText = "test"
        manager.simulatePause()             // → .sending

        mocks.voiceOutput.isSpeaking = true  // → .speaking (via Combine sink)

        let speakExp = expectation(description: "speaking")
        DispatchQueue.main.async {
            XCTAssertEqual(manager.state, .speaking)
            speakExp.fulfill()
        }
        wait(for: [speakExp], timeout: 1)

        mocks.voiceOutput.isSpeaking = false  // → .ready + activateAudioSession()

        let readyExp = expectation(description: "ready + session re-asserted")
        DispatchQueue.main.async {
            XCTAssertEqual(manager.state, .ready)
            XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
            readyExp.fulfill()
        }
        wait(for: [readyExp], timeout: 1)
    }
}
#endif
```

### Acceptance Criteria

1. With "Enable headset control" toggled on in iOS Settings, single-pressing AirPods starts voice recording in the VoiceCode iOS app
2. Single-pressing again stops recording and sends the transcription to the active session
3. The AI response is automatically spoken through the AirPods (existing auto-speak path)
4. Pressing AirPods during TTS playback stops TTS immediately
5. Now-playing info updates to reflect current state (Ready / Recording / Processing / Speaking) — visible on the iOS lock screen and Control Center
6. The feature works from the lock screen with AirPods connected (background audio)
7. Toggling "Enable headset control" off in Settings stops routing AirPods clicks to VoiceCode without restarting the app
8. When the client is not connected to the backend, AirPods presses are ignored with a logged warning
9. Empty transcriptions (silence or whitespace) do not send a prompt and return to ready state
10. `VoiceInputManager.isRecording` observed by the on-screen microphone button reflects headset-triggered recording (shared instance visible to the UI)

## Alternatives Considered

### Keep HeadsetRemoteCommandManager macOS-only; add a separate iOS class

**Approach:** Create `IOSHeadsetRemoteCommandManager.swift` with the iOS-specific audio session handling baked in, duplicating the state machine.

**Why rejected:** The state machine (ready / recording / sending / speaking), the `MPRemoteCommandCenter` registration, and the `VoiceInputManager` / `VoiceOutputManager` coordination are identical on both platforms. Duplicating 300 lines to avoid a handful of `#if os(iOS)` blocks is worse than the alternative.

### Use VoiceOutputManager's existing keep-alive for idle state

**Approach:** Expose `startKeepAliveTimer()` and `stopKeepAliveTimer()` as `internal` on `VoiceOutputManager`, then call them from `HeadsetRemoteCommandManager` when headset mode is active but not recording.

**Why rejected:** `VoiceOutputManager`'s keep-alive is coupled to TTS lifecycle (`continuePlaybackWhenLocked` guard, started when speech begins). Reusing it for a different purpose — keeping the session alive while idle — would require either removing the `continuePlaybackWhenLocked` guard for the headset path or adding a new parameter. A separate keep-alive in `HeadsetRemoteCommandManager` is simpler and avoids coupling two unrelated features. The silence player code is small enough that duplication is not a burden.

### AVAudioSession keep-alive using a long silent AVSpeechSynthesizer utterance

**Approach:** Speak a zero-length or space-only utterance periodically to keep the session alive.

**Why rejected:** `AVSpeechSynthesizer` utterances appear in the system's speech queue, may interact with VoiceOutputManager's in-flight utterances, and require `AVSpeechSynthesizerDelegate` cooperation. An `AVAudioPlayer` playing a silent PCM buffer (already the pattern in `VoiceOutputManager`) is lower-level, has no side effects on the speech queue, and is proven in production by the existing TTS keep-alive.

### Continuous audio session (never deactivate between states)

**Approach:** Activate once on `activate()` and never call `setActive(false)` until `deactivate()`, relying on iOS not reclaiming the session.

**Why (partly) adopted:** This is actually the design — `activateAudioSession()` is called on `activate()` and on each `stopRecordingAndSend()` and TTS-end. We do not call `setActive(false)` between states. The only deactivation is in `deactivate()`. The keep-alive timer is still needed to prevent iOS from reclaiming the session when the app is backgrounded for extended periods.

## Risks & Mitigations

### Audio session conflicts with other iOS apps

**Risk:** `.playback` + `.mixWithOthers` lets our session coexist with other audio, but VoiceInputManager's `.record` + `.duckOthers` category ducks other apps during recording. After `stopRecording()`, we re-assert `.playback` + `.mixWithOthers`, but there is a brief window where the duck is not released.

**Detection:** User reports background audio (podcast, music) staying ducked after stopping recording.

**Mitigation:** `VoiceInputManager.stopRecording()` calls `audioSession.setActive(false, options: .notifyOthersOnDeactivation)` which should signal other apps to resume. Verify this in integration testing. If not, add explicit `setActive(false, .notifyOthersOnDeactivation)` before our `activateAudioSession()` call in `stopRecordingAndSend()`.

### Now-playing slot stolen by other iOS apps

**Risk:** When the user switches to Spotify or opens Apple Music, that app claims the now-playing slot. Subsequent AirPods clicks route to that app rather than VoiceCode.

**Detection:** AirPods clicks stop working in VoiceCode after using another media app.

**Mitigation:** On iOS, when VoiceCode returns to the foreground, re-call `reclaimNowPlaying()` on the headset manager. `RootView` already has a `UIApplication.willEnterForegroundNotification` observer; extend it with the headset reclaim (requires Change 5 — `headsetManager` as an environment object in `RootView`):

```swift
// RootView — extend the existing iOS foreground handler
.onReceive(NotificationCenter.default.publisher(
    for: UIApplication.willEnterForegroundNotification
)) { _ in
    resourcesManager.updatePendingCount()
    if client.isConnected {
        resourcesManager.processPendingUploads()
    }
    #if os(iOS)
    headsetManager.reclaimNowPlaying()   // ← re-assert Now Playing slot
    #endif
}
```

`reclaimNowPlaying()` already guards on `headsetModeEnabled`, so it is a no-op when headset mode is off. No explicit "Reclaim" button is needed in the UI.

### Phone call interruption

**Risk:** An incoming phone call preempts the `AVAudioSession`, causing it to be deactivated. After the call ends, our session is not automatically restored.

**Detection:** AirPods clicks stop working after a phone call.

**Mitigation:** Observe `AVAudioSession.interruptionNotification`. On `.ended` with `shouldResume = true`, call `activateAudioSession()`. The observer is registered in `activate()` and removed in `deactivate()` — see Change 1 for the complete implementation. The token is stored in `interruptionObserver: NSObjectProtocol?` (added to the class body inside `#if os(iOS)` alongside `keepAlivePlayer` and `keepAliveTimer`); the block-based `addObserver` form must have its token stored explicitly or the observer is silently removed when the local variable goes out of scope.

### Shared VoiceInputManager instance conflicts

**Risk:** Headset-triggered recording and UI-triggered recording both call `VoiceInputManager.startRecording()`. If both fire simultaneously (e.g., headset press exactly as user taps mic), `startRecordingAfterTTSStopped()` may be entered twice, creating two `AVAudioEngine` instances.

**Detection:** Test harness: call `startRecording()` twice in rapid succession, verify single engine.

**Mitigation:** `VoiceInputManager.startRecording()` already calls `recognitionTask?.cancel()` and `audioEngine?.stop()` before creating a new engine — the second call safely tears down the first. Verify this guard covers the concurrent case. Add a `guard !isRecording` early-exit if needed.

### Rollback

All new iOS behavior is behind `headsetModeEnabled` (default: false). Toggling it off stops all `MPRemoteCommandCenter` registration and audio session keep-alive immediately. No schema changes, no protocol changes, no migration.
