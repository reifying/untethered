# Headset Remote Control (BlueParrott B450-XT)

## Overview

### Problem Statement

VoiceCode's push-to-talk on macOS (`Option+Space` via `PushToTalkModifier.swift`) requires the app window to be focused — it uses SwiftUI's `onKeyPress`, which only fires when the view has keyboard focus. This makes it impossible to have a hands-free conversation while away from the desk. The MenuBar quick-capture similarly requires clicking or having the popover focused.

Neither the Mac nor iOS app registers with `MPRemoteCommandCenter`, so Bluetooth headset buttons (play/pause, next/previous track) are completely ignored by the app.

### Goals

1. Map the BlueParrott B450-XT multifunction button (play/pause) to toggle voice recording on macOS — works regardless of which app is frontmost
2. Auto-send transcription and auto-speak AI responses to create a continuous hands-free conversation loop
3. Provide interrupt control (stop TTS mid-response) via headset buttons
4. Map the BlueParrott PTT button (mute/unmute) as an alternate recording trigger via CoreAudio device property monitoring

### Non-goals

- Always-listening / wake-word detection
- iOS headset support (separate effort, can reuse the architecture but requires a React Native native module bridge)
- Custom HID vendor report parsing (requires sandbox escape)
- Automatic audio device routing (user sets input/output in System Settings)
- Backend protocol changes (audio is entirely client-side)

## Background & Context

### Current State

**Mac voice input pipeline:**

```
PushToTalkModifier          ConversationVoiceInputView       MenuBarContentView
(Option+Space hold)         (tap mic button)                 (Space / click mic)
        │                           │                               │
        ▼                           ▼                               ▼
VoiceInputManager.startRecording()                    toggleRecording()
        │                                                    │
        ▼                                                    ▼
AVAudioEngine + SFSpeechRecognizer              VoiceInputManager
        │                                                    │
        ▼                                                    ▼
VoiceInputManager.stopRecording()               sendQuickPrompt()
        │
        ▼
ConversationView.sendPromptText()    ← user must tap "Stop" then
        │                              text auto-sends
        ▼
VoiceCodeClient.sendMessage({type: "prompt", ...})
```

All three input paths require window focus or direct click interaction. None respond to system media key events.

**Mac auto-speak pipeline (already exists):**

`SessionSyncManager.swift:598-613` — when new assistant messages arrive for the active session, they are automatically spoken via `VoiceOutputManager.speak()`. This runs on the main thread after CoreData save, checks `ActiveSessionManager.shared.isActive(sessionUUID)` to avoid TTS for background sessions, and passes `respectSilentMode: true`.

**Missing piece:** There is no path from "headset button pressed" → "start/stop recording" → "auto-send transcription". The auto-speak half already works.

### Why Now

Travis just purchased a BlueParrott B450-XT for hands-free AI conversations. Corporate IT restricts him to the Mac desktop app, and he needs to converse while away from his desk.

### Related Work

- @docs/blueparrott-headset-integration.md — Capability analysis and recommendation overview
- @docs/design/macos-desktop-redesign.md — Prior Mac UX work (introduced PTT, MenuBar, command palette)
- @docs/design/desktop-ux-improvements.md — Keyboard shortcut conventions

## Detailed Design

### Data Model

#### AppSettings Additions

```swift
// AppSettings.swift — new properties

/// When true, the app registers with MPRemoteCommandCenter to receive
/// headset button events (play/pause toggles recording). Defaults to false
/// to avoid claiming the now-playing slot from media apps unexpectedly.
@Published var headsetModeEnabled: Bool {
    didSet {
        UserDefaults.standard.set(headsetModeEnabled, forKey: "headsetModeEnabled")
    }
}

/// When true (and headsetModeEnabled), monitors CoreAudio Bluetooth input
/// device mute property to detect BlueParrott PTT button presses.
@Published var headsetPTTEnabled: Bool {
    didSet {
        UserDefaults.standard.set(headsetPTTEnabled, forKey: "headsetPTTEnabled")
    }
}

/// When true, recording stop automatically sends transcription to the
/// active session without requiring the user to review/confirm.
/// Only applies to headset-initiated recordings (not manual UI taps).
@Published var headsetAutoSend: Bool {
    didSet {
        UserDefaults.standard.set(headsetAutoSend, forKey: "headsetAutoSend")
    }
}
```

Initialize in `AppSettings.init()`:

```swift
self.headsetModeEnabled = UserDefaults.standard.bool(forKey: "headsetModeEnabled")
self.headsetPTTEnabled = UserDefaults.standard.bool(forKey: "headsetPTTEnabled")
// Default auto-send to true — headset mode without auto-send is unusable
self.headsetAutoSend = UserDefaults.standard.object(forKey: "headsetAutoSend") as? Bool ?? true
```

No CoreData schema changes. No migration needed.

### API Design

No HTTP/WebSocket protocol changes. The existing `prompt` message type carries all headset-initiated transcriptions. The backend is completely unaware of the input modality.

### Prerequisite: VoiceInputManager Shared Instance

Today, `VoiceInputManager` is independently instantiated in three places:

1. `ConversationView` — `@StateObject var voiceInput: VoiceInputManager` (line 47), created with a default in `init()` (line 85)
2. `MenuBarContentView` — `@StateObject private var voiceInput: VoiceInputManager` (line 28), created in `init()` (line 39)
3. The new `HeadsetRemoteCommandManager` needs its own reference

If the headset manager holds a separate instance, recording started via the headset won't be visible in the ConversationView, and `transcribedText` from one instance won't propagate to the other.

**Resolution: Hoist to App level and pass down.**

```swift
// VoiceCodeApp.swift — create VoiceInputManager at the App level

#if os(macOS)
@StateObject private var voiceInput: VoiceInputManager
#endif

// In init(), before creating headsetManager:
#if os(macOS)
let sharedVoiceInput = VoiceInputManager(voiceOutputManager: voiceManager)
_voiceInput = StateObject(wrappedValue: sharedVoiceInput)
#endif
```

Downstream changes required:

1. **`ConversationView`**: Change `@StateObject var voiceInput: VoiceInputManager` to `@ObservedObject var voiceInput: VoiceInputManager`. Remove the default value from `init()`. The caller (`SessionLookupView` or equivalent) must pass the app-level instance.

2. **`MenuBarContentView`**: Same change — `@StateObject` → `@ObservedObject`. The `VoiceCodeMenuBarExtra` scene receives the shared instance and passes it to `MenuBarContentView`.

3. **`VoiceCodeMenuBarExtra`**: Add a `voiceInput: VoiceInputManager` parameter. Update `VoiceCodeApp.body` to pass it:
   ```swift
   VoiceCodeMenuBarExtra(
       client: client,
       settings: settings,
       voiceOutput: voiceOutput,
       voiceInput: voiceInput  // new
   )
   ```

4. **`SessionLookupView`** (or wherever `ConversationView` is instantiated): Pass the shared `voiceInput` through.

This follows the existing pattern — `VoiceOutputManager` and `VoiceCodeClient` are already created at the App level and passed down via `@ObservedObject`. `VoiceInputManager` was the exception because it was only used locally; headset mode makes it app-wide.

**iOS impact:** None. On iOS, `VoiceInputManager` remains view-local since headset mode is macOS-only. The `ConversationView.init()` default parameter (`voiceInput: VoiceInputManager = VoiceInputManager()`) is removed on macOS but kept on iOS via `#if os(iOS)`.

### Code Examples

#### Component 1: HeadsetRemoteCommandManager

Central coordinator for headset button events. Owns the `MPRemoteCommandCenter` registration and orchestrates the recording → send → speak cycle.

```swift
// ios/VoiceCode/Managers/HeadsetRemoteCommandManager.swift

#if os(macOS)
import Foundation
import MediaPlayer
import Combine
import os.log

private let logger = Logger(subsystem: "dev.910labs.voice-code", category: "HeadsetRemote")

class HeadsetRemoteCommandManager: ObservableObject {
    @Published var isActive = false

    private let voiceInput: VoiceInputManager
    private let voiceOutput: VoiceOutputManager
    private let client: VoiceCodeClient
    private let settings: AppSettings
    private let resolveActiveSession: () -> (sessionId: UUID, workingDirectory: String)?
    private var cancellables = Set<AnyCancellable>()

    enum HeadsetState: CustomStringConvertible {
        case ready
        case recording
        case sending
        case speaking

        var description: String {
            switch self {
            case .ready: "Ready"
            case .recording: "Recording"
            case .sending: "Processing"
            case .speaking: "Speaking"
            }
        }
    }

    @Published private(set) var state: HeadsetState = .ready

    init(voiceInput: VoiceInputManager,
         voiceOutput: VoiceOutputManager,
         client: VoiceCodeClient,
         settings: AppSettings,
         resolveActiveSession: @escaping () -> (sessionId: UUID, workingDirectory: String)? = {
             guard let sessionId = ActiveSessionManager.shared.activeSessionId else { return nil }
             let context = PersistenceController.shared.container.viewContext
             guard let session = try? context.fetch(
                 CDBackendSession.fetchBackendSession(id: sessionId)
             ).first else { return nil }
             return (sessionId, session.workingDirectory)
         }) {
        self.voiceInput = voiceInput
        self.voiceOutput = voiceOutput
        self.client = client
        self.settings = settings
        self.resolveActiveSession = resolveActiveSession

        // Track speaking state from VoiceOutputManager
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
                }
            }
            .store(in: &cancellables)

        // Observe headsetModeEnabled setting
        settings.$headsetModeEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                if enabled {
                    self?.activate()
                } else {
                    self?.deactivate()
                }
            }
            .store(in: &cancellables)
    }

    func activate() {
        guard !isActive else { return }
        registerRemoteCommands()
        updateNowPlayingState()
        isActive = true
        logger.info("Headset remote control activated")
    }

    func deactivate() {
        guard isActive else { return }
        unregisterRemoteCommands()
        MPNowPlayingInfoCenter.default().playbackState = .unknown
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        isActive = false
        state = .ready
        logger.info("Headset remote control deactivated")
    }

    // MARK: - MPRemoteCommandCenter

    private func registerRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.handleTogglePlayPause()
            return .success
        }

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            self?.handlePlay()
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            self?.handlePause()
            return .success
        }

        // Next track = stop TTS (long-press MFB on BlueParrott)
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.handleInterrupt()
            return .success
        }

        // Disable commands we don't use so the headset doesn't
        // report phantom capabilities
        center.previousTrackCommand.isEnabled = false
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.changePlaybackRateCommand.isEnabled = false
    }

    private func unregisterRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.removeTarget(nil)
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
    }

    private func updateNowPlayingState() {
        let info: [String: Any]
        let playbackState: MPNowPlayingPlaybackState

        switch state {
        case .ready:
            info = [
                MPMediaItemPropertyTitle: "VoiceCode — Ready",
                MPMediaItemPropertyPlaybackDuration: 0,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: 0
            ]
            playbackState = .paused

        case .recording:
            info = [
                MPMediaItemPropertyTitle: "VoiceCode — Recording",
                MPMediaItemPropertyPlaybackDuration: 0,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: 0
            ]
            playbackState = .playing

        case .sending:
            info = [
                MPMediaItemPropertyTitle: "VoiceCode — Processing",
                MPMediaItemPropertyPlaybackDuration: 0,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: 0
            ]
            playbackState = .paused

        case .speaking:
            info = [
                MPMediaItemPropertyTitle: "VoiceCode — Speaking",
                MPMediaItemPropertyPlaybackDuration: 0,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: 0
            ]
            playbackState = .playing
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = playbackState
    }

    // MARK: - Button Handlers

    private func handleTogglePlayPause() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch self.state {
            case .ready:
                self.startRecording()
            case .recording:
                self.stopRecordingAndSend()
            case .speaking:
                self.handleInterrupt()
            case .sending:
                break // ignore during processing
            }
        }
    }

    private func handlePlay() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.state == .ready {
                self.startRecording()
            }
        }
    }

    private func handlePause() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.state == .recording {
                self.stopRecordingAndSend()
            }
        }
    }

    private func handleInterrupt() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.voiceOutput.stop()
            self.state = .ready
            self.updateNowPlayingState()
            logger.info("Headset interrupt: stopped TTS")
        }
    }

    // MARK: - Recording Lifecycle

    private func startRecording() {
        guard client.isConnected else {
            logger.warning("Headset record ignored: not connected")
            return
        }
        state = .recording
        updateNowPlayingState()
        voiceInput.startRecording()
        logger.info("Headset: recording started")
    }

    private func stopRecordingAndSend() {
        voiceInput.stopRecording()
        state = .sending
        updateNowPlayingState()

        // Defer reading transcribedText by one run-loop tick. stopRecording()
        // calls endAudio() which triggers the final recognition callback on
        // the main queue. Reading synchronously would miss that final result.
        // This matches ConversationVoiceInputView's pattern (line 1405).
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let text = self.voiceInput.transcribedText
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else {
                logger.info("Headset: empty transcription, returning to ready")
                self.state = .ready
                self.updateNowPlayingState()
                return
            }

            if self.settings.headsetAutoSend {
                self.sendToActiveSession(text)
            } else {
                self.state = .ready
                self.updateNowPlayingState()
            }
            logger.info("Headset: recording stopped, text length=\(text.count)")
        }
    }

    /// Send transcription to whichever session the user last had open.
    /// Uses the injected `resolveActiveSession` closure to look up the session
    /// ID and working directory (defaults to ActiveSessionManager + CoreData).
    private func sendToActiveSession(_ text: String) {
        guard let (sessionId, workingDirectory) = resolveActiveSession() else {
            logger.warning("Headset: no active session for auto-send")
            state = .ready
            updateNowPlayingState()
            return
        }

        let sessionIdStr = sessionId.uuidString.lowercased()

        client.sessionSyncManager.createOptimisticMessage(
            sessionId: sessionId,
            text: text
        ) { _ in }

        var message: [String: Any] = [
            "type": "prompt",
            "text": text,
            "resume_session_id": sessionIdStr,
            "working_directory": workingDirectory
        ]

        if !settings.systemPrompt.isEmpty {
            message["system_prompt"] = settings.systemPrompt
        }

        client.sendMessage(message)
        logger.info("Headset: sent prompt to session \(sessionIdStr)")
        // State transitions to .speaking when VoiceOutputManager starts TTS
        // via the existing auto-speak path in SessionSyncManager
    }

    /// Re-register as the now-playing app after another app (e.g. Spotify)
    /// claimed the slot. Call from a menu item or keyboard shortcut.
    func reclaimNowPlaying() {
        guard settings.headsetModeEnabled else { return }
        updateNowPlayingState()
        logger.info("Headset: reclaimed now-playing slot")
    }

    deinit {
        deactivate()
    }
}
#endif
```

#### Component 2: BluetoothAudioMonitor (PTT mute detection)

Monitors the Bluetooth input device's mute property via CoreAudio to detect BlueParrott PTT button presses.

```swift
// ios/VoiceCode/Managers/BluetoothAudioMonitor.swift

#if os(macOS)
import Foundation
import CoreAudio
import os.log

private let logger = Logger(subsystem: "dev.910labs.voice-code", category: "BluetoothAudio")

class BluetoothAudioMonitor {
    private var monitoredDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var onMuteChanged: ((Bool) -> Void)?

    // Property addresses we monitor
    private var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    private var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    func startMonitoring(onMuteChanged: @escaping (Bool) -> Void) {
        self.onMuteChanged = onMuteChanged
        listenForDeviceChanges()
        if let btDevice = findBluetoothInputDevice() {
            startMonitoringDevice(btDevice)
        }
    }

    func stopMonitoring() {
        stopMonitoringCurrentDevice()
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            DispatchQueue.main,
            deviceListListener
        )
        onMuteChanged = nil
    }

    // MARK: - Device Discovery

    private func findBluetoothInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size
        ) == noErr else { return nil }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &devices
        ) == noErr else { return nil }

        for device in devices {
            if isBluetoothDevice(device) && hasInputChannels(device) {
                let name = deviceName(device) ?? "unknown"
                logger.info("Found Bluetooth input device: \(name, privacy: .public) (ID: \(device))")
                return device
            }
        }
        return nil
    }

    private func isBluetoothDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &transport
        ) == noErr else { return false }

        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            deviceID, &address, 0, nil, &size
        ) == noErr, size > 0 else { return false }

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, bufferList
        ) == noErr else { return false }

        return bufferList.pointee.mNumberBuffers > 0
            && bufferList.pointee.mBuffers.mNumberChannels > 0
    }

    private func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &name
        ) == noErr else { return nil }
        return name as String
    }

    // MARK: - Mute Monitoring

    private func startMonitoringDevice(_ deviceID: AudioDeviceID) {
        stopMonitoringCurrentDevice()
        monitoredDeviceID = deviceID

        let status = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &muteAddress,
            DispatchQueue.main,
            muteListener
        )

        if status == noErr {
            let name = deviceName(deviceID) ?? "unknown"
            logger.info("Monitoring mute on: \(name, privacy: .public)")
        } else {
            logger.error("Failed to add mute listener: \(status)")
        }
    }

    private func stopMonitoringCurrentDevice() {
        guard monitoredDeviceID != kAudioObjectUnknown else { return }
        AudioObjectRemovePropertyListenerBlock(
            monitoredDeviceID,
            &muteAddress,
            DispatchQueue.main,
            muteListener
        )
        monitoredDeviceID = kAudioObjectUnknown
    }

    private lazy var muteListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        guard let self = self else { return }
        let muted = self.isMuted(self.monitoredDeviceID)
        logger.info("Bluetooth mute changed: \(muted ? "muted" : "unmuted")")
        self.onMuteChanged?(muted)
    }

    private lazy var deviceListListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        guard let self = self else { return }
        if let btDevice = self.findBluetoothInputDevice() {
            if btDevice != self.monitoredDeviceID {
                self.startMonitoringDevice(btDevice)
            }
        } else {
            self.stopMonitoringCurrentDevice()
            logger.info("Bluetooth input device disconnected")
        }
    }

    private func listenForDeviceChanges() {
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            DispatchQueue.main,
            deviceListListener
        )
    }

    private func isMuted(_ deviceID: AudioDeviceID) -> Bool {
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = muteAddress
        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &muted
        ) == noErr else { return false }
        return muted != 0
    }

    deinit {
        stopMonitoring()
    }
}
#endif
```

#### Component 3: Integration into VoiceCodeApp

Wire `HeadsetRemoteCommandManager` into the app lifecycle. It must live at the `App` level (not inside a view) to persist across window focus changes.

```swift
// VoiceCodeApp.swift — additions

// Add to struct VoiceCodeApp: App (macOS only)
#if os(macOS)
@StateObject private var voiceInput: VoiceInputManager
@StateObject private var headsetManager: HeadsetRemoteCommandManager
#endif

// In init(), after creating voiceManager, voiceClient, settings:
#if os(macOS)
let sharedVoiceInput = VoiceInputManager(voiceOutputManager: voiceManager)
_voiceInput = StateObject(wrappedValue: sharedVoiceInput)
let headset = HeadsetRemoteCommandManager(
    voiceInput: sharedVoiceInput,
    voiceOutput: voiceManager,
    client: voiceClient,
    settings: settings
)
_headsetManager = StateObject(wrappedValue: headset)
#endif

// In .commands { } block, add:
Button("Reclaim Headset") {
    headsetManager.reclaimNowPlaying()
}
.keyboardShortcut("h", modifiers: [.command, .shift])

// Pass shared voiceInput to MenuBarExtra:
VoiceCodeMenuBarExtra(
    client: client,
    settings: settings,
    voiceOutput: voiceOutput,
    voiceInput: voiceInput  // shared instance
)
```

See **Prerequisite: VoiceInputManager Shared Instance** above for the full list of downstream changes to `ConversationView`, `MenuBarContentView`, and `VoiceCodeMenuBarExtra`.

#### Component 4: PTT Support in HeadsetRemoteCommandManager

The following properties and methods are added to `HeadsetRemoteCommandManager` (Component 1) to integrate with `BluetoothAudioMonitor` (Component 2). They are shown separately here because PTT is an optional Phase 2 feature.

```swift
// HeadsetRemoteCommandManager.swift — PTT extension

extension HeadsetRemoteCommandManager {

    // Property: add to the class body alongside existing properties
    // private var bluetoothMonitor: BluetoothAudioMonitor?

    /// Start monitoring Bluetooth input device mute state for PTT.
    /// Called from activate() when settings.headsetPTTEnabled is true.
    func startPTTMonitoring() {
        let monitor = BluetoothAudioMonitor()
        monitor.startMonitoring { [weak self] isMuted in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if !isMuted && self.state == .ready {
                    self.startRecording()
                } else if isMuted && self.state == .recording {
                    self.stopRecordingAndSend()
                }
            }
        }
        self.bluetoothMonitor = monitor
    }

    /// Stop PTT monitoring. Called from deactivate().
    func stopPTTMonitoring() {
        bluetoothMonitor?.stopMonitoring()
        bluetoothMonitor = nil
    }
}
```

**Integration points in `activate()` / `deactivate()`:**

- `activate()`: after `registerRemoteCommands()`, add `if settings.headsetPTTEnabled { startPTTMonitoring() }`
- `deactivate()`: before `isActive = false`, add `stopPTTMonitoring()`

#### Component 5: Settings UI

```swift
// MacSettingsView.swift — new "Headset" tab

struct HeadsetSettingsTab: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var voiceOutput: VoiceOutputManager
    @EnvironmentObject var headsetManager: HeadsetRemoteCommandManager

    var body: some View {
        Form {
            Section("Headset Mode") {
                Toggle("Enable headset control", isOn: $settings.headsetModeEnabled)
                Text("Registers VoiceCode as the active media app so Bluetooth headset buttons control recording.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if settings.headsetModeEnabled {
                    Toggle("Auto-send on recording stop", isOn: $settings.headsetAutoSend)

                    Toggle("PTT button support (CoreAudio mute detection)",
                           isOn: $settings.headsetPTTEnabled)
                    Text("Monitors the Bluetooth input device mute state. Requires the headset's PTT button to be configured as Mute (the default).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if settings.headsetModeEnabled {
                // Warn if voice output is muted — headset mode is silent without TTS
                if voiceOutput.isMuted {
                    Section {
                        Label("Voice output is muted — headset responses will be silent. Unmute with ⌘⇧M.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                    }
                }

                Section("Status") {
                    LabeledContent("State") {
                        Text(headsetManager.state.description)
                    }
                    LabeledContent("Now Playing") {
                        Text(headsetManager.isActive ? "Claimed" : "Not claimed")
                    }
                    Button("Reclaim Now-Playing Slot") {
                        headsetManager.reclaimNowPlaying()
                    }
                    .help("Re-register as the media app if another app (e.g. Spotify) took the slot")
                }
            }
        }
        .formStyle(.grouped)
    }
}
```

### Component Interactions

#### Full Conversation Cycle (MFB play/pause)

```
User presses MFB (play/pause) on headset
    │
    ▼
macOS delivers togglePlayPauseCommand to MPRemoteCommandCenter
    │
    ▼
HeadsetRemoteCommandManager.handleTogglePlayPause()
    │
    ├─ state == .ready → startRecording()
    │   │
    │   ├── state = .recording
    │   ├── updateNowPlayingState() → "VoiceCode — Recording"
    │   └── VoiceInputManager.startRecording()
    │       └── AVAudioEngine captures from Bluetooth mic
    │           └── SFSpeechRecognizer transcribes
    │
    ├─ state == .recording → stopRecordingAndSend()
    │   │
    │   ├── VoiceInputManager.stopRecording()
    │   ├── text = voiceInput.transcribedText
    │   ├── state = .sending
    │   ├── updateNowPlayingState() → "VoiceCode — Processing"
    │   └── sendToActiveSession(text)
    │       ├── client.sessionSyncManager.createOptimisticMessage(...)
    │       └── client.sendMessage({type: "prompt", resume_session_id: ..., text: ...})
    │
    │           [backend processes turn]
    │
    │       SessionSyncManager receives session_history with assistant message
    │       └── line 598-613: auto-speak for active session
    │           └── VoiceOutputManager.speak(processedText, ...)
    │
    │       HeadsetRemoteCommandManager observes voiceOutput.$isSpeaking
    │       └── state = .speaking
    │       └── updateNowPlayingState() → "VoiceCode — Speaking"
    │
    │           [TTS plays through headset speakers]
    │
    │       VoiceOutputManager.isSpeaking → false
    │       └── state = .ready
    │       └── updateNowPlayingState() → "VoiceCode — Ready"
    │
    └─ state == .speaking → handleInterrupt()
        ├── voiceOutput.stop()
        ├── state = .ready
        └── updateNowPlayingState() → "VoiceCode — Ready"
```

#### PTT Button Cycle

```
User holds PTT button (BlueParrott mute = OFF)
    │
    ▼
CoreAudio fires kAudioDevicePropertyMute change (value: 0 = unmuted)
    │
    ▼
BluetoothAudioMonitor.muteListener → onMuteChanged(false)
    │
    ▼
HeadsetRemoteCommandManager: state == .ready → startRecording()

    [user speaks]

User releases PTT button (BlueParrott mute = ON)
    │
    ▼
CoreAudio fires kAudioDevicePropertyMute change (value: 1 = muted)
    │
    ▼
BluetoothAudioMonitor.muteListener → onMuteChanged(true)
    │
    ▼
HeadsetRemoteCommandManager: state == .recording → stopRecordingAndSend()
    [same flow as MFB from here]
```

#### Dependencies

```
VoiceCodeApp
    ├── HeadsetRemoteCommandManager (new)
    │   ├── VoiceInputManager (existing, hoisted to App level)
    │   ├── VoiceOutputManager (existing)
    │   ├── VoiceCodeClient (existing)
    │   ├── AppSettings (existing)
    │   ├── ActiveSessionManager (existing)
    │   └── BluetoothAudioMonitor (new, optional)
    └── ...existing managers
```

**New framework imports required:** `MediaPlayer` (for `MPRemoteCommandCenter` / `MPNowPlayingInfoCenter`) and `CoreAudio` (for `AudioObject*` device property monitoring). Neither is currently imported in the Mac app. Both are system frameworks that auto-link on import — no `project.yml` changes needed. No additional sandbox entitlements required; the existing `com.apple.security.device.audio-input` covers CoreAudio device property access.

## Verification Strategy

### Testing Approach

#### Unit Tests

All headset tests belong in the **`VoiceCodeMacTests`** target (`project.yml` line 202), which shares sources from `VoiceCodeTests/` but excludes iOS-specific tests. Add new test files to `VoiceCodeTests/` and exclude them from the iOS `VoiceCodeTests` target if they contain `#if os(macOS)` code that won't compile on iOS.

1. **HeadsetRemoteCommandManager state machine** — verify state transitions for every button×state combination
2. **BluetoothAudioMonitor device detection** — verify `isBluetoothDevice` and `hasInputChannels` with mock device IDs (requires CoreAudio test fixtures or protocol abstraction)
3. **Auto-send logic** — verify that `sendToActiveSession` constructs the correct message shape (including `working_directory`) and handles edge cases (no active session, empty transcription, disconnected client, session not found in CoreData)

#### Integration Tests

1. **MPRemoteCommandCenter registration** — verify that `activate()` registers handlers and `deactivate()` removes them cleanly without leaking
2. **VoiceInputManager coordination** — verify that `startRecording()` / `stopRecording()` calls via the headset manager produce the same transcription lifecycle as direct calls
3. **Now-playing contention** — verify `reclaimNowPlaying()` re-establishes the now-playing info after another app claims it

#### End-to-End Tests (Manual, with hardware)

1. Pair BlueParrott B450-XT with Mac
2. Enable headset mode in settings
3. Press MFB → verify recording starts (check VoiceInputManager.isRecording)
4. Speak a phrase → verify partial transcription appears
5. Press MFB → verify recording stops and prompt is sent to active session
6. Wait for AI response → verify TTS plays through headset speakers
7. During TTS, press MFB → verify TTS stops (interrupt)
8. Verify MFB still works when VoiceCode is not the frontmost app
9. Open Spotify, play a song → verify headset buttons route to Spotify
10. Click "Reclaim Headset" in VoiceCode → verify buttons route back to VoiceCode
11. Configure PTT to Mute/momentary in BlueParrott app → hold PTT → verify recording → release → verify send

### Testability Design

`HeadsetRemoteCommandManager`'s button handlers are `private` because they're called from `MPRemoteCommandCenter` callbacks. The handlers dispatch to `DispatchQueue.main.async` because `MPRemoteCommandCenter` calls targets on a system-provided queue. For unit testing, expose `internal` simulation methods behind `#if DEBUG` that call the underlying logic **synchronously** (bypassing the async dispatch), since tests already run on the main thread:

```swift
// HeadsetRemoteCommandManager.swift — test hooks

#if DEBUG
/// Simulate headset button presses for unit tests.
/// These bypass the DispatchQueue.main.async wrapper in the real handlers
/// so tests can assert state changes synchronously. Tests already run on
/// the main thread, so the async dispatch is unnecessary in that context.
func simulateTogglePlayPause() {
    switch state {
    case .ready:
        startRecording()
    case .recording:
        stopRecordingAndSend()
    case .speaking:
        voiceOutput.stop()
        state = .ready
        updateNowPlayingState()
    case .sending:
        break
    }
}
func simulatePlay() {
    if state == .ready { startRecording() }
}
func simulatePause() {
    if state == .recording { stopRecordingAndSend() }
}
func simulateInterrupt() {
    voiceOutput.stop()
    state = .ready
    updateNowPlayingState()
}

/// Simulate PTT mute state change for unit tests (synchronous).
func simulateMuteChanged(isMuted: Bool) {
    if !isMuted && state == .ready {
        startRecording()
    } else if isMuted && state == .recording {
        stopRecordingAndSend()
    }
}
#endif
```

Tests go in `VoiceCodeMacTests` target (the macOS-specific test target in `project.yml`, line 202).

### Test Examples

```swift
// VoiceCodeTests/HeadsetRemoteCommandManagerTests.swift
// (Included in VoiceCodeMacTests target, excluded from VoiceCodeTests iOS target)

import XCTest
@testable import VoiceCode

// MARK: - Mock Dependencies

class MockVoiceInputManager: VoiceInputManager {
    var startRecordingCalled = false
    var stopRecordingCalled = false

    override func startRecording() {
        startRecordingCalled = true
        DispatchQueue.main.async { self.isRecording = true }
    }

    override func stopRecording() {
        stopRecordingCalled = true
        DispatchQueue.main.async { self.isRecording = false }
    }
}

class MockVoiceOutputManager: VoiceOutputManager {
    var stopCalled = false

    override func stop() {
        stopCalled = true
        DispatchQueue.main.async { self.isSpeaking = false }
    }
}

class MockVoiceCodeClient: VoiceCodeClient {
    var lastSentMessage: [String: Any]?

    override func sendMessage(_ message: [String: Any]) {
        lastSentMessage = message
    }
}

struct MockDependencies {
    let voiceInput = MockVoiceInputManager()
    let voiceOutput = MockVoiceOutputManager()
    let client: MockVoiceCodeClient
    let settings = AppSettings()

    init() {
        client = MockVoiceCodeClient(
            serverURL: "ws://localhost:8080",
            voiceOutputManager: voiceOutput,
            appSettings: settings,
            setupObservers: false
        )
        client.isConnected = true
    }
}

// MARK: - Tests

final class HeadsetRemoteCommandManagerTests: XCTestCase {

    // MARK: - State Machine

    func testTogglePlayPause_fromReady_startsRecording() {
        let (manager, mocks) = makeManager()
        manager.activate()
        XCTAssertEqual(manager.state, .ready)

        manager.simulateTogglePlayPause()

        XCTAssertEqual(manager.state, .recording)
        XCTAssertTrue(mocks.voiceInput.startRecordingCalled)
    }

    func testTogglePlayPause_fromRecording_stopsAndSends() {
        let (manager, mocks) = makeManager()
        manager.activate()
        manager.simulateTogglePlayPause() // → .recording
        mocks.voiceInput.transcribedText = "test prompt"

        manager.simulateTogglePlayPause() // → .sending

        // stopRecordingAndSend defers text read to next run-loop tick
        let expectation = expectation(description: "async send")
        DispatchQueue.main.async {
            XCTAssertTrue(mocks.voiceInput.stopRecordingCalled)
            XCTAssertEqual(mocks.client.lastSentMessage?["text"] as? String, "test prompt")
            XCTAssertEqual(mocks.client.lastSentMessage?["working_directory"] as? String, "/test/working-dir")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testTogglePlayPause_fromSpeaking_interrupts() {
        let (manager, mocks) = makeManager()
        manager.activate()
        manager.simulateTogglePlayPause() // ready → recording
        mocks.voiceInput.transcribedText = "trigger send"
        manager.simulateTogglePlayPause() // recording → sending
        XCTAssertEqual(manager.state, .sending)

        // Simulate TTS starting — set isSpeaking and wait for Combine sink
        mocks.voiceOutput.isSpeaking = true
        let transitionExpectation = expectation(description: "sending → speaking")
        DispatchQueue.main.async {
            XCTAssertEqual(manager.state, .speaking)
            transitionExpectation.fulfill()
        }
        wait(for: [transitionExpectation], timeout: 1.0)

        // Now interrupt
        manager.simulateTogglePlayPause() // speaking → interrupt
        XCTAssertEqual(manager.state, .ready)
        XCTAssertTrue(mocks.voiceOutput.stopCalled)
    }

    func testEmptyTranscription_returnsToReady() {
        let (manager, mocks) = makeManager()
        manager.activate()
        manager.simulateTogglePlayPause() // → .recording
        mocks.voiceInput.transcribedText = "   " // whitespace only

        manager.simulateTogglePlayPause()

        let expectation = expectation(description: "async check")
        DispatchQueue.main.async {
            XCTAssertEqual(manager.state, .ready)
            XCTAssertNil(mocks.client.lastSentMessage)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testDisconnectedClient_doesNotStartRecording() {
        let (manager, mocks) = makeManager()
        mocks.client.isConnected = false
        manager.activate()

        manager.simulateTogglePlayPause()

        XCTAssertEqual(manager.state, .ready)
        XCTAssertFalse(mocks.voiceInput.startRecordingCalled)
    }

    func testNoActiveSession_returnsToReady() {
        let mocks = MockDependencies()
        let manager = HeadsetRemoteCommandManager(
            voiceInput: mocks.voiceInput,
            voiceOutput: mocks.voiceOutput,
            client: mocks.client,
            settings: mocks.settings,
            resolveActiveSession: { nil }
        )
        manager.activate()
        manager.simulateTogglePlayPause() // → .recording
        mocks.voiceInput.transcribedText = "orphaned prompt"

        manager.simulateTogglePlayPause() // → .sending → no session → .ready

        let expectation = expectation(description: "async fallback")
        DispatchQueue.main.async {
            XCTAssertEqual(manager.state, .ready)
            XCTAssertNil(mocks.client.lastSentMessage)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - PTT Mute Detection

    func testMuteOff_fromReady_startsRecording() {
        let (manager, _) = makeManager()
        manager.activate()

        manager.simulateMuteChanged(isMuted: false)

        XCTAssertEqual(manager.state, .recording)
    }

    func testMuteOn_fromRecording_stopsAndSends() {
        let (manager, mocks) = makeManager()
        manager.activate()
        manager.simulateMuteChanged(isMuted: false) // → .recording
        mocks.voiceInput.transcribedText = "ptt test"

        manager.simulateMuteChanged(isMuted: true) // → .sending

        // stopRecordingAndSend defers text read to next run-loop tick
        let expectation = expectation(description: "async send")
        DispatchQueue.main.async {
            XCTAssertEqual(mocks.client.lastSentMessage?["text"] as? String, "ptt test")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Helpers

    private let testSessionId = UUID()

    private func makeManager() -> (HeadsetRemoteCommandManager, MockDependencies) {
        let mocks = MockDependencies()
        let sessionId = testSessionId
        let manager = HeadsetRemoteCommandManager(
            voiceInput: mocks.voiceInput,
            voiceOutput: mocks.voiceOutput,
            client: mocks.client,
            settings: mocks.settings,
            resolveActiveSession: { (sessionId, "/test/working-dir") }
        )
        return (manager, mocks)
    }
}
```

### Acceptance Criteria

1. With headset mode enabled, pressing MFB play/pause on a connected Bluetooth headset starts voice recording — regardless of which app is frontmost
2. Pressing MFB again stops recording and sends the transcription to the active session
3. The AI response is automatically spoken through the headset (existing auto-speak path)
4. Pressing MFB during TTS playback stops TTS immediately
5. Now-playing info updates to reflect current state (Ready / Recording / Processing / Speaking)
6. "Reclaim Headset" (Cmd+Shift+H) re-registers as the now-playing app after another app takes the slot
7. With PTT mode enabled, holding the BlueParrott PTT button (mute off) starts recording; releasing (mute on) stops and sends
8. Headset mode can be toggled on/off in Settings without restarting the app
9. When headset mode is disabled, the app does not claim the now-playing slot
10. Empty transcriptions (silence, whitespace) do not send a prompt
11. When not connected to the backend, headset button presses are ignored with a log message
12. When no session is active, recording stop does not crash — returns to ready state

## Alternatives Considered

### 1. NSEvent.addGlobalMonitorForEvents for media keys

**Approach:** Monitor system-level key events for `NX_KEYTYPE_PLAY` and `NX_KEYTYPE_NEXT` via `NSEvent.addGlobalMonitorForEvents(matching: .systemDefined)`.

**Why rejected:** This API can only observe events, not consume them — the media key would still be delivered to whatever app macOS considers the "now playing" app. If Spotify is active, both Spotify and VoiceCode would respond. `MPRemoteCommandCenter` is the sanctioned way to claim media key ownership, and it's the only approach that works cleanly when the app is not frontmost.

### 2. IOKit HID for BlueParrott Custom Button mode

**Approach:** Configure the PTT button to "Custom Button" mode in the BlueParrott app, which sends a vendor-specific HID report on usage page 0xFF00. Capture it via `IOKit` HID API (`IOHIDManager`).

**Why rejected:** Sandboxed apps cannot create `IOHIDManager` instances for arbitrary HID devices without the `com.apple.security.device.usb` entitlement, which Apple does not grant for Mac App Store distribution. Even for Developer ID distribution, it adds unnecessary complexity compared to the CoreAudio mute-property approach, which works in-sandbox with the existing audio-input entitlement.

### 3. Separate headset companion daemon

**Approach:** Build a small, unsandboxed helper tool that monitors HID events and communicates with the sandboxed VoiceCode app via XPC or local socket.

**Why rejected:** Dramatically increases complexity (two processes, IPC, installation, lifecycle management) for marginal gain. The CoreAudio + MPRemoteCommandCenter approach covers the same use cases within the sandbox.

### 4. AudioUnit for output routing

**Approach:** Replace `AVSpeechSynthesizer` with an `AVAudioEngine` + `AVSpeechSynthesizer` pipeline to gain explicit output device selection.

**Why deferred (not rejected):** `AVSpeechSynthesizer` on macOS outputs to the system default audio device. If the user's default output is their Mac speakers rather than the headset, TTS won't play through the headset. However, this is a one-time System Settings change, and the complexity of wiring `AVSpeechSynthesizer` through `AVAudioEngine` with a specific output device is significant. Document the requirement (set headset as default output) rather than building automatic routing for v1.

## Risks & Mitigations

### Now-Playing Slot Contention

**Risk:** Another app (Spotify, Apple Music, podcast player) claims the now-playing slot, and headset buttons stop routing to VoiceCode.

**Detection:** Observe `MPNowPlayingInfoCenter` state changes. When the now-playing info no longer matches what we set, another app has claimed it.

**Mitigation:** "Reclaim Headset" menu item + keyboard shortcut (`Cmd+Shift+H`). Also consider auto-reclaim when VoiceCode detects it lost the slot and the user has headset mode enabled — but this could fight with legitimate media playback, so make it opt-in.

### Bluetooth Disconnection Mid-Recording

**Risk:** The headset goes out of range or powers off while recording. `AVAudioEngine` may throw or produce silence.

**Detection:** CoreAudio device removal notification (`kAudioHardwarePropertyDevices` listener in `BluetoothAudioMonitor`). Also `AVAudioEngine` input node errors.

**Mitigation:** On device removal, stop recording gracefully, discard partial transcription, transition to `.ready` state, show a brief notification. Do not send partial/garbage transcription.

### Mac Sleep

**Risk:** The Mac sleeps while the user is away from the desk, dropping the Bluetooth connection and stopping all processing.

**Detection:** N/A — system sleep is outside app control.

**Mitigation:** Document that the user should configure their Mac to stay awake (Energy Saver settings or `caffeinate`). Do not attempt to prevent sleep from within the sandboxed app.

### SFSpeechRecognizer Over Bluetooth Audio Quality

**Risk:** Bluetooth HFP/SCO codec is 8kHz mono. Speech recognition accuracy may degrade compared to the built-in mic.

**Detection:** Monitor transcription error rates or empty results during headset use.

**Mitigation:** `SFSpeechRecognizer` is designed to handle telephony-quality audio. If accuracy is poor, the user can switch the Mac's input to the built-in mic while keeping output on the headset — this is a System Settings change, not an app change.

### VoiceOutputManager Mute State Interaction

**Risk:** The existing auto-speak path (`SessionSyncManager.swift:612`) calls `speak(processedText, respectSilentMode: true, ...)`. On macOS, `VoiceOutputManager` has a persistent `isMuted` property (`UserDefaults "voiceOutputMuted"`) toggled via `Cmd+Shift+M`. When muted, all `speak()` calls are silently dropped (`VoiceOutputManager.swift:198-202`). If the user has muted voice output, headset mode completes the recording→send cycle but the response is never spoken — and there's no audible feedback that anything happened.

**Detection:** In `HeadsetRemoteCommandManager`, if state transitions from `.sending` but `voiceOutput.isSpeaking` never becomes true within a reasonable window (~5 seconds after `turn_complete`), the response was likely muted.

**Mitigation:** When activating headset mode, check `voiceOutput.isMuted` and warn in the settings UI: "Voice output is muted — headset responses will be silent. Unmute with ⌘⇧M." Do not auto-unmute (respects the user's choice). Alternatively, `HeadsetRemoteCommandManager.activate()` could force-unmute with a log message, but this is a behavioral decision for implementation time.

### Rollback Strategy

All new code is behind the `headsetModeEnabled` setting (default: false). If headset mode causes issues, toggling it off immediately stops all `MPRemoteCommandCenter` and CoreAudio monitoring. No migrations to roll back, no protocol changes to version.
